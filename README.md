# Roblox Block for Windows

A silent, multi-layer PowerShell solution for blocking the Roblox desktop client, Microsoft Store version, Roblox Studio, installers, background processes, and Roblox websites on Windows 10.

The script is designed for parental-control and managed-computer scenarios where Roblox must remain blocked after updates and restarts.

> [!IMPORTANT]
> The first installation must be started from an **elevated Windows PowerShell session**.
> The script does not display a UAC prompt by itself. When started without administrator privileges, it exits silently with exit code `5`.

## Features

The script applies several independent blocking layers:

- Blocks outbound Roblox traffic with Windows Defender Firewall and the `NetSecurity` PowerShell module.
- Blocks Roblox Microsoft Store packages with package-specific firewall rules.
- Blocks `roblox.com` and `rbxcdn.com` in Microsoft Edge and Google Chrome.
- Adds a Firefox `WebsiteFilter` policy.
- Creates machine-level Software Restriction Policies (SRP) for Roblox executables and installation directories.
- Terminates already running Roblox processes.
- Runs a hidden event-driven process guard under the `SYSTEM` account.
- Detects Roblox process launches through `Win32_ProcessStartTrace` instead of continuously polling every process.
- Searches for new Roblox versions every six hours and adds firewall rules for their exact executable paths.
- Runs silently without questions, console prompts, or confirmation dialogs.
- Includes a silent uninstall mode.

## Requirements

- Windows 10
- Windows PowerShell 5.1
- Administrator privileges for installation and removal
- Windows Defender Firewall service
- PowerShell modules included with Windows:
  - `NetSecurity`
  - `ScheduledTasks`
  - `Appx`

The child or restricted user account should be a **standard Windows user**, not an administrator. A local administrator can remove the policies, firewall rules, or scheduled tasks.

## Files

Main script:

```text
Block-Roblox-All.ps1
```

After installation, the script creates:

```text
C:\ProgramData\RobloxBlock\
├── Block-Roblox-All.ps1
├── RobloxProcessGuard.ps1
├── RobloxBlock.log
└── RobloxProcessGuard.log
```

It also creates two scheduled tasks:

```text
RobloxBlock-ProcessGuard
RobloxBlock-AutoRefresh
```

## Installation and first run

### 1. Download the script

Download `Block-Roblox-All.ps1` from this repository.

For the examples below, place it in:

```text
C:\Users\<USERNAME>\AppData\w_temp\Block-Roblox-All.ps1
```

You can create the directory from PowerShell:

```powershell
New-Item -Path "$env:USERPROFILE\AppData\w_temp" -ItemType Directory -Force
```

Copy the downloaded script into that directory.

### 2. Open Windows PowerShell as Administrator

This step is required.

1. Open the Windows Start menu.
2. Type **Windows PowerShell**.
3. Right-click **Windows PowerShell**.
4. Select **Run as administrator**.
5. Accept the Windows UAC prompt.

Do not run the initial installation from a normal, non-elevated PowerShell window.

### 3. Run the installation command

Run this command in the elevated Windows PowerShell window:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1"
```

The command intentionally produces no normal console output.

The script will:

1. Stop currently running Roblox processes.
2. Discover installed Roblox executables.
3. Add outbound Windows Firewall block rules.
4. Add Microsoft Store package firewall rules when applicable.
5. configure browser URL-blocking policies.
6. Install Software Restriction Policies.
7. Run a computer policy refresh when required.
8. Copy itself to:

   ```text
   C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1
   ```

9. Create and start the hidden process guard.
10. Create the six-hour firewall refresh task.

### Alternative: run from the current directory

When the script is in the current PowerShell directory:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File ".\Block-Roblox-All.ps1"
```

The PowerShell window must still be running as Administrator.

### Check the installation exit code

Run the script without closing the elevated PowerShell window, then check:

```powershell
$LASTEXITCODE
```

Expected values:

| Exit code | Meaning |
|---:|---|
| `0` | Installation or refresh completed |
| `2` | The script could not determine its own file path |
| `3` | `NetSecurity` could not be loaded or the firewall could not be updated |
| `5` | The script was not started with administrator privileges |

## What the script blocks

### Roblox executables

Known executable names include:

```text
Roblox.exe
RobloxCrashHandler.exe
RobloxGameClient.exe
RobloxInstaller.exe
RobloxPlayerBeta.exe
RobloxPlayerInstaller.exe
RobloxPlayerLauncher.exe
RobloxStudioBeta.exe
RobloxStudioLauncherBeta.exe
```

The script also detects additional `Roblox*.exe` files in known Roblox installation directories.

### Installation locations

Software Restriction Policies cover locations such as:

```text
%SystemDrive%\Users\*\AppData\Local\Roblox\*
%SystemDrive%\Users\*\AppData\Local\Temp\Roblox\*
%SystemDrive%\Users\*\AppData\Local\Temp\Roblox*.exe
%SystemDrive%\Users\*\Desktop\Roblox*.exe
%SystemDrive%\Users\*\Downloads\Roblox*.exe
%ProgramFiles%\Roblox\*
%ProgramFiles(x86)%\Roblox\*
%ProgramData%\Roblox\*
%ProgramFiles%\WindowsApps\ROBLOXCORPORATION.ROBLOX_*
```

### Websites

The browser policies block:

```text
roblox.com
rbxcdn.com
```

This includes Roblox subdomains and Roblox CDN content.

## Background tasks

### RobloxBlock-ProcessGuard

The process guard:

- Runs as `NT AUTHORITY\SYSTEM`.
- Starts at system startup.
- Starts at user logon.
- Runs hidden.
- Uses `Win32_ProcessStartTrace` events.
- Terminates `Roblox*.exe` processes as they start.
- Checks `Windows10Universal.exe` only when its executable path belongs to the Roblox Microsoft Store package.
- Restarts automatically if the task exits unexpectedly.

The guard is event-driven and does not enumerate every running process every few seconds.

### RobloxBlock-AutoRefresh

The refresh task:

- Runs as `NT AUTHORITY\SYSTEM`.
- Starts at system startup.
- Runs every six hours.
- Searches known Roblox installation locations.
- Adds firewall rules for newly installed or updated executable paths.
- Does not repeatedly reinstall browser policies or force `gpupdate`.

## Verification

### Check scheduled tasks

Open an elevated PowerShell window and run:

```powershell
Get-ScheduledTask -TaskName "RobloxBlock-*"
```

Expected task names:

```text
RobloxBlock-ProcessGuard
RobloxBlock-AutoRefresh
```

Check detailed task state:

```powershell
Get-ScheduledTask -TaskName "RobloxBlock-*" |
    Select-Object TaskName, State
```

### Check firewall rules

```powershell
Get-NetFirewallRule -Group "RobloxBlock" |
    Select-Object DisplayName, Enabled, Direction, Action
```

Expected values include:

```text
Enabled   : True
Direction : Outbound
Action    : Block
```

To inspect the program paths assigned to the rules:

```powershell
Get-NetFirewallRule -Group "RobloxBlock" |
    Get-NetFirewallApplicationFilter |
    Select-Object Program
```

### Check Microsoft Edge policy

Open:

```text
edge://policy
```

Locate:

```text
URLBlocklist
```

Use **Reload Policies** when necessary.

### Check Google Chrome policy

Open:

```text
chrome://policy
```

Locate:

```text
URLBlocklist
```

Use **Reload policies** when necessary.

### Check Firefox policy

Open:

```text
about:policies
```

Look for the active `WebsiteFilter` policy.

### Check SRP registry rules

```powershell
Get-ChildItem "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths" |
    ForEach-Object {
        Get-ItemProperty $_.PSPath
    } |
    Where-Object Description -Like "RobloxBlock:*" |
    Select-Object Description, ItemData
```

### Check logs

Main installation and refresh log:

```powershell
Get-Content "C:\ProgramData\RobloxBlock\RobloxBlock.log" -Tail 100
```

Process guard log:

```powershell
Get-Content "C:\ProgramData\RobloxBlock\RobloxProcessGuard.log" -Tail 100
```

Follow the process guard log in real time:

```powershell
Get-Content "C:\ProgramData\RobloxBlock\RobloxProcessGuard.log" -Wait
```

## Testing

After installation:

1. Fully close Microsoft Edge, Google Chrome, and Firefox.
2. Start the browsers again.
3. Try opening:

   ```text
   https://www.roblox.com
   ```

4. Try starting the installed Roblox client.
5. Try starting Roblox Studio, if installed.
6. Check the process guard log.

