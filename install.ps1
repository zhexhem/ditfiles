#Requires -Version 5.1
<#
.SYNOPSIS
    Installs dotfiles into $HOME by symlinking, hard-linking or copying them,
    using one or more named profiles.

.DESCRIPTION
    Reads a manifest that describes profiles (base, windows, work, ...) and
    materialises the selected ones on this machine.

    Resolution order, later wins:
        1. Common entries (applied to every profile)
        2. Each selected profile, parents before children
        3. Command-line selections applied left to right

    Entries are merged by resolved target path, so a child profile can
    redefine an inherited link.  A profile may also list targets in 'Remove'
    to drop entries inherited from its parents.

    The script is idempotent: an entry whose target already points at the
    right source is left alone, and anything that would be overwritten is
    moved into a timestamped backup folder first.

.PARAMETER Profile
    One or more profile names to install.  Later names override earlier ones.
    Defaults to the manifest's DefaultProfile.

.PARAMETER ListProfiles
    Print the available profiles and exit.

.PARAMETER SourceRoot
    Root of the dotfiles repository.  Relative Source paths are resolved
    against it.  Defaults to the folder containing this script.

.PARAMETER ConfigPath
    A .ps1 file that returns a hashtable describing the profiles.  Defaults
    to 'dotfiles.config.ps1' next to this script; if that file is absent a
    small built-in default set is used.

.PARAMETER BackupRoot
    Folder that overwritten files are moved into.
    Defaults to ~/.dotfiles-backup/<timestamp>.

.PARAMETER Mode
    SymbolicLink (default), HardLink or Copy.  Can be overridden per entry.

.PARAMETER NoBackup
    Delete anything in the way instead of backing it up.

.PARAMETER Force
    Replace existing real files without backing them up.  Destructive.

.EXAMPLE
    ./install.ps1 -ListProfiles

.EXAMPLE
    ./install.ps1 -Profile windows,work -WhatIf

.EXAMPLE
    ./install.ps1 -Profile personal -Mode Copy

.EXAMPLE
    ./install.ps1 -ConfigPath ./work.config.ps1 -Profile workstation
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
param(
    [string[]] $Profile,

    [switch] $ListProfiles,

    [string] $SourceRoot = $PSScriptRoot,

    [string] $ConfigPath,

    [string] $BackupRoot,

    [ValidateSet('SymbolicLink', 'HardLink', 'Copy')]
    [string] $Mode = 'SymbolicLink',

    [switch] $NoBackup,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Platform helpers
# ---------------------------------------------------------------------------

# $IsWindows does not exist on Windows PowerShell 5.1 - short-circuit around it.
$script:IsWin = $PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows

$script:PathComparison = if ($script:IsWin) {
    [StringComparison]::OrdinalIgnoreCase
} else {
    [StringComparison]::Ordinal
}

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

function Resolve-DotfilePath {
    <#
        Expands '~', %VAR% and $env:VAR, then makes the path absolute.
        Relative paths are resolved against -Base (or the current directory).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory, Position = 0)]
        [string] $Path,

        [string] $Base
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path must not be empty.'
    }

    if ($Path -eq '~') {
        $Path = $HOME
    }
    elseif ($Path -match '^~[\\/]') {
        $Path = Join-Path $HOME $Path.Substring(2)
    }

    $Path = [Environment]::ExpandEnvironmentVariables($Path)
    $Path = [regex]::Replace($Path, '\$\{?env:([A-Za-z_][A-Za-z0-9_]*)\}?', {
        param($m)
        $value = [Environment]::GetEnvironmentVariable($m.Groups[1].Value)
        if ($null -eq $value) { $m.Value } else { $value }
    })

    if (-not [IO.Path]::IsPathRooted($Path)) {
        if (-not $Base) { $Base = (Get-Location).ProviderPath }
        $Path = Join-Path $Base $Path
    }

    return [IO.Path]::GetFullPath($Path)
}

