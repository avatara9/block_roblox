<div align="center">

# Roblox Block for Windows

### A simple PowerShell script that blocks Roblox on Windows 10 and Windows 11

[![Release](https://img.shields.io/badge/release-v0.0.3-blue.svg)](#version-003)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE.svg?logo=powershell&logoColor=white)](#requirements)
[![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4.svg?logo=windows&logoColor=white)](#requirements)
[![Mode](https://img.shields.io/badge/runs-silently-success.svg)](#what-the-script-does)

**Version 0.0.3**

</div>

---

> [!WARNING]
> Use this script only on computers that you own or are allowed to manage.
> It changes Windows Firewall rules, local security policies, browser policies,
> scheduled tasks, and files under `C:\ProgramData`.

# Quick Start

This is the shortest way to install the script.

## Step 1: Download the file

Download:

```text
Block-Roblox-All.ps1
```

Place it in:

```text
C:\Users\<YOUR_USERNAME>\AppData\w_temp\Block-Roblox-All.ps1
```

You can create the folder with:

```powershell
New-Item `
    -Path "$env:USERPROFILE\AppData\w_temp" `
    -ItemType Directory `
    -Force
```

## Step 2: Open PowerShell as Administrator

1. Open the Windows **Start** menu.
2. Type:

   ```text
   Windows PowerShell
   ```

3. Right-click **Windows PowerShell**.
4. Select **Run as administrator**.
5. Click **Yes** when Windows asks for permission.
6. Check that the title bar says:

   ```text
   Administrator: Windows PowerShell
   ```

This is important. The script cannot install its firewall rules, policies, and
scheduled tasks from a normal PowerShell window.

## Step 3: Optional safety check

Before installing, you can see what the script plans to change:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1" `
    -WhatIf `
    -Verbose
```

`-WhatIf` shows planned changes without applying them.

## Step 4: Install

Run this command in the Administrator PowerShell window:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy Bypass `
    -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1"
```

The script runs silently. It may look like nothing happened. That is normal.

## Step 5: Check that it is installed

Open PowerShell as Administrator and run:

```powershell
Get-ScheduledTask -TaskName "RobloxBlock-*"
```

You should see RobloxBlock tasks.

Check the main log:

```powershell
Get-Content `
    "C:\ProgramData\RobloxBlock\RobloxBlock.jsonl" `
    -Tail 50
```

---

## Table of Contents

- [What the script does](#what-the-script-does)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation details](#installation-details)
- [Available commands](#available-commands)
- [How to verify the installation](#how-to-verify-the-installation)
- [Installed files and tasks](#installed-files-and-tasks)
- [Logs](#logs)
- [Safety and recovery](#safety-and-recovery)
- [Performance](#performance)
- [Compatibility](#compatibility)
- [Troubleshooting](#troubleshooting)
- [Uninstall](#uninstall)
- [Optional: installation on several computers](#optional-installation-on-several-computers)
- [Optional: code signing](#optional-code-signing)
- [Version 0.0.3](#version-003)
- [Disclaimer](#disclaimer)

# What the Script Does

The script blocks Roblox in several different ways.

## Blocks Roblox Internet Access

- Creates outbound Windows Firewall block rules.
- Uses the PowerShell `NetSecurity` module when available.
- Can use the Windows Firewall COM interface as a fallback.
- Creates rules for Roblox executable files.
- Creates package rules for the Microsoft Store version when AppX information
  is available.
- Warns when Windows Firewall profiles are disabled.

## Blocks Roblox from Starting

The script creates Software Restriction Policy rules for:

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

It also blocks common Roblox folders, including:

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

## Stops Running Roblox Processes

- Stops Roblox processes during installation or repair.
- Installs a hidden process guard.
- Runs the guard as `NT AUTHORITY\SYSTEM`.
- Uses Windows process-start events.
- Does not constantly scan every process.
- Uses a small targeted fallback when WMI events are unavailable.

## Blocks Roblox Websites

The script blocks:

```text
roblox.com
rbxcdn.com
```

Supported browsers:

- Microsoft Edge
- Google Chrome
- Mozilla Firefox

Browser policies may make the browser display:

```text
Managed by your organization
```

This is normal when system-wide browser policies are active.

## Repairs Itself

The script can check and restore:

- firewall rules;
- browser policies;
- Software Restriction Policy rules;
- scheduled tasks;
- the process guard;
- the main installed script;
- the backup copy;
- installation state files.

# How It Works

The old Mermaid diagram was replaced with a large text diagram so it stays
readable on desktop and mobile GitHub pages.

```text
+--------------------------------------------------+
|                  ROBLOX STARTS                    |
+--------------------------------------------------+
                         |
                         v
+--------------------------------------------------+
|  1. PROCESS GUARD                                |
|  Detects Roblox startup and closes the process   |
+--------------------------------------------------+
                         |
                         v
+--------------------------------------------------+
|  2. SOFTWARE RESTRICTION POLICIES                |
|  Block known Roblox files and installation paths |
+--------------------------------------------------+
                         |
                         v
+--------------------------------------------------+
|  3. WINDOWS FIREWALL                             |
|  Blocks outbound Roblox network connections      |
+--------------------------------------------------+
                         |
                         v
+--------------------------------------------------+
|  4. BROWSER POLICIES                             |
|  Blocks roblox.com and rbxcdn.com                |
+--------------------------------------------------+
                         |
                         v
+--------------------------------------------------+
|  5. AUTOMATIC CHECKS                             |
|  Finds new versions and repairs missing parts    |
+--------------------------------------------------+
```

Each layer works separately. If one layer is unavailable, the other layers can
still block Roblox.

# Requirements

## Supported Windows Versions

- Windows 10
- Windows 11
- 32-bit Windows
- 64-bit Windows
- standalone computers
- domain-joined computers

## PowerShell

- Windows PowerShell 5.1 or newer

The script can be started from PowerShell 7, but Windows-specific background
tasks use Windows PowerShell 5.1 for compatibility.

## Administrator Rights

Administrator rights are required for:

- installation;
- repair;
- firewall changes;
- policy changes;
- scheduled task creation;
- uninstall.

The restricted user should use a **standard Windows account**.

A Windows administrator can remove the blocking configuration.

## Windows Components Used

The script uses built-in Windows components when they are available:

- Windows Defender Firewall;
- `NetSecurity`;
- `ScheduledTasks`;
- AppX cmdlets;
- CIM/WMI;
- Windows Registry;
- Windows Event Log, when enabled.

Missing components are handled with fallbacks where possible.

# Installation Details

## Standard Silent Installation

Run from an Administrator PowerShell window:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy Bypass `
    -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1"
```

## Installation with Visible Details

Do not use `-WindowStyle Hidden` when you want to see messages.

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1" `
    -Verbose
```

## Installation with Windows Event Log

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy Bypass `
    -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1" `
    -EnableEventLog
```

## Custom Check Intervals

Example:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy Bypass `
    -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1" `
    -RefreshIntervalHours 6 `
    -HealthCheckIntervalHours 24
```

# Available Commands

## Normal Install or Repair

```powershell
.\Block-Roblox-All.ps1
```

Running the script again should update or repair the existing configuration
without intentionally creating duplicates.

## Simulate Changes

```powershell
.\Block-Roblox-All.ps1 -WhatIf -Verbose
```

## Show Detailed Output

```powershell
.\Block-Roblox-All.ps1 -Verbose
```

## Update Firewall Rules Only

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" `
    -RefreshOnly
```

`-RefreshOnly`:

- searches known Roblox folders;
- finds current Roblox executable files;
- adds or repairs managed firewall rules;
- checks AppX package rules when AppX information is available.

`-RefreshOnly` does not:

- modify browser policies;
- modify Software Restriction Policies;
- rewrite scheduled tasks;
- rewrite the guard script;
- rewrite installed script files;
- stop running Roblox processes.

## Repair All Managed Parts

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" `
    -RepairOnly
```

## Enable Windows Event Log Entries

```powershell
.\Block-Roblox-All.ps1 -EnableEventLog
```

The Event Log source is:

```text
RobloxBlock
```

## Require a Valid Script Signature

Use this only after signing the script with a trusted certificate:

```powershell
.\Block-Roblox-All.ps1 -RequireValidSignature
```

# How to Verify the Installation

## Check Scheduled Tasks

```powershell
Get-ScheduledTask -TaskName "RobloxBlock-*" |
    Select-Object TaskName, State
```

Expected task names may include:

```text
RobloxBlock-ProcessGuard
RobloxBlock-AutoRefresh
RobloxBlock-HealthCheck
```

## Check Firewall Rules

```powershell
Get-NetFirewallRule -Group "RobloxBlock" |
    Select-Object DisplayName, Enabled, Direction, Action
```

Expected values:

```text
Enabled   : True
Direction : Outbound
Action    : Block
```

Check linked program paths:

```powershell
Get-NetFirewallRule -Group "RobloxBlock" |
    Get-NetFirewallApplicationFilter |
    Select-Object Program, Package
```

## Check Windows Firewall Profiles

```powershell
Get-NetFirewallProfile |
    Select-Object Name, Enabled
```

Recommended result:

```text
Domain  True
Private True
Public  True
```

The script warns when a profile is disabled. It does not automatically enable
the profile because another Windows policy may control it.

## Check Edge

Open:

```text
edge://policy
```

Look for:

```text
URLBlocklist
```

## Check Chrome

Open:

```text
chrome://policy
```

Look for:

```text
URLBlocklist
```

## Check Firefox

Open:

```text
about:policies
```

Look for:

```text
WebsiteFilter
```

## Check Software Restriction Policy Rules

```powershell
Get-ChildItem `
    "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers\0\Paths" `
    -ErrorAction SilentlyContinue |
    ForEach-Object {
        Get-ItemProperty $_.PSPath
    } |
    Where-Object {
        $_.Description -like "RobloxBlock:*"
    } |
    Select-Object Description, ItemData
```

## Check Installed File Hashes

```powershell
Get-FileHash `
    "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" `
    -Algorithm SHA256

Get-FileHash `
    "C:\ProgramData\RobloxBlock\Block-Roblox-All.backup.ps1" `
    -Algorithm SHA256
```

# Installed Files and Tasks

Default folder:

```text
C:\ProgramData\RobloxBlock
```

Typical files:

```text
C:\ProgramData\RobloxBlock\
|-- Block-Roblox-All.ps1
|-- Block-Roblox-All.backup.ps1
|-- RobloxProcessGuard.ps1
|-- state.json
|-- RobloxBlock.jsonl
|-- RobloxProcessGuard.jsonl
`-- rotated log files
```

Scheduled tasks:

```text
RobloxBlock-ProcessGuard
RobloxBlock-AutoRefresh
RobloxBlock-HealthCheck
```

Firewall group:

```text
RobloxBlock
```

# Logs

## Main Log

```text
C:\ProgramData\RobloxBlock\RobloxBlock.jsonl
```

## Process Guard Log

```text
C:\ProgramData\RobloxBlock\RobloxProcessGuard.jsonl
```

## Read Recent Log Entries

```powershell
Get-Content `
    "C:\ProgramData\RobloxBlock\RobloxBlock.jsonl" `
    -Tail 100
```

## Watch the Process Guard Log

```powershell
Get-Content `
    "C:\ProgramData\RobloxBlock\RobloxProcessGuard.jsonl" `
    -Wait
```

## Convert the Log to PowerShell Objects

```powershell
Get-Content `
    "C:\ProgramData\RobloxBlock\RobloxBlock.jsonl" |
    ForEach-Object {
        $_ | ConvertFrom-Json
    } |
    Select-Object TimestampUtc, Level, Component, EventId, Message
```

## Show Only Errors

```powershell
Get-Content `
    "C:\ProgramData\RobloxBlock\RobloxBlock.jsonl" |
    ForEach-Object {
        $_ | ConvertFrom-Json
    } |
    Where-Object Level -eq "Error"
```

## Read Windows Event Log Entries

When `-EnableEventLog` is enabled:

```powershell
Get-WinEvent `
    -FilterHashtable @{
        LogName = "Application"
        ProviderName = "RobloxBlock"
    } `
    -MaxEvents 100
```

# Safety and Recovery

## Safe Administrator Check

The script checks administrator rights without creating temporary test files.

## Protected Installation Folder

The script restricts write access to the installation folder.

Expected full-control accounts:

- `NT AUTHORITY\SYSTEM`;
- local Administrators.

## Safer File Updates

Important files are written through temporary sibling files and then replaced.

This is used for items such as:

- Firefox `policies.json`;
- the state file;
- the guard script;
- installed script copies.

This reduces the chance of leaving a half-written file after a crash or power
failure.

## Validation

The script checks items such as:

- installation paths;
- state-file format;
- SHA-256 values;
- scheduled task settings;
- managed firewall rules;
- managed browser policy values.

## Rollback

If a serious installation error happens, the script attempts to undo changes
made by the current run.

Items that may be restored include:

- files;
- registry values;
- browser policy entries;
- Firefox policy data;
- Software Restriction Policy rules;
- newly created firewall rules;
- earlier scheduled task definitions.

Stopping a process cannot be undone.

## No Intentional Duplicates

Running the script again is designed not to intentionally duplicate:

- firewall rules;
- browser entries;
- Software Restriction Policy rules;
- scheduled tasks;
- installed payload files.

## Automatic Repair

The health check can restore missing or changed managed components.

# Performance

The script reduces background load by using:

- event-based process detection;
- targeted process checks;
- no continuous full-process scan;
- no full-disk scan;
- file scans limited to known Roblox folders;
- `[IO.Directory]::EnumerateFiles`;
- reusable file filters;
- cached information during each run;
- hash sets for existing rule names;
- firewall-only work during `-RefreshOnly`;
- `gpupdate` only when relevant policy data changes;
- configurable maintenance intervals.

The script does not keep `pktmon` running.

`pktmon` is useful for temporary network diagnostics, but it is not needed for
blocking Roblox and would create unnecessary background work and trace files.

# Compatibility

## 32-bit and 64-bit Windows

The script handles:

- missing `ProgramFiles(x86)` on 32-bit Windows;
- 32-bit PowerShell on 64-bit Windows;
- multiple user profiles;
- damaged or inaccessible profile registry records.

## When NetSecurity Is Missing

The script attempts to use the Windows Firewall COM interface.

## When AppX Commands Are Missing

The script continues with:

- executable firewall rules;
- browser policies;
- Software Restriction Policies;
- process blocking.

Package-specific detection may be skipped.

## When CIM or WMI Is Missing

The script logs a warning and uses available fallback behavior.

Other blocking layers continue to work.

## Domain-Managed Computers

Company or school policies may override local settings.

The script does not try to bypass centrally managed Windows security settings.

# Troubleshooting

## The Script Appears to Do Nothing

Silent operation is normal.

Run without `-WindowStyle Hidden`:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File ".\Block-Roblox-All.ps1" `
    -Verbose
```

Then check:

```text
C:\ProgramData\RobloxBlock\RobloxBlock.jsonl
```

## PowerShell Is Not Running as Administrator

Run:

```powershell
([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
```

The result must be:

```text
True
```

## Roblox Still Has Internet Access

Check Windows Firewall:

```powershell
Get-NetFirewallProfile |
    Select-Object Name, Enabled
```

Check managed rules:

```powershell
Get-NetFirewallRule -Group "RobloxBlock"
```

Run a firewall refresh:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" `
    -RefreshOnly `
    -Verbose
```

## Browser Blocking Is Not Visible

Close the browser completely and start it again.

Then open:

```text
edge://policy
chrome://policy
about:policies
```

## A Task Was Deleted

Run:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" `
    -RepairOnly `
    -Verbose
```

## The Process Guard Is Not Running

```powershell
Get-ScheduledTask -TaskName "RobloxBlock-ProcessGuard"
Get-ScheduledTaskInfo -TaskName "RobloxBlock-ProcessGuard"
```

Check:

```text
C:\ProgramData\RobloxBlock\RobloxProcessGuard.jsonl
```

## Firefox Already Has a Broken policies.json File

The script does not intentionally overwrite an existing policy file that
cannot be parsed safely.

Check:

```text
<Firefox installation folder>\distribution\policies.json
```

Repair the JSON and run the script again.

## Common Exit Codes

| Code | Meaning |
|---:|---|
| `0` | The operation completed |
| `1` | A serious error occurred |
| `2` | The script path could not be determined |
| `3` | Firewall setup or update failed |
| `5` | Administrator rights are required |
| `6` | Script signature validation failed |

The log normally contains more useful details than the exit code.

# Uninstall

## Standard Silent Uninstall

Open PowerShell as Administrator and run:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" `
    -Uninstall
```

## Keep Logs During Uninstall

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" `
    -Uninstall `
    -PreserveLogs
```

The uninstall process removes only items managed by this project, including:

- scheduled tasks;
- managed firewall rules;
- managed browser entries;
- managed Firefox entries;
- managed Software Restriction Policy rules;
- the process guard;
- installed payload files.

Unrelated firewall rules and browser policies should remain unchanged.

# Optional: Installation on Several Computers

Most home users do not need this section.

## GPO Startup Script

A school, office, or home lab can run the script as a computer startup script.

Example:

```powershell
powershell.exe `
    -NoLogo `
    -NoProfile `
    -NonInteractive `
    -WindowStyle Hidden `
    -ExecutionPolicy AllSigned `
    -File "\\example.local\SYSVOL\example.local\scripts\Block-Roblox-All.ps1" `
    -RequireValidSignature `
    -EnableEventLog
```

## SCCM or MECM

Install:

```text
powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File Block-Roblox-All.ps1 -EnableEventLog
```

Uninstall:

```text
powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1 -Uninstall
```

## Intune

Suggested settings:

- run using logged-on credentials: **No**;
- run in 64-bit PowerShell: **Yes**;
- run in device context;
- collect exit codes and logs.

# Optional: Code Signing

Most home users can skip this section.

## Check a Signature

```powershell
Get-AuthenticodeSignature ".\Block-Roblox-All.ps1" |
    Format-List
```

## Sign the Script

```powershell
$certificate = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
    Select-Object -First 1

Set-AuthenticodeSignature `
    -FilePath ".\Block-Roblox-All.ps1" `
    -Certificate $certificate `
    -TimestampServer "<timestamp server>"
```

After signing, do not edit the file. Any edit invalidates the signature.

# Version 0.0.3

## Main Changes

- multi-layer Roblox blocking;
- silent installation and uninstall;
- firewall, browser, SRP, and process blocking;
- event-based process guard;
- automatic firewall refresh;
- health checks and repair;
- protected installed and backup script copies;
- JSON Lines logging with rotation;
- optional Windows Event Log entries;
- optional signature checking;
- firewall COM fallback;
- AppX, CIM, and WMI fallback behavior;
- Windows 10 and Windows 11 support;
- PowerShell 5.1 support;
- `-WhatIf` and `-Verbose`;
- faster file discovery with `[IO.Directory]::EnumerateFiles`;
- fewer repeated file scans;
- clearer script sections and naming;
- optional log preservation during uninstall.

Recommended GitHub release settings:

```text
Tag: v0.0.3
Release title: Roblox Block for Windows v0.0.3
Target branch: main
```

# Before Installing on Several Computers

- [ ] Read the script.
- [ ] Run `-WhatIf -Verbose`.
- [ ] Test on one Windows 10 or Windows 11 computer.
- [ ] Restart the computer.
- [ ] Check all scheduled tasks.
- [ ] Test the Roblox desktop client.
- [ ] Test Roblox Studio.
- [ ] Test the Microsoft Store version when installed.
- [ ] Test Roblox websites.
- [ ] Test `-RefreshOnly`.
- [ ] Test `-RepairOnly`.
- [ ] Test `-Uninstall`.
- [ ] Keep a backup of the original script.

# Disclaimer

This project is provided **as is**, without warranty.

The author and contributors are not responsible for data loss, policy
conflicts, service interruption, or other problems caused by the script.

Test the script on one computer before using it on several computers.
