#Requires -Version 5.1
<#
.SYNOPSIS
    Production‑grade silent multi‑layer Roblox blocker for Windows 10/11.

.DESCRIPTION
    The script installs a comprehensive, maintenance‑free blocking solution
    that prevents Roblox from running or accessing the network. It operates
    without any user interaction, windows, or UAC prompts.

    Layers applied:
      * Outbound Windows Firewall rules (per‑executable + Microsoft Store packages)
      * Machine‑level Software Restriction Policies (SRP)
      * URL blocklists for Microsoft Edge, Google Chrome, and Mozilla Firefox
      * A hidden, event‑driven process guard that terminates Roblox processes in
        real time using WMI start‑trace events – without polling.
      * A periodic (every 6 hours) task that discovers new Roblox versions and
        adds matching firewall rules.

    All changes are idempotent. The initial run must be executed from an elevated
    PowerShell session. If elevation is unavailable the script exits with code 5
    without showing any dialog.

.PARAMETER RefreshOnly
    Internal background mode that only updates file‑based firewall rules.
    SRP, browser policies, and scheduled tasks are left untouched.

.PARAMETER Uninstall
    Silently removes all rules, policies, tasks, and files created by the script.

.PARAMETER WhatIf
    Shows what would happen without actually modifying the system.

.PARAMETER Verbose
    Outputs detailed diagnostic messages.

.EXAMPLE
    powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden `
        -ExecutionPolicy Bypass -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1"

.EXAMPLE
    powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden `
        -ExecutionPolicy Bypass -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" -Uninstall -WhatIf

.NOTES
    Version: 5.0 (production)
    Author:  Enterprise Automation Team
    Requires: Windows 10/11, PowerShell 5.1, Administrator rights.
    Deployment: The script can be signed with a code‑signing certificate and
    deployed via Group Policy startup script or SCCM package.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [switch]$RefreshOnly,
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# ------------------------------------------------------------------------------
# Constants & paths
# ------------------------------------------------------------------------------
$Script:ScriptVersion = '5.0'

$InstallDirectory = Join-Path $env:ProgramData 'RobloxBlock'
$InstalledScript   = Join-Path $InstallDirectory 'Block-Roblox-All.ps1'
$GuardScript       = Join-Path $InstallDirectory 'RobloxProcessGuard.ps1'
$LogFile           = Join-Path $InstallDirectory 'RobloxBlock.log'
$GuardLogFile      = Join-Path $InstallDirectory 'RobloxProcessGuard.log'
$StateFile         = Join-Path $InstallDirectory 'state.xml'          # transaction journal

$RefreshTaskName   = 'RobloxBlock-AutoRefresh'
$GuardTaskName     = 'RobloxBlock-ProcessGuard'

$FirewallGroup     = 'RobloxBlock'
$RulePrefix        = 'RBX-BLOCK-'

$SrpBasePath       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
$SrpRulesPath      = Join-Path $SrpBasePath '0\Paths'
$SrpDescriptionPrefix = 'RobloxBlock:'

$BlockedChromiumUrls = @('roblox.com', 'rbxcdn.com')
$BlockedFirefoxUrls  = @(
    '*://roblox.com/*',
    '*://*.roblox.com/*',
    '*://rbxcdn.com/*',
    '*://*.rbxcdn.com/*'
)

$RobloxExecutableNames = @(
    'Roblox.exe', 'RobloxCrashHandler.exe', 'RobloxGameClient.exe',
    'RobloxInstaller.exe', 'RobloxPlayerBeta.exe', 'RobloxPlayerInstaller.exe',
    'RobloxPlayerLauncher.exe', 'RobloxStudioBeta.exe', 'RobloxStudioLauncherBeta.exe'
)

# ------------------------------------------------------------------------------
# Helper: logging & transaction support
# ------------------------------------------------------------------------------
function Write-ScriptLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "$timestamp [$Level] $Message"
    Write-Verbose $line
    try {
        Add-Content -Path $LogFile -Encoding UTF8 -Value $line -ErrorAction Stop
    }
    catch {
        # silent – logging failure must not break the operation
    }
    # Optionally write to Windows Event Log
    if ($Level -eq 'ERROR') {
        try {
            $eventParams = @{
                LogName   = 'Application'
                Source    = 'RobloxBlock'
                EventId   = 1001
                EntryType = 'Error'
                Message   = $Message
            }
            if ([System.Diagnostics.EventLog]::SourceExists('RobloxBlock')) {
                Write-EventLog @eventParams -ErrorAction Stop
            }
        }
        catch { }
    }
}

function Write-TransactionStep {
    param([string]$Action, [string]$Detail)
    if (-not $StateFile) { return }
    try {
        $entry = [pscustomobject]@{
            Timestamp = (Get-Date).ToString('o')
            Action    = $Action
            Detail    = $Detail
        }
        $entry | Export-Clixml -Path $StateFile -Force -ErrorAction Stop
    }
    catch { }
}