function Test-Entry {
    <#
        Like Test-Path, but also returns $true for broken symlinks (which
        Test-Path follows and therefore reports as missing).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue) {
        return $true
    }

    $parent = Split-Path -Parent $Path
    $leaf   = Split-Path -Leaf $Path
    if ($parent -and (Test-Path -LiteralPath $parent)) {
        $hit = Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -eq $leaf } |
               Select-Object -First 1
        return $null -ne $hit
    }

    return $false
}

function Get-LinkTargetPath {
    <#
        Returns the absolute target of a symlink/junction, or $null when the
        path does not exist or is not a link.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or -not $item.LinkType) { return $null }

    $raw = @($item.Target) | Where-Object { $_ } | Select-Object -First 1
    if (-not $raw) { return $null }

    if (-not [IO.Path]::IsPathRooted($raw)) {
        $raw = Join-Path (Split-Path -Parent $Path) $raw
    }

    return [IO.Path]::GetFullPath($raw)
}

# ---------------------------------------------------------------------------
# Manifest helpers
# ---------------------------------------------------------------------------

function Get-OptionalList {
    <#
        $Table.Key as an array, tolerating missing keys and $null values.
        Without this, @($null) yields a one-element array and breaks loops.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] $Table,
        [Parameter(Mandatory)] [string] $Key
    )

    if ($Table -is [System.Collections.IDictionary] -and
        $Table.Contains($Key) -and
        $null -ne $Table[$Key]) {
        return @($Table[$Key])
    }

    return @()
}

function Get-ProfileLayerOrder {
    <#
        Depth-first flattening of a profile's inheritance chain: parents come
        before children, each profile appears at most once, cycles throw.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)] $Profiles,
        [Parameter(Mandatory)] [string[]] $Names
    )

    $order    = [System.Collections.Generic.List[string]]::new()
    $seen     = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $visiting = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    function Add-Layer {
        param([string] $Name)

        if ($visiting.Contains($Name)) {
            throw "Circular profile inheritance detected at '$Name'."
        }
        if ($seen.Contains($Name)) { return }

        if (-not $Profiles.Contains($Name)) {
            throw "Unknown profile '$Name'. Use -ListProfiles to see what is available."
        }

        $null = $visiting.Add($Name)
        $profile = $Profiles[$Name]

        foreach ($parent in (Get-OptionalList -Table $profile -Key 'Inherits')) {
            if ($parent) { Add-Layer -Name ([string]$parent) }
        }

        $null = $visiting.Remove($Name)
        if ($seen.Add($Name)) { $order.Add($Name) }
    }

    foreach ($name in $Names) { Add-Layer -Name $name }

    return $order.ToArray()
}

function Resolve-ProfileEntries {
    <#
        Merges Common + the flattened profile chain into a single ordered list
        of link entries.  Keyed by resolved target so a child profile can
        redefine an inherited link in place.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)] $Config,
        [Parameter(Mandatory)] [string[]] $LayerNames,
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $HomeRoot
    )

    # OrderedDictionary + case-insensitive comparer: stable order, correct
    # de-duplication on Windows and on case-insensitive macOS volumes.
    $entries = [System.Collections.Specialized.OrderedDictionary]::new([StringComparer]::OrdinalIgnoreCase)

    function Add-Layer {
        param($Layer, [string] $LayerName)

        # 'Remove' drops inherited entries before this layer adds its own.
        foreach ($target in (Get-OptionalList -Table $Layer -Key 'Remove')) {
            if (-not $target) { continue }
            $key = Resolve-DotfilePath -Path ([string]$target) -Base $HomeRoot
            if ($entries.Contains($key)) { $entries.Remove($key) }
        }

        foreach ($entry in (Get-OptionalList -Table $Layer -Key 'Links')) {
            if (-not $entry.Source -or -not $entry.Target) {
                Write-Warning "[$LayerName] Skipping malformed entry (needs Source and Target)."
                continue
            }

            $key = Resolve-DotfilePath -Path ([string]$entry.Target) -Base $HomeRoot

            # Clone so we never mutate the caller's manifest.
            $copy = @{}
            foreach ($k in $entry.Keys) { $copy[$k] = $entry[$k] }
            $copy['_Layer'] = $LayerName
            $copy['_Target'] = $key

            $entries[$key] = $copy
        }
    }

    if ($Config.Contains('Common')) {
        Add-Layer -Layer $Config['Common'] -LayerName 'common'
    }

    foreach ($name in $LayerNames) {
        Add-Layer -Layer $Config['Profiles'][$name] -LayerName $name
    }

    return @($entries.Values)
}

