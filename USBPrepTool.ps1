<#
.SYNOPSIS
    Builds a customised Windows installation USB - GPT, FAT32 boot + NTFS data,
    autounattend customisations, staged RAID drivers and application payload.

.DESCRIPTION
    A replacement for driving Rufus by hand. Rufus has no scriptable CLI (its
    command-line switches only preload the GUI), so this does the whole job with
    native Windows storage cmdlets and a generated autounattend.xml - which is
    exactly how Rufus implements its own customisation checkboxes.

.NOTES
    Requires PowerShell 5.1+ and administrator rights. Relaunches elevated itself.
#>
[CmdletBinding()]
param(
    [switch]$NoGui,
    [string]$ConfigPath,

    # Fido resolves official Microsoft ISO links and goes stale whenever Microsoft
    # changes their API, so it is refreshed on launch by default.
    [switch]$NoFidoUpdate,

    # Skip the network if the local Fido was checked more recently than this.
    [int]$FidoMaxAgeDays = 3
)

#Requires -Version 5.1

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition

# Launched by double-click or Start-Process, an unhandled error closes the window
# instantly and takes the reason with it. This makes any fatal error visible and
# writes logs\crash.txt even if logging never got a chance to initialize.
trap {
    $msg   = "$($_.Exception.Message)"
    # Cap the trace: a runaway recursion produces hundreds of identical frames
    # that bury the actual message in both the log and the dialog.
    $frames = @("$($_.ScriptStackTrace)" -split "`r?`n")
    $stack  = if ($frames.Count -gt 12) {
        (($frames | Select-Object -First 8) + "  ... $($frames.Count - 12) frames omitted ..." +
         ($frames | Select-Object -Last 4)) -join "`n"
    } else { $frames -join "`n" }

    try { Write-Log "FATAL: $msg" 'ERROR'; Write-Log $stack 'ERROR' } catch { }

    try {
        # $RepoRoot, not $PSScriptRoot - the latter can be empty depending on how
        # the script was invoked, and a crash handler must not itself crash.
        $crashDir = Join-Path $RepoRoot 'logs'
        if (-not (Test-Path $crashDir)) { New-Item -ItemType Directory -Path $crashDir -Force | Out-Null }
        Set-Content -Path (Join-Path $crashDir 'crash.txt') -Encoding utf8 -Value @(
            "USBPrepTool crashed at $(Get-Date -Format o)"
            "PowerShell $($PSVersionTable.PSVersion)  |  $([Environment]::OSVersion.VersionString)"
            ''
            $msg
            ''
            $stack
        )
    } catch { }

    try {
        Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
        [System.Windows.MessageBox]::Show(
            "$msg`n`n$stack`n`nDetails written to logs\crash.txt",
            'USB Prep Tool - unexpected error', 'OK', 'Error') | Out-Null
    } catch {
        Write-Host "`nFATAL: $msg" -ForegroundColor Red
        Write-Host $stack -ForegroundColor DarkGray
        Write-Host "`nPress Enter to close..." -ForegroundColor Yellow
        try { [void][Console]::ReadLine() } catch { }
    }
    exit 1
}

. (Join-Path $RepoRoot 'lib\Common.ps1')
. (Join-Path $RepoRoot 'lib\IsoSource.ps1')
. (Join-Path $RepoRoot 'lib\FidoUpdate.ps1')
. (Join-Path $RepoRoot 'lib\Hardware.ps1')
. (Join-Path $RepoRoot 'lib\AppFetch.ps1')
. (Join-Path $RepoRoot 'lib\DiskPrep.ps1')
. (Join-Path $RepoRoot 'lib\Unattend.ps1')
. (Join-Path $RepoRoot 'lib\Payload.ps1')

Initialize-Log -Directory (Join-Path $RepoRoot 'logs')

if (-not (Test-Administrator)) {
    Write-Log "Not elevated - relaunching as administrator." 'WARN'
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$($MyInvocation.MyCommand.Definition)`"")
    if ($NoGui)        { $argList += '-NoGui' }
    if ($ConfigPath)   { $argList += @('-ConfigPath', "`"$ConfigPath`"") }
    if ($NoFidoUpdate) { $argList += '-NoFidoUpdate' }
    $argList += @('-FidoMaxAgeDays', $FidoMaxAgeDays)
    Start-Process powershell.exe -Verb RunAs -ArgumentList $argList
    exit 0
}

