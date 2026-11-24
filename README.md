# iQ.Suite Env Switcher

Show and switch the **tenant mode** (MultiTenant / SingleTenant) of an iQ.Suite installation – from the command line or from a small **system tray app**.

| File | Purpose |
|------|---------|
| `Switch-iQSuiteTenantMode.ps1` | CLI tool: shows the current mode or switches it (all-or-nothing, with rollback) |
| `TenantTray.ps1` | Tray app: shows the current mode as an icon and switches it via menu |

## Tray icon

| Icon | Meaning |
|------|---------|
| 🔵 **M** | MultiTenant |
| 🟢 **S** | SingleTenant |
| 🔴 **?** | Inconsistent / unknown state (hover for details) |
| 🟠 **…** | Switch in progress |

Click the icon (left or right) to open the menu:

- **Status** – current mode (read-only entry)
- **Switch to SingleTenant / MultiTenant** – only the opposite mode is enabled; a confirmation dialog appears first
- **Open log** – opens `TenantTray.log` (output of the last switch)
- **Exit**

When a switch finishes, a balloon notification reports success or the exit code on failure. The status is refreshed every 5 seconds (`-PollSeconds` to change).

## Requirements

- Windows with PowerShell 5.1 (built in)
- iQ.Suite installed at the default locations
- **Administrator rights for switching** (registry under HKLM, files in `Program Files`, services, IIS). Reading the status works without.

## What a switch does

The tenant mode is stored in three places that must agree:

1. `C:\Program Files\GBS\iQ.Suite\Config\ConfigData.xml` (+ `SINGLE_` / `MULTI_` backup file)
2. `C:\ProgramData\GBS\iQ.Suite WebClient\dynamic_configuration.xml` (+ backup file)
3. `HKLM:\SOFTWARE\GBS\iQ.Suite\General` → `MultiTenant` (1 = Multi, 0 = Single)

A switch validates everything first, then: stops the services → removes stale `.lck` files → swaps the files → sets the registry value → starts the services → runs `iisreset` and restarts `iqsuitelivedata`. On any failure it rolls back. See the header of `Switch-iQSuiteTenantMode.ps1` for details.

## CLI usage

```powershell
.\Switch-iQSuiteTenantMode.ps1                      # status only
.\Switch-iQSuiteTenantMode.ps1 -SetSingleTenant     # switch (asks for confirmation)
.\Switch-iQSuiteTenantMode.ps1 -SetMultiTenant -Force   # switch without prompt
```

Exit codes:

| Code | Meaning |
|------|---------|
| `0` | OK (or already in target mode / aborted by user) |
| `1` | Not administrator / bad arguments |
| `2` | Inconsistent state – nothing changed |
| `3` | Pre-check failed (e.g. backup file missing) – nothing changed |
| `4` | Switch done, but state afterwards not consistent |
| `5` | Services could not be stopped – nothing changed, services restarted |
| `6` | Error while swapping files/registry – rolled back |
| `7` | Switch done, but a service could not be (re)started |
| `8` | Stale lock file could not be removed – nothing changed, services restarted |

## Running the tray app

Manually (hidden, no console window stays open):

```powershell
Start-Process powershell -WindowStyle Hidden -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','D:\envswitch\TenantTray.ps1'
```

Only one instance can run at a time. If you start it directly in a PowerShell window, closing that window also ends the app.

## Autostart (recommended)

The autostart is a **scheduled task** that starts the tray at logon **with highest privileges**. Because the tray then already runs elevated, switching does **not** trigger a UAC prompt.

> **Security:** the task and the switch run elevated, so the script folder must only be writable by administrators (and you). Otherwise any local user could edit the scripts and have them run as admin. `-InstallAutostart` and the tray's switch menu refuse to run if they detect non-admin write access. To lock down the folder (as Administrator):
>
> ```powershell
> icacls D:\envswitch /inheritance:d /remove:g *S-1-5-32-545 /grant *S-1-5-32-545:(OI)(CI)RX
> ```

Open PowerShell **as Administrator** in the repo folder:

```powershell
.\TenantTray.ps1 -InstallAutostart      # register the task "iQSuiteTenantTray"
Start-ScheduledTask iQSuiteTenantTray   # start it now (otherwise: next logon)
```

Check / stop / restart:

```powershell
Get-ScheduledTask iQSuiteTenantTray
Stop-ScheduledTask iQSuiteTenantTray; Start-ScheduledTask iQSuiteTenantTray
```

Remove the autostart (as Administrator):

```powershell
.\TenantTray.ps1 -UninstallAutostart
```

> The task points to the **current location** of `TenantTray.ps1`. If you move the folder, run `-InstallAutostart` again. After updating the script, restart the task so the new version is used.

Without the autostart task the tray still works from a normal (non-elevated) start: the switch then asks for elevation via UAC.

## Troubleshooting

- **Switch failed balloon** – open the log via the tray menu (`TenantTray.log` next to the script).
- **Red `?` icon** – the three sources disagree or a file/registry value is missing; run `.\Switch-iQSuiteTenantMode.ps1` to see the full report. The tray refuses to switch in this state on purpose.
- **Nothing appears after start** – an instance is probably already running (single-instance lock). Look for the icon in the hidden-icons area of the taskbar.
- **Execution policy errors** – start with `-ExecutionPolicy Bypass` as shown above.
