#Requires -Version 5.1
<#
.SYNOPSIS
    System tray app that shows the current iQ.Suite tenant mode and switches it
    by calling Switch-iQSuiteTenantMode.ps1.

.DESCRIPTION
    Tray icon: blue "M" = MultiTenant, green "S" = SingleTenant,
               red "?" = inconsistent/unknown, orange "..." = switch running.
    Left/right click opens the menu. The switch runs elevated (UAC prompt unless
    the tray itself already runs as administrator) and logs to TenantTray.log.

.PARAMETER InstallAutostart
    Registers a scheduled task that starts the tray at logon with highest
    privileges (no UAC prompt on switching). Requires administrator.

.PARAMETER UninstallAutostart
    Removes that scheduled task. Requires administrator.

.PARAMETER PollSeconds
    Status refresh interval (default 5).
#>
[CmdletBinding()]
param(
    [switch]$InstallAutostart,
    [switch]$UninstallAutostart,
    [int]$PollSeconds = 5
)

$ErrorActionPreference = 'Stop'
$AppName = 'iQ.Suite Env Switcher'
$Host.UI.RawUI.WindowTitle = $AppName

# Hide the console window as early as possible (the hidden start still flashes it briefly)
Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
$consoleWnd = [Win32.Native]::GetConsoleWindow()
if ($consoleWnd -ne [IntPtr]::Zero) { [void][Win32.Native]::ShowWindow($consoleWnd, 0) }

$TaskName   = 'iQSuiteTenantTray'
$ScriptPath = $MyInvocation.MyCommand.Path
$SwitchScript = Join-Path (Split-Path $ScriptPath) 'Switch-iQSuiteTenantMode.ps1'
$LogPath    = Join-Path (Split-Path $ScriptPath) 'TenantTray.log'

function Test-IsAdministrator {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($InstallAutostart -or $UninstallAutostart) {
    if (-not (Test-IsAdministrator)) { throw 'Administrator rights required.' }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    if ($InstallAutostart) {
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
        $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings | Out-Null
        Write-Host "Autostart task '$TaskName' registered."
    }
    else { Write-Host "Autostart task '$TaskName' removed." }
    return
}

# --- Status (read-only, mirrors the logic of Switch-iQSuiteTenantMode.ps1) ---
$ConfigDir    = 'C:\Program Files\GBS\iQ.Suite\Config'
$WebClientDir = 'C:\ProgramData\GBS\iQ.Suite WebClient'
$RegPath      = 'HKLM:\SOFTWARE\GBS\iQ.Suite\General'

function Get-FileMode([string]$Dir, [string]$Name) {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir $Name) -PathType Leaf)) { return 'Unknown' }
    $s = Test-Path -LiteralPath (Join-Path $Dir "SINGLE_$Name") -PathType Leaf
    $m = Test-Path -LiteralPath (Join-Path $Dir "MULTI_$Name") -PathType Leaf
    if ($s -and -not $m) { 'Multi' } elseif ($m -and -not $s) { 'Single' } else { 'Unknown' }
}

function Get-RegMode {
    $p = Get-ItemProperty -LiteralPath $RegPath -Name MultiTenant -ErrorAction SilentlyContinue
    if ($null -eq $p) { return 'Unknown' }
    switch ($p.MultiTenant) { 1 { 'Multi' } 0 { 'Single' } default { 'Unknown' } }
}

function Get-TenantState {
    try {
        $modes = @(
            (Get-FileMode $ConfigDir 'ConfigData.xml'),
            (Get-FileMode $WebClientDir 'dynamic_configuration.xml'),
            (Get-RegMode)
        )
        $distinct = @($modes | Select-Object -Unique)
        if ($distinct.Count -eq 1 -and $distinct[0] -ne 'Unknown') {
            return [PSCustomObject]@{ Mode = $distinct[0]; Detail = '' }
        }
        [PSCustomObject]@{ Mode = 'Unknown'; Detail = "Config=$($modes[0]), WebClient=$($modes[1]), Registry=$($modes[2])" }
    }
    catch { [PSCustomObject]@{ Mode = 'Unknown'; Detail = $_.Exception.Message } }
}

# --- UI ---
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Local\iQSuiteTenantTray', [ref]$createdNew)
if (-not $createdNew) { return }

