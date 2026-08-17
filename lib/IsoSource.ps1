# IsoSource.ps1 - obtaining a Windows ISO without making the user visit microsoft.com.
#
# Resolution order:
#   1. An ISO the operator browsed to manually.
#   2. A previously downloaded ISO in the local cache folder.
#   3. Fido (the same script Rufus uses for its DOWNLOAD button) -> official MS link.
#
# Fido is NOT bundled. Drop Fido.ps1 into .\tools\ - see tools\README.md.

function Get-CachedIso {
    param([Parameter(Mandatory)][string]$CacheDir)
    if (-not (Test-Path $CacheDir)) { return @() }
    Get-ChildItem -Path $CacheDir -Filter *.iso -File |
        Sort-Object LastWriteTime -Descending
}

function Test-FidoAvailable {
    param([Parameter(Mandatory)][string]$ToolsDir)
    Test-Path (Join-Path $ToolsDir 'Fido.ps1')
}

function Resolve-IsoDownloadUrl {
    <#
        Asks Fido for a direct, signed, time-limited link to an official Microsoft ISO.
        The link expires (typically ~24h), so download it promptly.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolsDir,
        [string]$Windows      = '11',
        [string]$Release      = 'Latest',
        [string]$Edition      = 'Windows 11 Home/Pro/Edu',
        # Fido's own vocabulary, not a locale name: 'English' is US English,
        # 'English International' is en-GB. Run Get-FidoOptions -List Lang to see
        # the current set - it changes with each Windows release.
        [string]$Language     = 'English',
        [string]$Architecture = 'x64'
    )
    $fido = Join-Path $ToolsDir 'Fido.ps1'
    if (-not (Test-Path $fido)) {
        throw "Fido.ps1 not found in $ToolsDir. See tools\README.md, or browse to an ISO you already have."
    }

    Write-Log "Asking Microsoft for a Windows $Windows $Release $Architecture ($Language) download link..."
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fido `
        -Win $Windows -Rel $Release -Ed $Edition -Lang $Language -Arch $Architecture -GetUrl 2>&1

    $url = $output | Where-Object { "$_" -match '^https?://' } | Select-Object -Last 1

    if (-not $url) {
        # Surface what Fido actually said. Its errors are specific and actionable
        # ("Invalid Windows language provided"), and burying them behind a guess
        # about Microsoft's API sends you chasing the wrong problem.
        $detail = ($output | ForEach-Object { "$_".Trim() } | Where-Object { $_ } | Select-Object -Last 4) -join ' / '
        foreach ($line in $output) { Write-Log "  fido: $line" 'WARN' }
        if (-not $detail) { $detail = 'no output' }
        throw "Fido did not return a download URL. Fido said: $detail"
    }
    Write-Log "Got official download link." 'OK'
    return "$url".Trim()
}

function Get-FidoOptions {
    <#
        Asks Fido what it currently accepts for -Lang, -Ed or -Rel. The valid
        values track whatever Microsoft is publishing, so they are worth querying
        rather than hardcoding.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolsDir,
        [ValidateSet('Lang','Ed','Rel')][string]$List = 'Lang',
        [string]$Windows = '11',
        [string]$Release = 'Latest'
    )
    $fido = Join-Path $ToolsDir 'Fido.ps1'
    if (-not (Test-Path $fido)) { throw "Fido.ps1 not found in $ToolsDir." }

    $args = @('-Win', $Windows)
    if ($List -ne 'Rel') { $args += @('-Rel', $Release) }
    $args += @("-$List", 'List')

    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fido @args 2>&1
    $out | Where-Object { "$_" -match '^\s*-\s+' } | ForEach-Object { ("$_" -replace '^\s*-\s+', '').Trim() }
}

function Save-IsoFromUrl {
    <#
        Downloads with BITS when available (resumable, shows real progress),
        falling back to a buffered stream copy.
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][string]$Destination,
        [scriptblock]$OnProgress
    )
    $dir = Split-Path $Destination -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    if (Get-Command Start-BitsTransfer -ErrorAction SilentlyContinue) {
        try {
            Write-Log "Downloading ISO via BITS to $Destination"
            $job = Start-BitsTransfer -Source $Url -Destination $Destination -Asynchronous -DisplayName 'USBPrepTool ISO'
            while ($job.JobState -in 'Connecting','Transferring','Queued') {
                if ($job.BytesTotal -gt 0 -and $OnProgress) {
                    & $OnProgress ([int](100 * $job.BytesTransferred / $job.BytesTotal))
                }
                Start-Sleep -Milliseconds 500
                $job = Get-BitsTransfer -JobId $job.JobId
            }
            if ($job.JobState -eq 'Transferred') {
                Complete-BitsTransfer -BitsJob $job
                Write-Log "ISO downloaded ($(Format-Size (Get-Item $Destination).Length))" 'OK'
                return $Destination
            }
            Remove-BitsTransfer -BitsJob $job -ErrorAction SilentlyContinue
            Write-Log "BITS transfer ended in state '$($job.JobState)'. Falling back to direct download." 'WARN'
        } catch {
            Write-Log "BITS unavailable ($($_.Exception.Message)). Falling back to direct download." 'WARN'
        }
    }

    Write-Log "Downloading ISO to $Destination"
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = 'Mozilla/5.0'
    $resp = $req.GetResponse()
    $total = $resp.ContentLength
    $in  = $resp.GetResponseStream()
    $out = [System.IO.File]::Create($Destination)
    try {
        $buffer = New-Object byte[] 1048576
        $read = 0; $done = 0; $lastPct = -1
        while (($read = $in.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $out.Write($buffer, 0, $read)
            $done += $read
            if ($total -gt 0 -and $OnProgress) {
                $pct = [int](100 * $done / $total)
                if ($pct -ne $lastPct) { & $OnProgress $pct; $lastPct = $pct }
            }
        }
    } finally {
        $out.Dispose(); $in.Dispose(); $resp.Dispose()
    }
    Write-Log "ISO downloaded ($(Format-Size (Get-Item $Destination).Length))" 'OK'
    return $Destination
}

function Mount-InstallIso {
    param([Parameter(Mandatory)][string]$IsoPath)
    if (-not (Test-Path $IsoPath)) { throw "ISO not found: $IsoPath" }

    Write-Log "Mounting $([IO.Path]::GetFileName($IsoPath))"
    $image = Mount-DiskImage -ImagePath (Resolve-Path $IsoPath).Path -PassThru -ErrorAction Stop
    $letter = ($image | Get-Volume).DriveLetter
    if (-not $letter) { throw "Mounted the ISO but could not determine its drive letter." }

    $root = "${letter}:\"
    foreach ($required in 'sources', 'boot', 'bootmgr') {
        if (-not (Test-Path (Join-Path $root $required))) {
            Dismount-DiskImage -ImagePath $IsoPath -ErrorAction SilentlyContinue | Out-Null
            throw "$([IO.Path]::GetFileName($IsoPath)) does not look like a Windows installation ISO (missing '$required')."
        }
    }
    Write-Log "ISO mounted at $root" 'OK'

    $wim = Get-ChildItem -Path (Join-Path $root 'sources') -Filter 'install.*' -File |
           Where-Object { $_.Extension -in '.wim', '.esd' } | Select-Object -First 1

    [pscustomobject]@{
        IsoPath     = (Resolve-Path $IsoPath).Path
        Root        = $root
        DriveLetter = $letter
        InstallImage= if ($wim) { $wim.Name } else { $null }
        ImageSize   = if ($wim) { $wim.Length } else { 0 }
    }
}

function Dismount-InstallIso {
    param([Parameter(Mandatory)][string]$IsoPath)
    try {
        Dismount-DiskImage -ImagePath $IsoPath -ErrorAction Stop | Out-Null
        Write-Log "ISO dismounted."
    } catch {
        Write-Log "Could not dismount ISO: $($_.Exception.Message)" 'WARN'
    }
}
