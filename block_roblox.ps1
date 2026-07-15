#Requires -Version 5.1
<#
.SYNOPSIS
    Optimized silent multi-layer Roblox blocking for Windows 10.

.DESCRIPTION
    Runs without prompts, windows, or confirmation dialogs:
      - blocks outbound Roblox traffic through the NetSecurity module;
      - blocks roblox.com and rbxcdn.com in Edge, Chrome, and Firefox;
      - creates machine-level Software Restriction Policies (SRP);
      - starts a hidden event-driven Roblox process guard;
      - periodically discovers new Roblox versions and adds firewall rules.

    Performance optimizations:
      - does not continuously poll every process every few seconds;
      - the process guard uses Win32_ProcessStartTrace events;
      - the file system is scanned only in known Roblox directories;
      - the firewall rule list is loaded into a HashSet once;
      - browser policies and gpupdate are not processed on every RefreshOnly run;
      - Pktmon is not kept running because it is a diagnostic tool.

    The initial run must be started from an elevated PowerShell session.
    The script intentionally does not invoke UAC and exits when elevation is
    not available, without displaying dialogs, using exit code 5.

.PARAMETER RefreshOnly
    Internal background mode for refreshing file-based firewall rules.

.PARAMETER Uninstall
    Silently removes the rules and tasks created by this script.

.EXAMPLE
    powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden `
      -ExecutionPolicy Bypass `
      -File "$env:USERPROFILE\AppData\w_temp\Block-Roblox-All.ps1"

.EXAMPLE
    powershell.exe -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden `
      -ExecutionPolicy Bypass `
      -File "C:\ProgramData\RobloxBlock\Block-Roblox-All.ps1" -Uninstall
#>

[CmdletBinding()]
param(
    [switch]$RefreshOnly,
    [switch]$Uninstall
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

$ScriptVersion = '4.0'

$InstallDirectory = Join-Path $env:ProgramData 'RobloxBlock'
$InstalledScript = Join-Path $InstallDirectory 'Block-Roblox-All.ps1'
$GuardScript = Join-Path $InstallDirectory 'RobloxProcessGuard.ps1'
$LogFile = Join-Path $InstallDirectory 'RobloxBlock.log'
$GuardLogFile = Join-Path $InstallDirectory 'RobloxProcessGuard.log'

$RefreshTaskName = 'RobloxBlock-AutoRefresh'
$GuardTaskName = 'RobloxBlock-ProcessGuard'

$FirewallGroup = 'RobloxBlock'
$RulePrefix = 'RBX-BLOCK-'

$SrpBasePath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Safer\CodeIdentifiers'
$SrpRulesPath = Join-Path $SrpBasePath '0\Paths'
$SrpDescriptionPrefix = 'RobloxBlock:'

$BlockedChromiumUrls = @(
    'roblox.com',
    'rbxcdn.com'
)

$BlockedFirefoxUrls = @(
    '*://roblox.com/*',
    '*://*.roblox.com/*',
    '*://rbxcdn.com/*',
    '*://*.rbxcdn.com/*'
)

$RobloxExecutableNames = @(
    'Roblox.exe',
    'RobloxCrashHandler.exe',
    'RobloxGameClient.exe',
    'RobloxInstaller.exe',
    'RobloxPlayerBeta.exe',
    'RobloxPlayerInstaller.exe',
    'RobloxPlayerLauncher.exe',
    'RobloxStudioBeta.exe',
    'RobloxStudioLauncherBeta.exe'
)

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
}

if (-not (Test-IsAdministrator)) {
    try {
        $temporaryErrorLog = Join-Path $env:TEMP 'RobloxBlock-install-error.log'
        Add-Content -Path $temporaryErrorLog -Encoding UTF8 -Value (
            '{0:yyyy-MM-dd HH:mm:ss} Administrator privileges are required.' -f
            (Get-Date)
        )
    }
    catch {
        # Ignore failures when writing the temporary log.
    }

    exit 5
}

New-Item -Path $InstallDirectory -ItemType Directory -Force | Out-Null

function Optimize-LogFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [int64]$MaximumSize = 2MB,

        [int]$KeepLines = 500
    )

    try {
        if (
            (Test-Path $Path) -and
            (Get-Item $Path).Length -gt $MaximumSize
        ) {
            $temporaryPath = "$Path.tmp"

            Get-Content $Path -Tail $KeepLines |
                Set-Content $temporaryPath -Encoding UTF8

            Move-Item $temporaryPath $Path -Force
        }
    }
    catch {
        # Logging must not affect the primary blocking mechanisms.
    }
}

Optimize-LogFile -Path $LogFile

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    try {
        Add-Content -Path $LogFile -Encoding UTF8 -Value (
            '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f
            (Get-Date), $Level, $Message
        )
    }
    catch {
        # Do not terminate the script because of a logging failure.
    }
}

function Get-StableMd5 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $algorithm = [Security.Cryptography.MD5]::Create()

    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text.ToLowerInvariant())

        return -join (
            $algorithm.ComputeHash($bytes) |
                ForEach-Object { $_.ToString('x2') }
        )
    }
    finally {
        $algorithm.Dispose()
    }
}

