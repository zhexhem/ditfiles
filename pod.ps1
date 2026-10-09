#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstraps containerisation and virtualisation tooling on Windows.

.DESCRIPTION
    Installs and verifies the three tools most commonly used to run containers
    and virtual machines on Windows:

        Docker   ->  Docker Desktop (WSL2 backend by default)
        Podman   ->  Podman CLI + Podman Desktop (daemonless, WSL2 machine)
        Virt     ->  Oracle VirtualBox (Type-2 hypervisor for full VMs)

    The script performs preflight checks first, because all three tools have
    hard prerequisites that fail opaquely when missing:

        * CPU virtualisation must be enabled in BIOS/UEFI.
        * WSL2 is required by Docker Desktop and by Podman's machine backend.
        * VirtualBox cannot run alongside Hyper-V's hypervisor; when Hyper-V is
          present the script warns and offers to disable it.

    The script is idempotent: anything already present is skipped, so it is
    safe to re-run after adding a tool or bumping a version.

.PARAMETER SkipDocker
    Do not install Docker Desktop.

.PARAMETER SkipPodman
    Do not install Podman (CLI) or Podman Desktop.

.PARAMETER SkipVirtualBox
    Do not install Oracle VirtualBox.

.PARAMETER SkipWsl
    Do not enable the WSL2 Windows features.  Use this when WSL is managed by
    Group Policy or is already provisioned.

.PARAMETER SkipPreflight
    Skip the hardware-virtualisation and Hyper-V checks.  Only useful in
    throwaway CI images.

.PARAMETER DisableHyperV
    When Hyper-V is detected, disable the Hyper-V hypervisor so VirtualBox can
    run.  This requires a reboot and will break Docker Desktop's Hyper-V backend
    (the WSL2 backend is unaffected).  Without this switch the script only warns.

.PARAMETER Force
    Re-run installers even when the tool is already present.

.EXAMPLE
    ./pod.ps1
    Install Docker, Podman and VirtualBox with defaults.

.EXAMPLE
    ./pod.ps1 -WhatIf
    Show the full plan without changing anything.

.EXAMPLE
    ./pod.ps1 -SkipVirtualBox
    Containers only; no full-VM hypervisor.

.EXAMPLE
    ./pod.ps1 -DisableHyperV
    Allow VirtualBox to run by turning off the Hyper-V hypervisor.

.EXAMPLE
    ./pod.ps1 -SkipWsl -SkipPreflight
    Assume WSL and BIOS virtualisation are already handled.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [switch] $SkipDocker,
    [switch] $SkipPodman,
    [switch] $SkipVirtualBox,
    [switch] $SkipWsl,
    [switch] $SkipPreflight,
    [switch] $DisableHyperV,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

$script:StepCount = 0

function Write-Step {
    param([string] $Message)
    $script:StepCount++
    Write-Host ''
    Write-Host ('  [{0}] {1}' -f $script:StepCount, $Message) -ForegroundColor White
}

function Write-Ok    { param([string]$m) Write-Host ('      + {0}' -f $m) -ForegroundColor Green }
function Write-Skip  { param([string]$m) Write-Host ('      = {0}' -f $m) -ForegroundColor DarkGray }
function Write-Warn2 { param([string]$m) Write-Host ('      ! {0}' -f $m) -ForegroundColor Yellow }

function Write-Result {
    param([string]$Text, [string]$Status)

    $colour = switch ($Status) {
        'installed' { 'Green' }
        'updated'   { 'Green' }
        'present'   { 'DarkGray' }
        'skipped'   { 'DarkGray' }
        'failed'    { 'Red' }
        'warning'   { 'Yellow' }
        default     { 'Gray' }
    }

    Write-Host ('  {0,-10}' -f $Status) -ForegroundColor $colour -NoNewline
    Write-Host $Text
}

# ---------------------------------------------------------------------------
# Process helpers
# ---------------------------------------------------------------------------

function Test-Command {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)] [string] $Name)

    return [bool] (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Get-CommandVersion {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string[]] $Arguments = @('--version')
    )

    if (-not (Test-Command $Name)) { return $null }

    try {
        $output = & $Name @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        return @($output | Where-Object { $_ -and "$_".Trim() } | Select-Object -First 1)
    }
    catch {
        return $null
    }
}

