$GitHubOwner   = 'azallc'          # e.g. 'yourshop'
$GitHubRepo    = 'usbpreptool'       # repository name
$BundleVersion = '1.0.0'             # release tag without the leading 'v'


$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$BundleName = "usbpreptool-$BundleVersion.zip"
$BundleUrl  = "https://github.com/$GitHubOwner/$GitHubRepo/releases/download/v$BundleVersion/$BundleName"
$InstallDir = Join-Path $env:LOCALAPPDATA "USBPrepTool\$BundleVersion"

function Say {
    param([string]$Message, [string]$Colour = 'Gray')
    Write-Host $Message -ForegroundColor $Colour
}

Say ""
Say "  USB Prep Tool  ($BundleVersion)" 'Cyan'
Say "  ---------------------------------------------" 'DarkGray'
Say ""

if ($GitHubOwner -eq 'CHANGEME') {
    Say "  This bootstrap has not been configured yet." 'Red'
    Say "  Set `$GitHubOwner / `$GitHubRepo / `$BundleVersion at the top of this file." 'Yellow'
    return
}

$entryPoint = Join-Path $InstallDir 'USBPrepTool.ps1'
$stateFile  = Join-Path $InstallDir '.bundle-state.json'

# The install directory is keyed on version, so re-uploading a release asset
# under the SAME tag would otherwise never invalidate an existing unpack - a
# machine that ran the old bootstrap would keep the old code forever. Compare the
# published asset's size and ETag against what was unpacked, and refresh if they
# differ. One cheap HEAD request; failures fall through to the cached copy so a
# missing network never blocks a build.
$needDownload = $true

if (Test-Path -LiteralPath $entryPoint) {
    $needDownload = $false
    try {
        $head = Invoke-WebRequest -Uri $BundleUrl -Method Head -UseBasicParsing -TimeoutSec 15
        $remoteLength = "$($head.Headers['Content-Length'])"
        $remoteTag    = "$($head.Headers['ETag'])"

        $state = if (Test-Path -LiteralPath $stateFile) {
            Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        } else { $null }

        $localLength = if ($state -and $state.PSObject.Properties['Length']) { "$($state.Length)" } else { '' }
        $localTag    = if ($state -and $state.PSObject.Properties['ETag'])   { "$($state.ETag)"   } else { '' }

        if ($localLength -ne $remoteLength -or $localTag -ne $remoteTag) {
            Say "  A different build is published - refreshing the local copy." 'Yellow'
            $needDownload = $true
        } else {
            Say "  Using the copy already downloaded to $InstallDir" 'DarkGray'
        }
    } catch {
        Say "  Could not check for a newer build; using the cached copy." 'DarkGray'
    }
}

if ($needDownload) {
    $tempZip = Join-Path $env:TEMP $BundleName
    Say "  Downloading $BundleName ..." 'Gray'

    try {
        try {
            Start-BitsTransfer -Source $BundleUrl -Destination $tempZip -ErrorAction Stop
        } catch {
            Invoke-WebRequest -Uri $BundleUrl -OutFile $tempZip -UseBasicParsing -TimeoutSec 180
        }
    } catch {
        Say ""
        Say "  Could not download the tool bundle." 'Red'
        Say "  $($_.Exception.Message)" 'DarkGray'
        Say ""
        Say "  URL: $BundleUrl" 'DarkGray'
        Say "  Check the machine has internet access, then run the command again." 'Yellow'
        return
    }

    $zipItem = Get-Item -LiteralPath $tempZip
    if ($zipItem.Length -lt 100KB) {
        Say "  The download is only $([int]($zipItem.Length/1KB)) KB - that is not the bundle." 'Red'
        Say "  Check that release v$BundleVersion exists and the asset is named $BundleName." 'Yellow'
        Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue
        return
    }
    Say "  Downloaded $([math]::Round($zipItem.Length/1MB,1)) MB" 'DarkGray'

    Say "  Unpacking to $InstallDir ..." 'Gray'

    # Extract to a staging directory and swap it in, rather than deleting in
    # place. Remove-Item -Recurse can return before Windows has finished
    # releasing the directory, so extracting straight afterwards can fail with
    # "the file already exists" against files that were supposed to be gone.
    # Seen for real on the refresh path, which is how every update now arrives.
    $staging = "$InstallDir.new"
    if (Test-Path -LiteralPath $staging) {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        [System.IO.Compression.ZipFile]::ExtractToDirectory($tempZip, $staging)
    } catch {
        Say "  Could not unpack the bundle: $($_.Exception.Message)" 'Red'
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    Remove-Item -LiteralPath $tempZip -Force -ErrorAction SilentlyContinue

    # Retire the old copy, giving Windows a few chances to let go of it.
    for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $InstallDir); $i++) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $InstallDir) { Start-Sleep -Milliseconds 300 }
    }

    if (Test-Path -LiteralPath $InstallDir) {
        # Something still holds it. Overwriting in place is less clean than a
        # rename but beats refusing to update.
        Say "  Previous copy is locked - overwriting in place." 'DarkGray'
        Copy-Item -Path (Join-Path $staging '*') -Destination $InstallDir -Recurse -Force
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    } else {
        Move-Item -LiteralPath $staging -Destination $InstallDir
    }

    if (-not (Test-Path -LiteralPath $entryPoint)) {
        Say "  Bundle unpacked but USBPrepTool.ps1 is missing - the release asset looks wrong." 'Red'
        return
    }

    # Recorded so the next run can tell whether the published asset has changed.
    try {
        $h = Invoke-WebRequest -Uri $BundleUrl -Method Head -UseBasicParsing -TimeoutSec 15
        [ordered]@{
            Length     = "$($h.Headers['Content-Length'])"
            ETag       = "$($h.Headers['ETag'])"
            Downloaded = (Get-Date).ToString('o')
        } | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding utf8
    } catch { }

    Say "  Ready." 'Green'
}

# irm | iex leaves no script on disk, so the entry point cannot relaunch itself
# from $MyInvocation. Launching the unpacked file by path sidesteps that
# entirely: it is a real file and elevation works normally from there.
$isAdmin = (New-Object Security.Principal.WindowsPrincipal(
    [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

Say ""

# Always launch as a fresh process, even when already elevated.
#
# Running it with `& $entryPoint` instead put the tool in a child scope of this
# iex'd string, and in that session state scriptblocks cannot reliably see the
# tool's dot-sourced functions - which surfaced as "The term 'Write-Log' is not
# recognized" mid-build, but only for users who were already administrators.
# A fresh process makes both paths identical to the one that gets tested.
$launchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$entryPoint`"")

if ($isAdmin) {
    Say "  Starting..." 'Cyan'
    Start-Process powershell.exe -ArgumentList $launchArgs
} else {
    Say "  Starting - approve the administrator prompt when it appears." 'Yellow'
    Say ""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $launchArgs
}