function ConvertTo-StableGuidString {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text
    )

    $hex = Get-StableMd5 -Text $Text

    return (
        '{{{0}-{1}-{2}-{3}-{4}}}' -f
        $hex.Substring(0, 8),
        $hex.Substring(8, 4),
        $hex.Substring(12, 4),
        $hex.Substring(16, 4),
        $hex.Substring(20, 12)
    )
}

function New-StringHashSet {
    param(
        [string[]]$Values = @()
    )

    $set = New-Object (
        'System.Collections.Generic.HashSet[string]'
    ) ([StringComparer]::OrdinalIgnoreCase)

    foreach ($value in $Values) {
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $null = $set.Add($value)
        }
    }

    return $set
}

function Get-LocalProfilePaths {
    $result = New-StringHashSet
    $profileList = (
        'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    )

    if (Test-Path $profileList) {
        foreach ($profileKey in (
            Get-ChildItem $profileList -ErrorAction SilentlyContinue
        )) {
            try {
                $rawPath = Get-ItemPropertyValue `
                    -Path $profileKey.PSPath `
                    -Name 'ProfileImagePath' `
                    -ErrorAction Stop

                $expandedPath = [Environment]::ExpandEnvironmentVariables(
                    [string]$rawPath
                )

                if (
                    $expandedPath -and
                    (Test-Path $expandedPath -PathType Container)
                ) {
                    $null = $result.Add($expandedPath)
                }
            }
            catch {
                # Skip invalid or corrupted profile entries.
            }
        }
    }

    if (
        $env:USERPROFILE -and
        (Test-Path $env:USERPROFILE -PathType Container)
    ) {
        $null = $result.Add($env:USERPROFILE)
    }

    return @($result)
}

function Add-ExistingFile {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$Set,

        [string]$Path
    )

    if (
        $Path -and
        (Test-Path $Path -PathType Leaf)
    ) {
        try {
            $fullPath = [IO.Path]::GetFullPath($Path)
            $null = $Set.Add($fullPath)
        }
        catch {
            # Skip invalid paths.
        }
    }
}

function Add-RobloxFilesFromDirectory {
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.HashSet[string]]$Set,

        [string]$Directory,

        [switch]$Recursive
    )

    if (
        -not $Directory -or
        -not (Test-Path $Directory -PathType Container)
    ) {
        return
    }

    $searchOption = if ($Recursive) {
        [IO.SearchOption]::AllDirectories
    }
    else {
        [IO.SearchOption]::TopDirectoryOnly
    }

    try {
        foreach ($path in (
            [IO.Directory]::EnumerateFiles(
                $Directory,
                'Roblox*.exe',
                $searchOption
            )
        )) {
            $null = $Set.Add($path)
        }
    }
    catch {
        # EnumerateFiles may stop on access-denied errors in protected directories.
        # Use a more tolerant fallback scan only for this directory.
        try {
            $parameters = @{
                Path = $Directory
                Filter = 'Roblox*.exe'
                File = $true
                Force = $true
                ErrorAction = 'SilentlyContinue'
            }

            if ($Recursive) {
                $parameters.Recurse = $true
            }

            foreach ($file in (Get-ChildItem @parameters)) {
                $null = $Set.Add($file.FullName)
            }
        }
        catch {
            Write-Log "Failed to scan directory: $Directory" 'WARN'
        }
    }
}

function Get-RobloxStorePackages {
    try {
        Import-Module Appx -ErrorAction Stop

        return @(
            Get-AppxPackage -AllUsers -ErrorAction Stop |
                Where-Object {
                    [string]$_.Name -match '(?i)roblox' -or
                    [string]$_.PackageFullName -match '(?i)roblox' -or
                    [string]$_.PackageFamilyName -match '(?i)roblox'
                } |
                Sort-Object PackageFamilyName -Unique
        )
    }
    catch {
        Write-Log 'Failed to read Roblox Microsoft Store packages.' 'WARN'
        return @()
    }
}

function Get-RobloxExecutablePaths {
    $files = New-StringHashSet

    foreach ($profilePath in (Get-LocalProfilePaths)) {
        $localAppData = Join-Path $profilePath 'AppData\Local'
        $robloxRoot = Join-Path $localAppData 'Roblox'
        $versionsRoot = Join-Path $robloxRoot 'Versions'
        $tempRoot = Join-Path $localAppData 'Temp'

        # The root directory usually contains the launcher or installer.
        Add-RobloxFilesFromDirectory `
            -Set $files `
            -Directory $robloxRoot

        # Do not recursively scan the entire AppData directory.
        # Check only Roblox version directories and expected executable files.
        if (Test-Path $versionsRoot -PathType Container) {
            foreach ($versionDirectory in (
                Get-ChildItem $versionsRoot -Directory -Force `
                    -ErrorAction SilentlyContinue
            )) {
                foreach ($fileName in $RobloxExecutableNames) {
                    Add-ExistingFile `
                        -Set $files `
                        -Path (Join-Path $versionDirectory.FullName $fileName)
                }

                # Detect new Roblox*.exe files if Roblox changes an executable name.
                Add-RobloxFilesFromDirectory `
                    -Set $files `
                    -Directory $versionDirectory.FullName
            }
        }

        # Installers may temporarily reside directly in the Temp directory.
        if (Test-Path $tempRoot -PathType Container) {
            try {
                foreach ($temporaryFile in (
                    Get-ChildItem $tempRoot -File -Filter 'Roblox*.exe' -Force `
                        -ErrorAction SilentlyContinue
                )) {
                    $null = $files.Add($temporaryFile.FullName)
                }
            }
            catch {
                # Ignore Temp directory access errors.
            }

            $temporaryRobloxDirectory = Join-Path $tempRoot 'Roblox'

            Add-RobloxFilesFromDirectory `
                -Set $files `
                -Directory $temporaryRobloxDirectory `
                -Recursive
        }
    }

    foreach ($machineRoot in @(
        (Join-Path $env:ProgramData 'Roblox'),
        $(if ($env:ProgramFiles) {
            Join-Path $env:ProgramFiles 'Roblox'
        }),
        $(if (${env:ProgramFiles(x86)}) {
            Join-Path ${env:ProgramFiles(x86)} 'Roblox'
        })
    )) {
        if ($machineRoot) {
            Add-RobloxFilesFromDirectory `
                -Set $files `
                -Directory $machineRoot `
                -Recursive
        }
    }

    foreach ($package in (Get-RobloxStorePackages)) {
        try {
            if (
                $package.InstallLocation -and
                (Test-Path $package.InstallLocation -PathType Container)
            ) {
                foreach ($packageExe in (
                    Get-ChildItem $package.InstallLocation -File -Filter '*.exe' `
                        -Force -ErrorAction SilentlyContinue
                )) {
                    $null = $files.Add($packageExe.FullName)
                }
            }
        }
        catch {
            # Some WindowsApps paths may be inaccessible.
        }
    }

    # Perform a one-time check of already running processes.
    foreach ($process in (
        Get-Process -Name 'Roblox*' -ErrorAction SilentlyContinue
    )) {
        try {
            if ($process.Path) {
                $null = $files.Add($process.Path)
            }
        }
        catch {
            # The process path may be unavailable.
        }
    }

    try {
        foreach ($storeProcess in (
            Get-CimInstance Win32_Process `
                -Filter "Name='Windows10Universal.exe'" `
                -ErrorAction SilentlyContinue
        )) {
            if (
                $storeProcess.ExecutablePath -match
                '(?i)ROBLOXCORPORATION\.ROBLOX_'
            ) {
                $null = $files.Add($storeProcess.ExecutablePath)
            }
        }
    }
    catch {
        # The CIM check for the packaged version is optional.
    }

    return @(
        $files |
            Where-Object {
                $_ -and
                (Test-Path $_ -PathType Leaf)
            } |
            Sort-Object
    )
}