function Clear-TransactionState {
    if (Test-Path $StateFile) {
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    }
}

# ------------------------------------------------------------------------------
# Elevation check
# ------------------------------------------------------------------------------
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdministrator)) {
    try {
        $tempErr = Join-Path $env:TEMP 'RobloxBlock-install-error.log'
        Add-Content -Path $tempErr -Encoding UTF8 -Value "$(Get-Date -Format 'o') Administrator privileges required."
    } catch {}
    exit 5
}

New-Item -Path $InstallDirectory -ItemType Directory -Force | Out-Null

# ------------------------------------------------------------------------------
# Log rotation
# ------------------------------------------------------------------------------
function Optimize-LogFile {
    param([string]$Path, [int64]$MaxSize = 2MB, [int]$KeepLines = 500)
    try {
        if ((Test-Path $Path) -and (Get-Item $Path).Length -gt $MaxSize) {
            $tmp = "$Path.tmp"
            Get-Content $Path -Tail $KeepLines | Set-Content $tmp -Encoding UTF8
            Move-Item $tmp $Path -Force
        }
    } catch {}
}
Optimize-LogFile -Path $LogFile

# ------------------------------------------------------------------------------
# Common string helpers
# ------------------------------------------------------------------------------
function Get-StableMd5 {
    param([string]$Text)
    $md5 = [Security.Cryptography.MD5]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())
        return -join ($md5.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') })
    } finally { $md5.Dispose() }
}

function ConvertTo-StableGuidString {
    param([string]$Text)
    $hex = Get-StableMd5 -Text $Text
    return '{{{0}-{1}-{2}-{3}-{4}}}' -f $hex.Substring(0,8), $hex.Substring(8,4), $hex.Substring(12,4), $hex.Substring(16,4), $hex.Substring(20,12)
}

function New-StringHashSet {
    param([string[]]$Values = @())
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($v in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($v)) { $null = $set.Add($v) }
    }
    return $set
}

# ------------------------------------------------------------------------------
# File system scanning (optimised)
# ------------------------------------------------------------------------------
function Get-LocalProfilePaths {
    $paths = New-StringHashSet
    $profListKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    if (Test-Path $profListKey) {
        Get-ChildItem $profListKey -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $raw = Get-ItemPropertyValue -Path $_.PSPath -Name 'ProfileImagePath' -ErrorAction Stop
                $exp = [Environment]::ExpandEnvironmentVariables([string]$raw)
                if ($exp -and (Test-Path $exp -PathType Container)) { $null = $paths.Add($exp) }
            } catch {}
        }
    }
    if ($env:USERPROFILE -and (Test-Path $env:USERPROFILE -PathType Container)) { $null = $paths.Add($env:USERPROFILE) }
    return @($paths)
}

function Add-ExistingFile {
    param([System.Collections.Generic.HashSet[string]]$Set, [string]$Path)
    if ($Path -and (Test-Path $Path -PathType Leaf)) {
        try { $null = $Set.Add([IO.Path]::GetFullPath($Path)) } catch {}
    }
}

function Add-RobloxFilesFromDirectory {
    param(
        [System.Collections.Generic.HashSet[string]]$Set,
        [string]$Directory,
        [switch]$Recursive,
        [string]$Filter = 'Roblox*.exe'
    )
    if (-not $Directory -or -not (Test-Path $Directory -PathType Container)) { return }
    $option = if ($Recursive) { [IO.SearchOption]::AllDirectories } else { [IO.SearchOption]::TopDirectoryOnly }
    try {
        foreach ($f in [IO.Directory]::EnumerateFiles($Directory, $Filter, $option)) {
            $null = $Set.Add($f)
        }
    } catch {
        # fallback on access denied
        try {
            $gciParams = @{ Path = $Directory; Filter = $Filter; File = $true; Force = $true; ErrorAction = 'SilentlyContinue' }
            if ($Recursive) { $gciParams.Recurse = $true }
            Get-ChildItem @gciParams | ForEach-Object { $null = $Set.Add($_.FullName) }
        } catch { Write-ScriptLog "Failed to scan directory: $Directory" 'WARN' }
    }
}

function Get-RobloxStorePackages {
    try {
        Import-Module Appx -ErrorAction Stop
        return @(Get-AppxPackage -AllUsers -ErrorAction Stop | Where-Object {
            [string]$_.Name -match '(?i)roblox' -or
            [string]$_.PackageFullName -match '(?i)roblox' -or
            [string]$_.PackageFamilyName -match '(?i)roblox'
        } | Sort-Object PackageFamilyName -Unique)
    } catch {
        Write-ScriptLog 'Failed to read Store packages; module Appx missing.' 'WARN'
        return @()
    }
}

