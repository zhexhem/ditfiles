#Requires -Version 5.1
<#
.SYNOPSIS
    Bootstraps a Windows development environment with Python, .NET, and Java.

.DESCRIPTION
    Installs and verifies the core toolchains used by most projects:

        Python  ->  uv (package/project manager) + a managed CPython
        .NET    ->  .NET SDK (via the official dotnet-install.ps1 script)
        Java    ->  Eclipse Temurin JDK 21 (via winget)

    Also installs a small set of supporting tools: Git, GitHub CLI, VS Code,
    and the Windows Terminal, if they are missing.

    The script is idempotent: anything already present is skipped, so it is
    safe to re-run after adding a new tool or bumping a version.

    Native Windows only.  If you want a Linux-parity shell, look at the
    Windows Developer Config project instead (https://aka.ms/devconfig).

.PARAMETER SkipUv
    Do not install uv or a managed Python.

.PARAMETER SkipDotnet
    Do not install the .NET SDK.

.PARAMETER SkipJava
    Do not install the JDK.

.PARAMETER SkipSupporting
    Do not install Git, GitHub CLI, VS Code, or Windows Terminal.

.PARAMETER DotnetChannel
    .NET release channel.  Defaults to 'LTS'.
    Examples: 'LTS', 'STS', '9.0', '10.0'.

.PARAMETER PythonVersion
    CPython version managed by uv.  Defaults to '3.13'.

.PARAMETER JavaPackage
    winget package id for the JDK.  Defaults to Eclipse Temurin 21.

.PARAMETER UvInstallDir
    Where uv places its binaries.  Defaults to ~/.local/bin, matching the
    upstream installer.

.PARAMETER WhatIf
    Print every action without performing it.

.PARAMETER Force
    Re-run installers even when the tool is already present.

.EXAMPLE
    ./dev.ps1
    Install everything with defaults.

.EXAMPLE
    ./dev.ps1 -WhatIf
    Show the full plan without changing anything.

.EXAMPLE
    ./dev.ps1 -DotnetChannel STS -PythonVersion 3.12
    Pin specific toolchain versions.

.EXAMPLE
    ./dev.ps1 -SkipJava -SkipSupporting
    Python and .NET only.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [switch] $SkipUv,
    [switch] $SkipDotnet,
    [switch] $SkipJava,
    [switch] $SkipSupporting,

    [string] $DotnetChannel = 'LTS',
    [string] $PythonVersion = '3.13',

    [string] $JavaPackage = 'EclipseAdoptium.Temurin.21.JDK',
    [string] $UvInstallDir = (Join-Path $HOME '.local/bin'),

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
    <#
        Runs "<name> <args>" and returns the first line of combined output.
        Returns $null when the command is missing or exits non-zero.
    #>
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
    <#
        Wrapper around a native command that respects -WhatIf and turns a
        non-zero exit code into a terminating error.
    #>
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
        # --version is fast and does not touch the network.
        $null = & winget --version 2>&1
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

function Install-WingetPackage {
    <#
        Installs a winget package.  Returns 'installed', 'present' or 'failed'.
    #>
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
    <#
        Re-reads the machine and user PATH so tools installed by an MSI or by
        winget become visible in this session without reopening the shell.
    #>
    [CmdletBinding()]
    param()

    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user    = [Environment]::GetEnvironmentVariable('Path', 'User')

    $combined = @($machine, $user) |
                Where-Object { $_ } |
                ForEach-Object { $_.TrimEnd(';') } |
                -join ';'

    $env:Path = $combined

    # .NET installs outside PATH and relies on DOTNET_ROOT.
    if (-not $env:DOTNET_ROOT) {
        $candidate = Join-Path $HOME '.dotnet'
        if (Test-Path -LiteralPath $candidate) { $env:DOTNET_ROOT = $candidate }
    }
}

# ---------------------------------------------------------------------------
# Python via uv
# ---------------------------------------------------------------------------

function Install-UvToolchain {
    [CmdletBinding()]
    param(
        [string] $Version,
        [string] $InstallDir,
        [switch] $Force
    )

    $uvPath = Join-Path $InstallDir 'uv.exe'
    $haveUv = (Test-Command 'uv') -or (Test-Path -LiteralPath $uvPath)

    if ($haveUv -and -not $Force) {
        $v = Get-CommandVersion -Name 'uv' -Arguments @('--version')
        if (-not $v -and (Test-Path -LiteralPath $uvPath)) {
            $v = (& $uvPath --version 2>&1 | Select-Object -First 1)
        }
        Write-Skip "uv already installed ($v)."
    }
    else {
        Write-Host '      Installing uv...' -ForegroundColor Gray

        $installer = {
            $env:UV_INSTALL_DIR = $InstallDir
            $script = Invoke-RestMethod -Uri 'https://astral.sh/uv/install.ps1'
            Invoke-Expression $script
        }

        if ($PSCmdlet.ShouldProcess('uv', 'download and run the standalone installer')) {
            & $installer
            Write-Ok "uv installed to $InstallDir."
        }

        Update-SessionPath
        if (Test-Path -LiteralPath $InstallDir) {
            $env:Path = "$InstallDir;$env:Path"
        }
    }

    if (-not (Test-Command 'uv') -and (Test-Path -LiteralPath $uvPath)) {
        $env:Path = "$InstallDir;$env:Path"
    }

    if (-not (Test-Command 'uv')) {
        Write-Warn2 'uv is not on PATH; skipping Python provisioning.'
        return 'failed'
    }

    # --- managed CPython --------------------------------------------------
    $installed = & uv python list --only-installed 2>&1
    $hasPython = ($installed -join "`n") -match [regex]::Escape($Version)

    if ($hasPython -and -not $Force) {
        Write-Skip "Python $Version already managed by uv."
        return 'present'
    }

    try {
        Invoke-External -FilePath 'uv' -Arguments @('python', 'install', $Version)
        Write-Ok "Python $Version installed via uv."
        return 'installed'
    }
    catch {
        Write-Warn2 "Python $Version failed: $($_.Exception.Message)"
        return 'failed'
    }
}

# ---------------------------------------------------------------------------
# .NET SDK
# ---------------------------------------------------------------------------

function Install-DotnetSdk {
    [CmdletBinding()]
    param(
        [string] $Channel,
        [switch] $Force
    )

    $dotnet = Get-CommandVersion -Name 'dotnet' -Arguments @('--version')

    if ($dotnet -and -not $Force) {
        Write-Skip "dotnet already installed (SDK $dotnet)."
        return 'present'
    }

    $installDir = Join-Path $HOME '.dotnet'
    $scriptPath = Join-Path $env:TEMP 'dotnet-install.ps1'

    Write-Host '      Fetching dotnet-install.ps1...' -ForegroundColor Gray

    if ($PSCmdlet.ShouldProcess($scriptPath, 'download the .NET install script')) {
        Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $scriptPath -UseBasicParsing
    }
    else {
        return 'skipped'
    }

    $args = @(
        '-Channel', $Channel,
        '-InstallDir', $installDir,
        '-NoPath'
    )

    try {
        Invoke-External -FilePath 'powershell' -Arguments (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath) + $args)
        Write-Ok ".NET SDK ($Channel) installed to $installDir."

        # Persist so new shells see it.
        $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($userPath -notlike "*$installDir*") {
            [Environment]::SetEnvironmentVariable('Path', "$userPath;$installDir", 'User')
            Write-Host "      Added $installDir to user PATH." -ForegroundColor Gray
        }

        [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $installDir, 'User')
        $env:DOTNET_ROOT = $installDir
        Update-SessionPath

        return 'installed'
    }
    catch {
        Write-Warn2 ".NET SDK failed: $($_.Exception.Message)"
        return 'failed'
    }
}