function Stop-CurrentlyRunningRoblox {
    $stopped = 0

    foreach ($process in (
        Get-Process -Name 'Roblox*' -ErrorAction SilentlyContinue
    )) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            $stopped++
        }
        catch {
            # The process may have exited on its own.
        }
    }

    try {
        foreach ($storeProcess in (
            Get-CimInstance Win32_Process `
                -Filter "Name='Windows10Universal.exe'" `
                -ErrorAction SilentlyContinue
        )) {
            if (
                $storeProcess.ExecutablePath -match
                '(?i)ROBLOXCORPORATION\.ROBLOX_'
            ) {
                Stop-Process `
                    -Id ([int]$storeProcess.ProcessId) `
                    -Force `
                    -ErrorAction SilentlyContinue

                $stopped++
            }
        }
    }
    catch {
        # Do not stop installation because of a CIM error.
    }

    if ($stopped -gt 0) {
        Write-Log "Stopped Roblox processes: $stopped"
    }
}

function Initialize-AppContainerSidHelper {
    if ($null -ne ('RobloxBlock.AppContainerSid' -as [type])) {
        return
    }

    $source = @'
using System;
using System.Runtime.InteropServices;
using System.Security.Principal;

namespace RobloxBlock
{
    public static class AppContainerSid
    {
        [DllImport("userenv.dll", CharSet = CharSet.Unicode)]
        private static extern int DeriveAppContainerSidFromAppContainerName(
            string appContainerName,
            out IntPtr sid);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern IntPtr FreeSid(IntPtr sid);

        public static string FromPackageFamilyName(string packageFamilyName)
        {
            IntPtr sidPointer;
            int result = DeriveAppContainerSidFromAppContainerName(
                packageFamilyName,
                out sidPointer);

            if (result != 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }

            try
            {
                return new SecurityIdentifier(sidPointer).Value;
            }
            finally
            {
                FreeSid(sidPointer);
            }
        }
    }
}
'@

    Add-Type -TypeDefinition $source -Language CSharp
}

function Get-ExistingRobloxFirewallRuleNames {
    try {
        return New-StringHashSet -Values @(
            Get-NetFirewallRule `
                -Group $FirewallGroup `
                -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Name
        )
    }
    catch {
        return New-StringHashSet
    }
}

function Add-RobloxFirewallRules {
    param(
        [string[]]$ExecutablePaths = @()
    )

    Import-Module NetSecurity -ErrorAction Stop

    $existingRuleNames = Get-ExistingRobloxFirewallRuleNames
    $added = 0

    foreach ($programPath in $ExecutablePaths) {
        if (
            -not $programPath -or
            -not (Test-Path $programPath -PathType Leaf)
        ) {
            continue
        }

        $ruleName = (
            "$RulePrefix" +
            'PROGRAM-' +
            (Get-StableMd5 -Text $programPath)
        )

        if ($existingRuleNames.Contains($ruleName)) {
            continue
        }

        try {
            New-NetFirewallRule `
                -Name $ruleName `
                -DisplayName (
                    'BLOCK ROBLOX — ' +
                    [IO.Path]::GetFileName($programPath)
                ) `
                -Description (
                    'Blocking outbound Roblox traffic: ' +
                    $programPath
                ) `
                -Group $FirewallGroup `
                -Direction Outbound `
                -Program $programPath `
                -Action Block `
                -Profile Any `
                -Enabled True | Out-Null

            $null = $existingRuleNames.Add($ruleName)
            $added++
        }
        catch {
            Write-Log "Failed to create firewall rule: $programPath" 'WARN'
        }
    }

    $packages = @(Get-RobloxStorePackages)

    if ($packages.Count -gt 0) {
        try {
            Initialize-AppContainerSidHelper

            foreach ($package in $packages) {
                try {
                    $packageSid = (
                        [RobloxBlock.AppContainerSid]::FromPackageFamilyName(
                            [string]$package.PackageFamilyName
                        )
                    )

                    $ruleName = (
                        "$RulePrefix" +
                        'PACKAGE-' +
                        (Get-StableMd5 -Text $packageSid)
                    )

                    if ($existingRuleNames.Contains($ruleName)) {
                        continue
                    }

                    New-NetFirewallRule `
                        -Name $ruleName `
                        -DisplayName (
                            "BLOCK ROBLOX — Store ($($package.Name))"
                        ) `
                        -Description (
                            'Blocking Roblox Store package: ' +
                            $package.PackageFamilyName
                        ) `
                        -Group $FirewallGroup `
                        -Direction Outbound `
                        -Package $packageSid `
                        -Action Block `
                        -Profile Any `
                        -Enabled True | Out-Null

                    $null = $existingRuleNames.Add($ruleName)
                    $added++
                }
                catch {
                    Write-Log (
                        'Failed to create Store package rule: ' +
                        $package.PackageFamilyName
                    ) 'WARN'
                }
            }
        }
        catch {
            Write-Log 'Failed to initialize Store package blocking.' 'WARN'
        }
    }

    return $added
}

function Add-RegistryListValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Values
    )

    New-Item -Path $RegistryPath -Force | Out-Null
    $registryKey = Get-Item $RegistryPath

    $existingNames = @(
        $registryKey.GetValueNames() |
            Where-Object { $_ }
    )

    $existingValues = New-StringHashSet -Values @(
        foreach ($name in $existingNames) {
            [string]$registryKey.GetValue($name)
        }
    )

    $nextIndex = 1

    foreach ($value in $Values) {
        if ($existingValues.Contains($value)) {
            continue
        }

        while ($existingNames -contains [string]$nextIndex) {
            $nextIndex++
        }

        New-ItemProperty `
            -Path $RegistryPath `
            -Name ([string]$nextIndex) `
            -Value $value `
            -PropertyType String `
            -Force | Out-Null

        $existingNames += [string]$nextIndex
        $null = $existingValues.Add($value)
        $nextIndex++
    }
}

function Remove-RegistryListValues {
    param(
        [Parameter(Mandatory = $true)]
        [string]$RegistryPath,

        [Parameter(Mandatory = $true)]
        [string[]]$Values
    )

    if (-not (Test-Path $RegistryPath)) {
        return
    }

    $targets = New-StringHashSet -Values $Values
    $registryKey = Get-Item $RegistryPath

    foreach ($name in (
        $registryKey.GetValueNames() |
            Where-Object { $_ }
    )) {
        if ($targets.Contains([string]$registryKey.GetValue($name))) {
            Remove-ItemProperty `
                -Path $RegistryPath `
                -Name $name `
                -Force `
                -ErrorAction SilentlyContinue
        }
    }
}

function Get-FirefoxInstallDirectories {
    $directories = New-StringHashSet

    foreach ($path in @(
        $(if ($env:ProgramFiles) {
            Join-Path $env:ProgramFiles 'Mozilla Firefox'
        }),
        $(if (${env:ProgramFiles(x86)}) {
            Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox'
        })
    )) {
        if (
            $path -and
            (Test-Path (Join-Path $path 'firefox.exe') -PathType Leaf)
        ) {
            $null = $directories.Add($path)
        }
    }

    return @($directories)
}

function Set-FirefoxBlockPolicy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FirefoxDirectory,

        [switch]$Remove
    )

    $distributionDirectory = Join-Path $FirefoxDirectory 'distribution'
    $policyFile = Join-Path $distributionDirectory 'policies.json'

    if ($Remove -and -not (Test-Path $policyFile -PathType Leaf)) {
        return
    }

    if (-not $Remove) {
        New-Item -Path $distributionDirectory `
            -ItemType Directory `
            -Force | Out-Null
    }

    $configuration = [pscustomobject]@{}

    if (Test-Path $policyFile -PathType Leaf) {
        try {
            $configuration = Get-Content $policyFile -Raw -Encoding UTF8 |
                ConvertFrom-Json
        }
        catch {
            Write-Log (
                "Invalid Firefox JSON was left unchanged: $policyFile"
            ) 'WARN'

            return
        }
    }

    if ($null -eq $configuration.PSObject.Properties['policies']) {
        $configuration |
            Add-Member -NotePropertyName policies `
                -NotePropertyValue ([pscustomobject]@{})
    }

    if ($null -eq $configuration.policies) {
        $configuration.policies = [pscustomobject]@{}
    }

    if (
        $null -eq
        $configuration.policies.PSObject.Properties['WebsiteFilter']
    ) {
        $configuration.policies |
            Add-Member -NotePropertyName WebsiteFilter `
                -NotePropertyValue ([pscustomobject]@{})
    }

    if ($null -eq $configuration.policies.WebsiteFilter) {
        $configuration.policies.WebsiteFilter = [pscustomobject]@{}
    }

    $websiteFilter = $configuration.policies.WebsiteFilter
    $current = @()

    if ($null -ne $websiteFilter.PSObject.Properties['Block']) {
        $current = @($websiteFilter.Block) |
            Where-Object {
                -not [string]::IsNullOrWhiteSpace([string]$_)
            }
    }

    if ($Remove) {
        $newValues = @(
            $current |
                Where-Object {
                    $BlockedFirefoxUrls -notcontains [string]$_
                } |
                Sort-Object -Unique
        )
    }
    else {
        $newValues = @(
            @($current + $BlockedFirefoxUrls) |
                Sort-Object -Unique
        )
    }

    if ($null -eq $websiteFilter.PSObject.Properties['Block']) {
        $websiteFilter |
            Add-Member -NotePropertyName Block `
                -NotePropertyValue $newValues
    }
    else {
        $websiteFilter.Block = $newValues
    }

    if (
        (Test-Path $policyFile -PathType Leaf) -and
        -not (Test-Path "$policyFile.robloxblock.bak" -PathType Leaf)
    ) {
        Copy-Item $policyFile "$policyFile.robloxblock.bak" -Force
    }

    $configuration |
        ConvertTo-Json -Depth 30 |
        Set-Content $policyFile -Encoding UTF8
}

function Test-RegistryValueExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    try {
        $null = Get-ItemPropertyValue `
            -Path $Path `
            -Name $Name `
            -ErrorAction Stop

        return $true
    }
    catch {
        return $false
    }
}

function Set-RegistryValueIfMissing {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        $Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('DWord', 'String', 'MultiString')]
        [string]$PropertyType
    )

    if (-not (Test-RegistryValueExists -Path $Path -Name $Name)) {
        New-ItemProperty `
            -Path $Path `
            -Name $Name `
            -Value $Value `
            -PropertyType $PropertyType `
            -Force | Out-Null

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

    foreach ($fileName in $RobloxExecutableNames) {
        $null = $paths.Add("*\$fileName")
    }

    foreach ($package in (Get-RobloxStorePackages)) {
        try {
            if ($package.InstallLocation) {
                $null = $paths.Add(
                    (Join-Path ([string]$package.InstallLocation) '*')
                )
            }
        }
        catch {
            # The package path may be unavailable.
        }
    }

    return @($paths)
}

function Set-RobloxSoftwareRestrictionPolicies {
    $changed = $false
    $baseWasMissing = -not (Test-Path $SrpBasePath)

    New-Item -Path $SrpBasePath -Force | Out-Null
    New-Item -Path $SrpRulesPath -Force | Out-Null

    if (
        Set-RegistryValueIfMissing `
            -Path $SrpBasePath `
            -Name 'DefaultLevel' `
            -Value 262144 `
            -PropertyType DWord
    ) {
        $changed = $true
    }

    if (
        Set-RegistryValueIfMissing `
            -Path $SrpBasePath `
            -Name 'PolicyScope' `
            -Value 0 `
            -PropertyType DWord
    ) {
        $changed = $true
    }

    if (
        Set-RegistryValueIfMissing `
            -Path $SrpBasePath `
            -Name 'TransparentEnabled' `
            -Value 1 `
            -PropertyType DWord
    ) {
        $changed = $true
    }

    if (
        Set-RegistryValueIfMissing `
            -Path $SrpBasePath `
            -Name 'AuthenticodeEnabled' `
            -Value 0 `
            -PropertyType DWord
    ) {
        $changed = $true
    }

    if (
        $baseWasMissing -and
        -not (
            Test-RegistryValueExists `
                -Path $SrpBasePath `
                -Name 'ExecutableTypes'
        )
    ) {
        $standardExecutableTypes = @(
            'ADE', 'ADP', 'BAS', 'BAT', 'CHM', 'CMD', 'COM', 'CPL',
            'CRT', 'EXE', 'HLP', 'HTA', 'INF', 'INS', 'ISP', 'JS',
            'JSE', 'LNK', 'MDB', 'MDE', 'MSC', 'MSI', 'MSP', 'MST',
            'OCX', 'PCD', 'PIF', 'REG', 'SCR', 'SHS', 'URL', 'VB',
            'VBE', 'VBS', 'WSC', 'WSF', 'WSH'
        )

        New-ItemProperty `
            -Path $SrpBasePath `
            -Name 'ExecutableTypes' `
            -Value ([string[]]$standardExecutableTypes) `
            -PropertyType MultiString `
            -Force | Out-Null

        $changed = $true
    }

    foreach ($rulePath in (Get-RobloxSrpPaths)) {
        $ruleRegistryPath = Join-Path (
            $SrpRulesPath
        ) (ConvertTo-StableGuidString -Text $rulePath)

        $expectedDescription = "$SrpDescriptionPrefix block $rulePath"
        $requiresWrite = -not (Test-Path $ruleRegistryPath)

        if (-not $requiresWrite) {
            try {
                $existingItemData = [string](
                    Get-ItemPropertyValue `
                        -Path $ruleRegistryPath `
                        -Name 'ItemData' `
                        -ErrorAction Stop
                )

                $existingDescription = [string](
                    Get-ItemPropertyValue `
                        -Path $ruleRegistryPath `
                        -Name 'Description' `
                        -ErrorAction Stop
                )

                $requiresWrite = (
                    $existingItemData -ne $rulePath -or
                    $existingDescription -ne $expectedDescription
                )
            }
            catch {
                $requiresWrite = $true
            }
        }

        if (-not $requiresWrite) {
            continue
        }

        New-Item -Path $ruleRegistryPath -Force | Out-Null

        New-ItemProperty `
            -Path $ruleRegistryPath `
            -Name 'ItemData' `
            -Value $rulePath `
            -PropertyType String `
            -Force | Out-Null

        New-ItemProperty `
            -Path $ruleRegistryPath `
            -Name 'SaferFlags' `
            -Value 0 `
            -PropertyType DWord `
            -Force | Out-Null

        New-ItemProperty `
            -Path $ruleRegistryPath `
            -Name 'Description' `
            -Value $expectedDescription `
            -PropertyType String `
            -Force | Out-Null

        $changed = $true
    }

    return $changed
}

function Remove-RobloxSoftwareRestrictionPolicies {
    if (-not (Test-Path $SrpRulesPath)) {
        return $false
    }

    $changed = $false

    foreach ($ruleKey in (
        Get-ChildItem $SrpRulesPath -ErrorAction SilentlyContinue
    )) {
        try {
            $description = [string](
                Get-ItemPropertyValue `
                    -Path $ruleKey.PSPath `
                    -Name 'Description' `
                    -ErrorAction SilentlyContinue
            )

            if (
                $description.StartsWith(
                    $SrpDescriptionPrefix,
                    [StringComparison]::OrdinalIgnoreCase
                )
            ) {
                Remove-Item $ruleKey.PSPath `
                    -Recurse `
                    -Force `
                    -ErrorAction SilentlyContinue

                $changed = $true
            }
        }
        catch {
            # Remove only rules that can be positively identified as ours.
        }
    }

    return $changed
}

function Invoke-ComputerPolicyRefresh {
    try {
        $gpupdatePath = Join-Path $env:SystemRoot 'System32\gpupdate.exe'

        if (Test-Path $gpupdatePath -PathType Leaf) {
            Start-Process `
                -FilePath $gpupdatePath `
                -ArgumentList '/target:computer /force' `
                -WindowStyle Hidden `
                -Wait `
                -ErrorAction SilentlyContinue | Out-Null
        }
    }
    catch {
        Write-Log 'Failed to run gpupdate.' 'WARN'
    }
}

