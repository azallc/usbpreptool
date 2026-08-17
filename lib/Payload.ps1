# Payload.ps1 - stages drivers and applications onto the NTFS partition and emits
# the two scripts that run on the target machine:
#
#   \USBPREP\peload.cmd      - runs inside WinPE, loads RAID/VMD drivers so Setup
#                              can see the disk
#   \USBPREP\firstlogon.cmd  - runs at first logon, hands off to Install-Payload.ps1
#
# Driver selection happens in Hardware.ps1, not here. The customer runs the tool
# on the machine being reinstalled, so detection there is authoritative and picks
# exactly one AMD RAID set - see Copy-RaidDriverBundle for why more than one would
# break.

$script:PayloadRoot = 'USBPREP'

function Copy-RaidDriverBundle {
    <#
        Stages the bundled AMD RAID drivers with a hard split:

            \USBPREP\Drivers\Active\   the ONE selected set - auto-loaded in WinPE
            \USBPREP\Drivers\All\<id>\ every set - present for manual F6 loading,
                                       never auto-loaded

        The split exists because all three AMD sets claim the same hardware IDs.
        If they were all visible to the automatic pnputil pass, Windows would rank
        them by DriverVer and an AM4 board would get the newer AM5 driver. Keeping
        the others out of Active is what prevents that, while still leaving them on
        the stick for a tech who needs to load one by hand.
    #>
    param(
        [Parameter(Mandatory)][string]$BundleRoot,   # ...\drivers\amd
        [string]$SetId,                              # am4-sata | am4-nvme | am5 | $null
        [Parameter(Mandatory)]$Target,
        [switch]$IncludeAllSets
    )

    $driversRoot = Join-Path $Target.DataRoot "$script:PayloadRoot\Drivers"
    $activeDir   = Join-Path $driversRoot 'Active'
    New-Item -ItemType Directory -Path $activeDir -Force | Out-Null

    if (-not (Test-Path -LiteralPath $BundleRoot)) {
        Write-Log "Driver bundle not found at $BundleRoot - no AMD RAID drivers staged." 'WARN'
        return 0
    }

    $staged = 0

    if ($SetId) {
        $src = Join-Path $BundleRoot $SetId
        if (Test-Path -LiteralPath $src) {
            if (-not (Copy-TreeWithProgress -Source $src -Destination $activeDir -Label "RAID set '$SetId'")) {
                throw "Failed to stage RAID driver set '$SetId'."
            }
            $staged = @(Get-ChildItem -LiteralPath $activeDir -Filter *.inf -File -Recurse).Count
            Write-Log "Active RAID set: $SetId ($staged .inf files) - this is the only set WinPE will load." 'OK'
        } else {
            Write-Log "Driver set '$SetId' missing from the bundle at $src." 'ERROR'
        }
    } else {
        Write-Log "No RAID set selected - Active is empty. Supply drivers manually if Setup cannot see the disk." 'WARN'
    }

    if ($IncludeAllSets) {
        $allDir = Join-Path $driversRoot 'All'
        foreach ($dir in Get-ChildItem -LiteralPath $BundleRoot -Directory -ErrorAction SilentlyContinue) {
            $dest = Join-Path $allDir $dir.Name
            Copy-TreeWithProgress -Source $dir.FullName -Destination $dest -Label "reference set '$($dir.Name)'" | Out-Null
        }
        Write-Log "All RAID sets staged under Drivers\All for manual use (not auto-loaded)."
    }

    return $staged
}

