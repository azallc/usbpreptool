<#
    Install-Payload.ps1 - runs ON THE TARGET MACHINE at first logon.

    Installs the staged drivers and applications into the fresh Windows install,
    and records what hardware it landed on - which is the first thing worth having
    when a remote support job goes wrong.

    Called by \USBPREP\firstlogon.cmd. Safe to re-run by hand.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PayloadRoot,
    [switch]$InstallApps,
    [switch]$RestoreFlaggedTools,
    [string]$StageTo = 'C:\USBPrep'
)

$ErrorActionPreference = 'Continue'
$logDir = Join-Path $StageTo 'Logs'
New-Item -ItemType Directory -Path $logDir -Force | Out-Null
$log = Join-Path $logDir ("firstlogon-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0:HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $log -Value $line -Encoding utf8
    Write-Host $line
}

function Get-TargetProfile {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $vendor = switch -Regex ($cpu.Manufacturer) {
        'Intel'         { 'Intel' }
        'AMD|Authentic' { 'AMD' }
        default         { 'Unknown' }
    }
    $arch = switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { 'x64' }
        'ARM64' { 'ARM64' }
        'x86'   { 'x86' }
        default { $env:PROCESSOR_ARCHITECTURE }
    }
    # Storage controllers matter more than the CPU for RAID drivers, so record them.
    $storage = Get-CimInstance Win32_PnPEntity -Filter "PNPClass='SCSIAdapter' OR PNPClass='HDC'" -ErrorAction SilentlyContinue |
               Select-Object -ExpandProperty Name -ErrorAction SilentlyContinue

    [pscustomobject]@{
        CpuName    = $cpu.Name.Trim()
        Vendor     = $vendor
        Cores      = $cpu.NumberOfCores
        Threads    = $cpu.NumberOfLogicalProcessors
        Arch       = $arch
        Manufacturer = (Get-CimInstance Win32_ComputerSystem).Manufacturer
        Model        = (Get-CimInstance Win32_ComputerSystem).Model
        Storage    = @($storage)
    }
}

$sysInfo = Get-TargetProfile
Log "Target: $($sysInfo.Manufacturer) $($sysInfo.Model)"
Log "CPU   : $($sysInfo.CpuName) [$($sysInfo.Vendor), $($sysInfo.Arch), $($sysInfo.Cores)C/$($sysInfo.Threads)T]"
foreach ($s in $sysInfo.Storage) { Log "Storage controller: $s" }

$driverSrc = Join-Path $PayloadRoot 'Drivers'
if (Test-Path $driverSrc) {
    $driverDst = Join-Path $StageTo 'Drivers'
    Log "Staging drivers to $driverDst"
    robocopy $driverSrc $driverDst /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null

    # Active + Extra only, matching what WinPE loaded. Drivers\All holds the
    # other AMD RAID sets for manual use; installing them here would let Windows
    # rank by DriverVer and replace the correct driver with a mismatched one.
    $scanRoots = @('Active', 'Extra') |
                 ForEach-Object { Join-Path $driverDst $_ } |
                 Where-Object { Test-Path -LiteralPath $_ }

    $infs = @(foreach ($r in $scanRoots) {
        Get-ChildItem -LiteralPath $r -Filter *.inf -File -Recurse -ErrorAction SilentlyContinue
    })
    Log "Installing drivers from: $($scanRoots -join ', ') ($($infs.Count) .inf file(s))"

    foreach ($inf in $infs) {
        $null = & pnputil.exe /add-driver "$($inf.FullName)" /install 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log "Installed $($inf.Name)" 'OK'
        } else {
            Log "Skipped $($inf.Name) (pnputil exit $LASTEXITCODE - usually 'no matching hardware')"
        }
    }
} else {
    Log "No Drivers folder at $driverSrc" 'WARN'
}

$appSrc = Join-Path $PayloadRoot 'Apps'
if (Test-Path $appSrc) {
    $appDst = Join-Path $StageTo 'Apps'
    Log "Staging applications to $appDst"
    robocopy $appSrc $appDst /E /R:1 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null

    if ($RestoreFlaggedTools) {
        # Defender-flagged tools were staged as .bin so the copy would survive.
        # Restoring them requires an exclusion, or Defender deletes them again.
        Get-ChildItem -Path $appDst -Filter *.bin -File -Recurse | ForEach-Object {
            $exe = [IO.Path]::ChangeExtension($_.FullName, 'exe')
            try {
                Add-MpPreference -ExclusionPath $_.DirectoryName -ErrorAction Stop
                Log "Added Defender exclusion for $($_.DirectoryName)" 'WARN'
            } catch {
                Log "Could not add Defender exclusion: $($_.Exception.Message)" 'WARN'
            }
            Rename-Item -LiteralPath $_.FullName -NewName ([IO.Path]::GetFileName($exe)) -Force -ErrorAction SilentlyContinue
            Log "Restored $([IO.Path]::GetFileName($exe))"
        }
    }

    if ($InstallApps) {
        $manifestPath = Join-Path $appDst 'apps.json'
        if (Test-Path $manifestPath) {
            $manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
            foreach ($app in $manifest.apps) {
                if ($app.PSObject.Properties['install'] -and -not $app.install) {
                    Log "Skipping $($app.name) - staged only (install: false)"
                    continue
                }
                if ($app.arch -and $app.arch -ne 'any' -and $app.arch -ne $sysInfo.Arch) {
                    Log "Skipping $($app.name) - built for $($app.arch), target is $($sysInfo.Arch)"
                    continue
                }
                $installer = Get-ChildItem -Path $appDst -Filter $app.match -File -Recurse |
                             Select-Object -First 1
                if (-not $installer) { Log "$($app.name): no file matching '$($app.match)'" 'WARN'; continue }

                Log "Installing $($app.name) ($($installer.Name))"
                try {
                    $args = if ($app.args) { $app.args } else { @() }
                    $p = Start-Process -FilePath $installer.FullName -ArgumentList $args -Wait -PassThru -ErrorAction Stop
                    Log "$($app.name) finished with exit code $($p.ExitCode)" $(if ($p.ExitCode -in 0,1638,3010) { 'OK' } else { 'WARN' })
                } catch {
                    Log "$($app.name) failed: $($_.Exception.Message)" 'ERROR'
                }
            }
        } else {
            Log "No apps.json in $appDst - nothing installed automatically." 'WARN'
        }
    } else {
        Log "Applications staged to $appDst but not installed (auto-install was off)."
    }
} else {
    Log "No Apps folder at $appSrc" 'WARN'
}

# Leave a readable summary on the desktop so the operator sees what happened.
$summary = Join-Path ([Environment]::GetFolderPath('Desktop')) 'USBPrep-FirstLogon.txt'
Copy-Item -Path $log -Destination $summary -Force -ErrorAction SilentlyContinue

Log "Done." 'OK'
exit 0
