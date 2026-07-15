# Roblox Blocker for Windows (Production‑Grade)

A production‑ready PowerShell script that silently blocks Roblox execution and network access on Windows 10/11. It combines firewall rules, Software Restriction Policies, browser URL blocklists, and a real‑time process guard into a single maintenance‑free solution – ideal for enterprise, educational, and parental control environments.

## Features

- **Multi‑layered blocking** – stops Roblox at every level:
    
    - **Windows Firewall** – blocks outbound traffic for all discovered Roblox executables and Microsoft Store packages.
        
    - **Software Restriction Policies (SRP)** – prevents launching any Roblox‑related executable from known paths.
        
    - **Browser Blocklists** – blocks `roblox.com` and `rbxcdn.com` in Microsoft Edge, Google Chrome, and Mozilla Firefox.
        
    - **Event‑driven Process Guard** – a lightweight WMI start‑trace monitor that instantly terminates any Roblox process the moment it appears (no polling).
        
- **Fully silent** – no windows, prompts, or user interaction after installation.
    
- **Idempotent** – re‑running the installer does not duplicate rules, tasks, or policies.
    
- **Self‑healing** – automatically detects and repairs missing components (guard script, scheduled tasks).
    
- **Transactional SRP** – backs up existing policies before changes; rolls back on failure to prevent registry corruption.
    
- **‑WhatIf / ‑Verbose support** – safely preview all changes or get detailed diagnostic output.
    
- **Automatic discovery** – a scheduled task rescans for new Roblox versions every 6 hours and updates firewall rules.
    
- **Windows 10/11 support** – works on all editions (Home, Pro, Enterprise) and both 64‑bit and 32‑bit systems.
    

## Requirements

- Windows 10 or Windows 11
    
- PowerShell 5.1 or later
    
- Administrator privileges
    

## Quick Start

1. Open an **elevated PowerShell** console (Run as Administrator).
    
2. Run the script once – it will install all components and keep them running permanently:
    

powershell

powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden `
    -ExecutionPolicy Bypass -File "C:\Path\To\Block-Roblox-All.ps1"

After installation, no further action is required. The blocking layers work silently in the background.

## Usage

### Install / Apply All Blocks

powershell

.\Block-Roblox-All.ps1

### Preview Changes (Dry‑Run)

powershell

.\Block-Roblox-All.ps1 -WhatIf -Verbose

### Uninstall Completely

Removes all firewall rules, SRP policies, browser blocklists, scheduled tasks, and script files.

powershell

.\Block-Roblox-All.ps1 -Uninstall

### Refresh Firewall Rules Only (Without Touching Other Layers)

This mode is used internally by the scheduled auto‑refresh task, but can also be triggered manually:

powershell

.\Block-Roblox-All.ps1 -RefreshOnly

### Logging

All operations are logged to:

text

C:\ProgramData\RobloxBlock\RobloxBlock.log
C:\ProgramData\RobloxBlock\RobloxProcessGuard.log

Logs are automatically rotated when they exceed 2 MB.

## How It Works

### Installation (first run)

- The script copies itself to `C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1`.
    
- It stops any running Roblox processes.
    
- It scans known Roblox installation folders (per‑user `AppData`, `Program Files`, `ProgramData`, Microsoft Store) and creates outbound firewall block rules for every discovered executable.
    
- It writes Software Restriction Policies to the registry (`HKLM\SOFTWARE\Policies\Microsoft\Windows\Safer`) that cover all standard Roblox paths.
    
- It adds URL blocklist entries for Edge and Chrome, and a `policies.json` for Firefox.
    
- It registers two scheduled tasks that run with `SYSTEM` privileges:
    
    - **RobloxBlock-ProcessGuard** – starts at boot and log on, using a WMI `Win32_ProcessStartTrace` query to instantly kill any Roblox process.
        
    - **RobloxBlock-AutoRefresh** – runs every 6 hours to scan for new Roblox versions and update firewall rules.
        

### Process Guard (Real‑Time Protection)

The guard script (`RobloxProcessGuard.ps1`) subscribes to WMI start events for processes whose name matches `Roblox*` or `Windows10Universal.exe`. When a match is detected, the process is terminated immediately – no CPU‑intensive polling required.

### Idempotency & Resilience

- All rules and tasks are checked for existence before creation – repeated runs never cause duplicates.
    
- SRP modifications are transactional: a backup of existing rules is made before changes, and if an error occurs the previous state is restored automatically.
    
- A self‑diagnostic function verifies that the guard script and tasks are present; if they are missing, they are reinstalled.
    

## Production‑Readiness Optimizations (Version 5.0)

- **Security**
    
    - All write operations wrapped in `ShouldProcess` (`-WhatIf` support).
        
    - Minimal temporary file usage; no credential exposure.
        
- **Fault tolerance**
    
    - Every critical operation (CIM, AppX, registry) is guarded with fallbacks.
        
    - Partial failures do not abort the entire installation.
        
- **Performance**
    
    - File scanning uses `[IO.Directory]::EnumerateFiles` – avoids creating unnecessary objects.
        
    - CIM queries reduced to a single call for Microsoft Store processes.
        
- **Audit & logging**
    
    - Structured logging with `INFO`/`WARN`/`ERROR` levels.
        
    - Optional Windows Event Log integration.
        
    - Transaction journal (`state.xml`) records all changes.
        
- **Deployment ready**
    
    - Can be signed and distributed via Group Policy or SCCM.
        
    - Idempotent, self‑healing, and fully autonomous.
        

## Deployment in Enterprise Environments

1. **Sign the script** with a code‑signing certificate.
    
2. Distribute it via:
    
    - Group Policy startup script (Computer Configuration → Windows Settings → Scripts).
        
    - SCCM package or Microsoft Intune.
        
    - Third‑party deployment tools (PDQ Deploy, etc.).
        
3. Run once on each machine – the scheduled tasks will maintain the block indefinitely.
    

## File Locations After Installation

|Component|Path|
|---|---|
|Main script|`C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1`|
|Process guard script|`C:\ProgramData\RobloxBlock\RobloxProcessGuard.ps1`|
|Logs|`C:\ProgramData\RobloxBlock\RobloxBlock.log`  <br>`C:\ProgramData\RobloxBlock\RobloxProcessGuard.log`|
|Transaction state|`C:\ProgramData\RobloxBlock\state.xml`|
|Scheduled tasks|`Task Scheduler` → `RobloxBlock-ProcessGuard`  <br>`Task Scheduler` → `RobloxBlock-AutoRefresh`|

## Uninstallation

Run the script with `-Uninstall` as described above. This removes all components completely.

## License

This project is distributed under the MIT License. See the `LICENSE` file for details.

## Contributing

Pull requests and issues are welcome. Please ensure that all changes preserve idempotency, fault tolerance, and the silent execution model.
