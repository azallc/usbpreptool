# FidoUpdate.ps1 - keeps tools\Fido.ps1 current.
#
# Fido is the script Rufus uses to resolve official Microsoft ISO links. Microsoft
# changes their download API periodically and Fido gets patched upstream within
# days, so a pinned copy goes stale in a way you only discover mid-build.
#
# This fetches it from the official repo, but deliberately does NOT blindly trust
# what comes back:
#
#   * HTTPS to a hardcoded raw.githubusercontent.com URL - never a redirect chain
#     or a URL from config.
#   * The payload is validated as an actual Fido script before it replaces
#     anything (captive portals and error pages return HTTP 200 with HTML).
#   * The previous copy is kept as Fido.ps1.bak so a bad upstream day is one
#     rename away from fixed.
#   * SHA-256 of every version installed is recorded in Fido.state.json.
#   * Any failure is non-fatal - the cached copy keeps working, offline included.

$script:FidoUrl        = 'https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1'
$script:FidoMinBytes   = 20KB      # real Fido is ~60-100 KB; anything tiny is an error page
$script:FidoMaxBytes   = 2MB

function Get-FidoPaths {
    param([Parameter(Mandatory)][string]$ToolsDir)
    [pscustomobject]@{
        Script = Join-Path $ToolsDir 'Fido.ps1'
        Backup = Join-Path $ToolsDir 'Fido.ps1.bak'
        State  = Join-Path $ToolsDir 'Fido.state.json'
    }
}

function Get-FidoVersion {
    <#
        Fido carries its version in a header comment and/or a script variable.
        Neither is guaranteed across versions, so try both and degrade gracefully.
    #>
    param([Parameter(Mandatory)][string]$Content)
    foreach ($pattern in @(
            '(?m)^\s*#\s*Fido\s+v([0-9]+\.[0-9]+(\.[0-9]+)?)',
            '(?m)^\s*\$?Version\s*=\s*[''"]([0-9]+\.[0-9]+(\.[0-9]+)?)[''"]',
            'Fido\s+v([0-9]+\.[0-9]+(\.[0-9]+)?)')) {
        $m = [regex]::Match($Content, $pattern)
        if ($m.Success) { return $m.Groups[1].Value }
    }
    'unknown'
}

function Remove-Bom {
    <#
        Fido ships with a UTF-8 BOM. Invoke-WebRequest hands it back as a literal
        U+FEFF character at the head of the string rather than stripping it the
        way a file read would, which pushes param() out of first-statement
        position and makes the whole script fail to parse. Strip it before both
        validation and writing.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $Content.TrimStart([char]0xFEFF)
}

function Test-FidoContent {
    <#
        Gatekeeper. Returns $true only if this really looks like Fido, so an
        error page, a captive-portal login, or a truncated transfer can never
        overwrite a working copy.
    #>
    param([Parameter(Mandatory)][string]$Content)

    if ($Content.Length -lt $script:FidoMinBytes) {
        Write-Log "Rejected Fido download: only $($Content.Length) bytes." 'WARN'; return $false
    }
    if ($Content -match '(?i)^\s*<(!doctype|html)') {
        Write-Log "Rejected Fido download: got HTML, not a script (captive portal or proxy?)." 'WARN'; return $false
    }

    # Markers that must all be present in a genuine Fido.ps1.
    $required = @(
        '(?i)param\s*\(',
        '(?i)\bWin\b',
        '(?i)\bGetUrl\b',
        '(?i)software-download|software_download|api/controls|vlscppe\.microsoft\.com'
    )
    foreach ($r in $required) {
        if ($Content -notmatch $r) {
            Write-Log "Rejected Fido download: missing expected marker /$r/." 'WARN'; return $false
        }
    }

    # Must parse as PowerShell. A syntactically broken script is not worth keeping.
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($Content, [ref]$null, [ref]$errs)
    if ($errs -and $errs.Count) {
        Write-Log "Rejected Fido download: $($errs.Count) PowerShell parse error(s)." 'WARN'; return $false
    }
    $true
}

function Get-StateValue {
    <#
        Reads a property that may not exist. ConvertFrom-Json objects only carry
        the keys the file actually had, and under Set-StrictMode -Version 2.0 a
        missing property is a terminating error rather than $null.
    #>
    param($State, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $State) { return $null }
    if (-not $State.PSObject.Properties[$Name]) { return $null }
    $State.$Name
}

function Get-FidoState {
    param([Parameter(Mandatory)][string]$ToolsDir)
    $p = (Get-FidoPaths -ToolsDir $ToolsDir).State
    if (Test-Path $p) {
        try { return Get-Content $p -Raw | ConvertFrom-Json } catch { }
    }
    $null
}