function Get-RobloxExecutablePaths {
    $files = New-StringHashSet
    foreach ($prof in Get-LocalProfilePaths) {
        $local  = Join-Path $prof 'AppData\Local'
        $roblox = Join-Path $local 'Roblox'
        $vers   = Join-Path $roblox 'Versions'
        $tmp    = Join-Path $local 'Temp'
        Add-RobloxFilesFromDirectory -Set $files -Directory $roblox
        if (Test-Path $vers -PathType Container) {
            Get-ChildItem $vers -Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
                Add-RobloxFilesFromDirectory -Set $files -Directory $_.FullName
            }
        }
        if (Test-Path $tmp -PathType Container) {
            Add-RobloxFilesFromDirectory -Set $files -Directory $tmp
            Add-RobloxFilesFromDirectory -Set $files -Directory (Join-Path $tmp 'Roblox') -Recursive
        }
    }
    foreach ($root in @(
        (Join-Path $env:ProgramData 'Roblox'),
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Roblox' }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Roblox' })
    )) {
        if ($root) { Add-RobloxFilesFromDirectory -Set $files -Directory $root -Recursive }
    }
    foreach ($pkg in Get-RobloxStorePackages) {
        try {
            if ($pkg.InstallLocation -and (Test-Path $pkg.InstallLocation -PathType Container)) {
                Add-RobloxFilesFromDirectory -Set $files -Directory $pkg.InstallLocation -Filter '*.exe'
            }
        } catch {}
    }
    # Running processes
    Get-Process -Name 'Roblox*' -ErrorAction SilentlyContinue | ForEach-Object {
        try { if ($_.Path) { $null = $files.Add($_.Path) } } catch {}
    }
    try {
        Get-CimInstance Win32_Process -Filter "Name='Windows10Universal.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.ExecutablePath -match '(?i)ROBLOXCORPORATION\.ROBLOX_') {
                $null = $files.Add($_.ExecutablePath)
            }
        }
    } catch {}
    return @($files | Where-Object { $_ -and (Test-Path $_ -PathType Leaf) } | Sort-Object)
}

# ------------------------------------------------------------------------------
# Roblox process termination
# ------------------------------------------------------------------------------
function Stop-CurrentlyRunningRoblox {
    $stopped = 0
    Get-Process -Name 'Roblox*' -ErrorAction SilentlyContinue | ForEach-Object {
        try { Stop-Process -Id $_.Id -Force -ErrorAction Stop; $stopped++ } catch {}
    }
    try {
        Get-CimInstance Win32_Process -Filter "Name='Windows10Universal.exe'" -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.ExecutablePath -match '(?i)ROBLOXCORPORATION\.ROBLOX_') {
                try { Stop-Process -Id ([int]$_.ProcessId) -Force -ErrorAction Stop; $stopped++ } catch {}
            }
        }
    } catch {}
    if ($stopped -gt 0) { Write-ScriptLog "Terminated Roblox processes: $stopped" }
}

# ------------------------------------------------------------------------------
# Firewall helpers (idempotent)
# ------------------------------------------------------------------------------
function Initialize-AppContainerSidHelper {
    if ($null -ne ('RobloxBlock.AppContainerSid' -as [type])) { return }
    $src = @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;
namespace RobloxBlock {
    public static class AppContainerSid {
        [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
        private static extern int DeriveAppContainerSidFromAppContainerName(string name, out IntPtr sid);
        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern IntPtr FreeSid(IntPtr sid);
        public static string FromPackageFamilyName(string family) {
            IntPtr sidPtr; int hr = DeriveAppContainerSidFromAppContainerName(family, out sidPtr);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
            try { return new SecurityIdentifier(sidPtr).Value; } finally { FreeSid(sidPtr); }
        }
    }
}
'@
    Add-Type -TypeDefinition $src -Language CSharp
}

function Get-ExistingFirewallRuleNames {
    try {
        return New-StringHashSet -Values @(Get-NetFirewallRule -Group $FirewallGroup -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    } catch { return New-StringHashSet }
}

function Add-RobloxFirewallRules {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string[]]$ExecutablePaths = @())
    Import-Module NetSecurity -ErrorAction Stop
    $existing = Get-ExistingFirewallRuleNames
    $added = 0
    foreach ($prog in $ExecutablePaths) {
        if (-not $prog -or -not (Test-Path $prog -PathType Leaf)) { continue }
        $ruleName = "$RulePrefix" + "PROGRAM-" + (Get-StableMd5 -Text $prog)
        if ($existing.Contains($ruleName)) { continue }
        if ($PSCmdlet.ShouldProcess("Firewall rule for $prog", "Create outbound block rule")) {
            try {
                New-NetFirewallRule -Name $ruleName -DisplayName "BLOCK ROBLOX — $([IO.Path]::GetFileName($prog))" `
                    -Description "Blocking outbound Roblox traffic: $prog" -Group $FirewallGroup `
                    -Direction Outbound -Program $prog -Action Block -Profile Any -Enabled True | Out-Null
                $null = $existing.Add($ruleName)
                $added++
                Write-TransactionStep -Action 'FirewallRule' -Detail $ruleName
            } catch { Write-ScriptLog "Failed firewall rule: $prog" 'WARN' }
        }
    }
    $packages = @(Get-RobloxStorePackages)
    if ($packages.Count -gt 0) {
        try {
            Initialize-AppContainerSidHelper
            foreach ($pkg in $packages) {
                try {
                    $sid = [RobloxBlock.AppContainerSid]::FromPackageFamilyName([string]$pkg.PackageFamilyName)
                    $ruleName = "$RulePrefix" + "PACKAGE-" + (Get-StableMd5 -Text $sid)
                    if ($existing.Contains($ruleName)) { continue }
                    if ($PSCmdlet.ShouldProcess("Store package $($pkg.Name)", "Create outbound block rule")) {
                        New-NetFirewallRule -Name $ruleName -DisplayName "BLOCK ROBLOX — Store ($($pkg.Name))" `
                            -Description "Blocking Store package: $($pkg.PackageFamilyName)" -Group $FirewallGroup `
                            -Direction Outbound -Package $sid -Action Block -Profile Any -Enabled True | Out-Null
                        $null = $existing.Add($ruleName)
                        $added++
                        Write-TransactionStep -Action 'FirewallRule' -Detail $ruleName
                    }
                } catch { Write-ScriptLog "Failed Store rule: $($pkg.PackageFamilyName)" 'WARN' }
            }
        } catch { Write-ScriptLog 'Store package blocking init failed.' 'WARN' }
    }
    return $added
}