function Write-ProcessGuardScript {
    $guardContent = @'
#Requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

$InstallDirectory = Join-Path $env:ProgramData 'RobloxBlock'
$LogFile = Join-Path $InstallDirectory 'RobloxProcessGuard.log'
$MutexName = 'Global\RobloxBlockProcessGuard'
$SourceIdentifier = 'RobloxBlock.ProcessStarted'

function Optimize-GuardLog {
    try {
        if (
            (Test-Path $LogFile) -and
            (Get-Item $LogFile).Length -gt 1MB
        ) {
            Get-Content $LogFile -Tail 300 |
                Set-Content "$LogFile.tmp" -Encoding UTF8

            Move-Item "$LogFile.tmp" $LogFile -Force
        }
    }
    catch {
        # Logging must not affect the process guard.
    }
}

function Write-GuardLog {
    param([string]$Message)

    try {
        Add-Content -Path $LogFile -Encoding UTF8 -Value (
            '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        )
    }
    catch {
        # Ignore logging failures.
    }
}

function Stop-RobloxPid {
    param(
        [Parameter(Mandatory = $true)]
        [uint32]$ProcessId,

        [Parameter(Mandatory = $true)]
        [string]$ProcessName
    )

    $shouldStop = $ProcessName -match '(?i)^Roblox.*\.exe$'
    $path = $null

    if (-not $shouldStop -and $ProcessName -ieq 'Windows10Universal.exe') {
        try {
            $instance = Get-CimInstance Win32_Process `
                -Filter "ProcessId=$ProcessId" `
                -ErrorAction SilentlyContinue

            $path = [string]$instance.ExecutablePath

            $shouldStop = (
                $path -match '(?i)ROBLOXCORPORATION\.ROBLOX_'
            )
        }
        catch {
            $shouldStop = $false
        }
    }

    if (-not $shouldStop) {
        return
    }

    try {
        Stop-Process `
            -Id ([int]$ProcessId) `
            -Force `
            -ErrorAction SilentlyContinue

        $description = "$ProcessName PID=$ProcessId"

        if ($path) {
            $description += " PATH=$path"
        }

        Write-GuardLog "Terminated $description"
    }
    catch {
        # The process may already have exited.
    }
}

function Stop-InitialRobloxProcesses {
    foreach ($process in (
        Get-Process -Name 'Roblox*' -ErrorAction SilentlyContinue
    )) {
        Stop-RobloxPid `
            -ProcessId ([uint32]$process.Id) `
            -ProcessName ($process.ProcessName + '.exe')
    }

    try {
        foreach ($instance in (
            Get-CimInstance Win32_Process `
                -Filter "Name='Windows10Universal.exe'" `
                -ErrorAction SilentlyContinue
        )) {
            Stop-RobloxPid `
                -ProcessId ([uint32]$instance.ProcessId) `
                -ProcessName 'Windows10Universal.exe'
        }
    }
    catch {
        # Checking the Microsoft Store process is optional.
    }
}

$mutex = $null
$ownsMutex = $false

try {
    Optimize-GuardLog

    $mutex = New-Object Threading.Mutex($false, $MutexName)
    $ownsMutex = $mutex.WaitOne(0, $false)

    if (-not $ownsMutex) {
        exit 0
    }

    Stop-InitialRobloxProcesses

    # Event-driven subscription: no repeated enumeration of all processes.
    $query = @"
SELECT * FROM Win32_ProcessStartTrace
WHERE ProcessName LIKE 'Roblox%'
   OR ProcessName = 'Windows10Universal.exe'
"@

    Register-WmiEvent `
        -Query $query `
        -SourceIdentifier $SourceIdentifier |
        Out-Null

    Write-GuardLog 'Event-driven process guard started.'

    while ($true) {
        $event = Wait-Event `
            -SourceIdentifier $SourceIdentifier `
            -Timeout 300

        if ($null -eq $event) {
            continue
        }

        try {
            $newEvent = $event.SourceEventArgs.NewEvent

            Stop-RobloxPid `
                -ProcessId ([uint32]$newEvent.ProcessID) `
                -ProcessName ([string]$newEvent.ProcessName)
        }
        finally {
            Remove-Event -EventIdentifier $event.EventIdentifier `
                -ErrorAction SilentlyContinue
        }
    }
}
finally {
    Unregister-Event `
        -SourceIdentifier $SourceIdentifier `
        -ErrorAction SilentlyContinue

    Get-Event -SourceIdentifier $SourceIdentifier `
        -ErrorAction SilentlyContinue |
        Remove-Event -ErrorAction SilentlyContinue

    if ($ownsMutex -and $mutex) {
        try {
            $mutex.ReleaseMutex()
        }
        catch {
            # Ignore.
        }
    }

    if ($mutex) {
        $mutex.Dispose()
    }
}
'@

    Set-Content `
        -Path $GuardScript `
        -Value $guardContent `
        -Encoding UTF8 `
        -Force
}

function Get-SystemTaskPrincipal {
    return New-ScheduledTaskPrincipal `
        -UserId 'SYSTEM' `
        -LogonType ServiceAccount `
        -RunLevel Highest
}

function Install-ProcessGuardTask {
    Import-Module ScheduledTasks -ErrorAction Stop
    Write-ProcessGuardScript

    $powerShellPath = Join-Path $env:SystemRoot (
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    )

    $action = New-ScheduledTaskAction `
        -Execute $powerShellPath `
        -Argument (
            '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden ' +
            '-ExecutionPolicy Bypass -File "' +
            $GuardScript +
            '"'
        )

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1) `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -MultipleInstances IgnoreNew `
        -Hidden

    Register-ScheduledTask `
        -TaskName $GuardTaskName `
        -Action $action `
        -Trigger @(
            (New-ScheduledTaskTrigger -AtStartup),
            (New-ScheduledTaskTrigger -AtLogOn)
        ) `
        -Principal (Get-SystemTaskPrincipal) `
        -Settings $settings `
        -Description (
            'Terminates Roblox processes using process-start events without continuous polling.'
        ) `
        -Force | Out-Null

    Start-ScheduledTask `
        -TaskName $GuardTaskName `
        -ErrorAction SilentlyContinue
}

function Install-AutoRefreshTask {
    Import-Module ScheduledTasks -ErrorAction Stop

    $powerShellPath = Join-Path $env:SystemRoot (
        'System32\WindowsPowerShell\v1.0\powershell.exe'
    )

    $action = New-ScheduledTaskAction `
        -Execute $powerShellPath `
        -Argument (
            '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden ' +
            '-ExecutionPolicy Bypass -File "' +
            $InstalledScript +
            '" -RefreshOnly'
        )

    # The interval is increased to six hours because SRP and the event-driven guard
    # already block execution; this task only adds the exact path to the firewall.
    $periodicTrigger = New-ScheduledTaskTrigger `
        -Once `
        -At (Get-Date).AddMinutes(3) `
        -RepetitionInterval (New-TimeSpan -Hours 6) `
        -RepetitionDuration (New-TimeSpan -Days 3650)

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) `
        -MultipleInstances IgnoreNew `
        -Hidden

    Register-ScheduledTask `
        -TaskName $RefreshTaskName `
        -Action $action `
        -Trigger @(
            (New-ScheduledTaskTrigger -AtStartup),
            $periodicTrigger
        ) `
        -Principal (Get-SystemTaskPrincipal) `
        -Settings $settings `
        -Description (
            'Scans for new Roblox versions and updates the firewall every six hours.'
        ) `
        -Force | Out-Null
}