$Machine = Get-PrepMachineInfo
Write-Log "Build host: $($Machine.CpuName) [$($Machine.CpuVendor), $($Machine.Architecture)]"
Write-Log "Locale: system=$($Machine.SystemLocale) user=$($Machine.UserLocale) input=$($Machine.InputLocale) tz=$($Machine.TimeZone)"

$ToolsDir = Join-Path $RepoRoot 'tools'

# Bundled AMD RAID drivers, normalised to set ids by build\New-Release.ps1.
# Falls back to the raw repo layout when running from a working copy.
$DriverBundleRoot = Join-Path $RepoRoot 'drivers\amd'

# The customer runs this on the machine being reinstalled, so local detection is
# authoritative rather than a guess.
$Platform  = Get-CpuPlatform
$Storage   = Get-StorageProfile
$RaidPick  = Select-RaidDriverSet -Platform $Platform -Storage $Storage
Write-HardwareReport -Platform $Platform -Storage $Storage -Selection $RaidPick | Out-Null

# Non-fatal by design: a failed check leaves whatever copy exists in place, so a
# missing network never blocks a build from a local ISO.
$script:FidoStatus = $null
if ($NoFidoUpdate) {
    $existing = Get-FidoState -ToolsDir $ToolsDir
    $script:FidoStatus = [pscustomobject]@{
        Action = 'skipped'
        Version = Get-StateValue -State $existing -Name 'Version'
        Message = 'Fido auto-update disabled (-NoFidoUpdate).'
        HaveWorkingCopy = (Test-FidoAvailable -ToolsDir $ToolsDir)
    }
    Write-Log $script:FidoStatus.Message
} else {
    $script:FidoStatus = Update-Fido -ToolsDir $ToolsDir -MaxAgeDays $FidoMaxAgeDays
}