# ---------------------------------------------------------------------------
# File-system operations
# ---------------------------------------------------------------------------

function Backup-DotfileItem {
    <#
        Moves a file/directory/link into the backup root, mirroring its
        original path so collisions are impossible.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $BackupRoot
    )

    $relative = $Path -replace '^([A-Za-z]):', '$1'
    $relative = $relative -replace '[\\/]+', [string][IO.Path]::DirectorySeparatorChar
    $relative = $relative.TrimStart([char[]]@('\', '/', [IO.Path]::DirectorySeparatorChar))

    $destination = Join-Path $BackupRoot $relative

    $parent = Split-Path -Parent $destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # Never clobber an earlier backup.
    $final = $destination
    $i = 1
    while (Test-Path -LiteralPath $final) {
        $final = '{0}.{1}' -f $destination, $i
        $i++
    }

    Move-Item -LiteralPath $Path -Destination $final -Force
    return $final
}

function Remove-DotfileLink {
    <#
        Removes a link without ever recursing into its target.
        (Remove-Item -Recurse on a directory junction is historically unsafe.)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if ($script:IsWin) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($item -and $item.PSIsContainer) {
            [IO.Directory]::Delete($Path, $false)
            return
        }
    }

    Remove-Item -LiteralPath $Path -Force
}

function New-DotfileLink {
    <#
        Creates the link/copy and returns a short description of what was made.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $Mode
    )

    $isContainer = (Get-Item -LiteralPath $Source -Force).PSIsContainer

    if ($Mode -eq 'Copy') {
        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
        return 'Copy'
    }

    if ($Mode -eq 'HardLink') {
        if ($isContainer) { throw 'Hard links are not supported for directories.' }
        New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
        return 'HardLink'
    }

    # --- SymbolicLink, with graceful degradation -------------------------
    try {
        New-Item -ItemType SymbolicLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
        return 'SymbolicLink'
    }
    catch {
        Write-Verbose "Symlink creation failed: $($_.Exception.Message)"

        if ($isContainer) {
            if ($script:IsWin) {
                New-Item -ItemType Junction -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
                return 'Junction'
            }
        }
        else {
            try {
                New-Item -ItemType HardLink -Path $Destination -Target $Source -ErrorAction Stop | Out-Null
                return 'HardLink'
            }
            catch {
                Write-Verbose "Hard link creation failed: $($_.Exception.Message)"
            }
        }

        Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
        return 'Copy'
    }
}

# ---------------------------------------------------------------------------
# Core install routine
# ---------------------------------------------------------------------------

