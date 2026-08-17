<#
.SYNOPSIS
    Packages the tool + AMD RAID drivers into a release zip for GitHub Releases.

.DESCRIPTION
    Produces usbpreptool-<version>.zip containing lib\, gui\, target\, the GUI
    entry point, and drivers\amd\ with the three AMD RAID sets normalised to
    stable ids:

        drivers\amd\am4-sata\
        drivers\amd\am4-nvme\
        drivers\amd\am5\

    The shipped AMD tree uses folder names with square brackets
    ("AM4 RAID [PUT IN USB]"), which PowerShell treats as wildcard character
    classes. Renaming them here means nothing downstream has to keep remembering
    -LiteralPath.

    Upload the resulting zip as a release asset. The bootstrap
    (Install-USBPrep.ps1) downloads it at runtime.

.EXAMPLE
    .\build\New-Release.ps1 -Version 1.0.0
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Version,

    # Defaults to <repo>\dist. NOT defaulted here on purpose: when a script in a
    # subdirectory is launched by relative path (powershell -File build\x.ps1),
    # $PSScriptRoot is empty during parameter binding, so a default computed from
    # it fails before the script body ever runs. Resolved below instead.
    [string]$OutputDir,

    # Fido is GPLv3. Bundling it makes your release a distribution of GPL'd code,
    # which brings licence obligations you do not otherwise have. The tool fetches
    # Fido from the official repo at runtime anyway, so the default is to leave it
    # out - you distribute nothing of theirs, and users always get the current one.
    [switch]$IncludeFido
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is reliable in the body, but fall back to MyInvocation anyway so
# this works however the script is invoked.
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }

$RepoRoot = Resolve-Path (Join-Path $ScriptDir '..')
if (-not $OutputDir) { $OutputDir = Join-Path $RepoRoot 'dist' }

. (Join-Path $RepoRoot 'lib\Common.ps1')
Initialize-Log -Directory (Join-Path $RepoRoot 'logs')

# Source folder -> normalised set id. Matched case-insensitively on the path.
$DriverSetMap = @(
    @{ Id = 'am4-nvme'; Match = 'AM4*\*RAID NVME';        Label = 'AM4 - NVMe RAID' }
    @{ Id = 'am4-sata'; Match = 'AM4*\*RAID SATA';        Label = 'AM4 - SATA RAID' }
    @{ Id = 'am5';      Match = 'AM5*\*RAID NVME + SATA'; Label = 'AM5 - NVMe + SATA RAID' }
)

$staging = Join-Path $env:TEMP "usbpreptool-build-$Version"
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
New-Item -ItemType Directory -Path $staging -Force | Out-Null
Write-Log "Staging in $staging"

foreach ($item in 'lib', 'gui', 'target') {
    $src = Join-Path $RepoRoot $item
    if (-not (Test-Path -LiteralPath $src)) { throw "Missing required folder: $src" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $staging $item) -Recurse -Force
    Write-Log "Packaged $item\"
}
Copy-Item -LiteralPath (Join-Path $RepoRoot 'USBPrepTool.ps1') -Destination $staging -Force
Write-Log "Packaged USBPrepTool.ps1"

# Shipped so a first run works offline-ish; the tool still refreshes it on launch.
$toolsOut = Join-Path $staging 'tools'
New-Item -ItemType Directory -Path $toolsOut -Force | Out-Null

if ($IncludeFido) {
    $fido = Join-Path $RepoRoot 'tools\Fido.ps1'
    if (Test-Path -LiteralPath $fido) {
        Copy-Item -LiteralPath $fido -Destination $toolsOut -Force
        Write-Log "Packaged tools\Fido.ps1 - NOTE: your release now redistributes GPLv3 code." 'WARN'
        Write-Log "  Include Fido's licence and source offer, or drop -IncludeFido." 'WARN'
    } else {
        Write-Log "-IncludeFido given but tools\Fido.ps1 is not present." 'WARN'
    }
} else {
    Write-Log "Fido not bundled (GPLv3) - the tool fetches it from the official repo on first launch."
}

$driverSrc = Join-Path $RepoRoot 'tools\AMD RAID Drivers'
if (-not (Test-Path -LiteralPath $driverSrc)) { throw "AMD RAID Drivers folder not found at $driverSrc" }

$driverOut = Join-Path $staging 'drivers\amd'
New-Item -ItemType Directory -Path $driverOut -Force | Out-Null