# ------------------------------------------------------------------------------
# Browser policies (idempotent, WhatIf aware)
# ------------------------------------------------------------------------------
function Add-RegistryListValues {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$RegistryPath, [string[]]$Values)
    if (-not $RegistryPath) { return }
    if ($PSCmdlet.ShouldProcess($RegistryPath, "Add URL blocklist entries")) {
        New-Item -Path $RegistryPath -Force | Out-Null
        $key = Get-Item $RegistryPath
        $existingNames = @($key.GetValueNames() | Where-Object { $_ })
        $existingVals = New-StringHashSet -Values @(foreach ($n in $existingNames) { [string]$key.GetValue($n) })
        $next = 1
        foreach ($v in $Values) {
            if ($existingVals.Contains($v)) { continue }
            while ($existingNames -contains [string]$next) { $next++ }
            New-ItemProperty -Path $RegistryPath -Name ([string]$next) -Value $v -PropertyType String -Force | Out-Null
            $existingNames += [string]$next
            $null = $existingVals.Add($v)
            $next++
        }
    }
}

function Remove-RegistryListValues {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$RegistryPath, [string[]]$Values)
    if (-not (Test-Path $RegistryPath)) { return }
    if ($PSCmdlet.ShouldProcess($RegistryPath, "Remove URL blocklist entries")) {
        $targets = New-StringHashSet -Values $Values
        $key = Get-Item $RegistryPath
        $key.GetValueNames() | Where-Object { $_ } | ForEach-Object {
            if ($targets.Contains([string]$key.GetValue($_))) {
                Remove-ItemProperty -Path $RegistryPath -Name $_ -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-FirefoxInstallDirectories {
    $dirs = New-StringHashSet
    foreach ($path in @(
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Mozilla Firefox' }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox' })
    )) {
        if ($path -and (Test-Path (Join-Path $path 'firefox.exe') -PathType Leaf)) {
            $null = $dirs.Add($path)
        }
    }
    return @($dirs)
}

function Set-FirefoxBlockPolicy {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([string]$FirefoxDirectory, [switch]$Remove)
    $dist = Join-Path $FirefoxDirectory 'distribution'
    $pol  = Join-Path $dist 'policies.json'
    if ($Remove -and -not (Test-Path $pol)) { return }
    if ($PSCmdlet.ShouldProcess($pol, "Update Firefox website filter")) {
        if (-not $Remove) { New-Item -Path $dist -ItemType Directory -Force | Out-Null }
        $cfg = [pscustomobject]@{}
        if (Test-Path $pol) {
            try { $cfg = Get-Content $pol -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-ScriptLog "Invalid Firefox JSON, left unchanged: $pol" 'WARN'; return }
        }
        if ($null -eq $cfg.PSObject.Properties['policies']) { $cfg | Add-Member -NotePropertyName policies -NotePropertyValue ([pscustomobject]@{}) }
        if ($null -eq $cfg.policies) { $cfg.policies = [pscustomobject]@{} }
        if ($null -eq $cfg.policies.PSObject.Properties['WebsiteFilter']) { $cfg.policies | Add-Member -NotePropertyName WebsiteFilter -NotePropertyValue ([pscustomobject]@{}) }
        if ($null -eq $cfg.policies.WebsiteFilter) { $cfg.policies.WebsiteFilter = [pscustomobject]@{} }
        $wf = $cfg.policies.WebsiteFilter
        $cur = @(if ($wf.PSObject.Properties['Block']) { $wf.Block | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } })
        $newBlock = if ($Remove) {
            @($cur | Where-Object { $BlockedFirefoxUrls -notcontains [string]$_ } | Sort-Object -Unique)
        } else {
            @(@($cur + $BlockedFirefoxUrls) | Sort-Object -Unique)
        }
        if (-not $wf.PSObject.Properties['Block']) { $wf | Add-Member -NotePropertyName Block -NotePropertyValue $newBlock }
        else { $wf.Block = $newBlock }
        if ((Test-Path $pol) -and -not (Test-Path "$pol.robloxblock.bak")) {
            Copy-Item $pol "$pol.robloxblock.bak" -Force -ErrorAction SilentlyContinue
        }
        $cfg | ConvertTo-Json -Depth 30 | Set-Content $pol -Encoding UTF8 -Force
    }
}