function Install-DotfileItem {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination,
        [Parameter(Mandatory)] [string] $Mode,
        [string] $Layer,
        [string] $BackupRoot,
        [switch] $Force
    )

    $result = [pscustomobject]@{
        Status      = 'Skipped'
        Layer       = $Layer
        Destination = $Destination
        Source      = $Source
        Detail      = ''
    }

    if (-not (Test-Path -LiteralPath $Source)) {
        $result.Status = 'Missing'
        $result.Detail = 'source not found'
        return $result
    }

    # --- already correct? -------------------------------------------------
    $existingTarget = Get-LinkTargetPath -Path $Destination
    if ($existingTarget -and
        [string]::Equals($existingTarget, $Source, $script:PathComparison)) {
        $result.Status = 'OK'
        $result.Detail = 'already linked'
        return $result
    }

    $exists = Test-Entry -Path $Destination

    if (-not $PSCmdlet.ShouldProcess($Destination, "link -> $Source")) {
        $result.Status = 'WhatIf'
        $result.Detail = if ($exists) { 'would replace' } else { 'would create' }
        return $result
    }

    # --- make room --------------------------------------------------------
    $parent = Split-Path -Parent $Destination
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if ($exists) {
        if ($existingTarget) {
            # It is a link - nothing of value is lost, just drop it.
            Remove-DotfileLink -Path $Destination
        }
        elseif ($Force -or $NoBackup -or -not $BackupRoot) {
            Remove-Item -LiteralPath $Destination -Recurse -Force
            $result.Detail = 'replaced existing'
        }
        else {
            $saved = Backup-DotfileItem -Path $Destination -BackupRoot $BackupRoot
            $result.Detail = "backed up -> $saved"
        }
    }

    # --- create -----------------------------------------------------------
    $kind = New-DotfileLink -Source $Source -Destination $Destination -Mode $Mode

    $result.Status = 'Linked'
    if ($result.Detail) {
        $result.Detail = "$kind; $($result.Detail)"
    }
    else {
        $result.Detail = $kind
    }

    return $result
}

# ---------------------------------------------------------------------------
# Default manifest (used when no dotfiles.config.ps1 is found)
# ---------------------------------------------------------------------------