function Copy-DriverPayload {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)]$Target
    )
    # Extra drivers are operator-supplied (Intel RST/VMD, NIC, chipset). They go
    # alongside Active and are auto-loaded too - the collision risk only exists
    # between the three AMD sets, which Copy-RaidDriverBundle already isolates.
    $dest = Join-Path $Target.DataRoot "$script:PayloadRoot\Drivers\Extra"

    # -LiteralPath throughout: vendor driver folders routinely contain square
    # brackets (the shipped AMD tree has "AM4 RAID [PUT IN USB]"), which
    # PowerShell would otherwise treat as wildcard character classes and fail to
    # find anything.
    if (-not (Test-Path -LiteralPath $SourceDir)) {
        Write-Log "Driver folder '$SourceDir' does not exist - skipping extra drivers." 'WARN'
        New-Item -ItemType Directory -Path $dest -Force | Out-Null
        return 0
    }

    $infs = @(Get-ChildItem -LiteralPath $SourceDir -Filter *.inf -File -Recurse -ErrorAction SilentlyContinue)
    if (-not $infs.Count) {
        Write-Log "No .inf files under '$SourceDir'. Drivers will not be loaded in WinPE." 'WARN'
    } else {
        Write-Log "Found $($infs.Count) driver .inf file(s) to stage."
    }

    if (-not (Copy-TreeWithProgress -Source $SourceDir -Destination $dest -Label 'drivers')) {
        throw "Failed to stage drivers to $dest."
    }
    return $infs.Count
}

function Copy-AppPayload {
    <#
        Copies installers to \USBPREP\Apps and carries apps.json along so the
        first-logon script knows the silent switches.

        Defender Control is handled specially: Defender classifies it as
        HackTool/riskware and will delete it mid-copy. It is staged with a
        neutralised extension so the copy survives; the target-side script
        renames it back only if the operator asked for it.
    #>
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)]$Target,
        [switch]$NeutraliseFlagged
    )
    $dest = Join-Path $Target.DataRoot "$script:PayloadRoot\Apps"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null

    if (-not (Test-Path $SourceDir)) {
        Write-Log "App folder '$SourceDir' does not exist - skipping applications." 'WARN'
        return 0
    }

    # Names Defender reliably quarantines. Extend as needed.
    $flagged = @('dcontrol', 'defendercontrol', 'defender_control')

    $files = @(Get-ChildItem -Path $SourceDir -File -Recurse)
    $count = 0
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($SourceDir.TrimEnd('\').Length).TrimStart('\')
        $outPath = Join-Path $dest $rel
        $outDir  = Split-Path $outPath -Parent
        if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

        $isFlagged = $NeutraliseFlagged -and
                     ($flagged | Where-Object { $f.BaseName.ToLower() -replace '[^a-z]','' -like "*$_*" })

        try {
            if ($isFlagged) {
                # .bin is inert to Defender's on-access scanner and to double-clicks.
                $outPath = [IO.Path]::ChangeExtension($outPath, 'bin')
                Copy-Item -LiteralPath $f.FullName -Destination $outPath -Force -ErrorAction Stop
                Write-Log "Staged $($f.Name) as $(Split-Path $outPath -Leaf) (Defender would quarantine the original)." 'WARN'
            } else {
                Copy-Item -LiteralPath $f.FullName -Destination $outPath -Force -ErrorAction Stop
            }
            $count++
        } catch {
            Write-Log "Could not stage $($f.Name): $($_.Exception.Message)" 'ERROR'
        }
    }
    Write-Log "Staged $count application file(s)." 'OK'
    return $count
}

function Write-TargetScripts {
    <#
        Emits peload.cmd, firstlogon.cmd and Install-Payload.ps1 onto the stick.
        Install-Payload.ps1 is copied from .\target\ so it stays editable in the repo.
    #>
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][hashtable]$Options
    )
    $payloadDir = Join-Path $Target.DataRoot $script:PayloadRoot
    New-Item -ItemType Directory -Path $payloadDir -Force | Out-Null

    # Loads Active + Extra only. Drivers\All is deliberately NOT scanned: all
    # three AMD sets claim the same hardware IDs, so exposing them here would let
    # Windows rank by DriverVer and load the AM5 driver on an AM4 board.
    $peload = @'
@echo off
rem Runs inside WinPE, before disk configuration.
set "PAYLOAD=%~dp0"

call :load "%PAYLOAD%Drivers\Active"
call :load "%PAYLOAD%Drivers\Extra"
exit /b 0

