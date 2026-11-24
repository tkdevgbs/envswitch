#Requires -Version 5.1
<#
.SYNOPSIS
    Shows the currently active tenant mode (MultiTenant / SingleTenant) of the
    iQ.Suite or switches between the two modes.

.DESCRIPTION
    Checks three places where the tenant mode of the iQ.Suite is stored:
      1. C:\Program Files\GBS\iQ.Suite\Config\ConfigData.xml
         (active file) + SINGLE_ConfigData.xml / MULTI_ConfigData.xml (backup)
      2. C:\ProgramData\GBS\iQ.Suite WebClient\dynamic_configuration.xml
         (active file) + SINGLE_dynamic_configuration.xml / MULTI_dynamic_configuration.xml (backup)
      3. HKLM:\SOFTWARE\GBS\iQ.Suite\General -> DWORD MultiTenant (1 = Multi, 0 = Single)

    Without parameters, only the current status of all three sources is shown.
    With -SetMultiTenant or -SetSingleTenant, the script switches to the
    respective mode:
      1. Stops the iQ.Suite services (dependents first). A service that does
         not stop within the timeout is killed (e.g. a hung DatabaseScan).
      2. Removes stale *.lck files in the iQ.Suite config directory (left
         behind e.g. by the DataCollector when it stops on a mode change).
      3. Swaps the active files with their backup files (rename) and sets the
         registry value. If anything fails here, all changes are rolled back
         and the previously running services are started again.
      4. Starts the services again that were running before. In MultiTenant
         mode the DataCollector (iqsuitedc) is NOT started (it only waits in
         that mode); in SingleTenant mode it is always started.
      5. Runs iisreset and restarts the WebClient LiveDataProvider service so
         that the new WebClient configuration is picked up (errors here are
         not fatal, only a warning is shown).

    The switch is all-or-nothing: First, the script checks that all required
    files exist and that the registry key can be set. If anything is missing,
    it aborts WITHOUT changing anything (services are not touched either).

.PARAMETER SetMultiTenant
    Switches the iQ.Suite to MultiTenant mode.

.PARAMETER SetSingleTenant
    Switches the iQ.Suite to SingleTenant mode.

.PARAMETER Force
    Skips the confirmation prompt before switching. Does NOT skip the
    consistency/validation check.

.EXAMPLE
    .\Switch-iQSuiteTenantMode.ps1
    Shows the current status only.

.EXAMPLE
    .\Switch-iQSuiteTenantMode.ps1 -SetSingleTenant
    Switches to SingleTenant mode (after confirmation).

.EXAMPLE
    .\Switch-iQSuiteTenantMode.ps1 -SetMultiTenant -Force
    Switches to MultiTenant mode without prompting.
#>

[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(ParameterSetName = 'ToMulti')]
    [switch]$SetMultiTenant,

    [Parameter(ParameterSetName = 'ToSingle')]
    [switch]$SetSingleTenant,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
$Script:ConfigDir     = 'C:\Program Files\GBS\iQ.Suite\Config'
$Script:ConfigFile    = 'ConfigData.xml'

$Script:WebClientDir  = 'C:\ProgramData\GBS\iQ.Suite WebClient'
$Script:WebClientFile = 'dynamic_configuration.xml'

$Script:RegPath       = 'HKLM:\SOFTWARE\GBS\iQ.Suite\General'
$Script:RegValueName  = 'MultiTenant'

# iQ.Suite services in STOP order (dependents first):
#   iqsuitectrl <- iqsuite <- iqsuiteews, iqsuitedc
# They are started again in reverse order.
$Script:ServiceStopOrder = @('iqsuitedc', 'iqsuiteews', 'iqsuite', 'iqsuitectrl')

# Services that must not run in MultiTenant mode and are always started in
# SingleTenant mode (DataCollector only waits in MultiTenant mode and leaves
# a stale ConfigData.xml.lck behind when it stops on a mode change).
$Script:SingleTenantOnlyServices = @('iqsuitedc')

# Services that read the WebClient configuration and are restarted after iisreset.
$Script:WebClientServices = @('iqsuitelivedata')