function Get-DefaultDotfileConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $psProfileDir = if ($PSVersionTable.PSEdition -eq 'Desktop') {
        Join-Path $HOME 'Documents\WindowsPowerShell'
    }
    elseif ($script:IsWin) {
        Join-Path $HOME 'Documents\PowerShell'
    }
    else {
        Join-Path $HOME '.config/powershell'
    }

    return @{
        DefaultProfile = 'base'

        Common = @{
            Links = @(
                @{ Source = 'git/gitconfig'; Target = '~/.gitconfig' }
                @{ Source = 'git/gitignore'; Target = '~/.gitignore' }
            )
        }

        Profiles = @{
            base = @{
                Description = 'Portable settings every machine gets.'
                Links = @(
                    @{ Source = 'powershell/profile.ps1'; Target = (Join-Path $psProfileDir 'Microsoft.PowerShell_profile.ps1') }
                )
            }

            windows = @{
                Description = 'Windows-specific tools and terminal settings.'
                Inherits = @('base')
                Links = @(
                    @{ Source = 'windows/terminal.json'; Target = '~/AppData/Local/Packages/Microsoft.WindowsTerminal_8wekyb3d8bbwe/LocalState/settings.json' }
                    @{ Source = 'powershell/profile.ps1'; Target = (Join-Path $psProfileDir 'profile.ps1') }
                )
            }

            linux = @{
                Description = 'Linux shell and editor configuration.'
                Inherits = @('base')
                Links = @(
                    @{ Source = 'shell/bashrc';   Target = '~/.bashrc' }
                    @{ Source = 'shell/profile';  Target = '~/.profile' }
                    @{ Source = 'nvim/init.lua';  Target = '~/.config/nvim/init.lua' }
                )
            }

            macos = @{
                Description = 'macOS shell, editor and window management.'
                Inherits = @('linux')
                Links = @(
                    @{ Source = 'macos/karabiner.json'; Target = '~/.config/karabiner/karabiner.json' }
                )
            }

            work = @{
                Description = 'Corporate overlays: proxy, certificates, verbose git.'
                Inherits = @('base')
                Links = @(
                    @{ Source = 'work/gitconfig.inc'; Target = '~/.gitconfig.work' }
                    @{ Source = 'work/npmrc';        Target = '~/.npmrc' }
                )
                # Inherited from Common, but not wanted on a locked-down box.
                Remove = @('~/.gitignore')
            }

            personal = @{
                Description = 'Personal machine: everything, plus extras.'
                Inherits = @('base')
                Links = @(
                    @{ Source = 'shell/zshrc';     Target = '~/.zshrc' }
                    @{ Source = 'tmux/tmux.conf';  Target = '~/.tmux.conf' }
                )
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Write-ProfileList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Config
    )

    Write-Host ''
    Write-Host '  Available profiles' -ForegroundColor White
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray

    foreach ($name in ($Config['Profiles'].Keys | Sort-Object)) {
        $profile  = $Config['Profiles'][$name]
        $isDefault = $name -eq $Config['DefaultProfile']
        $marker    = if ($isDefault) { ' *' } else { '  ' }

        Write-Host ('  {0}{1}' -f $marker, $name) -ForegroundColor Green -NoNewline

        $parents = Get-OptionalList -Table $profile -Key 'Inherits'
        if ($parents.Count -gt 0) {
            Write-Host ('  <- {0}' -f ($parents -join ', ')) -ForegroundColor DarkGray -NoNewline
        }

        Write-Host ''
        if ($profile.Description) {
            Write-Host ('      {0}' -f $profile.Description) -ForegroundColor Gray
        }

        $linkCount = (Get-OptionalList -Table $profile -Key 'Links').Count
        Write-Host ('      {0} link(s)' -f $linkCount) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  * = default profile' -ForegroundColor DarkGray
    Write-Host ''
}

function Write-InstallSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Results,
        [string[]] $Profiles,
        [string] $BackupRoot
    )

    Write-Host ''
    Write-Host ('  Dotfiles  [{0}]' -f ($Profiles -join ' + ')) -ForegroundColor White
    Write-Host ('  ' + ('-' * 68)) -ForegroundColor DarkGray

    $width = ($Results | Measure-Object { $_.Destination.Length } -Maximum).Maximum
    if (-not $width -or $width -gt 60) { $width = 60 }

    foreach ($r in $Results) {
        $colour = switch ($r.Status) {
            'Linked'  { 'Green' }
            'OK'      { 'DarkGray' }
            'Missing' { 'Yellow' }
            'WhatIf'  { 'Cyan' }
            'Failed'  { 'Red' }
            default   { 'Gray' }
        }

        Write-Host ('  {0,-8}' -f $r.Status) -ForegroundColor $colour -NoNewline
        Write-Host ('{0,-{1}}' -f $r.Destination, $width) -ForegroundColor $colour -NoNewline

        $notes = @()
        if ($r.PSObject.Properties['Layer'] -and $r.Layer) { $notes += $r.Layer }
        if ($r.Detail) { $notes += $r.Detail }

        if ($notes.Count -gt 0) {
            Write-Host ('  {0}' -f ($notes -join '; ')) -ForegroundColor DarkGray
        }
        else {
            Write-Host ''
        }
    }

    $summary = $Results | Group-Object Status |
               ForEach-Object { '{0} {1}' -f $_.Count, $_.Name.ToLower() }

    Write-Host ''
    Write-Host ('  ' + ($summary -join ', ')) -ForegroundColor Gray

    $backedUp = @($Results | Where-Object { $_.Detail -like 'backed up ->*' }).Count
    if ($backedUp -gt 0) {
        Write-Host ("  {0} item(s) backed up to {1}" -f $backedUp, $BackupRoot) -ForegroundColor Yellow
    }

    Write-Host ''
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not $SourceRoot) {
    $SourceRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).ProviderPath }
}
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).ProviderPath

if (-not $ConfigPath) {
    $ConfigPath = Join-Path $SourceRoot 'dotfiles.config.ps1'
}

