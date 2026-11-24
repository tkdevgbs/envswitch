# iQ.Suite Env Switcher

Show and switch the environment of an iQ.Suite dev machine – from the command line or from a small **system tray app**:

- **Tenant mode** – MultiTenant / SingleTenant of the installed iQ.Suite
- **Frontend variant** – which VB6/MMC frontend is registered: the **Dev** build from the repo or the **Installed** product

| File | Purpose |
|------|---------|
| `TenantTray.ps1` | Tray app: shows tenant mode and frontend variant in one icon and switches both via menu |
| `Switch-iQSuiteTenantMode.ps1` | CLI: shows / switches the tenant mode (all-or-nothing, with rollback) |
| `Switch-iQSuiteFrontend.ps1` | CLI: shows / switches the frontend variant (with rollback) |
| `iQSuiteFrontend.Common.ps1` | Shared component lists and status detection for the frontend (used by CLI and tray) |

## Requirements

- Windows with PowerShell 5.1 (built in)
- iQ.Suite installed at the default locations
- For the frontend switch: a built repo working copy (default `D:\git\iqsuite-code`)
- **Administrator rights for switching** (registry under HKLM, files in `Program Files`, services, IIS, COM registration). Reading the status works without.

## Tray app

### Icon

| Icon | Tenant mode |
|------|-------------|
| 🔵 **M** | MultiTenant |
| 🟢 **S** | SingleTenant |
| 🔴 **?** | Inconsistent / unknown state (hover for details) |
| 🟠 **…** | Switch in progress |

A small badge in the lower right corner shows the frontend variant:

| Badge | Frontend |
|-------|----------|
| none | Installed |
| 🟡 | Dev |
| 🔴 | Mixed (parts of both registered) or not registered |

The tooltip shows both, e.g. `iQ.Suite: SingleTenant | Frontend: Dev`.

### Menu

Click the icon (left or right):