# Seconds to wait for a service to stop before its process is killed.
$Script:ServiceStopTimeoutSeconds = 60

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

function Test-IsAdministrator {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
    Checks a file set (active file + backup files) in a directory
    and determines the currently active mode from it.
    Returns: PSCustomObject with Mode (Multi/Single/Unknown), details, paths.
#>
function Get-TenantModeOfLocation {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$FileName
    )

    $activePath  = Join-Path $Directory $FileName
    $singlePath  = Join-Path $Directory "SINGLE_$FileName"
    $multiPath   = Join-Path $Directory "MULTI_$FileName"

    $activeExists = Test-Path -LiteralPath $activePath -PathType Leaf
    $singleExists = Test-Path -LiteralPath $singlePath -PathType Leaf
    $multiExists  = Test-Path -LiteralPath $multiPath -PathType Leaf

    $mode    = 'Unknown'
    $details = ''

    if (-not $activeExists) {
        $details = "Active file '$activePath' is missing."
    }
    elseif ($singleExists -and $multiExists) {
        $details = "Both '$singlePath' and '$multiPath' exist - ambiguous."
    }
    elseif ($singleExists) {
        # Single backup is next to it -> active file is the Multi variant
        $mode    = 'Multi'
        $details = "Active: '$activePath'; Backup: '$singlePath'"
    }
    elseif ($multiExists) {
        # Multi backup is next to it -> active file is the Single variant
        $mode    = 'Single'
        $details = "Active: '$activePath'; Backup: '$multiPath'"
    }
    else {
        $details = "Neither '$singlePath' nor '$multiPath' exists - no backup found."
    }

    [PSCustomObject]@{
        Source       = "$Directory\$FileName"
        Mode         = $mode
        Details      = $details
        ActivePath   = $activePath
        SinglePath   = $singlePath
        MultiPath    = $multiPath
        ActiveExists = $activeExists
        SingleExists = $singleExists
        MultiExists  = $multiExists
    }
}

function Get-TenantModeFromRegistry {
    $source = "$RegPath\$RegValueName"

    if (-not (Test-Path -LiteralPath $RegPath)) {
        return [PSCustomObject]@{
            Source  = $source
            Mode    = 'Unknown'
            Details = "Registry path '$RegPath' does not exist."
        }
    }

    $prop = Get-ItemProperty -LiteralPath $RegPath -Name $RegValueName -ErrorAction SilentlyContinue
    if ($null -eq $prop) {
        return [PSCustomObject]@{
            Source  = $source
            Mode    = 'Unknown'
            Details = "Value '$RegValueName' does not exist under '$RegPath'."
        }
    }

    $value = $prop.$RegValueName
    switch ($value) {
        1 { [PSCustomObject]@{ Source = $source; Mode = 'Multi';   Details = "$RegValueName = 1" } }
        0 { [PSCustomObject]@{ Source = $source; Mode = 'Single';  Details = "$RegValueName = 0" } }
        default {
            [PSCustomObject]@{ Source = $source; Mode = 'Unknown'; Details = "$RegValueName = $value (unexpected value)" }
        }
    }
}

<#
    Returns the *.lck files in the iQ.Suite config directory.
#>
function Get-ConfigLockFiles {
    , @(Get-ChildItem -LiteralPath $ConfigDir -Filter '*.lck' -File -Force -ErrorAction SilentlyContinue)
}

<#
    Returns leftover '*.switching.tmp' files of an interrupted earlier switch.
#>
function Get-LeftoverSwitchFiles {
    $result = @()
    foreach ($dir in @($ConfigDir, $WebClientDir)) {
        $result += @(Get-ChildItem -LiteralPath $dir -Filter '*.switching.tmp' -File -Force -ErrorAction SilentlyContinue)
    }
    , $result
}

<#
    Determines the overall status from all three sources and summarizes
    whether the result is consistent.