# ---------------------------------------------------------------------------
# Java JDK
# ---------------------------------------------------------------------------

function Install-JavaJdk {
    [CmdletBinding()]
    param(
        [string] $PackageId,
        [switch] $Force
    )

    $java = Get-CommandVersion -Name 'java' -Arguments @('-version')

    if ($java -and -not $Force) {
        Write-Skip "java already installed ($java)."
        return 'present'
    }

    $status = Install-WingetPackage -Id $PackageId -Label 'Eclipse Temurin JDK 21' -Force:$Force
    if ($status -eq 'failed') { return 'failed' }

    Update-SessionPath

    $java = Get-CommandVersion -Name 'java' -Arguments @('-version')
    if ($java) {
        Write-Ok "java ready ($java)."
    }
    else {
        Write-Warn2 'JDK installed but java is not on PATH yet. Open a new terminal.'
    }

    # JAVA_HOME is required by Maven, Gradle and Android Studio.
    if (-not $env:JAVA_HOME) {
        $candidate = Get-ChildItem -Path (Join-Path ${env:ProgramFiles} 'Eclipse Adoptium') -Directory -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -like 'jdk-*' } |
                     Sort-Object Name -Descending |
                     Select-Object -First 1

        if ($candidate) {
            [Environment]::SetEnvironmentVariable('JAVA_HOME', $candidate.FullName, 'User')
            $env:JAVA_HOME = $candidate.FullName
            Write-Host ("      JAVA_HOME set to {0}" -f $candidate.FullName) -ForegroundColor Gray
        }
        else {
            Write-Warn2 'Could not locate the JDK folder to set JAVA_HOME. Set it manually.'
        }
    }

    return $status
}

