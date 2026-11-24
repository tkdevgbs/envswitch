#Requires -Version 5.1
<#
.SYNOPSIS
    Shows which iQ.Suite frontend variant (Dev build from the repo or the
    installed product) is registered, or switches between the two.

.DESCRIPTION
    The VB6/MMC frontend exists twice on a dev machine:
      Installed : C:\Program Files\GBS\iQ.Suite\Bin (GTFSuite2.dll = merged frontend)
      Dev       : <RepoRoot>\msx\Implementation\Code\Frontend\{_Components,Core\!Binaries,ConfigurationFrontend\!Binaries}
    Both register the same COM classes (32-bit, WOW6432Node), so only one can be active.
    See iQSuiteFrontend.Common.ps1 for the component lists and the status detection.

    Without parameters only the status is shown. With -SetDev / -SetInstalled:
      1. Pre-checks: administrator, required files of the target variant exist,
         regsvr32/RegAsm (32-bit) exist, no process holds the frontend
         (mmc, VB6, DataGUI, GrpStat).
      2. Unregisters the OTHER variant (reverse order) - also cleans up a mixed state.
      3. Registers the target variant (32-bit regsvr32, RegAsm /codebase for the
         .NET RemotingClient).
      4. If a registration fails: unregisters the target again and re-registers
         the previous variant (only possible if the previous state was Dev or Installed).
    No services are stopped: only the 32-bit MMC frontend loads these components.

.PARAMETER SetDev
    Registers the Dev build from the repo.

.PARAMETER SetInstalled
    Registers the installed product's frontend.

.PARAMETER RepoRoot
    Root of the iqsuite-code repo (default D:\git\iqsuite-code).

.PARAMETER Force
    Skips the confirmation prompt (not the pre-checks).

.PARAMETER DryRun
    Runs the pre-checks and prints the planned actions without changing anything.

.NOTES
    Exit codes:
      0  OK (status Dev/Installed / switch done / already active / aborted by user / dry run)
      1  Not administrator or invalid arguments
      2  Status is Mixed or None (status mode only)
      3  Pre-check failed, e.g. required file missing (nothing changed)
      4  Switch done, but the state afterwards is not the expected one
      5  Frontend is in use (mmc/VB6/...), nothing changed
      6  Registration failed, previous variant restored
      7  Registration failed and rollback failed or was not possible - check manually
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'ToDev')][switch]$SetDev,
    [Parameter(ParameterSetName = 'ToInstalled')][switch]$SetInstalled,
    [string]$RepoRoot = 'D:\git\iqsuite-code',
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Script:FrontendRepoRoot = $RepoRoot
. (Join-Path $PSScriptRoot 'iQSuiteFrontend.Common.ps1')