#>
function Get-OverallTenantStatus {
    $configStatus    = Get-TenantModeOfLocation -Directory $ConfigDir -FileName $ConfigFile
    $webClientStatus = Get-TenantModeOfLocation -Directory $WebClientDir -FileName $WebClientFile
    $registryStatus  = Get-TenantModeFromRegistry

    $allStatuses = @($configStatus, $webClientStatus, $registryStatus)
    $distinctModes = @($allStatuses | Select-Object -ExpandProperty Mode -Unique)

    $isConsistent  = ($distinctModes.Count -eq 1) -and ($distinctModes[0] -ne 'Unknown')
    $overallMode   = if ($isConsistent) { $distinctModes[0] } else { 'Unknown' }

    [PSCustomObject]@{
        ConfigStatus    = $configStatus
        WebClientStatus = $webClientStatus
        RegistryStatus  = $registryStatus
        IsConsistent    = $isConsistent
        OverallMode     = $overallMode
        LockFiles       = (Get-ConfigLockFiles)
    }
}

function Write-TenantStatusReport {
    param(
        [Parameter(Mandatory)]$Status
    )

    Write-Host ''
    Write-Host 'iQ.Suite Tenant Mode - Status' -ForegroundColor Cyan
    Write-Host '--------------------------------'
    foreach ($entry in @($Status.ConfigStatus, $Status.WebClientStatus, $Status.RegistryStatus)) {
        $color = switch ($entry.Mode) {
            'Multi'   { 'Green' }
            'Single'  { 'Green' }
            default   { 'Yellow' }
        }
        Write-Host ("  {0,-55} -> {1,-8} ({2})" -f $entry.Source, $entry.Mode, $entry.Details) -ForegroundColor $color
    }
    Write-Host ''

    Write-Host 'Services:' -ForegroundColor Cyan
    foreach ($name in @($ServiceStopOrder + $WebClientServices)) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -eq $svc) {
            Write-Host ("  {0,-20} not installed" -f $name) -ForegroundColor DarkGray
        }
        else {
            Write-Host ("  {0,-20} {1,-10} ({2})" -f $name, $svc.Status, $svc.DisplayName)
        }
    }
    Write-Host ''

    if (@($Status.LockFiles).Count -gt 0) {
        Write-Host 'WARNING: Lock file(s) found in the config directory:' -ForegroundColor Yellow
        foreach ($f in $Status.LockFiles) {
            $firstLine = Get-Content -LiteralPath $f.FullName -TotalCount 1 -ErrorAction SilentlyContinue
            Write-Host "  - $($f.FullName): $firstLine" -ForegroundColor Yellow
        }
        Write-Host '  If no iQ.Suite service holds them, they block config loading and tenant deployment.' -ForegroundColor Yellow
        Write-Host '  A switch removes them automatically after stopping the services.' -ForegroundColor Yellow
        Write-Host ''
    }

    if ($Status.IsConsistent) {
        Write-Host ("Current mode: {0}Tenant" -f $Status.OverallMode) -ForegroundColor Cyan
    }
    else {
        Write-Host 'WARNING: Inconsistent state - the three sources do not match!' -ForegroundColor Red
        Write-Host 'Please check manually before switching automatically.' -ForegroundColor Red
    }
    Write-Host ''
}

<#
    Checks whether switching a file location towards $TargetMode is possible
    (backup file for the target mode exists, active file exists).
    Returns $true/$false and fills $Reason via [ref].
#>
function Test-LocationSwitchPossible {
    param(
        [Parameter(Mandatory)]$LocationStatus,
        [Parameter(Mandatory)][ValidateSet('Multi', 'Single')][string]$TargetMode,
        [ref]$Reason
    )

    if (-not $LocationStatus.ActiveExists) {
        $Reason.Value = "Active file '$($LocationStatus.ActivePath)' is missing."
        return $false
    }

    # The backup file containing the TargetMode must exist
    $neededBackup = if ($TargetMode -eq 'Multi') { $LocationStatus.MultiPath } else { $LocationStatus.SinglePath }
    $neededExists = if ($TargetMode -eq 'Multi') { $LocationStatus.MultiExists } else { $LocationStatus.SingleExists }

    if (-not $neededExists) {
        $Reason.Value = "Required backup file '$neededBackup' for target mode '$TargetMode' is missing."
        return $false
    }

    $Reason.Value = 'OK'
    return $true
}