function Remove-RobloxTasks {
    try {
        Import-Module ScheduledTasks -ErrorAction SilentlyContinue

        foreach ($taskName in @($GuardTaskName, $RefreshTaskName)) {
            Stop-ScheduledTask `
                -TaskName $taskName `
                -ErrorAction SilentlyContinue

            Unregister-ScheduledTask `
                -TaskName $taskName `
                -Confirm:$false `
                -ErrorAction SilentlyContinue
        }
    }
    catch {
        Write-Log 'Failed to completely remove background tasks.' 'WARN'
    }
}

function Install-BrowserPolicies {
    Add-RegistryListValues `
        -RegistryPath (
            'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'
        ) `
        -Values $BlockedChromiumUrls

    Add-RegistryListValues `
        -RegistryPath (
            'HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
        ) `
        -Values $BlockedChromiumUrls

    foreach ($firefoxDirectory in (Get-FirefoxInstallDirectories)) {
        try {
            Set-FirefoxBlockPolicy `
                -FirefoxDirectory $firefoxDirectory
        }
        catch {
            Write-Log (
                "Failed to configure Firefox policy: $firefoxDirectory"
            ) 'WARN'
        }
    }
}

function Remove-BrowserPolicies {
    Remove-RegistryListValues `
        -RegistryPath (
            'HKLM:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'
        ) `
        -Values $BlockedChromiumUrls

    Remove-RegistryListValues `
        -RegistryPath (
            'HKLM:\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
        ) `
        -Values $BlockedChromiumUrls

    foreach ($firefoxDirectory in (Get-FirefoxInstallDirectories)) {
        try {
            Set-FirefoxBlockPolicy `
                -FirefoxDirectory $firefoxDirectory `
                -Remove
        }
        catch {
            Write-Log (
                "Failed to remove Firefox policy entries: $firefoxDirectory"
            ) 'WARN'
        }
    }
}