function Test-IsAdministrator {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Write-FrontendStatusReport($State) {
    Write-Host ''
    Write-Host 'iQ.Suite Frontend - Status' -ForegroundColor Cyan
    Write-Host '--------------------------'
    Write-Host "  Dev root    : $FrontendDevRoot"
    Write-Host "  Install bin : $FrontendInstallBin"
    Write-Host ''
    foreach ($p in $State.Probes) {
        $color = switch ($p.Variant) { 'Dev' { 'Yellow' } 'Installed' { 'Green' } 'Missing' { 'DarkGray' } default { 'Red' } }
        Write-Host ("  {0,-20} {1,-10} {2}" -f $p.Name, $p.Variant, $(if ($p.Path) { $p.Path } else { "($($p.ProgId) not registered)" })) -ForegroundColor $color
    }
    Write-Host ''
    $color = switch ($State.Mode) { 'Dev' { 'Yellow' } 'Installed' { 'Green' } default { 'Red' } }
    Write-Host "Current frontend: $($State.Mode)" -ForegroundColor $color
    Write-Host ''
}

<#
    Runs regsvr32 (32-bit) or RegAsm (32-bit) for one component.
    Returns $true on success. Output goes to the host (= log).
#>
function Invoke-ComponentRegistration {
    param(
        [Parameter(Mandatory)]$Component,
        [switch]$Unregister
    )
    $verb = if ($Unregister) { 'Unregister' } else { 'Register' }
    if (-not (Test-Path -LiteralPath $Component.Path -PathType Leaf)) {
        Write-Host "  - $verb $($Component.Path): file not found, skipped." -ForegroundColor DarkGray
        return $true
    }

    if ($Component.Type -eq 'Net') {
        $argList = @(if ($Unregister) { '/unregister' } else { '/codebase' }) + @('/silent', $Component.Path)
        # Windows PowerShell 5.1 turns native stderr into terminating errors under
        # ErrorActionPreference 'Stop' when redirected with 2>&1 - that would abort
        # the switch without rollback. Evaluate the exit code instead.
        $ErrorActionPreference = 'Continue'
        $out = & $RegAsm32Exe @argList 2>&1
        $code = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        $out | Where-Object { "$_".Trim() } | ForEach-Object { Write-Host "      $_" }
    }
    else {
        $argList = @('/s') + @(if ($Unregister) { '/u' }) + @("`"$($Component.Path)`"")
        $proc = Start-Process -FilePath $Regsvr32Exe -ArgumentList $argList -Wait -PassThru -WindowStyle Hidden
        $code = $proc.ExitCode
    }

    if ($code -eq 0) {
        Write-Host "  - $verb $($Component.Path): OK"
        return $true
    }
    $color = if ($Unregister) { 'Yellow' } else { 'Red' }
    Write-Host "  - $verb $($Component.Path): FAILED (exit code $code)" -ForegroundColor $color
    return $false
}

<# Unregisters a component list in reverse order. Failures are only warnings. #>
function Invoke-Unregister([object[]]$Components) {
    for ($i = $Components.Count - 1; $i -ge 0; $i--) {
        [void](Invoke-ComponentRegistration -Component $Components[$i] -Unregister)
    }
}

<# Registers a component list in order. Returns the failed paths. #>
function Invoke-Register([object[]]$Components) {
    $failed = @()
    foreach ($c in $Components) {
        if (-not (Invoke-ComponentRegistration -Component $c)) { $failed += $c.Path }
    }
    , $failed
}

function Invoke-FrontendSwitch {
    param(
        [Parameter(Mandatory)][ValidateSet('Dev', 'Installed')][string]$Target,
        [switch]$Force,
        [switch]$DryRun
    )

    if (-not $DryRun -and -not (Test-IsAdministrator)) {
        Write-Host 'ERROR: Administrator rights required (COM registration under HKLM).' -ForegroundColor Red
        exit 1
    }

    $state = Get-FrontendState
    if ($state.Mode -eq $Target) {
        Write-Host "Frontend is already registered as '$Target'. No change necessary." -ForegroundColor Cyan
        Write-FrontendStatusReport $state
        exit 0
    }

    $other           = if ($Target -eq 'Dev') { 'Installed' } else { 'Dev' }
    $targetComps     = @(Get-FrontendComponents $Target)
    $otherComps      = @(Get-FrontendComponents $other)
    $extraUnregister = @(Get-FrontendExtraUnregister $Target)

    # --- Pre-checks (nothing is changed before all of them pass) ---
    Write-Host "Checking whether switching the frontend from '$($state.Mode)' to '$Target' is possible ..." -ForegroundColor Cyan
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($exe in @($Regsvr32Exe, $RegAsm32Exe)) {
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { $problems.Add("Tool not found: $exe") }
    }
    foreach ($c in $targetComps | Where-Object Required) {
        if (-not (Test-Path -LiteralPath $c.Path -PathType Leaf)) { $problems.Add("Required file missing: $($c.Path)") }
    }
    if ($problems.Count -gt 0) {
        Write-Host 'ERROR: Switch not possible, NOTHING was changed:' -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
        exit 3
    }

    $blocking = @(Get-Process -Name $FrontendBlockingProcesses -ErrorAction SilentlyContinue)
    if ($blocking.Count -gt 0) {
        Write-Host 'ERROR: The frontend is in use, NOTHING was changed. Close these processes first:' -ForegroundColor Red
        foreach ($p in $blocking) { Write-Host "  - $($p.ProcessName) (PID $($p.Id))" -ForegroundColor Red }
        exit 5
    }

    Write-Host 'Pre-checks passed. Planned actions:' -ForegroundColor Cyan
    Write-Host "  1. Unregister '$other' components ($($otherComps.Count + $extraUnregister.Count) files, reverse order)"
    Write-Host "  2. Register '$Target' components ($($targetComps.Count) files):"
    foreach ($c in $targetComps) {
        $flag = if (Test-Path -LiteralPath $c.Path -PathType Leaf) { '' } else { '  (missing, optional - skipped)' }
        Write-Host "       $($c.Type)  $($c.Path)$flag"
    }
    Write-Host ''

    if ($DryRun) {
        Write-Host 'Dry run - nothing was changed.' -ForegroundColor Yellow
        Write-FrontendStatusReport $state
        exit 0
    }

    if (-not $Force) {
        $answer = Read-Host "Switch frontend to '$Target' now? (Y/N)"
        if ($answer -notmatch '^(y|yes|j|ja)$') {
            Write-Host 'Aborted by user. No changes were made.' -ForegroundColor Yellow
            exit 0
        }
    }

    Write-Host "1. Unregistering '$other' components ..." -ForegroundColor Cyan
    Invoke-Unregister ($extraUnregister + $otherComps)

    Write-Host "2. Registering '$Target' components ..." -ForegroundColor Cyan
    $failed = Invoke-Register $targetComps

    if ($failed.Count -gt 0) {
        Write-Host ''
        Write-Host "ERROR: $($failed.Count) component(s) could not be registered." -ForegroundColor Red
        if ($state.Mode -in @('Dev', 'Installed')) {
            Write-Host "Rolling back to '$($state.Mode)' ..." -ForegroundColor Yellow
            Invoke-Unregister $targetComps
            $rbFailed = Invoke-Register (Get-FrontendComponents $state.Mode)
            $after = Get-FrontendState
            Write-FrontendStatusReport $after
            if ($rbFailed.Count -eq 0 -and $after.Mode -eq $state.Mode) {
                Write-Host "Rollback completed, frontend is '$($state.Mode)' again." -ForegroundColor Yellow
                exit 6
            }
            Write-Host 'Rollback was NOT completely successful. Please check the registration manually!' -ForegroundColor Red
            exit 7
        }
        Write-Host "Previous state was '$($state.Mode)' - no automatic rollback possible. Please check manually!" -ForegroundColor Red
        Write-FrontendStatusReport (Get-FrontendState)
        exit 7
    }

    $newState = Get-FrontendState
    Write-Host ''
    Write-FrontendStatusReport $newState
    if ($newState.Mode -ne $Target) {
        Write-Host "WARNING: After the switch the frontend is '$($newState.Mode)', expected '$Target'. Please check manually." -ForegroundColor Red
        exit 4
    }
    Write-Host "Frontend switched to '$Target'." -ForegroundColor Green
    exit 0
}

# --- Main ---
if ($SetDev -and $SetInstalled) {
    Write-Host 'ERROR: -SetDev and -SetInstalled cannot be combined.' -ForegroundColor Red
    exit 1
}
if ($SetDev)           { Invoke-FrontendSwitch -Target 'Dev' -Force:$Force -DryRun:$DryRun }
elseif ($SetInstalled) { Invoke-FrontendSwitch -Target 'Installed' -Force:$Force -DryRun:$DryRun }
else {
    $state = Get-FrontendState
    Write-FrontendStatusReport $state
    if ($state.Mode -in @('Dev', 'Installed')) { exit 0 } else { exit 2 }
}