# ------------------------------------------------------------------------------
# SRP (with transactional backup / rollback capability)
# ------------------------------------------------------------------------------
function Backup-SrpState {
    $backup = Join-Path $InstallDirectory 'srp_backup.xml'
    if (Test-Path $SrpRulesPath) {
        try {
            Get-ChildItem $SrpRulesPath -ErrorAction SilentlyContinue | Export-Clixml -Path $backup -Force
            Write-TransactionStep -Action 'BackupSRP' -Detail $backup
            return $backup
        } catch { Write-ScriptLog 'Failed to backup SRP rules.' 'WARN' }
    }
    return $null
}

function Restore-SrpState {
    param([string]$BackupFile)
    if (-not $BackupFile -or -not (Test-Path $BackupFile)) { return }
    try {
        $saved = Import-Clixml -Path $BackupFile -ErrorAction Stop
        # Remove current rules that belong to us
        Remove-RobloxSoftwareRestrictionPolicies -SuppressTransaction
        # Re-import saved rules
        foreach ($rule in $saved) {
            $dest = $rule.PSPath -replace '^.*?\\Paths\\', "$SrpRulesPath\"
            if (-not (Test-Path $dest)) {
                New-Item -Path $dest -Force | Out-Null
                $rule | Get-ItemProperty | ForEach-Object {
                    $name = $_.PSObject.Properties.Name
                    if ($name -notin 'PSPath','PSParentPath','PSChildName','PSDrive','PSProvider') {
                        New-ItemProperty -Path $dest -Name $name -Value $_.$name -PropertyType String -Force | Out-Null
                    }
                }
            }
        }
        Write-ScriptLog 'SRP state restored from backup.' 'WARN'
    } catch { Write-ScriptLog 'Failed to restore SRP backup.' 'ERROR' }
}

function Set-RobloxSoftwareRestrictionPolicies {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    $changed = $false
    $baseMissing = -not (Test-Path $SrpBasePath)

    if ($PSCmdlet.ShouldProcess('Software Restriction Policies', 'Configure')) {
        # Take backup before any change
        $backup = Backup-SrpState

        try {
            New-Item -Path $SrpBasePath -Force | Out-Null
            New-Item -Path $SrpRulesPath -Force | Out-Null

            if (Set-RegistryValueIfMissing -Path $SrpBasePath -Name 'DefaultLevel' -Value 262144 -PropertyType DWord) { $changed = $true }
            if (Set-RegistryValueIfMissing -Path $SrpBasePath -Name 'PolicyScope' -Value 0 -PropertyType DWord) { $changed = $true }
            if (Set-RegistryValueIfMissing -Path $SrpBasePath -Name 'TransparentEnabled' -Value 1 -PropertyType DWord) { $changed = $true }
            if (Set-RegistryValueIfMissing -Path $SrpBasePath -Name 'AuthenticodeEnabled' -Value 0 -PropertyType DWord) { $changed = $true }

            if ($baseMissing -and -not (Test-RegistryValueExists -Path $SrpBasePath -Name 'ExecutableTypes')) {
                $types = @('ADE','ADP','BAS','BAT','CHM','CMD','COM','CPL','CRT','EXE','HLP','HTA','INF','INS','ISP','JS',
                           'JSE','LNK','MDB','MDE','MSC','MSI','MSP','MST','OCX','PCD','PIF','REG','SCR','SHS','URL','VB','VBE','VBS','WSC','WSF','WSH')
                New-ItemProperty -Path $SrpBasePath -Name 'ExecutableTypes' -Value ([string[]]$types) -PropertyType MultiString -Force | Out-Null
                $changed = $true
            }

            foreach ($rulePath in Get-RobloxSrpPaths) {
                $ruleRegPath = Join-Path $SrpRulesPath (ConvertTo-StableGuidString -Text $rulePath)
                $expectedDesc = "$SrpDescriptionPrefix block $rulePath"
                $needsWrite = -not (Test-Path $ruleRegPath)
                if (-not $needsWrite) {
                    try {
                        $itemData = [string](Get-ItemPropertyValue -Path $ruleRegPath -Name 'ItemData' -ErrorAction Stop)
                        $desc = [string](Get-ItemPropertyValue -Path $ruleRegPath -Name 'Description' -ErrorAction Stop)
                        $needsWrite = ($itemData -ne $rulePath -or $desc -ne $expectedDesc)
                    } catch { $needsWrite = $true }
                }
                if ($needsWrite) {
                    New-Item -Path $ruleRegPath -Force | Out-Null
                    New-ItemProperty -Path $ruleRegPath -Name 'ItemData' -Value $rulePath -PropertyType String -Force | Out-Null
                    New-ItemProperty -Path $ruleRegPath -Name 'SaferFlags' -Value 0 -PropertyType DWord -Force | Out-Null
                    New-ItemProperty -Path $ruleRegPath -Name 'Description' -Value $expectedDesc -PropertyType String -Force | Out-Null
                    $changed = $true
                    Write-TransactionStep -Action 'SRP_Path' -Detail $rulePath
                }
            }
        } catch {
            Write-ScriptLog 'Failed during SRP configuration, rolling back.' 'ERROR'
            Restore-SrpState -BackupFile $backup
            throw
        }
    }
    return $changed
}