# ---------------------------------------------------------------------------
# Supporting tools
# ---------------------------------------------------------------------------

function Install-SupportingTools {
    [CmdletBinding()]
    param([switch] $Force)

    $tools = @(
        @{ Id = 'Git.Git';                        Label = 'Git';             Command = 'git' }
        @{ Id = 'GitHub.cli';                     Label = 'GitHub CLI';      Command = 'gh' }
        @{ Id = 'Microsoft.VisualStudioCode';     Label = 'VS Code';         Command = 'code' }
        @{ Id = 'Microsoft.WindowsTerminal';      Label = 'Windows Terminal'; Command = $null }
    )

    foreach ($tool in $tools) {
        $present = $tool.Command -and (Test-Command $tool.Command)

        if ($present -and -not $Force) {
            $v = Get-CommandVersion -Name $tool.Command
            Write-Skip "$($tool.Label) already installed ($v)."
            continue
        }

        $null = Install-WingetPackage -Id $tool.Id -Label $tool.Label -Force:$Force
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '  Windows dev bootstrap' -ForegroundColor White
Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray

$results = [ordered]@{}

# --- supporting tools -----------------------------------------------------
if (-not $SkipSupporting) {
    Write-Step 'Supporting tools (Git, GitHub CLI, VS Code, Windows Terminal)'
    Install-SupportingTools -Force:$Force
    $results['Supporting tools'] = 'done'
}

Update-SessionPath

# --- Python ---------------------------------------------------------------
if (-not $SkipUv) {
    Write-Step ("Python {0} via uv" -f $PythonVersion)
    $results['uv + Python'] = Install-UvToolchain -Version $PythonVersion -InstallDir $UvInstallDir -Force:$Force
}
else {
    Write-Step 'Python (skipped)'
    $results['uv + Python'] = 'skipped'
}

# --- .NET -----------------------------------------------------------------
if (-not $SkipDotnet) {
    Write-Step (".NET SDK ({0} channel)" -f $DotnetChannel)
    $results['.NET SDK'] = Install-DotnetSdk -Channel $DotnetChannel -Force:$Force
}
else {
    Write-Step '.NET SDK (skipped)'
    $results['.NET SDK'] = 'skipped'
}

# --- Java -----------------------------------------------------------------
if (-not $SkipJava) {
    Write-Step 'Java JDK (Eclipse Temurin 21)'
    $results['Java JDK'] = Install-JavaJdk -PackageId $JavaPackage -Force:$Force
}
else {
    Write-Step 'Java JDK (skipped)'
    $results['Java JDK'] = 'skipped'
}

# --- verification ---------------------------------------------------------
Write-Step 'Verification'

Update-SessionPath

$checks = @(
    @{ Label = 'uv';      Command = 'uv';     Args = @('--version') }
    @{ Label = 'Python';  Command = 'python'; Args = @('--version') }
    @{ Label = 'dotnet';  Command = 'dotnet'; Args = @('--version') }
    @{ Label = 'java';    Command = 'java';   Args = @('-version') }
    @{ Label = 'git';     Command = 'git';    Args = @('--version') }
)

$allGood = $true
foreach ($check in $checks) {
    $v = Get-CommandVersion -Name $check.Command -Arguments $check.Args
    if ($v) {
        Write-Result ('{0,-8} {1}' -f $check.Label, $v) 'present'
    }
    else {
        Write-Result ('{0,-8} not found on PATH' -f $check.Label) 'failed'
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
    Write-Host '  Everything is ready. Open a new terminal to pick up PATH changes.' -ForegroundColor Green
}
else {
    Write-Host '  Some tools are missing. Open a new terminal and re-run, or check the output above.' -ForegroundColor Yellow
}
Write-Host ''