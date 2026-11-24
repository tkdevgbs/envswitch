<#
    Shared definitions for the iQ.Suite frontend (VB6 / MMC) COM switch.
    Dot-sourced by Switch-iQSuiteFrontend.ps1 and TenantTray.ps1.

    The frontend exists in two variants that register the same COM classes:
      Installed : C:\Program Files\GBS\iQ.Suite\Bin  (GTFSuite2.dll = merged frontend)
      Dev       : <repo>\msx\Implementation\Code\Frontend\...\!Binaries  (one DLL per VB6 project)
    The snap-in creates "GrpIQSuite.CTRLMainRoot" (GTFSuite2) first and falls back
    to "GrpCMRoot.CTRLMainRoot" (Dev GTFSCO01), so the registration decides which
    code runs. All components are 32-bit (registered under WOW6432Node).
#>

if (-not (Get-Variable -Name FrontendRepoRoot -Scope Script -ErrorAction SilentlyContinue)) {
    $Script:FrontendRepoRoot = 'D:\git\iqsuite-code'
}
$Script:FrontendInstallBin = 'C:\Program Files\GBS\iQ.Suite\Bin'
$Script:FrontendDevRoot    = Join-Path $Script:FrontendRepoRoot 'msx\Implementation\Code\Frontend'

$Script:Regsvr32Exe = Join-Path $env:windir 'SysWOW64\regsvr32.exe'
$Script:RegAsm32Exe = Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\RegAsm.exe'

# Processes that load the frontend DLLs - switching while they run fails or leaves a mess.
$Script:FrontendBlockingProcesses = @('mmc', 'VB6', 'DataGUI', 'GrpStat')

<#
    Component lists in REGISTRATION order (dependencies first).
    Unregistration uses the reverse order.
      Type     : Com (regsvr32) or Net (RegAsm /codebase)
      Required : missing file -> pre-check fails; otherwise it is skipped
#>
function Get-FrontendComponents {
    param([Parameter(Mandatory)][ValidateSet('Dev', 'Installed')][string]$Variant)

    function C([string]$Dir, [string]$File, [string]$Type = 'Com', [bool]$Required = $true) {
        [PSCustomObject]@{ Path = (Join-Path $Dir $File); Type = $Type; Required = $Required }
    }

    if ($Variant -eq 'Installed') {
        $b = $Script:FrontendInstallBin
        return @(
            (C $b 'De.Group.Msx.RemotingClient.dll' 'Net'),
            (C $b 'GTFTLS01.dll'),
            (C $b 'GTFCDB01.dll'),
            (C $b 'GTFSSD01.dll'),
            (C $b 'GTFSMO01.dll'),
            (C $b 'GTFSuite2.dll'),
            (C $b 'GTFSSN03.dll')
        )
    }

    $comp = Join-Path $Script:FrontendDevRoot '_Components'
    $core = Join-Path $Script:FrontendDevRoot 'Core\!Binaries'
    $cfg  = Join-Path $Script:FrontendDevRoot 'ConfigurationFrontend\!Binaries'
    @(
        (C $comp 'De.Group.Msx.RemotingClient.dll' 'Net'),
        (C $comp 'GTFTLS01.dll'),
        (C $core 'GTFCDB01.dll'),
        (C $core 'DBEngADO.dll'    'Com' $false),
        (C $core 'DBEngNotes.dll'  'Com' $false),
        (C $core 'DBEngWebDAV.dll' 'Com' $false),
        (C $core 'GTFCLN01.dll'),
        (C $core 'GTFCCT01.dll'),
        (C $core 'GTFCUC01.dll'),
        (C $core 'GTFCUE01.ocx'),
        (C $cfg  'GTFSSD01.dll'),
        (C $cfg  'GTFSMO01.dll'),
        (C $cfg  'GTFSBL01.dll'),
        (C $cfg  'GTFSUI01.ocx'),
        (C $cfg  'GTFSCO01.dll'),
        (C $cfg  'GTFSSN01.dll'),
        (C $cfg  'GTFSSN03.dll'),
        (C $cfg  'GTFSSN02.dll'          'Com' $false),
        (C $cfg  'MTServerSnapIn.dll'    'Com' $false),
        (C $cfg  'MTMasterSnapIn.dll'    'Com' $false),
        (C $cfg  'MTTenantSnapIn.dll'    'Com' $false)
    )
}

<#
    Files that are only UNregistered when switching to $Variant (never registered):
    the Dev build of the merged GTFSuite2.dll would otherwise keep
    "GrpIQSuite.*" pointing into the repo and override the Dev multi-component setup.
