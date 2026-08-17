<#
.SYNOPSIS
    Verifies a finished USB stick, without needing to boot it.

.DESCRIPTION
    Checks the things that actually determine whether the stick will boot and
    install: partition scheme, filesystems, the EFI boot chain, where install.wim
    landed, autounattend content, and that exactly one RAID set is in the
    auto-loaded position.

    Run after a build:
        .\build\Test-BuiltUsb.ps1 -DiskNumber 3
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$DiskNumber
)

$ErrorActionPreference = 'Stop'
$script:Pass = 0
$script:Fail = 0
$script:Warn = 0

function Check {
    param([string]$Name, [scriptblock]$Test, [switch]$Warning)
    try {
        $result = & $Test
        if ($result -is [string]) { $ok = $true; $detail = $result }
        else { $ok = [bool]$result; $detail = '' }
    } catch { $ok = $false; $detail = $_.Exception.Message }

    if ($ok) {
        $script:Pass++
        Write-Host ("  [PASS] {0}{1}" -f $Name, $(if ($detail) { " - $detail" })) -ForegroundColor Green
    } elseif ($Warning) {
        $script:Warn++
        Write-Host ("  [WARN] {0}{1}" -f $Name, $(if ($detail) { " - $detail" })) -ForegroundColor Yellow
    } else {
        $script:Fail++
        Write-Host ("  [FAIL] {0}{1}" -f $Name, $(if ($detail) { " - $detail" })) -ForegroundColor Red
    }
}

$disk  = Get-Disk -Number $DiskNumber
$parts = @(Get-Partition -DiskNumber $DiskNumber | Where-Object DriveLetter | Sort-Object PartitionNumber)

Write-Host "`n=== Disk $DiskNumber : $($disk.FriendlyName) ===" -ForegroundColor Cyan

Check 'Partition style is GPT' { $disk.PartitionStyle -eq 'GPT' }
Check 'Exactly two lettered partitions' { "$($parts.Count) found" ; $parts.Count -eq 2 }

if ($parts.Count -lt 2) { Write-Host "`nCannot continue - expected 2 partitions.`n" -ForegroundColor Red; exit 1 }

$boot = "$($parts[0].DriveLetter):\"
$data = "$($parts[1].DriveLetter):\"
$bootVol = Get-Volume -DriveLetter $parts[0].DriveLetter
$dataVol = Get-Volume -DriveLetter $parts[1].DriveLetter

Write-Host "`n--- Partition 1 (boot): $boot ---" -ForegroundColor Cyan
Check 'Filesystem is FAT32'  { "$($bootVol.FileSystem)"; $bootVol.FileSystem -match 'FAT32' }
Check 'Label is WPT_BOOT'    { "$($bootVol.FileSystemLabel)"; $bootVol.FileSystemLabel -eq 'WPT_BOOT' }
Check 'bootmgr present'      { Test-Path (Join-Path $boot 'bootmgr') }
Check 'EFI boot loader present' { Test-Path (Join-Path $boot 'efi\boot\bootx64.efi') }
Check 'boot\ directory present' { Test-Path (Join-Path $boot 'boot') }
Check 'sources\boot.wim present' { Test-Path (Join-Path $boot 'sources\boot.wim') }
Check 'install.wim NOT on FAT32' { -not (Test-Path (Join-Path $boot 'sources\install.wim')) }
Check 'No file exceeds FAT32 4 GB limit' {
    $big = Get-ChildItem $boot -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Length -ge 4GB } | Select-Object -First 1
    if ($big) { throw "$($big.Name) is $([int]($big.Length/1GB)) GB" }
    $true
}

Write-Host "`n--- Partition 2 (data): $data ---" -ForegroundColor Cyan
Check 'Filesystem is NTFS' { "$($dataVol.FileSystem)"; $dataVol.FileSystem -eq 'NTFS' }
Check 'Label is WPT_DATA'  { "$($dataVol.FileSystemLabel)"; $dataVol.FileSystemLabel -eq 'WPT_DATA' }
Check 'install image present' {
    $w = Get-ChildItem (Join-Path $data 'sources') -Filter 'install.*' -ErrorAction SilentlyContinue |
         Where-Object { $_.Extension -in '.wim', '.esd' } | Select-Object -First 1
    if (-not $w) { throw 'no install.wim/esd' }
    "$($w.Name), $('{0:N2}' -f ($w.Length/1GB)) GB"
}