function Invoke-UsbBuild {
    <#
        The whole build, GUI-agnostic. $Options is a plain hashtable so the
        console path and the GUI path share one implementation.
    #>
    param(
        [Parameter(Mandatory)][hashtable]$Options,
        [scriptblock]$OnProgress = { param($p) }
    )

    $mounted = $null
    try {
        & $OnProgress 2
        Write-Log "=== Build starting ===" 'OK'

        $mounted = Mount-InstallIso -IsoPath $Options.IsoPath
        if ($mounted.InstallImage) {
            Write-Log "Install image: $($mounted.InstallImage) ($(Format-Size $mounted.ImageSize))"
            if ($mounted.ImageSize -gt 4GB) {
                Write-Log "Image exceeds the FAT32 4 GB file limit - the NTFS data partition handles it."
            }
        }
        & $OnProgress 8

        # Checked before Clear-Disk, so a too-small stick fails with data intact.
        $isoBytes = (Get-Item $Options.IsoPath).Length
        Test-UsbTargetSpace -DiskNumber $Options.DiskNumber -RequiredBytes $isoBytes | Out-Null

        $target = Initialize-UsbTarget -DiskNumber $Options.DiskNumber
        & $OnProgress 20

        Copy-WindowsSource -IsoRoot $mounted.Root -Target $target
        & $OnProgress 65

        $xml = New-UnattendXml -Options $Options -Machine $Machine
        Write-UnattendToTarget -Xml $xml -Target $target
        Copy-Item -Path (Join-Path $target.BootRoot 'autounattend.xml') `
                  -Destination (Join-Path $RepoRoot 'logs\last-autounattend.xml') -Force
        & $OnProgress 72

        # Exactly one set into Active; see Copy-RaidDriverBundle for why.
        $driverCount = Copy-RaidDriverBundle -BundleRoot $DriverBundleRoot `
                            -SetId $Options.RaidSetId -Target $target `
                            -IncludeAllSets:$Options.IncludeAllDriverSets
        & $OnProgress 76


        if ($Options.DriverSource -and (Test-Path -LiteralPath $Options.DriverSource)) {
            $driverCount += Copy-DriverPayload -SourceDir $Options.DriverSource -Target $target
        }
        & $OnProgress 80


        $appCount = 0
        $appsDir  = Join-Path $target.DataRoot 'USBPREP\Apps'
        if ($Options.DownloadApps) {
            # Two constraints on this callback, both learned the hard way:
            #
            # 1. It must not be named $OnProgress. Scriptblocks resolve variables
            #    in the scope that invokes them, so that name would bind to
            #    Get-AppPayload's own callback parameter - this very scriptblock -
            #    and recurse until the stack overflows.
            # 2. No .GetNewClosure(), and no calls to dot-sourced functions such
            #    as Write-Log. Under the GUI the build runs inside a WPF event
            #    handler, whose session state does not expose script-scope
            #    functions; a closure created there fails with "The term
            #    'Write-Log' is not recognized". Get-AppPayload already logs each
            #    download, so nothing is lost by keeping this to arithmetic.
            $reportProgress = $OnProgress
            $appResults = Get-AppPayload -Destination $appsDir -ProgressCallback {
                param($pct, $label)
                & $reportProgress (80 + [int](12 * $pct / 100))
            }
            Write-AppManifest -Destination $appsDir -Results $appResults | Out-Null
            $appCount = @($appResults | Where-Object Success).Count

            $failed = @($appResults | Where-Object { -not $_.Success })
            if ($failed.Count) {
                # Non-fatal: the stick still installs Windows. Say so plainly
                # rather than letting a missing WinRAR look like a broken build.
                Write-Log "$($failed.Count) app download(s) failed - the USB is still usable:" 'WARN'
                foreach ($f in $failed) { Write-Log "    $($f.Name): $($f.Error)" 'WARN' }
            }
        }


        if ($Options.AppSource -and (Test-Path -LiteralPath $Options.AppSource)) {
            $appCount += Copy-AppPayload -SourceDir $Options.AppSource -Target $target `
                            -NeutraliseFlagged:$Options.NeutraliseFlaggedTools
        }
        & $OnProgress 92

        Write-TargetScripts -Target $target -RepoRoot $RepoRoot -Options $Options
        Write-BuildManifest -Target $target -Options $Options -Machine $Machine `
                            -IsoName ([IO.Path]::GetFileName($Options.IsoPath)) `
                            -DriverCount $driverCount -AppCount $appCount
        & $OnProgress 97

        Write-Log "Flushing write caches..."
        Get-Volume -DriveLetter $target.BootRoot[0], $target.DataRoot[0] -ErrorAction SilentlyContinue | Out-Null
        & $OnProgress 100

        Write-Log "=== Build complete. Eject the drive before removing it. ===" 'OK'
        return $target
    }
    finally {
        if ($mounted) { Dismount-InstallIso -IsoPath $mounted.IsoPath }
    }
}