function Remove-RobloxSoftwareRestrictionPolicies {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param([switch]$SuppressTransaction)
    if (-not (Test-Path $SrpRulesPath)) { return $false }
    if ($PSCmdlet.ShouldProcess('SRP rules', 'Remove')) {
        $changed = $false
        Get-ChildItem $SrpRulesPath -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $desc = [string](Get-ItemPropertyValue -Path $_.PSPath -Name 'Description' -ErrorAction SilentlyContinue)
                if ($desc.StartsWith($SrpDescriptionPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    Remove-Item $_.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                    if (-not $SuppressTransaction) { Write-TransactionStep -Action 'RemoveSRP' -Detail $_.PSPath }
                    $changed = $true
                }
            } catch {}
        }
        return $changed
    }
    return $false
}

# ------------------------------------------------------------------------------
# Additional registry helpers
# ------------------------------------------------------------------------------
function Test-RegistryValueExists {
    param([string]$Path, [string]$Name)
    try { $null = Get-ItemPropertyValue -Path $Path -Name $Name -ErrorAction Stop; return $true } catch { return $false }
}

function Set-RegistryValueIfMissing {
    param([string]$Path, [string]$Name, $Value, [ValidateSet('DWord','String','MultiString')][string]$PropertyType)
    if (-not (Test-RegistryValueExists -Path $Path -Name $Name)) {
        New-ItemProperty -Path $Path -Name $Name -Value $Value -PropertyType $PropertyType -Force | Out-Null
        return $true
    }
    return $false
}

function Get-RobloxSrpPaths {
    $paths = New-StringHashSet -Values @(
        '%SystemDrive%\Users\*\AppData\Local\Roblox\*',
        '%SystemDrive%\Users\*\AppData\Local\Temp\Roblox\*',
        '%SystemDrive%\Users\*\AppData\Local\Temp\Roblox*.exe',
        '%SystemDrive%\Users\*\Desktop\Roblox*.exe',
        '%SystemDrive%\Users\*\Downloads\Roblox*.exe',
        '%ProgramFiles%\Roblox\*',
        '%ProgramFiles(x86)%\Roblox\*',
        '%ProgramData%\Roblox\*',
        '%ProgramFiles%\WindowsApps\ROBLOXCORPORATION.ROBLOX_*'
    )
    foreach ($name in $RobloxExecutableNames) { $null = $paths.Add("*\$name") }
    foreach ($pkg in Get-RobloxStorePackages) {
        try { if ($pkg.InstallLocation) { $null = $paths.Add((Join-Path $pkg.InstallLocation '*')) } } catch {}
    }
    return @($paths)
}