- **Status** – current tenant mode and frontend variant (read-only entries; `Frontend: Dev (<repo>)`, `Installed`, `mixed (<details>)` or `not registered`)
- **Switch to SingleTenant / MultiTenant** – only the opposite mode is enabled; a confirmation dialog appears first
- **Switch frontend to Installed / Dev** – only the variant that is not active is enabled (in a mixed state both); confirmation first, then a warning if the Dev DLLs are writable by non-admins (see [Security](#security))
- **Open log** – opens `TenantTray.log` (output of the last switch, tenant or frontend)
- **Exit**

Only one switch runs at a time. When it finishes, a balloon notification reports success or the exit code on failure. The status is refreshed every 5 seconds (`-PollSeconds` to change).

## Tenant switch

The tenant mode is stored in three places that must agree:

1. `C:\Program Files\GBS\iQ.Suite\Config\ConfigData.xml` (+ `SINGLE_` / `MULTI_` backup file)
2. `C:\ProgramData\GBS\iQ.Suite WebClient\dynamic_configuration.xml` (+ backup file)
3. `HKLM:\SOFTWARE\GBS\iQ.Suite\General` → `MultiTenant` (1 = Multi, 0 = Single)

A switch validates everything first, then: stops the services → removes stale `.lck` files → swaps the files → sets the registry value → starts the services → runs `iisreset` and restarts `iqsuitelivedata`. On any failure it rolls back. See the header of `Switch-iQSuiteTenantMode.ps1` for details.

```powershell
.\Switch-iQSuiteTenantMode.ps1                          # status only
.\Switch-iQSuiteTenantMode.ps1 -SetSingleTenant         # switch (asks for confirmation)
.\Switch-iQSuiteTenantMode.ps1 -SetMultiTenant -Force   # switch without prompt
```

| Exit code | Meaning |
|-----------|---------|
| `0` | OK (or already in target mode / aborted by user) |
| `1` | Not administrator / bad arguments |
| `2` | Inconsistent state – nothing changed |
| `3` | Pre-check failed (e.g. backup file missing) – nothing changed |
| `4` | Switch done, but state afterwards not consistent |
| `5` | Services could not be stopped – nothing changed, services restarted |
| `6` | Error while swapping files/registry – rolled back |
| `7` | Switch done, but a service could not be (re)started |
| `8` | Stale lock file could not be removed – nothing changed, services restarted |

## Frontend switch (Dev / Installed)

The VB6/MMC frontend exists twice on a dev machine. Both variants register the same 32-bit COM classes (`WOW6432Node`), so only one can be active:

| Variant | Location | Components |
|---------|----------|------------|
| Installed | `C:\Program Files\GBS\iQ.Suite\Bin` | `GTFSuite2.dll` (merged frontend), GTFSSD01, GTFSMO01, GTFCDB01, GTFTLS01, GTFSSN03, RemotingClient |
| Dev | `<repo>\msx\Implementation\Code\Frontend` (`_Components`, `Core\!Binaries`, `ConfigurationFrontend\!Binaries`) | one DLL per VB6 project (GTFC\*, GTFS\*, snap-ins incl. MT), GTFTLS01, RemotingClient |

The snap-in uses `GrpIQSuite.CTRLMainRoot` (installed `GTFSuite2.dll`) if it is registered, otherwise `GrpCMRoot.CTRLMainRoot` (Dev). The status is derived from a few marker ProgIDs (root objects, snap-ins, DBCore, GTFTLS01, RemotingClient):

| Status | Meaning |
|--------|---------|
| `Dev` | all markers point into the repo, `GrpIQSuite.*` is not registered |
| `Installed` | all markers point to `Bin\`, the Dev-only classes (`GrpCMRoot.*`, `GTIQSuite2.*`) are not registered |
| `Mixed` | anything else, e.g. parts of both variants, or a class temporarily redirected by the VB6 debugger |
| `None` | nothing registered |

A switch:

1. **Pre-checks** – administrator, required files of the target variant exist, 32-bit `regsvr32` / `RegAsm` exist, no process holds the frontend (**mmc**, VB6, DataGUI, GrpStat – note: *any* open MMC console blocks). Nothing is changed if a check fails.
2. **Unregisters the other variant** in reverse order (plus a Dev build of `GTFSuite2.dll` when switching to Dev, so `GrpIQSuite.*` cannot override the Dev DLLs). This also cleans up a mixed state.
3. **Registers the target variant** – `C:\Windows\SysWOW64\regsvr32.exe` for COM DLLs/OCXs, 32-bit `RegAsm /codebase` for the .NET RemotingClient. Optional Dev components that were not built (DBEng\*, H+B and MT snap-ins) are skipped.
4. **Verifies** the status. If a registration fails, the target is unregistered again and the previous variant is re-registered (only possible if the previous status was `Dev` or `Installed`).

No services are stopped – only the 32-bit MMC frontend loads these components. `msflxgrd.ocx` (in `SysWOW64`) is not touched.

```powershell
.\Switch-iQSuiteFrontend.ps1                          # status only (per marker: Dev / Installed / Missing / Other)
.\Switch-iQSuiteFrontend.ps1 -SetInstalled -DryRun    # pre-checks + plan, no changes
.\Switch-iQSuiteFrontend.ps1 -SetDev                  # switch (asks for confirmation)
.\Switch-iQSuiteFrontend.ps1 -SetDev -Force           # switch without prompt
.\Switch-iQSuiteFrontend.ps1 -SetDev -RepoRoot E:\src\iqsuite-code
```

| Exit code | Meaning |
|-----------|---------|
| `0` | OK (status Dev/Installed, switch done, already active, aborted by user or dry run) |
| `1` | Not administrator / bad arguments |
| `2` | Status is Mixed or None (status mode only) |
| `3` | Pre-check failed (e.g. required file missing) – nothing changed |
| `4` | Switch done, but the status afterwards is not the expected one |
| `5` | Frontend in use (MMC / VB6 / …) – nothing changed |
| `6` | Registration failed – previous variant restored |
| `7` | Registration failed and rollback failed or was not possible – check manually |

The default repo path is `D:\git\iqsuite-code`. The CLI takes `-RepoRoot`; for the tray change `$FrontendRepoRoot` in `iQSuiteFrontend.Common.ps1`.

## Running the tray app

Manually (hidden, no console window stays open):

```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\envswitch\TenantTray.ps1'
```

Only one instance can run at a time. If you start it directly in a PowerShell window, closing that window also ends the app.

### Autostart (recommended)

The autostart is a **scheduled task** that starts the tray at logon **with highest privileges**. Because the tray then already runs elevated, switching does **not** trigger a UAC prompt.

Open PowerShell **as Administrator** in the repo folder:

```powershell
.\TenantTray.ps1 -InstallAutostart      # register the task "iQSuiteTenantTray"
Start-ScheduledTask iQSuiteTenantTray   # start it now (otherwise: next logon)
```

Check / stop / restart:

```powershell
Get-ScheduledTask iQSuiteTenantTray
Stop-ScheduledTask iQSuiteTenantTray; Start-Sleep 2; Start-ScheduledTask iQSuiteTenantTray
```

> Wait a moment between stop and start: if the old instance still holds the single-instance lock, the new one exits immediately (task state `Ready` instead of `Running`).

Remove the autostart (as Administrator):

```powershell
.\TenantTray.ps1 -UninstallAutostart
```

> The task points to the **current location** of `TenantTray.ps1`. If you move the folder, run `-InstallAutostart` again. After updating the scripts, restart the task so the new version is used.

Without the autostart task the tray still works from a normal (non-elevated) start: a switch then asks for elevation via UAC.

## Security

The scripts in this folder run elevated, so the folder must only be writable by administrators (and you). Otherwise any local user could edit the scripts and have them run as admin. `-InstallAutostart` and all switch menu entries **refuse** to run if they detect non-admin write access. To lock down the folder (as Administrator):

```powershell
icacls D:\envswitch /inheritance:d /remove:g *S-1-5-32-545 /grant *S-1-5-32-545:(OI)(CI)RX
```

The frontend switch additionally runs `DllRegisterServer` / `DllUnregisterServer` of the **Dev DLLs** elevated – in both directions, because switching to Installed unregisters them. The repo is a dev working copy that is usually writable by `Users`, so the tray only **warns** about it and asks whether to continue (by design, it does not refuse). To get rid of the warning, apply the same `icacls` command to the repo folder.

## Troubleshooting

- **Switch failed balloon** – open the log via the tray menu (`TenantTray.log` next to the script).
- **Red `?` icon** – the three tenant sources disagree or a file/registry value is missing; run `.\Switch-iQSuiteTenantMode.ps1` to see the full report. The tray refuses to switch in this state on purpose.
- **Frontend switch fails with exit code 5** – close all MMC consoles (also unrelated ones like Services), VB6, DataGUI and GrpStat.
- **Red badge (frontend mixed)** – run `.\Switch-iQSuiteFrontend.ps1` to see which marker points where. While a project runs in the VB6 debugger, single classes point to VB6 – that is expected. Otherwise switch to the wanted variant, which cleans up the other one.
- **Dev frontend fails on open** (e.g. `Laufzeitfehler -2147417848 (80010108)`) – usually a wrong `GTFTLS01.dll` in `Frontend\_Components`; it must be the full build matching the other DLLs (same as in `Bin\`).
- **"Send to" / `GROUP.msc` / `MT_*.msc` do not start** – these consoles use the Dev snap-ins (GTFSSN01, MT\*SnapIn) and only work with the **Dev** frontend; the installed `iQ.Suite.msc` (GTFSSN03) works with both.
- **Nothing appears after start** – an instance is probably already running (single-instance lock). Look for the icon in the hidden-icons area of the taskbar.
- **Execution policy errors** – start with `-ExecutionPolicy Bypass` as shown above.