function Show-MainWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

    $xamlPath = Join-Path $RepoRoot 'gui\MainWindow.xaml'
    [xml]$xaml = Get-Content $xamlPath -Raw
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))

    # Pull every x:Named element into a hashtable.
    $ui = @{}
    $xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
        $n = $_.Name
        if ($n) { $ui[$n] = $window.FindName($n) }
    }

    function Repaint { $window.Dispatcher.Invoke([action]{}, [Windows.Threading.DispatcherPriority]::Render) }

    function Set-Status {
        param([string]$Message, [string]$Level = 'INFO')
        $ui.lblStatus.Text = $Message
        $ui.lblStatus.Foreground = switch ($Level) {
            'ERROR' { 'IndianRed' }; 'WARN' { '#E0A030' }; 'OK' { '#5BC85B' }; default { '#E8E8E8' }
        }
        Repaint
    }
    Set-StatusCallback ${function:Set-Status}

    $ui.txtUserName.Text = $env:USERNAME
    # Extra folders default to empty - the bundled drivers and downloaded apps
    # cover the normal case, and a stale path here would silently stage junk.
    $ui.txtDrivers.Text  = ''
    $ui.txtApps.Text     = ''
    $ui.lblRegional.Text = "Will apply: $($Machine.SystemLocale) / $($Machine.UserLocale) / keyboard $($Machine.InputLocale) / $($Machine.TimeZone)"

    $ui.lblMachine.Text = @(
        $Platform.CpuName
        "$($Platform.Vendor)$(if ($Platform.Socket) { " - socket $($Platform.Socket)" }) - $($Machine.Architecture) - $($Machine.Cores)C/$($Machine.Threads)T"
        $Platform.Board
        "Storage: $($Storage.Detail)$(if ($Storage.AlreadyRaid) { ' - already in RAID mode' })"
    ) -join "`n"

    if ($RaidPick.NeedsManual) {
        $ui.brdIntelWarn.Visibility = 'Visible'
        $ui.lblIntelWarn.Text = "$($RaidPick.Reason)`n`n$($RaidPick.Guidance)".Trim()
    }

    $ui.lblAppList.Text = ((Get-AppCatalog) | ForEach-Object { $_.Name }) -join "`n"

    # 'Auto' resolves to whatever detection chose; the explicit entries let a
    # tech override when the customer's array does not match the default.
    $driverChoices = New-Object System.Collections.Generic.List[object]
    $autoLabel = if ($RaidPick.SetId) {
        "Auto-detected: $($RaidPick.Label)"
    } else {
        'Auto-detected: none (supply drivers manually)'
    }
    $driverChoices.Add([pscustomobject]@{ Id = $RaidPick.SetId; Display = $autoLabel }) | Out-Null
    foreach ($id in Get-DriverSetIds) {
        $driverChoices.Add([pscustomobject]@{ Id = $id; Display = "Force: $(Get-DriverSetLabel $id)" }) | Out-Null
    }
    $driverChoices.Add([pscustomobject]@{ Id = $null; Display = 'None - do not load any bundled RAID driver' }) | Out-Null

    foreach ($c in $driverChoices) { $ui.cboDriverSet.Items.Add($c.Display) | Out-Null }
    $ui.cboDriverSet.Tag = $driverChoices
    $ui.cboDriverSet.SelectedIndex = 0
    $ui.lblDriverReason.Text = $RaidPick.Reason

    $ui.cboDriverSet.Add_SelectionChanged({
        $sel = @($ui.cboDriverSet.Tag)[$ui.cboDriverSet.SelectedIndex]
        $ui.lblDriverReason.Text = if ($ui.cboDriverSet.SelectedIndex -eq 0) {
            $RaidPick.Reason
        } elseif ($sel.Id) {
            "Manual override - $(Get-DriverSetLabel $sel.Id) will be the only set loaded in WinPE."
        } else {
            'No bundled RAID driver will be loaded. Use the Extra folder if Setup cannot see the disk.'
        }
    })

    if (-not (Test-Path -LiteralPath $DriverBundleRoot)) {
        Write-Log "Driver bundle missing at $DriverBundleRoot - running from a working copy without a built bundle?" 'WARN'
        $ui.lblDriverReason.Text = "Driver bundle not found at $DriverBundleRoot. Run build\New-Release.ps1, or use the Extra folder."
    }

    $script:SelectedIso = $null

    function Update-DiskList {
        $ui.cboDisk.Items.Clear()
        $disks = @(Get-CandidateUsbDisk)
        if (-not $disks.Count) {
            $ui.cboDisk.Items.Add("No USB drive detected - plug one in and press Refresh") | Out-Null
            $ui.cboDisk.SelectedIndex = 0
            $ui.cboDisk.Tag = $null
            return
        }
        foreach ($d in $disks) { $ui.cboDisk.Items.Add($d.Display) | Out-Null }
        $ui.cboDisk.Tag = $disks
        $ui.cboDisk.SelectedIndex = 0
    }
    Update-DiskList

    function Get-SelectedDiskNumber {
        $disks = $ui.cboDisk.Tag
        if (-not $disks) { return $null }
        @($disks)[$ui.cboDisk.SelectedIndex].Number
    }

    function Select-Folder {
        param([string]$Description, [string]$Initial)
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = $Description
        if ($Initial -and (Test-Path $Initial)) { $dlg.SelectedPath = $Initial }
        if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath }
        $null
    }

    $ui.btnRefreshDisks.Add_Click({ Update-DiskList; Set-Status "Disk list refreshed." })

    $ui.btnBrowseIso.Add_Click({
        $dlg = New-Object System.Windows.Forms.OpenFileDialog
        $dlg.Filter = 'Windows ISO (*.iso)|*.iso'
        $dlg.Title  = 'Select a Windows installation ISO'
        if ($dlg.ShowDialog() -eq 'OK') {
            $script:SelectedIso = $dlg.FileName
            $ui.txtIso.Text = $dlg.FileName
            Set-Status "ISO selected: $([IO.Path]::GetFileName($dlg.FileName))" 'OK'
        }
    })

    function Show-FidoStatus {
        param($Status)
        if (-not $Status) { $ui.lblFido.Text = 'Fido: unknown'; return }
        $ui.lblFido.Text = switch ($Status.Action) {
            'installed' { "Fido v$($Status.Version) downloaded." }
            'updated'   { "Fido updated to v$($Status.Version)." }
            'uptodate'  { "Fido v$($Status.Version) - current." }
            'skipped'   { if ($Status.Version) { "Fido v$($Status.Version) - cached." } else { 'Fido: not installed.' } }
            'failed'    { $Status.Message }
            default     { 'Fido: unknown' }
        }
        $ui.lblFido.Foreground = if ($Status.HaveWorkingCopy) {
            if ($Status.Action -eq 'failed') { '#E0A030' } else { '#9A9A9A' }
        } else { 'IndianRed' }
        $ui.btnFidoRollback.IsEnabled = Test-Path (Get-FidoPaths -ToolsDir $ToolsDir).Backup
        $ui.btnDownloadIso.IsEnabled  = [bool]$Status.HaveWorkingCopy
    }
    Show-FidoStatus $script:FidoStatus

    $ui.btnFidoUpdate.Add_Click({
        $ui.btnFidoUpdate.IsEnabled = $false
        Set-Status "Fetching the latest Fido..."
        $script:FidoStatus = Update-Fido -ToolsDir $ToolsDir -Force
        Show-FidoStatus $script:FidoStatus
        Set-Status $script:FidoStatus.Message $(if ($script:FidoStatus.Action -eq 'failed') { 'WARN' } else { 'OK' })
        $ui.btnFidoUpdate.IsEnabled = $true
    })

    $ui.btnFidoRollback.Add_Click({
        if (Restore-PreviousFido -ToolsDir $ToolsDir) {
            $state = Get-FidoState -ToolsDir $ToolsDir
            $script:FidoStatus = [pscustomobject]@{
                Action = 'skipped'; Version = $state.Version
                Message = "Rolled back to Fido v$($state.Version)."
                HaveWorkingCopy = $true
            }
            Show-FidoStatus $script:FidoStatus
            Set-Status $script:FidoStatus.Message 'OK'
        } else {
            Set-Status "Nothing to roll back to." 'WARN'
        }
    })

    $ui.btnDownloadIso.Add_Click({
        try {
            $cache = Join-Path $RepoRoot 'iso'
            $tools = $ToolsDir

            if (-not (Test-FidoAvailable -ToolsDir $tools)) {
                Set-Status "Fido is missing - fetching it now..."
                $script:FidoStatus = Update-Fido -ToolsDir $tools -Force
                Show-FidoStatus $script:FidoStatus
                if (-not (Test-FidoAvailable -ToolsDir $tools)) {
                    [System.Windows.MessageBox]::Show(
                        "Could not download Fido.`n`n$($script:FidoStatus.Message)`n`nUse Browse to pick an ISO you already have, or see tools\README.md.",
                        'Fido unavailable', 'OK', 'Warning') | Out-Null
                    return
                }
            }

            $ui.btnDownloadIso.IsEnabled = $false
            Set-Status "Resolving official Microsoft download link..."

            try {
                $url = Resolve-IsoDownloadUrl -ToolsDir $tools
            } catch {
                # The usual cause is Microsoft having moved their API. Pull the
                # freshest Fido and try exactly once more before giving up.
                Write-Log "Fido failed: $($_.Exception.Message)" 'WARN'
                Set-Status "Fido failed - fetching the latest version and retrying..."
                $script:FidoStatus = Update-Fido -ToolsDir $tools -Force
                Show-FidoStatus $script:FidoStatus
                if ($script:FidoStatus.Action -in 'updated','installed') {
                    $url = Resolve-IsoDownloadUrl -ToolsDir $tools
                } else {
                    throw "Fido could not resolve a download link, and no newer version is available. Use Browse to pick an ISO you already have."
                }
            }

            $name = ([uri]$url).Segments[-1]
            if ($name -notmatch '\.iso$') { $name = "Win11_x64_$(Get-Date -Format yyyyMMdd).iso" }
            $dest = Join-Path $cache $name

            Set-Status "Downloading $name ..."
            Save-IsoFromUrl -Url $url -Destination $dest -OnProgress {
                param($p) $ui.barProgress.Value = $p
                Set-Status "Downloading $name ... $p%"
            } | Out-Null

            $script:SelectedIso = $dest
            $ui.txtIso.Text = $dest
            $ui.barProgress.Value = 0
            Set-Status "ISO ready." 'OK'
        } catch {
            Set-Status $_.Exception.Message 'ERROR'
            Write-Log $_.Exception.Message 'ERROR'
        } finally {
            $ui.btnDownloadIso.IsEnabled = $true
        }
    })

    $ui.btnBrowseDrivers.Add_Click({
        $p = Select-Folder -Description 'Folder containing RAID / storage drivers' -Initial $ui.txtDrivers.Text
        if ($p) { $ui.txtDrivers.Text = $p }
    })
    $ui.btnBrowseApps.Add_Click({
        $p = Select-Folder -Description 'Folder containing application installers' -Initial $ui.txtApps.Text
        if ($p) { $ui.txtApps.Text = $p }
    })

    $ui.btnClose.Add_Click({ $window.Close() })

    $ui.btnStart.Add_Click({
        try {
            if (-not $script:SelectedIso) { Set-Status "Select or download an ISO first." 'WARN'; return }
            $diskNumber = Get-SelectedDiskNumber
            if ($null -eq $diskNumber) { Set-Status "No USB drive selected." 'WARN'; return }

            $disk = @($ui.cboDisk.Tag)[$ui.cboDisk.SelectedIndex]
            $answer = [System.Windows.MessageBox]::Show(
                "This will ERASE EVERYTHING on:`n`n    $($disk.Display)`n`nContinue?",
                'Confirm - all data will be destroyed', 'YesNo', 'Warning')
            if ($answer -ne 'Yes') { Set-Status "Cancelled."; return }

            $options = @{
                DiskNumber               = $diskNumber
                IsoPath                  = $script:SelectedIso
                BypassHardwareChecks     = [bool]$ui.chkBypass.IsChecked
                SkipMicrosoftAccount     = [bool]$ui.chkNoMsa.IsChecked
                CreateLocalAccount       = [bool]$ui.chkLocalUser.IsChecked
                LocalAccountName         = $ui.txtUserName.Text.Trim()
                LocalAccountPassword     = ''
                AutoLogon                = $false
                MatchRegionalOptions     = [bool]$ui.chkRegional.IsChecked
                DisableDataCollection    = [bool]$ui.chkPrivacy.IsChecked
                LoadRaidDrivers          = [bool]$ui.chkLoadDrivers.IsChecked
                RaidSetId                = @($ui.cboDriverSet.Tag)[$ui.cboDriverSet.SelectedIndex].Id
                IncludeAllDriverSets     = [bool]$ui.chkIncludeAllSets.IsChecked
                DownloadApps             = [bool]$ui.chkDownloadApps.IsChecked
                InstallAppsAutomatically = [bool]$ui.chkAutoApps.IsChecked
                NeutraliseFlaggedTools   = [bool]$ui.chkNeutralise.IsChecked
                RestoreFlaggedTools      = [bool]$ui.chkRestoreFlagged.IsChecked
                RunFirstLogonScript      = $true
                DriverSource             = $ui.txtDrivers.Text.Trim()
                AppSource                = $ui.txtApps.Text.Trim()
            }

            if ($options.CreateLocalAccount -and -not $options.LocalAccountName) {
                Set-Status "Enter a username, or untick the local account option." 'WARN'; return
            }

            $ui.btnStart.IsEnabled = $false
            $ui.btnClose.IsEnabled = $false
            $ui.barProgress.Value = 0

            $target = Invoke-UsbBuild -Options $options -OnProgress {
                param($p) $ui.barProgress.Value = $p; Repaint
            }

            Set-Status "Done. Boot partition $($target.BootRoot), data partition $($target.DataRoot). Eject before removing." 'OK'
            [System.Windows.MessageBox]::Show(
                "USB is ready.`n`nBoot partition : $($target.BootRoot) (FAT32)`nData partition : $($target.DataRoot) (NTFS)`n`nEject the drive before unplugging it.",
                'Finished', 'OK', 'Information') | Out-Null
        } catch {
            Set-Status $_.Exception.Message 'ERROR'
            Write-Log "BUILD FAILED: $($_.Exception.Message)" 'ERROR'
            Write-Log $_.ScriptStackTrace 'ERROR'
            [System.Windows.MessageBox]::Show($_.Exception.Message, 'Build failed', 'OK', 'Error') | Out-Null
        } finally {
            $ui.btnStart.IsEnabled = $true
            $ui.btnClose.IsEnabled = $true
            Update-DiskList
        }
    })

    $window.ShowDialog() | Out-Null
}