<#
    Performs the rename swap for a file location:
    active file -> backup with the prefix of the mode we are leaving
    backup with the prefix of the target mode -> active file
    Every successful rename is recorded in $Journal so it can be rolled back.
#>
function Invoke-LocationSwitch {
    param(
        [Parameter(Mandatory)]$LocationStatus,
        [Parameter(Mandatory)][ValidateSet('Multi', 'Single')][string]$CurrentMode,
        [Parameter(Mandatory)][ValidateSet('Multi', 'Single')][string]$TargetMode,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Journal
    )

    $leavingPrefixPath = if ($CurrentMode -eq 'Multi') { $LocationStatus.MultiPath } else { $LocationStatus.SinglePath }
    $targetBackupPath  = if ($TargetMode -eq 'Multi') { $LocationStatus.MultiPath } else { $LocationStatus.SinglePath }

    # Intermediate step via a temporary name, so that a target file is never
    # overwritten if something already exists due to edge cases.
    $tempPath = $LocationStatus.ActivePath + '.switching.tmp'

    $steps = @(
        @{ From = $LocationStatus.ActivePath; To = $tempPath },
        @{ From = $targetBackupPath;          To = $LocationStatus.ActivePath },
        @{ From = $tempPath;                  To = $leavingPrefixPath }
    )

    foreach ($step in $steps) {
        Write-Host "  - Rename '$($step.From)' -> '$($step.To)'"
        Rename-Item -LiteralPath $step.From -NewName (Split-Path $step.To -Leaf) -Force
        $Journal.Add([PSCustomObject]@{
            CurrentPath  = $step.To
            OriginalName = (Split-Path $step.From -Leaf)
        })
    }
}

<#
    Reverts all renames recorded in $Journal (in reverse order).
    Returns $true if everything could be reverted.
#>
function Undo-LocationSwitches {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Journal
    )

    $ok = $true
    for ($i = $Journal.Count - 1; $i -ge 0; $i--) {
        $entry = $Journal[$i]
        try {
            Write-Host "  - Revert '$($entry.CurrentPath)' -> '$($entry.OriginalName)'" -ForegroundColor Yellow
            Rename-Item -LiteralPath $entry.CurrentPath -NewName $entry.OriginalName -Force
        }
        catch {
            Write-Host "    FAILED: $($_.Exception.Message)" -ForegroundColor Red
            $ok = $false
        }
    }
    return $ok
}

# ---------------------------------------------------------------------------
# Service handling
# ---------------------------------------------------------------------------

<#
    Returns the names of the iQ.Suite services (from $ServiceStopOrder) that
    are currently not stopped.
#>
function Get-RunningIQSuiteServices {
    , @($ServiceStopOrder | Where-Object {
        $svc = Get-Service -Name $_ -ErrorAction SilentlyContinue
        $null -ne $svc -and $svc.Status -ne 'Stopped'
    })
}

<#
    Stops a service. If it does not stop within $ServiceStopTimeoutSeconds,
    its process is killed. Throws if the service is still not stopped.