function Remove-RobloxBlock {
    Write-Log "Started removal of version $ScriptVersion."

    Remove-RobloxTasks
    Stop-CurrentlyRunningRoblox

    try {
        Import-Module NetSecurity -ErrorAction SilentlyContinue

        Get-NetFirewallRule `
            -Group $FirewallGroup `
            -ErrorAction SilentlyContinue |
            Remove-NetFirewallRule `
                -ErrorAction SilentlyContinue
    }
    catch {
        Write-Log 'Failed to completely remove firewall rules.' 'WARN'
    }

    Remove-BrowserPolicies

    $srpChanged = Remove-RobloxSoftwareRestrictionPolicies

    if ($srpChanged) {
        Invoke-ComputerPolicyRefresh
    }

    Remove-Item $GuardScript -Force -ErrorAction SilentlyContinue

    Write-Log 'Roblox blocking has been removed.'
}

if ($Uninstall) {
    Remove-RobloxBlock
    exit 0
}

if (-not $RefreshOnly) {
    if ([string]::IsNullOrWhiteSpace($PSCommandPath)) {
        Write-Log 'The current script path could not be determined.' 'ERROR'
        exit 2
    }

    if (
        -not [string]::Equals(
            [IO.Path]::GetFullPath($PSCommandPath),
            [IO.Path]::GetFullPath($InstalledScript),
            [StringComparison]::OrdinalIgnoreCase
        )
    ) {
        Copy-Item `
            -Path $PSCommandPath `
            -Destination $InstalledScript `
            -Force
    }
}