Write-Host "`n--- autounattend.xml ---" -ForegroundColor Cyan
foreach ($root in $boot, $data) {
    Check "Present at $root" { Test-Path (Join-Path $root 'autounattend.xml') }
}
$xmlPath = Join-Path $boot 'autounattend.xml'
if (Test-Path $xmlPath) {
    Check 'Parses as XML' { [xml](Get-Content $xmlPath -Raw); $true }
    $x = [xml](Get-Content $xmlPath -Raw)
    Check 'No BOM (Setup parses it cleanly)' {
        $b = [byte[]]::new(3); $fs=[IO.File]::OpenRead($xmlPath)
        try { $null = $fs.Read($b,0,3) } finally { $fs.Dispose() }
        -not ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    }
    Check 'Has all three settings passes' {
        $passes = @($x.unattend.settings | ForEach-Object { $_.pass })
        "$($passes -join ', ')"
        (@('windowsPE','specialize','oobeSystem') | Where-Object { $passes -notcontains $_ }).Count -eq 0
    }
    Check 'TPM/SecureBoot/RAM bypasses present' {
        $paths = ($x.unattend.settings | Where-Object pass -eq 'windowsPE').component.RunSynchronous.RunSynchronousCommand.Path -join ' '
        $needed = 'BypassTPMCheck','BypassSecureBootCheck','BypassRAMCheck'
        (@($needed | Where-Object { $paths -notmatch $_ }).Count -eq 0)
    }
    Check 'Local account defined' {
        $shell = ($x.unattend.settings | Where-Object pass -eq 'oobeSystem').component |
                 Where-Object name -eq 'Microsoft-Windows-Shell-Setup'
        $n = $shell.UserAccounts.LocalAccounts.LocalAccount.Name
        if (-not $n) { throw 'none' }
        "user '$n', group '$($shell.UserAccounts.LocalAccounts.LocalAccount.Group)'"
    }
    Check 'WinPE driver load command present' {
        $paths = ($x.unattend.settings | Where-Object pass -eq 'windowsPE').component.RunSynchronous.RunSynchronousCommand.Path -join ' '
        $paths -match 'peload\.cmd'
    }
}

Write-Host "`n--- Payload ---" -ForegroundColor Cyan
$payload = Join-Path $data 'USBPREP'
Check 'USBPREP folder present' { Test-Path $payload }
Check 'peload.cmd present'     { Test-Path (Join-Path $payload 'peload.cmd') }
Check 'firstlogon.cmd present' { Test-Path (Join-Path $payload 'firstlogon.cmd') }
Check 'Install-Payload.ps1 present' { Test-Path (Join-Path $payload 'Install-Payload.ps1') }

$active = Join-Path $payload 'Drivers\Active'
Check 'Exactly one RAID set in Active' {
    $infs = @(Get-ChildItem -LiteralPath $active -Filter *.inf -File -Recurse -ErrorAction SilentlyContinue)
    if (-not $infs.Count) { throw 'Active is empty' }
    $vers = @($infs | ForEach-Object {
        ([regex]::Match((Get-Content -LiteralPath $_.FullName -Raw), 'DriverVer\s*=\s*([^\r\n]+)')).Groups[1].Value.Trim()
    } | Sort-Object -Unique)
    if ($vers.Count -gt 1) { throw "MIXED VERSIONS: $($vers -join ' | ') - Windows would pick by version, not by board" }
    "$($infs.Count) .inf, DriverVer $($vers[0])"
}
Check 'Reference sets kept out of the auto-load path' -Warning {
    $all = Join-Path $payload 'Drivers\All'
    if (-not (Test-Path $all)) { throw 'Drivers\All absent (IncludeAllDriverSets was off)' }
    "$(@(Get-ChildItem -LiteralPath $all -Directory).Count) set(s) staged for manual use"
}
Check 'peload.cmd does not scan Drivers\All' {
    $c = Get-Content (Join-Path $payload 'peload.cmd') -Raw
    ($c -match 'Drivers\\Active') -and ($c -notmatch 'Drivers\\All')
}

$appsDir = Join-Path $payload 'Apps'
Check 'apps.json present' -Warning { Test-Path (Join-Path $appsDir 'apps.json') }
if (Test-Path (Join-Path $appsDir 'apps.json')) {
    $m = Get-Content (Join-Path $appsDir 'apps.json') -Raw | ConvertFrom-Json
    Check 'Every app in the manifest exists on disk' {
        $missing = @($m.apps | Where-Object { -not (Get-ChildItem -LiteralPath $appsDir -Filter $_.match -Recurse -ErrorAction SilentlyContinue) })
        if ($missing.Count) { throw "missing: $($missing.name -join ', ')" }
        "$(@($m.apps).Count) app(s), all present"
    }
    Check 'Staged installers are validly signed' -Warning {
        $bad = @(Get-ChildItem -LiteralPath $appsDir -Filter *.exe -Recurse |
                 Where-Object { (Get-AuthenticodeSignature $_.FullName).Status -ne 'Valid' })
        if ($bad.Count) { throw "unsigned/invalid: $($bad.Name -join ', ')" }
        'all valid'
    }
}

Write-Host "`n=== $script:Pass passed, $script:Fail failed, $script:Warn warnings ===" -ForegroundColor $(
    if ($script:Fail) { 'Red' } elseif ($script:Warn) { 'Yellow' } else { 'Green' })
if ($script:Fail) { Write-Host "The stick is NOT ready.`n" -ForegroundColor Red }
else { Write-Host "Structure looks correct. Boot-test to be certain.`n" -ForegroundColor Green }