#>
function Stop-IQSuiteServiceSafe {
    param([Parameter(Mandatory)][string]$Name)

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Host "  - Service '$Name' is not installed, skipping."
        return
    }
    if ($svc.Status -eq 'Stopped') {
        Write-Host "  - Service '$Name' is already stopped."
        return
    }

    Write-Host "  - Stopping service '$Name' (timeout $ServiceStopTimeoutSeconds s) ..."
    try {
        if ($svc.Status -ne 'StopPending') { $svc.Stop() }
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds($ServiceStopTimeoutSeconds))
        Write-Host '    stopped.'
        return
    }
    catch {
        Write-Host "    Service did not stop cleanly: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Service hangs -> kill its process
    $procId = (Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'").ProcessId
    if ($procId -and $procId -ne 0) {
        Write-Host "    Killing hung process (PID $procId) ..." -ForegroundColor Yellow
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }

    try {
        $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
    catch {
        $svc.Refresh()
        throw "Service '$Name' could not be stopped (status: $($svc.Status))."
    }
    Write-Host '    stopped (process killed).' -ForegroundColor Yellow
}

<#
    Starts a service. Errors are reported as a warning and returned as $false.
#>
function Start-IQSuiteServiceSafe {
    param([Parameter(Mandatory)][string]$Name)

    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Host "  - Service '$Name' is not installed, skipping."
        return $true
    }
    if ($svc.Status -eq 'Running') {
        Write-Host "  - Service '$Name' is already running."
        return $true
    }

    Write-Host "  - Starting service '$Name' ..."
    try {
        Start-Service -Name $Name
        Write-Host '    started.'
        return $true
    }
    catch {
        Write-Host "    WARNING: Could not start '$Name': $($_.Exception.Message)" -ForegroundColor Yellow
        return $false
    }
}

<#
    Stops all iQ.Suite services in dependency order (dependents first).
#>
function Stop-IQSuiteServices {
    foreach ($name in $ServiceStopOrder) {
        Stop-IQSuiteServiceSafe -Name $name
    }
}

<#
    Starts the given services in reverse stop order (dependencies first).
    Returns the names of the services that failed to start.
#>
function Start-IQSuiteServices {
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names)

    $failed = @()
    $startOrder = @($ServiceStopOrder)
    [array]::Reverse($startOrder)
    foreach ($name in $startOrder) {
        if ($Names -contains $name) {
            if (-not (Start-IQSuiteServiceSafe -Name $name)) { $failed += $name }
        }
    }
    return $failed
}

<#
    Determines which services have to be started after switching to $TargetMode:
    all services that were running before, except the SingleTenant-only
    services in MultiTenant mode; in SingleTenant mode these are always started.
#>
function Get-ServicesToStart {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$PreviouslyRunning,
        [Parameter(Mandatory)][ValidateSet('Multi', 'Single')][string]$TargetMode
    )

    , @($ServiceStopOrder | Where-Object {
        $isSingleOnly = $SingleTenantOnlyServices -contains $_
        if ($TargetMode -eq 'Multi') {
            ($PreviouslyRunning -contains $_) -and -not $isSingleOnly
        }
        else {
            ($PreviouslyRunning -contains $_) -or $isSingleOnly
        }
    })
}

<#
    Removes stale *.lck files in the config directory. Must only be called
    while all iQ.Suite services are stopped.
#>
function Remove-StaleLockFiles {
    $lockFiles = Get-ConfigLockFiles
    if ($lockFiles.Count -eq 0) {
        Write-Host '  - No lock files found.'
        return
    }
    foreach ($f in $lockFiles) {
        $firstLine = Get-Content -LiteralPath $f.FullName -TotalCount 1 -ErrorAction SilentlyContinue
        Write-Host "  - Removing '$($f.FullName)' ($firstLine)" -ForegroundColor Yellow
        Remove-Item -LiteralPath $f.FullName -Force
    }
}

# ---------------------------------------------------------------------------
# Switch
# ---------------------------------------------------------------------------