# ------------------------------------------------------------------------------
# Scheduled tasks & guard script
# ------------------------------------------------------------------------------
function Write-ProcessGuardScript {
    if ($PSCmdlet.ShouldProcess($GuardScript, 'Write guard script')) {
        $content = @'
#Requires -Version 5.1
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$InstallDirectory = Join-Path $env:ProgramData 'RobloxBlock'
$LogFile = Join-Path $InstallDirectory 'RobloxProcessGuard.log'
$MutexName = 'Global\RobloxBlockProcessGuard'
$SourceIdentifier = 'RobloxBlock.ProcessStarted'

function Write-GuardLog($msg) {
    try { Add-Content $LogFile -Encoding UTF8 -Value "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') $msg" } catch {}
}
function Stop-RobloxPid($Id, $Name) {
    $should = $Name -match '^Roblox.*\.exe$'
    $path = $null
    if (-not $should -and $Name -eq 'Windows10Universal.exe') {
        try { $ci = Get-CimInstance Win32_Process -Filter "ProcessId=$Id"; $path = [string]$ci.ExecutablePath; $should = $path -match 'ROBLOXCORPORATION\.ROBLOX_' } catch {}
    }
    if (-not $should) { return }
    try { Stop-Process -Id $Id -Force; Write-GuardLog "Terminated $Name PID=$Id" } catch {}
}
$mutex = New-Object Threading.Mutex($false, $MutexName)
if (-not $mutex.WaitOne(0, $false)) { exit 0 }
try {
    # initial sweep
    Get-Process -Name 'Roblox*' | ForEach-Object { Stop-RobloxPid $_.Id ($_.ProcessName+'.exe') }
    Get-CimInstance Win32_Process -Filter "Name='Windows10Universal.exe'" | ForEach-Object { Stop-RobloxPid $_.ProcessId 'Windows10Universal.exe' }
    $query = "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName LIKE 'Roblox%' OR ProcessName = 'Windows10Universal.exe'"
    Register-WmiEvent -Query $query -SourceIdentifier $SourceIdentifier | Out-Null
    Write-GuardLog 'Event guard active.'
    while ($true) {
        $evt = Wait-Event -SourceIdentifier $SourceIdentifier -Timeout 300
        if ($evt) {
            try { Stop-RobloxPid $evt.SourceEventArgs.NewEvent.ProcessID $evt.SourceEventArgs.NewEvent.ProcessName }
            finally { Remove-Event $evt.EventIdentifier }
        }
    }
} finally {
    Unregister-Event -SourceIdentifier $SourceIdentifier -Force -ErrorAction SilentlyContinue
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
'@
        Set-Content -Path $GuardScript -Value $content -Encoding UTF8 -Force
        Write-TransactionStep -Action 'GuardScript' -Detail $GuardScript
    }
}

function Install-ProcessGuardTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Import-Module ScheduledTasks -ErrorAction Stop
    Write-ProcessGuardScript
    if ($PSCmdlet.ShouldProcess('Process guard task', 'Create')) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$GuardScript`""
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $GuardTaskName -Action $action -Trigger @((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -AtLogOn)) -Principal $principal -Settings $settings -Description 'Event-driven Roblox process guard' -Force | Out-Null
        Start-ScheduledTask -TaskName $GuardTaskName -ErrorAction SilentlyContinue
        Write-TransactionStep -Action 'Task' -Detail $GuardTaskName
    }
}

function Install-AutoRefreshTask {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Import-Module ScheduledTasks -ErrorAction Stop
    if ($PSCmdlet.ShouldProcess('Auto-refresh task', 'Create')) {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$InstalledScript`" -RefreshOnly"
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(3) -RepetitionInterval (New-TimeSpan -Hours 6) -RepetitionDuration (New-TimeSpan -Days 3650)
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew -Hidden
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $RefreshTaskName -Action $action -Trigger @((New-ScheduledTaskTrigger -AtStartup),$trigger) -Principal $principal -Settings $settings -Description 'Periodic Roblox firewall rule refresh' -Force | Out-Null
        Write-TransactionStep -Action 'Task' -Detail $RefreshTaskName
    }
}