A blocked process may appear briefly in Task Manager before the process-start event is handled and the process is terminated.

## Silent uninstall

Open **Windows PowerShell as Administrator** and run:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" -Uninstall
```

The uninstall operation removes:

- Scheduled tasks created by the script.
- Windows Firewall rules in the `RobloxBlock` group.
- Edge and Chrome URL block entries added by the script.
- Firefox block entries added by the script.
- SRP path rules whose descriptions begin with `RobloxBlock:`.
- The generated process guard script.

The main log and installed script directory may remain for diagnostics and manual cleanup.

To remove the remaining directory after uninstalling:

```powershell
Remove-Item "C:\ProgramData\RobloxBlock" -Recurse -Force
```

Do not delete the directory before running `-Uninstall`, because the installed copy is used to remove the configuration.

## Manually run a firewall refresh

The `RefreshOnly` parameter is intended for the scheduled task, but it can also be run manually from an elevated PowerShell window:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" -RefreshOnly
```

This mode:

- Stops currently running Roblox processes.
- Searches for current Roblox executable paths.
- Adds missing firewall rules.
- Does not reinstall browser policies.
- Does not recreate SRP rules.
- Does not recreate scheduled tasks.

## Troubleshooting

### The script appears to do nothing

This is expected. It runs silently.

Check the exit code:

```powershell
$LASTEXITCODE
```

Then inspect:

```text
C:\ProgramData\RobloxBlock\RobloxBlock.log
```

When the script is started without administrator rights, it exits with code `5` and may write:

```text
%TEMP%\RobloxBlock-install-error.log
```

### Roblox still has network access

Check whether Windows Defender Firewall is enabled:

```powershell
Get-NetFirewallProfile |
    Select-Object Name, Enabled
```

Enable all firewall profiles when appropriate:

```powershell
Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
```

Review the Roblox firewall group:

```powershell
Get-NetFirewallRule -Group "RobloxBlock"
```

Run a manual refresh after a Roblox update:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" -RefreshOnly
```

### Browser policies do not appear immediately

Completely close and restart the browser.

For Edge:

```text
edge://policy
```

For Chrome:

```text
chrome://policy
```

Use the policy reload button.

### The process guard is not running

Check its state:

```powershell
Get-ScheduledTask -TaskName "RobloxBlock-ProcessGuard" |
    Select-Object TaskName, State
```

Start it manually:

```powershell
Start-ScheduledTask -TaskName "RobloxBlock-ProcessGuard"
```

Review the task result:

```powershell
Get-ScheduledTaskInfo -TaskName "RobloxBlock-ProcessGuard"
```

### Reinstall or repair the configuration

Run the installation command again from an elevated PowerShell window:

```powershell
powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1"
```

The script uses stable rule identifiers and replaces its scheduled tasks, so rerunning it is intended to be idempotent.

## Pktmon

The script does not keep Packet Monitor (`pktmon`) running.

`pktmon` is useful for diagnostics, packet capture, and dropped-packet analysis, but it is not required for the blocking mechanism. Keeping packet capture active would add unnecessary overhead and generate trace data.

Windows Defender Firewall and the `NetSecurity` module perform the actual network blocking.

## Security notes

- The script makes machine-wide changes.
- Installation and removal require local administrator privileges.
- A user with administrator rights can disable or remove the restrictions.
- Keep restricted users on standard accounts.
- Review the script before running it in production or managed environments.
- Domain Group Policy may override local browser, firewall, or SRP settings.
- Antivirus or endpoint security products may flag process-termination behavior.
- Browser policy configuration may cause the browser to display a “managed by your organization” notice.

## Performance

The script is designed to minimize background overhead:

- Process blocking is event-driven.
- No permanent packet capture is used.
- No continuous full file-system scan is used.
- The refresh scan is limited to known Roblox locations.
- Existing firewall rules are loaded into a case-insensitive `HashSet`.
- Refresh runs occur every six hours instead of every few minutes.
- `gpupdate` is run only when SRP configuration changes.

## Compatibility

Designed for:

```text
Windows 10
Windows PowerShell 5.1
```

It may also work on newer Windows versions, but they are not the primary target of this script.

## Disclaimer

This project is provided as-is, without warranty.

Use it only on computers you own or administer. You are responsible for testing the script and understanding the machine-wide security policies it applies.