function Update-Fido {
    <#
    .SYNOPSIS
        Fetches Fido.ps1 if it is missing, stale, or -Force is given.

    .PARAMETER MaxAgeDays
        Skip the network entirely if the local copy was checked more recently
        than this. Launch is not the place to spend five seconds on a request
        that almost always returns the same bytes.

    .OUTPUTS
        A result object. Never throws - callers carry on with whatever copy exists.
    #>
    param(
        [Parameter(Mandatory)][string]$ToolsDir,
        [int]$MaxAgeDays = 7,
        [int]$TimeoutSec = 15,
        [switch]$Force
    )

    $paths  = Get-FidoPaths -ToolsDir $ToolsDir
    $result = [pscustomobject]@{
        Action        = 'none'      # none | installed | updated | uptodate | failed | skipped
        Version       = $null
        PreviousVersion = $null
        Sha256        = $null
        Message       = ''
        HaveWorkingCopy = (Test-Path $paths.Script)
    }

    if (-not (Test-Path $ToolsDir)) { New-Item -ItemType Directory -Path $ToolsDir -Force | Out-Null }

    $state   = Get-FidoState -ToolsDir $ToolsDir
    $exists  = Test-Path $paths.Script

    # A hand-edited or truncated state file may be missing fields, and under
    # Set-StrictMode -Version 2.0 reading an absent property throws.
    $lastChecked   = Get-StateValue -State $state -Name 'LastChecked'
    $cachedVersion = Get-StateValue -State $state -Name 'Version'

    if ($exists -and -not $Force -and $lastChecked) {
        try {
            $age = (Get-Date) - [datetime]$lastChecked
            if ($age.TotalDays -lt $MaxAgeDays) {
                $result.Action  = 'skipped'
                $result.Version = $cachedVersion
                $result.Message = "Fido v$cachedVersion, checked $([int]$age.TotalDays)d ago."
                Write-Log $result.Message
                return $result
            }
        } catch { }
    }

    try {
        Write-Log "Checking for a newer Fido..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $resp = Invoke-WebRequest -Uri $script:FidoUrl -UseBasicParsing `
                    -TimeoutSec $TimeoutSec -MaximumRedirection 2 -ErrorAction Stop
        $content = $resp.Content
        if ($content -isnot [string]) { $content = [Text.Encoding]::UTF8.GetString($content) }
        $content = Remove-Bom -Content $content

        if ($content.Length -gt $script:FidoMaxBytes) {
            throw "Response was $(Format-Size $content.Length) - refusing it."
        }
        if (-not (Test-FidoContent -Content $content)) {
            throw "Downloaded content did not validate as Fido."
        }

        $newHash = (Get-FileHash -InputStream ([IO.MemoryStream]::new(
                        [Text.Encoding]::UTF8.GetBytes($content))) -Algorithm SHA256).Hash
        $newVersion = Get-FidoVersion -Content $content

        if ($exists) {
            $oldHash = (Get-FileHash -Path $paths.Script -Algorithm SHA256).Hash
            $result.PreviousVersion = Get-FidoVersion -Content (Get-Content $paths.Script -Raw)
            if ($oldHash -eq $newHash) {
                Save-FidoState -ToolsDir $ToolsDir -Version $newVersion -Sha256 $newHash
                $result.Action  = 'uptodate'
                $result.Version = $newVersion
                $result.Sha256  = $newHash
                $result.Message = "Fido v$newVersion is current."
                Write-Log $result.Message 'OK'
                return $result
            }
            Copy-Item -Path $paths.Script -Destination $paths.Backup -Force
            Write-Log "Previous Fido (v$($result.PreviousVersion)) backed up to Fido.ps1.bak"
        }

        [IO.File]::WriteAllText($paths.Script, $content, (New-Object Text.UTF8Encoding $false))
        Save-FidoState -ToolsDir $ToolsDir -Version $newVersion -Sha256 $newHash

        $result.Action  = if ($exists) { 'updated' } else { 'installed' }
        $result.Version = $newVersion
        $result.Sha256  = $newHash
        $result.HaveWorkingCopy = $true
        $result.Message = if ($exists) {
            "Fido updated: v$($result.PreviousVersion) -> v$newVersion"
        } else {
            "Fido v$newVersion installed."
        }
        Write-Log $result.Message 'OK'
        Write-Log "Fido SHA-256: $newHash"
        return $result
    }
    catch {
        $result.Action  = 'failed'
        $result.Message = if ($exists) {
            "Could not refresh Fido ($($_.Exception.Message)). Using the cached copy."
        } else {
            "Could not download Fido: $($_.Exception.Message)"
        }
        Write-Log $result.Message $(if ($exists) { 'WARN' } else { 'ERROR' })

        # Record the failed attempt but do not stamp LastChecked - we want the
        # next launch to try again rather than wait out MaxAgeDays.
        return $result
    }
}

function Save-FidoState {
    param(
        [Parameter(Mandatory)][string]$ToolsDir,
        [string]$Version,
        [string]$Sha256
    )
    $paths = Get-FidoPaths -ToolsDir $ToolsDir
    $state = [ordered]@{
        Version     = $Version
        Sha256      = $Sha256
        Source      = $script:FidoUrl
        LastChecked = (Get-Date).ToString('o')
    }
    $state | ConvertTo-Json | Set-Content -Path $paths.State -Encoding utf8
}

function Restore-PreviousFido {
    <#
        Rolls back to Fido.ps1.bak. For the day upstream ships something broken
        and the last version was working fine.
    #>
    param([Parameter(Mandatory)][string]$ToolsDir)
    $paths = Get-FidoPaths -ToolsDir $ToolsDir
    if (-not (Test-Path $paths.Backup)) {
        Write-Log "No Fido.ps1.bak to roll back to." 'WARN'
        return $false
    }
    Copy-Item -Path $paths.Backup -Destination $paths.Script -Force
    $v = Get-FidoVersion -Content (Get-Content $paths.Script -Raw)
    Save-FidoState -ToolsDir $ToolsDir -Version $v -Sha256 (Get-FileHash $paths.Script -Algorithm SHA256).Hash
    Write-Log "Rolled Fido back to v$v" 'OK'
    $true
}