Stop-CurrentlyRunningRoblox

$executables = @(Get-RobloxExecutablePaths)

try {
    $newFirewallRules = Add-RobloxFirewallRules `
        -ExecutablePaths $executables
}
catch {
    Write-Log 'Failed to load NetSecurity or update the firewall.' 'ERROR'
    exit 3
}

if (-not $RefreshOnly) {
    Install-BrowserPolicies

    $srpChanged = $false

    try {
        $srpChanged = Set-RobloxSoftwareRestrictionPolicies
    }
    catch {
        Write-Log 'Failed to completely install the SRP rules.' 'ERROR'
    }

    if ($srpChanged) {
        Invoke-ComputerPolicyRefresh
    }

    try {
        Install-AutoRefreshTask
    }
    catch {
        Write-Log 'Failed to create the refresh task.' 'ERROR'
    }

    try {
        Install-ProcessGuardTask
    }
    catch {
        Write-Log 'Failed to create the event-driven process guard.' 'ERROR'
    }
}

try {
    $disabledProfiles = @(
        Get-NetFirewallProfile -ErrorAction SilentlyContinue |
            Where-Object { $_.Enabled -eq $false } |
            Select-Object -ExpandProperty Name
    )

    if ($disabledProfiles.Count -gt 0) {
        Write-Log (
            'Windows Firewall is disabled for profiles: ' +
            ($disabledProfiles -join ', ')
        ) 'WARN'
    }
}
catch {
    # This diagnostic check does not affect the result.
}

Write-Log (
    "Version=$ScriptVersion; RefreshOnly=$RefreshOnly; " +
    "EXE files found=$($executables.Count); " +
    "firewall rules added=$newFirewallRules."
)

exit 0
