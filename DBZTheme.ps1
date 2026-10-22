# ============================================
#  DRAGON BALL Z PowerShell Theme
#  "It's over 9000!!!" 
# ============================================

# --- Colors (DBZ Palette) ---
$DBZ = @{
    GokuOrange  = "`e[38;2;255;140;0m"   # Goku's gi
    GokuBlue    = "`e[38;2;0;150;255m"   # Super Saiyan Blue
    VegetaBlue  = "`e[38;2;30;80;200m"   # Vegeta's suit
    SaiyanGold  = "`e[38;2;255;215;0m"   # Super Saiyan hair
    DragonRed   = "`e[38;2;200;0;0m"     # Shenron / Dragon Balls
    KiYellow    = "`e[38;2;255;255;100m" # Ki energy
    FriezaPurple= "`e[38;2;160;32;240m"  # Frieza
    PiccoloGreen= "`e[38;2;60;179;113m"  # Piccolo
    Reset       = "`e[0m"
    Bold        = "`e[1m"
    Dim         = "`e[2m"
}

# --- Power Level Tracker ---
$global:DBZPowerLevel = 9001
$global:DBZTransformations = @{
    "Base"              = @{ Mult = 1;    Color = $DBZ.GokuOrange }
    "Kaioken"           = @{ Mult = 4;    Color = $DBZ.DragonRed }
    "SuperSaiyan"       = @{ Mult = 50;   Color = $DBZ.SaiyanGold }
    "SuperSaiyan2"      = @{ Mult = 100;  Color = $DBZ.KiYellow }
    "SuperSaiyan3"      = @{ Mult = 400;  Color = $DBZ.SaiyanGold }
    "SuperSaiyanGod"    = @{ Mult = 1000; Color = $DBZ.DragonRed }
    "SuperSaiyanBlue"   = @{ Mult = 5000; Color = $DBZ.GokuBlue }
    "UltraInstinct"     = @{ Mult = 9001; Color = "`e[38;2;200;220;255m" }
}
$global:DBZCurrentForm = "Base"

# --- Banner ---
function Show-DBZBanner {
    Write-Host ""
    Write-Host "$($DBZ.SaiyanGold)$($DBZ.Bold)  ╔═══════════════════════════════════════════════════════════╗$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ║$($DBZ.GokuOrange)$($DBZ.Bold)     ██████╗ ██████╗ ███████╗                        $($DBZ.SaiyanGold)║$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ║$($DBZ.GokuOrange)$($DBZ.Bold)     ██╔══██╗██╔══██╗╚══███╔╝                        $($DBZ.SaiyanGold)║$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ║$($DBZ.GokuOrange)$($DBZ.Bold)     ██║  ██║██████╔╝  ███╔╝                         $($DBZ.SaiyanGold)║$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ║$($DBZ.GokuOrange)$($DBZ.Bold)     ██║  ██║██╔══██╗ ███╔╝                          $($DBZ.SaiyanGold)║$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ║$($DBZ.GokuOrange)$($DBZ.Bold)     ██████╔╝██████╔╝███████╗                        $($DBZ.SaiyanGold)║$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ║$($DBZ.GokuOrange)$($DBZ.Bold)     ╚═════╝ ╚═════╝ ╚══════╝                        $($DBZ.SaiyanGold)║$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ║$($DBZ.KiYellow)        ⚡ Power Level: $global:DBZPowerLevel ⚡                 $($DBZ.SaiyanGold)║$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ║$($DBZ.DragonRed)        🐉 Form: $($global:DBZCurrentForm.PadRight(20))              $($DBZ.SaiyanGold)║$($DBZ.Reset)"
    Write-Host "$($DBZ.SaiyanGold)  ╚═══════════════════════════════════════════════════════════╝$($DBZ.Reset)"
    Write-Host ""
}

# --- Custom Prompt (Goku's hair as prompt arrow) ---
function prompt {
    $curForm = $global:DBZTransformations[$global:DBZCurrentForm]
    $formColor = $curForm.Color
    $location = (Get-Location).Path -replace [regex]::Escape($HOME), '~'
    $time = Get-Date -Format "HH:mm:ss"

    # Location line
    Write-Host "$($DBZ.Dim)[$time]$($DBZ.Reset) $($DBZ.VegetaBlue)📁 $location$($DBZ.Reset)"

    # Power level + arrow
    $kiLevel = [math]::Round($global:DBZPowerLevel * $curForm.Mult)
    $arrow = if ($kiLevel -gt 9000) { "⚡⚡⚡" } else { "⚡" }
    Write-Host "$($formColor)$($DBZ.Bold)$arrow $($global:DBZCurrentForm) [$kiLevel]$($DBZ.Reset) $($DBZ.SaiyanGold)»$($DBZ.Reset) " -NoNewline
    return " "
}