function Invoke-External {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [switch] $IgnoreExitCode
    )

    $display = '{0} {1}' -f $FilePath, ($Arguments -join ' ')

    if (-not $PSCmdlet.ShouldProcess($display, 'run')) { return }

    Write-Verbose "> $display"

    & $FilePath @Arguments
    $code = $LASTEXITCODE

    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "'$display' exited with code $code."
    }
}

function Test-WingetAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-Command 'winget')) { return $false }

    try {
        $null = & winget --version 2>&1
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Install-WingetPackage {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Id,
        [string] $Label = $Id,
        [switch] $Force
    )

    if (-not (Test-WingetAvailable)) {
        Write-Warn2 "winget is not available; cannot install $Label."
        return 'failed'
    }

    if (-not $Force) {
        $listed = & winget list --id $Id --exact --accept-source-agreements 2>&1
        if ($LASTEXITCODE -eq 0 -and ($listed -join "`n") -match [regex]::Escape($Id)) {
            Write-Skip "$Label already installed."
            return 'present'
        }
    }

    $wingetArgs = @(
        'install', '--id', $Id, '--exact',
        '--accept-source-agreements', '--accept-package-agreements',
        '--silent'
    )

    try {
        Invoke-External -FilePath 'winget' -Arguments $wingetArgs
        Write-Ok "$Label installed."
        return 'installed'
    }
    catch {
        Write-Warn2 "$Label failed: $($_.Exception.Message)"
        return 'failed'
    }
}

# ---------------------------------------------------------------------------
# PATH refresh
# ---------------------------------------------------------------------------

function Update-SessionPath {
    [CmdletBinding()]
    param()

    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')

    $combined = @($machine, $user) |
                Where-Object { $_ } |
                ForEach-Object { $_.TrimEnd(';') } |
                -join ';'

    $env:Path = $combined
}

# ---------------------------------------------------------------------------
# Preflight: hardware virtualisation
# ---------------------------------------------------------------------------

function Test-HardwareVirtualization {
    <#
        Returns $true when the CPU exposes virtualisation extensions to the OS.
        HyperVisorPresent reflects whether the firmware actually handed them
        over, which is what all three tools need.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $info = Get-ComputerInfo -Property HyperVRequirementVirtualizationFirmwareEnabled,
                                          HyperVisorPresent -ErrorAction Stop

        # Older builds only expose one of the two; accept either signal.
        if ($null -ne $info.HyperVRequirementVirtualizationFirmwareEnabled) {
            return [bool] $info.HyperVRequirementVirtualizationFirmwareEnabled
        }

        return [bool] $info.HyperVisorPresent
    }
    catch {
        Write-Verbose "Get-ComputerInfo failed: $($_.Exception.Message)"
        return $null  # Unknown, not necessarily false.
    }
}

function Test-HyperVPresent {
    <#
        True when the Hyper-V hypervisor is running.  This blocks VirtualBox
        from using hardware virtualisation.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $info = Get-ComputerInfo -Property HyperVisorPresent -ErrorAction Stop
        return [bool] $info.HyperVisorPresent
    }
    catch {
        # Fall back to the service, which is authoritative enough here.
        $svc = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
        return ($svc -and $svc.Status -eq 'Running')
    }
}

# ---------------------------------------------------------------------------
# Preflight: WSL2
# ---------------------------------------------------------------------------

function Test-WslInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-Command 'wsl')) { return $false }

    try {
        $output = & wsl --status 2>&1
        # wsl --status exits 0 even when no distro is installed, as long as
        # the feature itself is present.
        return ($LASTEXITCODE -eq 0) -and (($output -join "`n") -notmatch 'not installed')
    }
    catch {
        return $false
    }
}

function Test-Wsl2Default {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    if (-not (Test-Command 'wsl')) { return $false }

    try {
        $output = & wsl --status 2>&1
        return ($output -join "`n") -match 'Default Version:\s*2'
    }
    catch {
        return $false
    }
}