# --- load manifest ---------------------------------------------------------
if (Test-Path -LiteralPath $ConfigPath) {
    Write-Verbose "Using manifest: $ConfigPath"
    $config = & $ConfigPath
}
else {
    Write-Verbose "No manifest at '$ConfigPath'; using built-in defaults."
    $config = Get-DefaultDotfileConfig
}

if ($config -isnot [System.Collections.IDictionary]) {
    throw "Config '$ConfigPath' must return a hashtable."
}

# Normalise: a legacy flat manifest becomes Common, and every manifest gets
# at least one profile so the rest of the script has a uniform shape.
if (-not $config.Contains('Common')) { $config['Common'] = @{} }
if (-not $config.Contains('Profiles')) { $config['Profiles'] = @{} }

if ($config.Contains('Links') -and $config['Links']) {
    if (-not $config['Common'].Contains('Links')) {
        $config['Common']['Links'] = $config['Links']
    }
    $config.Remove('Links')
}

if ($config['Profiles'].Count -eq 0) {
    $config['Profiles']['default'] = @{
        Description = 'Implicit profile for a flat manifest.'
        Links       = @()
    }
}

if (-not $config.Contains('DefaultProfile') -or -not $config['DefaultProfile']) {
    $config['DefaultProfile'] = if ($config['Profiles'].Contains('base')) { 'base' }
                                else { @($config['Profiles'].Keys)[0] }
}

# --- list and exit ---------------------------------------------------------
if ($ListProfiles) {
    Write-ProfileList -Config $config
    return
}

# --- resolve selection -----------------------------------------------------
$requested = if ($Profile) { @($Profile) } else { @($config['DefaultProfile']) }

foreach ($name in $requested) {
    if (-not $config['Profiles'].Contains($name)) {
        throw "Unknown profile '$name'. Use -ListProfiles to see what is available."
    }
}

$layers = Get-ProfileLayerOrder -Profiles $config['Profiles'] -Names $requested

Write-Verbose ("Profiles: requested=[{0}] layers=[{1}]" -f ($requested -join ', '), ($layers -join ' -> '))

$entries = Resolve-ProfileEntries -Config $config `
                                  -LayerNames $layers `
                                  -SourceRoot $SourceRoot `
                                  -HomeRoot $HOME

if ($entries.Count -eq 0) {
    Write-Warning ("Nothing to install - profile(s) '{0}' contain no links." -f ($layers -join ', '))
    return
}

# --- backup root -----------------------------------------------------------
$backupRootToUse = $null
if (-not $NoBackup -and -not $Force) {
    $backupRootToUse = if ($BackupRoot) {
        $BackupRoot
    } else {
        Join-Path $HOME ('.dotfiles-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }
    $backupRootToUse = Resolve-DotfilePath -Path $backupRootToUse -Base $HOME
}

# --- run -------------------------------------------------------------------
Write-Host ''
Write-Host ("  Installing dotfiles from {0}" -f $SourceRoot) -ForegroundColor White
Write-Host ("  Profile(s): {0}" -f (($requested) -join ', ')) -ForegroundColor DarkGray

$results = foreach ($entry in $entries) {
    # Per-entry Mode beats the command-line default.
    $entryMode = if ($entry.Mode) { [string]$entry.Mode } else { $Mode }

    $src = Resolve-DotfilePath -Path ([string]$entry.Source) -Base $SourceRoot
    $dst = $entry['_Target']

    try {
        Install-DotfileItem -Source $src `
                            -Destination $dst `
                            -Mode $entryMode `
                            -Layer $entry['_Layer'] `
                            -BackupRoot $backupRootToUse `
                            -Force:$Force
    }
    catch {
        [pscustomobject]@{
            Status      = 'Failed'
            Layer       = $entry['_Layer']
            Destination = $dst
            Source      = $src
            Detail      = $_.Exception.Message
        }
    }
}

Write-InstallSummary -Results $results -Profiles $layers -BackupRoot $backupRootToUse