:load
if not exist "%~1" exit /b 0
dir /b "%~1\*.inf" >nul 2>&1 || dir /b /s "%~1\*.inf" >nul 2>&1 || exit /b 0
echo Loading storage drivers from %~1 ...
pnputil /add-driver "%~1\*.inf" /subdirs /install
if errorlevel 1 (
    rem Older WinPE builds lack /install; fall back to drvload.
    for /r "%~1" %%f in (*.inf) do drvload "%%f"
)
exit /b 0
'@
    Set-Content -Path (Join-Path $payloadDir 'peload.cmd') -Value $peload -Encoding ascii
    Write-Log "Wrote \$($script:PayloadRoot)\peload.cmd"

    $installApps = if ($Options.InstallAppsAutomatically) { '-InstallApps' } else { '' }
    $restoreDc   = if ($Options.RestoreFlaggedTools)      { '-RestoreFlaggedTools' } else { '' }
    $firstlogon = @"
@echo off
rem Runs once, at first logon, as the newly created local administrator.
set "PAYLOAD=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PAYLOAD%Install-Payload.ps1" -PayloadRoot "%PAYLOAD%" $installApps $restoreDc
exit /b 0
"@
    Set-Content -Path (Join-Path $payloadDir 'firstlogon.cmd') -Value $firstlogon -Encoding ascii
    Write-Log "Wrote \$($script:PayloadRoot)\firstlogon.cmd"

    $src = Join-Path $RepoRoot 'target\Install-Payload.ps1'
    if (Test-Path $src) {
        Copy-Item -Path $src -Destination $payloadDir -Force
        Write-Log "Wrote \$($script:PayloadRoot)\Install-Payload.ps1"
    } else {
        Write-Log "target\Install-Payload.ps1 missing from the repo - first logon will do nothing." 'ERROR'
    }

    # apps.json is written by Write-AppManifest from what actually downloaded.
    # Nothing is copied here on purpose: this function runs after the download
    # step, so copying a template would clobber the real manifest and leave the
    # target trying to install files that are not on the stick.
}

function Write-BuildManifest {
    <#
        A plain-text record of what went on the stick, left at the root of the
        data partition. Saves a lot of "what is on this one?" later.
    #>
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][hashtable]$Options,
        [Parameter(Mandatory)][pscustomobject]$Machine,
        [Parameter(Mandatory)][string]$IsoName,
        [int]$DriverCount = 0,
        [int]$AppCount = 0
    )
    $lines = @(
        "USBPrepTool build manifest"
        "=========================="
        "Built          : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Built on       : $env:COMPUTERNAME ($($Machine.CpuName), $($Machine.Architecture))"
        "Source ISO     : $IsoName"
        "Layout         : GPT | P1 FAT32 $($Target.BootLabel) | P2 NTFS $($Target.DataLabel)"
        ""
        "Customisations"
        "--------------"
        "Bypass TPM / Secure Boot / RAM checks : $($Options.BypassHardwareChecks)"
        "Skip Microsoft account                : $($Options.SkipMicrosoftAccount)"
        "Local account                         : $(if ($Options.CreateLocalAccount) { $Options.LocalAccountName } else { '(none)' })"
        "Regional options copied from builder  : $($Options.MatchRegionalOptions)"
        "  system locale : $($Machine.SystemLocale)"
        "  user locale   : $($Machine.UserLocale)"
        "  input locale  : $($Machine.InputLocale)"
        "  time zone     : $($Machine.TimeZone)"
        "Disable data collection               : $($Options.DisableDataCollection)"
        ""
        "Payload"
        "-------"
        "RAID set (auto-loaded)   : $(if ($Options.RaidSetId) { $Options.RaidSetId } else { 'none' })"
        "Other sets copied        : $($Options.IncludeAllDriverSets)"
        "Driver .inf files staged : $DriverCount"
        "Application files staged : $AppCount"
        "Load drivers in WinPE    : $($Options.LoadRaidDrivers)"
        "Apps downloaded          : $($Options.DownloadApps)"
        "Auto-install apps        : $($Options.InstallAppsAutomatically)"
        ""
        "Drivers\Active is the only set WinPE loads. Drivers\All holds the other"
        "AMD sets for manual F6 loading - they share hardware IDs, so loading more"
        "than one lets Windows pick by version instead of by board."
        ""
        "Everything staged lives under \$($script:PayloadRoot) on the NTFS partition."
    )
    $path = Join-Path $Target.DataRoot 'USBPrepTool-build.txt'
    Set-Content -Path $path -Value $lines -Encoding utf8
    Write-Log "Wrote build manifest to $path" 'OK'
}