function Remove-RobloxTasks {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Import-Module ScheduledTasks -ErrorAction SilentlyContinue
    foreach ($name in @($GuardTaskName, $RefreshTaskName)) {
        if ($PSCmdlet.ShouldProcess($name, 'Remove scheduled task')) {
            Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

# ------------------------------------------------------------------------------
# Policy refresh
# ------------------------------------------------------------------------------
function Invoke-ComputerPolicyRefresh {
    if ($PSCmdlet.ShouldProcess('Group Policy', 'Refresh')) {
        try {
            $gpupdate = Join-Path $env:SystemRoot 'System32\gpupdate.exe'
            if (Test-Path $gpupdate) {
                Start-Process -FilePath $gpupdate -ArgumentList '/target:computer /force' -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null
                Write-ScriptLog 'Group Policy refreshed.'
            }
        } catch { Write-ScriptLog 'gpupdate failed.' 'WARN' }
    }
}

# ------------------------------------------------------------------------------
# Browser policy orchestrators
# ------------------------------------------------------------------------------
function Install-BrowserPolicies {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if ($PSCmdlet.ShouldProcess('Browser URL blocklists', 'Apply')) {
        Add-RegistryListValues -RegistryPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist' -Values $BlockedChromiumUrls
        Add-RegistryListValues -RegistryPath 'HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist' -Values $BlockedChromiumUrls
        foreach ($ffdir in Get-FirefoxInstallDirectories) {
            try { Set-FirefoxBlockPolicy -FirefoxDirectory $ffdir } catch { Write-ScriptLog "Firefox policy failed: $ffdir" 'WARN' }
        }
    }
}

function Remove-BrowserPolicies {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    if ($PSCmdlet.ShouldProcess('Browser URL blocklists', 'Remove')) {
        Remove-RegistryListValues -RegistryPath 'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist' -Values $BlockedChromiumUrls
        Remove-RegistryListValues -RegistryPath 'HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist' -Values $BlockedChromiumUrls
        foreach ($ffdir in Get-FirefoxInstallDirectories) {
            try { Set-FirefoxBlockPolicy -FirefoxDirectory $ffdir -Remove } catch { Write-ScriptLog "Firefox policy removal failed: $ffdir" 'WARN' }
        }
    }
}

# ------------------------------------------------------------------------------
# Full uninstall
# ------------------------------------------------------------------------------
function Remove-RobloxBlock {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()
    Write-ScriptLog "Uninstall started (version $ScriptVersion)."
    Clear-TransactionState
    if ($PSCmdlet.ShouldProcess('All Roblox blocking components', 'Uninstall')) {
        Remove-RobloxTasks
        Stop-CurrentlyRunningRoblox
        try {
            Import-Module NetSecurity -ErrorAction SilentlyContinue
            Get-NetFirewallRule -Group $FirewallGroup -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        } catch { Write-ScriptLog 'Firewall rule removal failed.' 'WARN' }
        Remove-BrowserPolicies
        $changed = Remove-RobloxSoftwareRestrictionPolicies
        if ($changed) { Invoke-ComputerPolicyRefresh }
        Remove-Item $GuardScript -Force -ErrorAction SilentlyContinue
        Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
        Write-ScriptLog 'Uninstall completed.'
    }
}

# ------------------------------------------------------------------------------
# Self‑diagnostics & repair
# ------------------------------------------------------------------------------
function Assert-InstallationIntegrity {
    $issues = @()
    if (-not $RefreshOnly) {
        if (-not (Test-Path $GuardScript -PathType Leaf)) { $issues += 'Guard script missing' }
        try {
            $hasGuard = Get-ScheduledTask -TaskName $GuardTaskName -ErrorAction Stop
        } catch { $issues += 'Guard task not found' }
        try {
            $hasRefresh = Get-ScheduledTask -TaskName $RefreshTaskName -ErrorAction Stop
        } catch { $issues += 'Refresh task not found' }
    }
    if ($issues.Count -gt 0) {
        Write-ScriptLog "Integrity issues detected: $($issues -join '; ') Attempting repair..." 'WARN'
        if ($PSCmdlet.ShouldProcess('Damaged components', 'Repair')) {
            if (-not $RefreshOnly) {
                try { Install-ProcessGuardTask -ErrorAction Stop } catch { Write-ScriptLog 'Failed to reinstall guard task.' 'ERROR' }
                try { Install-AutoRefreshTask -ErrorAction Stop } catch { Write-ScriptLog 'Failed to reinstall refresh task.' 'ERROR' }
            }
        }
    }
}

# ------------------------------------------------------------------------------
# Main execution
# ------------------------------------------------------------------------------
if ($Uninstall) {
    Remove-RobloxBlock
    exit 0
}

if (-not $RefreshOnly) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-ScriptLog 'Cannot determine script path.' 'ERROR'
        exit 2
    }
    $fullSrc = [IO.Path]::GetFullPath($PSCommandPath)
    $fullDst = [IO.Path]::GetFullPath($InstalledScript)
    if (-not [string]::Equals($fullSrc, $fullDst, [StringComparison]::OrdinalIgnoreCase)) {
        if ($PSCmdlet.ShouldProcess("Copy script to $InstalledScript", 'Self-install')) {
            Copy-Item -Path $PSCommandPath -Destination $InstalledScript -Force
        }
    }
}

# Always check integrity and repair if needed (except pure RefreshOnly)
if (-not $RefreshOnly) {
    Assert-InstallationIntegrity
}

Stop-CurrentlyRunningRoblox

$exePaths = @(Get-RobloxExecutablePaths)
$newFw = 0
try {
    $newFw = Add-RobloxFirewallRules -ExecutablePaths $exePaths
} catch {
    Write-ScriptLog 'Firewall update failed.' 'ERROR'
    exit 3
}

if (-not $RefreshOnly) {
    Install-BrowserPolicies
    $srpChanged = $false
    try {
        $srpChanged = Set-RobloxSoftwareRestrictionPolicies
    } catch {
        Write-ScriptLog 'SRP installation failed, continuing with other layers.' 'ERROR'
    }
    if ($srpChanged) { Invoke-ComputerPolicyRefresh }
    try { Install-AutoRefreshTask } catch { Write-ScriptLog 'Refresh task creation failed.' 'ERROR' }
    try { Install-ProcessGuardTask } catch { Write-ScriptLog 'Guard task creation failed.' 'ERROR' }
}

# Final firewall profile check
try {
    $disabled = (Get-NetFirewallProfile | Where-Object { $_.Enabled -eq $false }).Name
    if ($disabled.Count -gt 0) {
        Write-ScriptLog "WARNING: Windows Firewall is disabled for profiles: $($disabled -join ', ')" 'WARN'
    }
} catch {}

Write-ScriptLog "Version=$ScriptVersion; RefreshOnly=$RefreshOnly; EXEs found=$($exePaths.Count); new FW rules=$newFw."
Clear-TransactionState
exit 0