if ($NoGui) {
    if (-not $ConfigPath) { $ConfigPath = Join-Path $RepoRoot 'settings.json' }
    if (-not (Test-Path $ConfigPath)) { throw "Config not found: $ConfigPath" }

    $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
    $options = @{}
    $cfg.PSObject.Properties | ForEach-Object { $options[$_.Name] = $_.Value }

    # Anything the config omits falls back to a sensible default, with RaidSetId
    # coming from live detection. Without this a headless run would silently
    # stage no RAID driver just because the key was missing.
    $defaults = @{
        BypassHardwareChecks     = $true
        SkipMicrosoftAccount     = $true
        CreateLocalAccount       = $true
        LocalAccountName         = $env:USERNAME
        LocalAccountPassword     = ''
        AutoLogon                = $false
        MatchRegionalOptions     = $true
        DisableDataCollection    = $true
        LoadRaidDrivers          = $true
        RaidSetId                = $RaidPick.SetId
        IncludeAllDriverSets     = $true
        DownloadApps             = $true
        InstallAppsAutomatically = $true
        NeutraliseFlaggedTools   = $true
        RestoreFlaggedTools      = $false
        RunFirstLogonScript      = $true
        DriverSource             = ''
        AppSource                = ''
    }
    foreach ($k in $defaults.Keys) {
        if (-not $options.ContainsKey($k)) {
            $options[$k] = $defaults[$k]
            Write-Log "config: '$k' not set, using default '$($defaults[$k])'"
        }
    }

    # RaidSetId needs three distinct states, so a missing key is not enough:
    #   "auto"  -> use detection          (the default)
    #   "am5"   -> force that set
    #   null    -> deliberately no bundled RAID driver
    # Without the sentinel, an explicit null would be indistinguishable from
    # "key present, use it" and would silently stage nothing.
    if ("$($options.RaidSetId)" -eq 'auto') {
        $options.RaidSetId = $RaidPick.SetId
        Write-Log "config: RaidSetId 'auto' resolved to '$($options.RaidSetId)' by detection."
    } elseif ($null -eq $options.RaidSetId) {
        Write-Log "config: RaidSetId is null - no bundled RAID driver will be loaded." 'WARN'
    }

    foreach ($required in 'DiskNumber', 'IsoPath') {
        if (-not $options.ContainsKey($required) -or -not $options[$required]) {
            throw "Config is missing required setting '$required'."
        }
    }

    Write-Log "Headless build: disk $($options.DiskNumber), RAID set '$($options.RaidSetId)'"
    Invoke-UsbBuild -Options $options | Out-Null
} else {
    Show-MainWindow
}