function Invoke-TenantSwitch {
    param(
        [Parameter(Mandatory)][ValidateSet('Multi', 'Single')][string]$TargetMode,
        [switch]$Force
    )

    if (-not (Test-IsAdministrator)) {
        Write-Host 'ERROR: This script requires administrative privileges (registry under HKLM, files under Program Files, services).' -ForegroundColor Red
        Write-Host 'Please start PowerShell as Administrator and run it again.' -ForegroundColor Red
        exit 1
    }

    $status = Get-OverallTenantStatus

    if ($status.IsConsistent -and $status.OverallMode -eq $TargetMode) {
        Write-Host "Already in the desired mode: ${TargetMode}Tenant. No change necessary." -ForegroundColor Cyan
        Write-TenantStatusReport -Status $status
        exit 0
    }

    if (-not $status.IsConsistent) {
        Write-Host 'ERROR: The current state is inconsistent. Aborting to avoid making wrong assumptions.' -ForegroundColor Red
        Write-TenantStatusReport -Status $status
        exit 2
    }

    $currentMode = $status.OverallMode

    # --- Validation phase (all-or-nothing) ---
    Write-Host "Checking whether switching from ${currentMode}Tenant to ${TargetMode}Tenant is possible ..." -ForegroundColor Cyan

    $problems = New-Object System.Collections.Generic.List[string]

    $reason = ''
    if (-not (Test-LocationSwitchPossible -LocationStatus $status.ConfigStatus -TargetMode $TargetMode -Reason ([ref]$reason))) {
        $problems.Add("Config: $reason")
    }
    if (-not (Test-LocationSwitchPossible -LocationStatus $status.WebClientStatus -TargetMode $TargetMode -Reason ([ref]$reason))) {
        $problems.Add("WebClient: $reason")
    }
    if (-not (Test-Path -LiteralPath $RegPath)) {
        $problems.Add("Registry: Path '$RegPath' does not exist.")
    }
    foreach ($leftover in (Get-LeftoverSwitchFiles)) {
        $problems.Add("Leftover file of an interrupted switch: '$($leftover.FullName)'")
    }

    if ($problems.Count -gt 0) {
        Write-Host 'ERROR: Switch not possible, NOTHING was changed:' -ForegroundColor Red
        foreach ($p in $problems) { Write-Host "  - $p" -ForegroundColor Red }
        exit 3
    }

    $previouslyRunning = Get-RunningIQSuiteServices
    $servicesToStart   = Get-ServicesToStart -PreviouslyRunning $previouslyRunning -TargetMode $TargetMode
    $regValue          = if ($TargetMode -eq 'Multi') { 1 } else { 0 }
    $oldRegValue       = (Get-ItemProperty -LiteralPath $RegPath -Name $RegValueName).$RegValueName

    Write-Host 'Validation successful. The following actions will be performed:' -ForegroundColor Cyan
    Write-Host "  1. Stop iQ.Suite services: $($ServiceStopOrder -join ', ') (hung processes are killed)"
    Write-Host "  2. Remove stale lock files in '$ConfigDir'"
    Write-Host "  3. Swap config files in '$ConfigDir'"
    Write-Host "  4. Swap WebClient files in '$WebClientDir'"
    Write-Host "  5. Set registry value '$RegPath\$RegValueName' to $regValue"
    Write-Host "  6. Start services: $(if ($servicesToStart.Count) { $servicesToStart -join ', ' } else { '(none)' })"
    Write-Host "  7. Run iisreset and restart $($WebClientServices -join ', ')"
    if (@($status.LockFiles).Count -gt 0) {
        Write-Host ''
        Write-Host "  Note: $(@($status.LockFiles).Count) lock file(s) currently exist and will be removed in step 2." -ForegroundColor Yellow
    }
    Write-Host ''

    if (-not $Force) {
        $answer = Read-Host "Switch from ${currentMode}Tenant to ${TargetMode}Tenant now? (Y/N)"
        if ($answer -notmatch '^(y|yes)$') {
            Write-Host 'Aborted by user. No changes were made.' -ForegroundColor Yellow
            exit 0
        }
    }

    # --- 1. Stop services ---
    Write-Host ''
    Write-Host '1. Stopping iQ.Suite services ...' -ForegroundColor Cyan
    try {
        Stop-IQSuiteServices
    }
    catch {
        Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'No files or registry values were changed. Starting the previously running services again ...' -ForegroundColor Red
        [void](Start-IQSuiteServices -Names $previouslyRunning)
        exit 5
    }

    # --- 2. Remove stale lock files ---
    Write-Host '2. Removing stale lock files ...' -ForegroundColor Cyan
    Remove-StaleLockFiles

    # --- 3.-5. Swap files and set registry (with rollback) ---
    $journal = New-Object 'System.Collections.Generic.List[object]'
    $registryChanged = $false
    try {
        Write-Host '3. Swapping config files ...' -ForegroundColor Cyan
        Invoke-LocationSwitch -LocationStatus $status.ConfigStatus -CurrentMode $currentMode -TargetMode $TargetMode -Journal $journal

        Write-Host '4. Swapping WebClient files ...' -ForegroundColor Cyan
        Invoke-LocationSwitch -LocationStatus $status.WebClientStatus -CurrentMode $currentMode -TargetMode $TargetMode -Journal $journal

        Write-Host '5. Setting registry value ...' -ForegroundColor Cyan
        Set-ItemProperty -LiteralPath $RegPath -Name $RegValueName -Value $regValue -Type DWord
        $registryChanged = $true
    }
    catch {
        Write-Host ''
        Write-Host "ERROR during switch: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Rolling back ...' -ForegroundColor Yellow

        $rollbackOk = Undo-LocationSwitches -Journal $journal
        if ($registryChanged) {
            try {
                Set-ItemProperty -LiteralPath $RegPath -Name $RegValueName -Value $oldRegValue -Type DWord
            }
            catch {
                Write-Host "  - Restoring registry value FAILED: $($_.Exception.Message)" -ForegroundColor Red
                $rollbackOk = $false
            }
        }

        Write-Host 'Starting the previously running services again ...' -ForegroundColor Yellow
        [void](Start-IQSuiteServices -Names $previouslyRunning)

        if ($rollbackOk) {
            Write-Host "Rollback completed. The system is in ${currentMode}Tenant mode again." -ForegroundColor Yellow
        }
        else {
            Write-Host 'Rollback was NOT completely successful. Please check the files and registry manually!' -ForegroundColor Red
        }
        Write-TenantStatusReport -Status (Get-OverallTenantStatus)
        exit 6
    }

    # --- 6. Start services ---
    Write-Host '6. Starting iQ.Suite services ...' -ForegroundColor Cyan
    $failedServices = @(Start-IQSuiteServices -Names $servicesToStart)

    # --- 7. iisreset + WebClient services ---
    Write-Host '7. Running iisreset ...' -ForegroundColor Cyan
    try {
        $iisresetOutput = & iisreset.exe 2>&1
        $iisresetOutput | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) {
            Write-Host "WARNING: iisreset exited with exit code $LASTEXITCODE. Please check IIS manually." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "WARNING: iisreset could not be executed: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host 'The file/registry switch was completed nevertheless. Please restart IIS manually if necessary.' -ForegroundColor Yellow
    }

    foreach ($name in $WebClientServices) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -eq 'Running') {
            Write-Host "  - Restarting service '$name' ..."
            try {
                Restart-Service -Name $name -Force
                Write-Host '    restarted.'
            }
            catch {
                Write-Host "    WARNING: Could not restart '$name': $($_.Exception.Message)" -ForegroundColor Yellow
                $failedServices += $name
            }
        }
    }

    Write-Host ''
    Write-Host "Switch to ${TargetMode}Tenant completed." -ForegroundColor Green

    $newStatus = Get-OverallTenantStatus
    Write-TenantStatusReport -Status $newStatus

    if (-not ($newStatus.IsConsistent -and $newStatus.OverallMode -eq $TargetMode)) {
        Write-Host 'WARNING: After the switch, the state is not consistent as expected. Please check manually.' -ForegroundColor Red
        exit 4
    }

    if ($failedServices.Count -gt 0) {
        Write-Host "WARNING: The following services could not be (re)started: $($failedServices -join ', ')" -ForegroundColor Yellow
        exit 7
    }

    exit 0
}

# ---------------------------------------------------------------------------
# Main flow
# ---------------------------------------------------------------------------

if ($SetMultiTenant -and $SetSingleTenant) {
    Write-Host 'ERROR: -SetMultiTenant and -SetSingleTenant cannot be specified at the same time.' -ForegroundColor Red
    exit 1
}

if ($SetMultiTenant) {
    Invoke-TenantSwitch -TargetMode 'Multi' -Force:$Force
}
elseif ($SetSingleTenant) {
    Invoke-TenantSwitch -TargetMode 'Single' -Force:$Force
}
else {
    $status = Get-OverallTenantStatus
    Write-TenantStatusReport -Status $status
    if ($status.IsConsistent) { exit 0 } else { exit 2 }
}