function Enable-WslFeatures {
    <#
        Enables the two Windows optional features WSL2 needs.  Both are DISM
        operations and require an elevated shell.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $features = @(
        'Microsoft-Windows-Subsystem-Linux',
        'VirtualMachinePlatform'
    )

    # Check first so a re-run is a no-op.
    $allEnabled = $true
    foreach ($feature in $features) {
        $state = (Get-WindowsOptionalFeature -Online -FeatureName $feature -ErrorAction SilentlyContinue).State
        if ($state -ne 'Enabled') { $allEnabled = $false; break }
    }

    if ($allEnabled) {
        Write-Skip 'WSL2 Windows features already enabled.'
        return 'present'
    }

    if (-not $PSCmdlet.ShouldProcess('WSL2 features', 'enable via DISM (requires admin + reboot)')) {
        return 'skipped'
    }

    try {
        foreach ($feature in $features) {
            Invoke-External -FilePath 'dism.exe' -Arguments @(
                '/online', '/enable-feature',
                "/featurename:$feature",
                '/all', '/norestart'
            ) -IgnoreExitCode
        }

        Write-Ok 'WSL2 features enabled. A reboot is required before containers will run.'
        return 'installed'
    }
    catch {
        Write-Warn2 "Could not enable WSL2 features: $($_.Exception.Message)"
        Write-Warn2 'Run this script from an elevated PowerShell prompt.'
        return 'failed'
    }
}

function Initialize-Wsl2 {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if (Test-WslInstalled) {
        if (Test-Wsl2Default) {
            Write-Skip 'WSL2 is installed and is the default version.'
        }
        else {
            Write-Host '      Setting WSL default version to 2...' -ForegroundColor Gray
            Invoke-External -FilePath 'wsl' -Arguments @('--set-default-version', '2') -IgnoreExitCode
            Write-Ok 'WSL default version set to 2.'
        }

        # Keep the kernel current; Docker and Podman both care about this.
        Invoke-External -FilePath 'wsl' -Arguments @('--update') -IgnoreExitCode
        return 'present'
    }

    # The modern one-shot installer handles feature enablement, kernel
    # download and default-version selection.
    try {
        Invoke-External -FilePath 'wsl' -Arguments @('--install', '--no-distribution') -IgnoreExitCode
        Write-Ok 'WSL2 installed (no distribution).'
        return 'installed'
    }
    catch {
        Write-Warn2 "wsl --install failed: $($_.Exception.Message)"
        return 'failed'
    }
}

# ---------------------------------------------------------------------------
# Docker Desktop
# ---------------------------------------------------------------------------

function Install-DockerDesktop {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch] $Force)

    $docker = Get-CommandVersion -Name 'docker' -Arguments @('--version')

    if ($docker -and -not $Force) {
        Write-Skip "Docker already installed ($docker)."
        return 'present'
    }

    # WSL2 is the default and recommended backend.  Warn rather than fail:
    # a Hyper-V backend install is still valid.
    if (-not (Test-WslInstalled)) {
        Write-Warn2 'WSL2 not detected. Docker Desktop will need the Hyper-V backend,'
        Write-Warn2 'or you can re-run this script after WSL2 is available.'
    }

    # Docker.DockerDesktop is the stable channel; Docker.DockerDesktopEdge is
    # the pre-release.  Stable is the right default for a dev box.
    $status = Install-WingetPackage -Id 'Docker.DockerDesktop' -Label 'Docker Desktop' -Force:$Force
    if ($status -eq 'failed') { return 'failed' }

    Update-SessionPath

    # Docker Desktop ships its own CLI shim; the docker command appears once
    # the app has been started at least once.
    $docker = Get-CommandVersion -Name 'docker' -Arguments @('--version')
    if ($docker) {
        Write-Ok "docker ready ($docker)."
    }
    else {
        Write-Warn2 'Docker Desktop installed. Start it once from the Start menu to finish setup.'
    }

    return $status
}

# ---------------------------------------------------------------------------
# Podman
# ---------------------------------------------------------------------------

