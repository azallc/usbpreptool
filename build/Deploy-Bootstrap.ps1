<#
.SYNOPSIS
    Publishes Install-USBPrep.ps1 to the web host, BOM-free, and verifies it.

.DESCRIPTION
    The bootstrap is fetched with irm and executed with iex. A UTF-8 BOM survives
    that round trip as a literal U+FEFF character glued to the first token, and
    iex then fails with:

        The term '<#' is not recognized as the name of a cmdlet...

    Nothing about that message points at encoding, so this script strips the BOM
    before upload and refuses to publish a file that would fail.

.EXAMPLE
    .\build\Deploy-Bootstrap.ps1 -PiHost pi@raspberrypi.local -Url https://prep.example.com/prep
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PiHost,
    [string]$RemotePath = '/srv/usbpreptool/Install-USBPrep.ps1',
    [string]$Url,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'
$ScriptDir = $PSScriptRoot
if (-not $ScriptDir) { $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition }
$RepoRoot  = Resolve-Path (Join-Path $ScriptDir '..')
$Source    = Join-Path $RepoRoot 'Install-USBPrep.ps1'

function Test-BootstrapContent {
    param([Parameter(Mandatory)][string]$Text, [string]$Label)

    $ok = $true
    if ($Text.Length -gt 0 -and [int][char]$Text[0] -eq 0xFEFF) {
        Write-Host "  [FAIL] $Label starts with U+FEFF - iex would fail with" -ForegroundColor Red
        Write-Host "         \"The term '<#' is not recognized...\"" -ForegroundColor Red
        $ok = $false
    }

    if ($Text -match '(?i)^\s*<(!doctype|html)') {
        Write-Host "  [FAIL] $Label is HTML, not a script" -ForegroundColor Red
        $ok = $false
    }

    foreach ($marker in 'GitHubOwner', 'BundleVersion', 'USBPrepTool.ps1') {
        if ($Text -notmatch [regex]::Escape($marker)) {
            Write-Host "  [FAIL] $Label is missing '$marker'" -ForegroundColor Red
            $ok = $false
        }
    }

    # Match the assignment, not the word. The bootstrap legitimately contains
    # "CHANGEME" in its own guard clause, so a bare substring test always fails.
    if ($Text -match "\`$GitHubOwner\s*=\s*'CHANGEME'") {
        Write-Host "  [FAIL] $Label is unconfigured (\$GitHubOwner is still CHANGEME)" -ForegroundColor Red
        $ok = $false
    }

    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) {
        Write-Host "  [FAIL] $Label has $($errs.Count) parse error(s)" -ForegroundColor Red
        $ok = $false
    } else {
        Write-Host "  [PASS] $Label parses as PowerShell" -ForegroundColor Green
    }

    # The real test: does iex actually accept it? Parse alone does not catch the
    # BOM case, because the tokenizer treats U+FEFF differently from the parser.
    try {
        $null = [scriptblock]::Create($Text)
        Write-Host "  [PASS] $Label compiles" -ForegroundColor Green
    } catch {
        Write-Host "  [FAIL] $Label will not compile: $($_.Exception.Message)" -ForegroundColor Red
        $ok = $false
    }

    $ok
}

# The local file is always checked. -VerifyOnly skips the upload, not the checks -
# otherwise it would report nothing at all, which is worse than useless.
Write-Host "`n=== Local file ===" -ForegroundColor Cyan

# Detect the BOM from the raw bytes. ReadAllText silently strips it, so a
# string-level check on a local file always reports "no BOM" even when the file
# on disk starts with EF BB BF - and the BOM'd file would then be uploaded as-is.
# (Content fetched over HTTP is different: there the BOM does arrive as U+FEFF in
# the string, which is what Test-BootstrapContent checks.)
$bytes  = [IO.File]::ReadAllBytes($Source)
$hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
$text   = [IO.File]::ReadAllText($Source)

if ($hasBom) {
    Write-Host "  [FIX ] stripping UTF-8 BOM from $Source" -ForegroundColor Yellow
    [IO.File]::WriteAllText($Source, $text, (New-Object Text.UTF8Encoding $false))
} else {
    Write-Host "  [PASS] file on disk has no BOM" -ForegroundColor Green
}

if (-not (Test-BootstrapContent -Text $text -Label 'local file')) {
    throw "Refusing to deploy - the local bootstrap failed validation."
}

if (-not $VerifyOnly) {
    Write-Host "`n=== Upload ===" -ForegroundColor Cyan
    $remoteDir = Split-Path $RemotePath -Parent
    Write-Host "  ssh $PiHost mkdir -p $remoteDir"
    & ssh $PiHost "mkdir -p '$remoteDir'"
    if ($LASTEXITCODE -ne 0) { throw "ssh failed (exit $LASTEXITCODE)" }

    Write-Host "  scp -> ${PiHost}:$RemotePath"
    & scp $Source "${PiHost}:$RemotePath"
    if ($LASTEXITCODE -ne 0) { throw "scp failed (exit $LASTEXITCODE)" }

    # Bytes on the Pi must match byte-for-byte; a mangled transfer is otherwise
    # invisible until a customer runs it.
    $localHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash.ToLower()
    $remoteHash = (& ssh $PiHost "sha256sum '$RemotePath' | cut -d' ' -f1").Trim()
    Write-Host "  local  sha256: $localHash"
    Write-Host "  remote sha256: $remoteHash"
    if ($localHash -ne $remoteHash) { throw "Hash mismatch after upload." }
    Write-Host "  [PASS] uploaded file matches" -ForegroundColor Green
}

if ($Url) {
    Write-Host "`n=== Fetch over HTTPS (what customers get) ===" -ForegroundColor Cyan
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $resp = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 30
    Write-Host "  HTTP $($resp.StatusCode)  Content-Type: $($resp.Headers['Content-Type'])"
    Write-Host "  Cache-Control: $($resp.Headers['Cache-Control'])"

    $served = "$($resp.Content)"
    if (-not (Test-BootstrapContent -Text $served -Label 'served content')) {
        throw "The URL is serving something that will not run."
    }

    $servedHash = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash(
            [Text.Encoding]::UTF8.GetBytes($served))).Replace('-','').ToLower()
    $localHash = [BitConverter]::ToString(
        [Security.Cryptography.SHA256]::Create().ComputeHash(
            [Text.Encoding]::UTF8.GetBytes([IO.File]::ReadAllText($Source)))).Replace('-','').ToLower()
    if ($servedHash -ne $localHash) {
        Write-Host "  [WARN] served content differs from local - stale cache?" -ForegroundColor Yellow
        Write-Host "         Purge the Cloudflare cache or add a bypass rule for this path." -ForegroundColor Yellow
    } else {
        Write-Host "  [PASS] served content matches local exactly" -ForegroundColor Green
    }

    Write-Host "`n  Customers can now run:" -ForegroundColor Cyan
    Write-Host "    irm $Url | iex" -ForegroundColor White
}

Write-Host ""