function New-TrayIcon([string]$Text, [System.Drawing.Color]$Color) {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'AntiAliasGridFit'
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $Color), 1, 1, 30, 30)
    $font = New-Object System.Drawing.Font('Segoe UI', 15, [System.Drawing.FontStyle]::Bold, [System.Drawing.GraphicsUnit]::Pixel)
    $sf = New-Object System.Drawing.StringFormat
    $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
    $g.DrawString($Text, $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 1, 32, 32), $sf)
    $g.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $icon
}

$icons = @{
    Multi   = New-TrayIcon 'M' ([System.Drawing.Color]::RoyalBlue)
    Single  = New-TrayIcon 'S' ([System.Drawing.Color]::SeaGreen)
    Unknown = New-TrayIcon '?' ([System.Drawing.Color]::Firebrick)
    Busy    = New-TrayIcon ([string][char]0x2026) ([System.Drawing.Color]::DarkOrange)
}

$script:switchProc = $null
$script:switchTarget = $null

$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miStatus = $menu.Items.Add('Status: ...'); $miStatus.Enabled = $false
$null = $menu.Items.Add('-')
$miSingle = $menu.Items.Add('Switch to SingleTenant')
$miMulti  = $menu.Items.Add('Switch to MultiTenant')
$null = $menu.Items.Add('-')
$miLog  = $menu.Items.Add('Open log')
$miExit = $menu.Items.Add('Exit')
$notify.ContextMenuStrip = $menu

function Update-Ui {
    $busy = $null -ne $script:switchProc
    $state = Get-TenantState
    if ($busy) {
        $notify.Icon = $icons.Busy
        $text = "Switching to $($script:switchTarget)Tenant ..."
    }
    else {
        $notify.Icon = $icons[$state.Mode]
        $text = if ($state.Mode -eq 'Unknown') { "iQ.Suite: inconsistent ($($state.Detail))" } else { "iQ.Suite: $($state.Mode)Tenant" }
    }
    $miStatus.Text = $text
    $notify.Text = $text.Substring(0, [Math]::Min(63, $text.Length))
    $miSingle.Enabled = -not $busy -and $state.Mode -eq 'Multi'
    $miMulti.Enabled  = -not $busy -and $state.Mode -eq 'Single'
}

function Start-Switch([string]$Target) {
    if ($script:switchProc) { return }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        "Switch iQ.Suite to ${Target}Tenant?`nServices are stopped and IIS is reset (can take about a minute).",
        $AppName, 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }

    $cmd = "& '$SwitchScript' -Set${Target}Tenant -Force *> '$LogPath'; exit `$LASTEXITCODE"
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-Command', $cmd)
    try {
        $sp = @{ FilePath = 'powershell.exe'; ArgumentList = $args; PassThru = $true; WindowStyle = 'Hidden' }
        if (-not (Test-IsAdministrator)) { $sp.Verb = 'RunAs' }
        $script:switchProc = Start-Process @sp
        $script:switchTarget = $Target
    }
    catch {
        $notify.ShowBalloonTip(5000, $AppName, "Switch not started: $($_.Exception.Message)", 'Warning')
    }
    Update-Ui
}

$miSingle.add_Click({ Start-Switch 'Single' })
$miMulti.add_Click({ Start-Switch 'Multi' })
$miLog.add_Click({ if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath } })
$miExit.add_Click({
    $timer.Stop(); $notify.Visible = $false; $notify.Dispose()
    [System.Windows.Forms.Application]::Exit()
})
$notify.add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq 'Left') {
        [void][System.Windows.Forms.NotifyIcon].GetMethod('ShowContextMenu', [System.Reflection.BindingFlags]'Instance,NonPublic').Invoke($notify, $null)
    }
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [Math]::Max(1, $PollSeconds) * 1000
$timer.add_Tick({
    if ($script:switchProc -and $script:switchProc.HasExited) {
        $code = $script:switchProc.ExitCode
        $target = $script:switchTarget
        $script:switchProc = $null
        if ($code -eq 0) { $notify.ShowBalloonTip(4000, $AppName, "Switched to ${target}Tenant.", 'Info') }
        else { $notify.ShowBalloonTip(8000, $AppName, "Switch failed (exit code $code). See TenantTray.log.", 'Error') }
    }
    Update-Ui
})

Update-Ui
$timer.Start()
[System.Windows.Forms.Application]::Run()
$mutex.ReleaseMutex()