function Install-Podman {
    [CmdletBinding()]
    [OutputType([string])]
    param([switch] $Force)

    $podman = Get-CommandVersion -Name 'podman' -Arguments @('--version')

    if ($podman -and -not $Force) {
        Write-Skip "Podman already installed ($podman)."
    }
    else {
        # RedHat.Podman is the CLI/engine; RedHat.Podman-Desktop is the GUI.
        # Install both, engine first so Desktop finds it during setup.
        $engine = Install-WingetPackage -Id 'RedHat.Podman' -Label 'Podman' -Force:$Force
        if ($engine -eq 'failed') { return 'failed' }

        $null = Install-WingetPackage -Id 'RedHat.Podman-Desktop' -Label 'Podman Desktop' -Force:$Force
        Update-SessionPath
    }

    # --- WSL machine ------------------------------------------------------
    # Podman on Windows runs containers inside a WSL2-backed Fedora machine.
    # Without `podman machine init` the CLI installs but cannot run anything.
    if (-not (Test-WslInstalled)) {
        Write-Warn2 'WSL2 not available; skipping podman machine init.'
        Write-Warn2 'Re-run this script after WSL2 is ready.'
        return 'warning'
    }

    $machines = & podman machine list --format '{{.Name}}' 2>&1
    $hasMachine = ($LASTEXITCODE -eq 0) -and (($machines | Where-Object { $_ -and "$_".Trim() }) -as [array]).Count -gt 0

    if ($hasMachine -and -not $Force) {
        Write-Skip 'Podman machine already initialised.'
    }
    else {
        Write-Host '      Initialising the Podman WSL2 machine...' -ForegroundColor Gray
        try {
            Invoke-External -FilePath 'podman' -Arguments @(
                'machine', 'init',
                '--provider', 'wsl',
                '--cpus', '2',
                '--memory', '2048',
                '--disk-size', '20'
            )
            Write-Ok 'Podman machine initialised.'
        }
        catch {
            Write-Warn2 "podman machine init failed: $($_.Exception.Message)"
            return 'failed'
        }
    }

    # Start it so the socket exists and `podman run` works immediately.
    $running = & podman machine list --format '{{.Running}}' 2>&1
    if (-not (($running -join "`n") -match 'true')) {
        Invoke-External -FilePath 'podman' -Arguments @('machine', 'start') -IgnoreExitCode
    }

    $podman = Get-CommandVersion -Name 'podman' -Arguments @('--version')
    if ($podman) { Write-Ok "podman ready ($podman)." }

    return 'installed'
}

# ---------------------------------------------------------------------------
# VirtualBox
# ---------------------------------------------------------------------------

function Install-VirtualBox {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch] $Force,
        [switch] $DisableHyperV
    )

    $vbox = Get-CommandVersion -Name 'VBoxManage' -Arguments @('--version')

    if ($vbox -and -not $Force) {
        Write-Skip "VirtualBox already installed ($vbox)."
        return 'present'
    }

    # --- Hyper-V conflict -------------------------------------------------
    # VirtualBox is a Type-2 hypervisor and cannot use hardware virtualisation
    # while Microsoft's hypervisor is running.
    if (Test-HyperVPresent) {
        Write-Warn2 'Hyper-V is running; VirtualBox will not be able to use hardware virtualisation.'

        if ($DisableHyperV) {
            $targets = @('Microsoft-Hyper-V-All', 'VirtualMachinePlatform', 'HypervisorPlatform')

            if ($PSCmdlet.ShouldProcess('Hyper-V hypervisor', 'disable via bcdedit (requires reboot)')) {
                # bcdedit is the switch that actually releases the CPU, even
                # when the optional feature remains nominally installed.
                Invoke-External -FilePath 'bcdedit.exe' -Arguments @('/set', 'hypervisorlaunchtype', 'off') -IgnoreExitCode

                foreach ($feature in $targets) {
                    Invoke-External -FilePath 'dism.exe' -Arguments @(
                        '/online', '/disable-feature',
                        "/featurename:$feature",
                        '/norestart'
                    ) -IgnoreExitCode
                }

                Write-Ok 'Hyper-V hypervisor disabled. Reboot before using VirtualBox.'
            }
        }
        else {
            Write-Warn2 'Pass -DisableHyperV to turn it off, or expect slow software-emulated VMs.'
        }
    }

    # VirtualBox installs machine-scope and needs elevation for its drivers.
    $status = Install-WingetPackage -Id 'Oracle.VirtualBox' -Label 'Oracle VirtualBox' -Force:$Force
    if ($status -eq 'failed') { return 'failed' }

    Update-SessionPath

    # VBoxManage lives in the install dir, which is not always on PATH yet.
    if (-not (Test-Command 'VBoxManage')) {
        $candidate = Join-Path ${env:ProgramFiles} 'Oracle\VirtualBox'
        if (Test-Path -LiteralPath $candidate) {
            $env:Path = "$candidate;$env:Path"
        }
    }

    $vbox = Get-CommandVersion -Name 'VBoxManage' -Arguments @('--version')
    if ($vbox) {
        Write-Ok "VirtualBox ready ($vbox)."

        # Extension Pack is a separate download and must match the version
        # exactly, so we point the user at it rather than guessing a URL.
        Write-Host '      Download the matching Extension Pack from:' -ForegroundColor DarkGray
        Write-Host ('        https://download.virtualbox.org/virtualbox/{0}/' -f $vbox) -ForegroundColor DarkGray
    }
    else {
        Write-Warn2 'VirtualBox installed but VBoxManage is not on PATH yet. Open a new terminal.'
    }

    return $status
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  Windows container & VM bootstrap' -ForegroundColor White
Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray

$results = [ordered]@{}

# --- preflight ------------------------------------------------------------
if (-not $SkipPreflight) {
    Write-Step 'Preflight checks'

    $hv = Test-HardwareVirtualization
    if ($hv -eq $true) {
        Write-Ok 'Hardware virtualisation is enabled.'
    }
    elseif ($hv -eq $false) {
        Write-Warn2 'Hardware virtualisation is DISABLED in firmware.'
        Write-Warn2 'Enable Intel VT-x / AMD-V in BIOS/UEFI, then re-run.'
        $results['Preflight'] = 'warning'
    }
    else {
        Write-Skip 'Virtualisation status could not be determined; continuing.'
    }

    if (Test-HyperVPresent) {
        Write-Warn2 'Hyper-V hypervisor is running (affects VirtualBox only).'
    }
    else {
        Write-Ok 'No Hyper-V hypervisor detected.'
    }
}

# --- WSL2 -----------------------------------------------------------------
if (-not $SkipWsl) {
    Write-Step 'WSL2 (required by Docker Desktop and Podman)'
    $results['WSL2'] = Initialize-Wsl2
}
else {
    Write-Step 'WSL2 (skipped)'
    $results['WSL2'] = 'skipped'
}

# --- Docker ---------------------------------------------------------------
if (-not $SkipDocker) {
    Write-Step 'Docker Desktop'
    $results['Docker'] = Install-DockerDesktop -Force:$Force
}
else {
    Write-Step 'Docker Desktop (skipped)'
    $results['Docker'] = 'skipped'
}

# --- Podman ---------------------------------------------------------------
if (-not $SkipPodman) {
    Write-Step 'Podman (CLI + Desktop + WSL2 machine)'
    $results['Podman'] = Install-Podman -Force:$Force
}
else {
    Write-Step 'Podman (skipped)'
    $results['Podman'] = 'skipped'
}

# --- VirtualBox -----------------------------------------------------------
if (-not $SkipVirtualBox) {
    Write-Step 'Oracle VirtualBox'
    $results['VirtualBox'] = Install-VirtualBox -Force:$Force -DisableHyperV:$DisableHyperV
}
else {
    Write-Step 'Oracle VirtualBox (skipped)'
    $results['VirtualBox'] = 'skipped'
}

# --- verification ---------------------------------------------------------
Write-Step 'Verification'

Update-SessionPath

$checks = @(
    @{ Label = 'docker';    Command = 'docker';    Args = @('--version') }
    @{ Label = 'podman';    Command = 'podman';    Args = @('--version') }
    @{ Label = 'VBoxManage'; Command = 'VBoxManage'; Args = @('--version') }
    @{ Label = 'wsl';       Command = 'wsl';       Args = @('--status') }
)

$allGood = $true
foreach ($check in $checks) {
    $v = Get-CommandVersion -Name $check.Command -Arguments $check.Args
    if ($v) {
        Write-Result ('{0,-12} {1}' -f $check.Label, $v) 'present'
    }
    else {
        Write-Result ('{0,-12} not found on PATH' -f $check.Label) 'failed'
        $allGood = $false
    }
}

# --- summary --------------------------------------------------------------
Write-Host ''
Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray

foreach ($key in $results.Keys) {
    Write-Result $key $results[$key]
}

Write-Host ''
if ($allGood) {
    Write-Host '  Tooling is in place. Reboot if WSL2 or Hyper-V features changed.' -ForegroundColor Green
    Write-Host '  Start Docker Desktop once to complete its first-run setup.' -ForegroundColor Green
}
else {
    Write-Host '  Some tools are not on PATH yet. Open a new terminal and re-run to verify.' -ForegroundColor Yellow
}
Write-Host ''