#>
function Get-FrontendExtraUnregister {
    param([Parameter(Mandatory)][ValidateSet('Dev', 'Installed')][string]$Variant)
    if ($Variant -eq 'Dev') {
        @([PSCustomObject]@{ Path = (Join-Path $Script:FrontendDevRoot 'ConfigurationFrontend\!Binaries\GTFSuite2.dll'); Type = 'Com'; Required = $false })
    }
    else { @() }
}

<#
    Marker ProgIDs used to detect the active variant.
      Role Shared        : must point to the active variant
      Role DevOnly       : registered only in Dev       (must be missing in Installed)
      Role InstalledOnly : registered only in Installed (must be missing in Dev)
#>
$Script:FrontendProbes = @(
    [PSCustomObject]@{ Name = 'Root (GTFSuite2)';   ProgId = 'GrpIQSuite.CTRLMainRoot';                       Role = 'InstalledOnly' },
    [PSCustomObject]@{ Name = 'Root (GTFSCO01)';    ProgId = 'GrpCMRoot.CTRLMainRoot';                        Role = 'DevOnly' },
    [PSCustomObject]@{ Name = 'SnapIn (GTFSSN01)';  ProgId = 'GTIQSuite2.iQSuiteSnapIn';                      Role = 'DevOnly' },
    [PSCustomObject]@{ Name = 'SnapIn (GTFSSN03)';  ProgId = 'SnapInSMTP.IQSuiteSMTP';                        Role = 'Shared' },
    [PSCustomObject]@{ Name = 'DBCore (GTFCDB01)';  ProgId = 'GTDBCore.DBManager';                            Role = 'Shared' },
    [PSCustomObject]@{ Name = 'Tools (GTFTLS01)';   ProgId = 'GTFTLS01.HelperTools';                          Role = 'Shared' },
    [PSCustomObject]@{ Name = 'RemotingClient';     ProgId = 'De.Group.Mail.Msx.Remoting.COM.RemotingClient'; Role = 'Shared' }
)

function Get-RegValue([string]$Key, [string]$Name = '(default)') {
    $p = Get-ItemProperty -LiteralPath $Key -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    $prop = $p.PSObject.Properties[$Name]
    if ($prop) { $prop.Value } else { $null }
}

function Get-ComServerPath([string]$ProgId) {
    $clsid = Get-RegValue "HKLM:\SOFTWARE\Classes\$ProgId\Clsid"
    if (-not $clsid) { return $null }
    $key = "HKLM:\SOFTWARE\Classes\WOW6432Node\CLSID\$clsid\InprocServer32"
    $codeBase = Get-RegValue $key 'CodeBase'
    if ($codeBase) {
        try { return ([Uri]$codeBase).LocalPath } catch { return [string]$codeBase }
    }
    $server = Get-RegValue $key
    if ($server) { [string]$server } else { $null }
}

function Get-PathVariant([string]$Path) {
    if (-not $Path) { return 'Missing' }
    $full = $Path.Trim('"')
    if ($full.StartsWith($Script:FrontendDevRoot, [StringComparison]::OrdinalIgnoreCase)) { return 'Dev' }
    if ($full.StartsWith($Script:FrontendInstallBin, [StringComparison]::OrdinalIgnoreCase)) { return 'Installed' }
    'Other'
}

<#
    Returns Mode = Dev | Installed | Mixed | None, a short Detail text and the probe results.
#>
function Get-FrontendState {
    $results = foreach ($probe in $Script:FrontendProbes) {
        $path = Get-ComServerPath $probe.ProgId
        [PSCustomObject]@{
            Name    = $probe.Name
            ProgId  = $probe.ProgId
            Role    = $probe.Role
            Path    = $path
            Variant = (Get-PathVariant $path)
        }
    }

    $isVariant = {
        param($v)
        $other = if ($v -eq 'Dev') { 'InstalledOnly' } else { 'DevOnly' }
        @($results | Where-Object {
            if ($_.Role -eq $other) { $_.Variant -ne 'Missing' } else { $_.Variant -ne $v }
        }).Count -eq 0
    }

    $mode = if (& $isVariant 'Dev') { 'Dev' }
            elseif (& $isVariant 'Installed') { 'Installed' }
            elseif (@($results | Where-Object Variant -ne 'Missing').Count -eq 0) { 'None' }
            else { 'Mixed' }

    $detail = if ($mode -eq 'Mixed') {
        (@($results | Where-Object Variant -ne 'Missing' | ForEach-Object { "$($_.Name)=$($_.Variant)" }) -join ', ')
    } else { '' }

    [PSCustomObject]@{ Mode = $mode; Detail = $detail; Probes = @($results) }
}

<# Folders whose DLLs are executed (DllRegisterServer/DllUnregisterServer) during a switch. #>
function Get-FrontendDevFolders {
    @('_Components', 'Core\!Binaries', 'ConfigurationFrontend\!Binaries') |
        ForEach-Object { Join-Path $Script:FrontendDevRoot $_ }
}