$summary = New-Object System.Collections.Generic.List[object]

foreach ($set in $DriverSetMap) {
    $candidates = @(Get-ChildItem -LiteralPath $driverSrc -Directory -Recurse -ErrorAction SilentlyContinue |
                    Where-Object { $_.FullName -like "*$($set.Match)" })

    if (-not $candidates.Count) {
        Write-Log "No source folder matched '$($set.Match)' for set '$($set.Id)'." 'ERROR'
        continue
    }
    if ($candidates.Count -gt 1) {
        Write-Log "'$($set.Match)' matched $($candidates.Count) folders; using the first." 'WARN'
    }

    $from = $candidates[0].FullName
    $to   = Join-Path $driverOut $set.Id
    New-Item -ItemType Directory -Path $to -Force | Out-Null

    # robocopy handles brackets in paths without wildcard interpretation.
    $null = & robocopy.exe $from $to /E /R:2 /W:2 /NP /NFL /NDL /NJH /NJS
    $rc = $LASTEXITCODE
    $global:LASTEXITCODE = 0          # robocopy 0-7 are success variants
    if ($rc -ge 8) { throw "robocopy failed for $($set.Id) (exit $rc)" }

    $infs = @(Get-ChildItem -LiteralPath $to -Filter *.inf -File -Recurse)
    $ver  = ''
    if ($infs.Count) {
        $raw = Get-Content -LiteralPath $infs[0].FullName -Raw
        $ver = ([regex]::Match($raw, 'DriverVer\s*=\s*([^\r\n]+)')).Groups[1].Value.Trim()
    }

    $summary.Add([pscustomobject]@{
        Id = $set.Id; Label = $set.Label; Infs = $infs.Count; DriverVer = $ver
        Bytes = (Get-ChildItem -LiteralPath $to -Recurse -File | Measure-Object Length -Sum).Sum
    }) | Out-Null

    Write-Log "Packaged drivers\amd\$($set.Id) - $($infs.Count) .inf, DriverVer $ver" 'OK'
}

if ($summary.Count -ne $DriverSetMap.Count) {
    throw "Expected $($DriverSetMap.Count) driver sets, packaged $($summary.Count). Refusing to publish an incomplete bundle."
}

$manifest = [ordered]@{
    version   = $Version
    built     = (Get-Date).ToString('o')
    driverSets = @($summary | ForEach-Object {
        [ordered]@{ id = $_.Id; label = $_.Label; driverVer = $_.DriverVer; infCount = $_.Infs }
    })
    note = 'AMD RAID sets share hardware IDs. Exactly one may be auto-loaded; see lib\Hardware.ps1.'
}
$manifest | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $staging 'bundle.json') -Encoding utf8

if (-not (Test-Path -LiteralPath $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
$zip = Join-Path (Resolve-Path $OutputDir) "usbpreptool-$Version.zip"
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }

Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.IO.Compression.ZipFile]::CreateFromDirectory($staging, $zip,
    [System.IO.Compression.CompressionLevel]::Optimal, $false)

$zipItem = Get-Item -LiteralPath $zip
$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash

Write-Log ""
Write-Log "Release built: $zip" 'OK'
Write-Log "Size   : $(Format-Size $zipItem.Length)"
Write-Log "SHA256 : $hash"
Write-Log ""
Write-Log "Driver sets packaged:"
foreach ($s in $summary) { Write-Log "  $($s.Id.PadRight(9)) $($s.DriverVer.PadRight(24)) $($s.Infs) inf  $(Format-Size $s.Bytes)" }
Write-Log ""
Write-Log 'Next: upload as a GitHub release asset tagged v1.0.0-style, then set'
Write-Log "      `$BundleVersion in Install-USBPrep.ps1 to '$Version'."

# Mirror the normalised driver tree into the working copy so running
# USBPrepTool.ps1 straight from the repo behaves like a real install.
$repoDrivers = Join-Path $RepoRoot 'drivers'
if (Test-Path -LiteralPath $repoDrivers) { Remove-Item -LiteralPath $repoDrivers -Recurse -Force }
Copy-Item -LiteralPath (Join-Path $staging 'drivers') -Destination $repoDrivers -Recurse -Force
Write-Log "Mirrored drivers\ into the working copy for local testing."

Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue

[pscustomobject]@{ Path = $zip; Sha256 = $hash; Bytes = $zipItem.Length; Sets = $summary }