# --- Transform! ---
function Transform {
    param(
        [ValidateSet("Base","Kaioken","SuperSaiyan","SuperSaiyan2","SuperSaiyan3","SuperSaiyanGod","SuperSaiyanBlue","UltraInstinct")]
        [string]$Form = "SuperSaiyan"
    )
    $global:DBZCurrentForm = $Form
    $mult = $global:DBZTransformations[$Form].Mult
    $color = $global:DBZTransformations[$Form].Color

    Write-Host "$($color)$($DBZ.Bold)"
    Write-Host "  ╔═══════════════════════════════════════════════╗"
    Write-Host "  ║   ⚡ TRANSFORMING TO $($Form.ToUpper().PadRight(20)) ║"
    Write-Host "  ╚═══════════════════════════════════════════════╝"
    Write-Host "$($DBZ.Reset)"

    switch ($Form) {
        "Base"            { Write-Host "$($DBZ.GokuOrange)  🥋 Back to base form. Power: $(9001)$($DBZ.Reset)" }
        "Kaioken"         { Write-Host "$($DBZ.DragonRed)  🔴 KAIOKEN! x4 multiplier!$($DBZ.Reset)" }
        "SuperSaiyan"     { Write-Host "$($DBZ.SaiyanGold)  💛 AHHHHH! Super Saiyan! Hair turns gold!$($DBZ.Reset)" }
        "SuperSaiyan2"    { Write-Host "$($DBZ.KiYellow)  💛⚡ Super Saiyan 2! Lightning crackles!$($DBZ.Reset)" }
        "SuperSaiyan3"    { Write-Host "$($DBZ.SaiyanGold)  💛💛 Super Saiyan 3! Long hair, no eyebrows!$($DBZ.Reset)" }
        "SuperSaiyanGod"  { Write-Host "$($DBZ.DragonRed)  🔥 Super Saiyan God! Red hair, divine ki!$($DBZ.Reset)" }
        "SuperSaiyanBlue" { Write-Host "$($DBZ.GokuBlue)  💙 Super Saiyan BLUE! God ki mastered!$($DBZ.Reset)" }
        "UltraInstinct"   { Write-Host "$($DBZ.Bold)`e[38;2;200;220;255m  ✨ ULTRA INSTINCT! Silver hair, mastered!$($DBZ.Reset)" }
    }
    Write-Host "$($DBZ.Dim)  Power Level: $([math]::Round($global:DBZPowerLevel * $mult))$($DBZ.Reset)"
    Write-Host ""
}

# --- Kaio-ken animation on command error ---
$global:DBZOnError = {
    Write-Host "$($DBZ.DragonRed)  💥 That attack missed! (error)$($DBZ.Reset)" -ForegroundColor Red
}

# --- Fun: Power up command ---
function PowerUp {
    param([int]$Amount = 1000)
    $global:DBZPowerLevel += $Amount
    $global:DBZPowerLevel *= 1.1
    $global:DBZPowerLevel = [math]::Round($global:DBZPowerLevel)
    $mult = $global:DBZTransformations[$global:DBZCurrentForm].Mult
    $total = [math]::Round($global:DBZPowerLevel * $mult)

    Write-Host "$($DBZ.KiYellow)$($DBZ.Bold)"
    Write-Host "  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
    Write-Host "  ██  POWERING UP! +$Amount                                                  ██"
    Write-Host "  ██  Total Power: $total                                                    ██"
    if ($total -gt 9000) {
        Write-Host "  ██  💢 IT'S OVER 9000!!! 💢                                                 ██"
    }
    Write-Host "  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓"
    Write-Host "$($DBZ.Reset)"
}

# --- Kamehameha clear alias ---
function Invoke-Kamehameha {
    Write-Host "$($DBZ.GokuBlue)$($DBZ.Bold)"
    Write-Host "  KA-ME-HA-ME..."
    Start-Sleep -Milliseconds 400
    Write-Host "  HA!!!"
    Write-Host "$($DBZ.Reset)"
    Start-Sleep -Milliseconds 300
    Clear-Host
    Show-DBZBanner
}
Set-Alias kamehameha Invoke-Kamehameha
Set-Alias clear-dbz Invoke-Kamehameha

# --- Dragon Ball status command ---
function Get-DragonBalls {
    $balls = @("🔴","🟠","🟡","🟢","🔵","🟣","⚪")
    $status = "Dragon Balls: " + ($balls -join " ")
    $status += "  |  Form: $($global:DBZCurrentForm)"
    $status += "  |  Base PL: $($global:DBZPowerLevel)"
    $status += "  |  Effective: $([math]::Round($global:DBZPowerLevel * $global:DBZTransformations[$global:DBZCurrentForm].Mult))"
    Write-Host "$($DBZ.SaiyanGold)$status$($DBZ.Reset)"
}
Set-Alias shenron Get-DragonBalls

# --- Custom aliases (DBZ style) ---
Set-Alias ki              Get-ChildItem       # Feel energy (list files)
Set-Alias sense           Get-Process          # Sense power levels
Set-Alias fly             Set-Location         # Fly to directory
Set-Alias scout           Get-Help             # Scout info
Set-Alias senzu           Get-Content          # Read senzu bean (file)
Set-Alias capsule         Copy-Item            # Capsule Corp copy
Set-Alias hyperbolic     Start-Job            # Hyperbolic Time Chamber (bg job)
Set-Alias fusion          Invoke-Expression    # Fusion technique

# --- Welcome Message ---
function Start-DBZSession {
    Show-DBZBanner
    Write-Host "$($DBZ.GokuOrange)  Welcome, warrior! Type $($DBZ.KiYellow)Transform <Form>$($DBZ.GokuOrange) to power up.$($DBZ.Reset)"
    Write-Host "$($DBZ.Dim)  Forms: Base, Kaioken, SuperSaiyan, SuperSaiyan2, SuperSaiyan3, SuperSaiyanGod, SuperSaiyanBlue, UltraInstinct$($DBZ.Reset)"
    Write-Host "$($DBZ.Dim)  Commands: PowerUp, kamehameha, shenron, Transform, Start-DBZSession$($DBZ.Reset)"
    Write-Host ""
}

Start-DBZSession