# AppFetch.ps1 - downloads the application payload from vendor direct links.
#
# Everything here is fetched from the vendor at build time rather than bundled,
# so the stick always carries current installers and the release bundle stays
# small. Each download is validated as a real PE executable before it counts.
#
# A failed app download is never fatal. The USB is still bootable and still
# installs Windows; a missing WinRAR is an annoyance, not a reason to abort.

$script:AppCatalog = @(
    @{
        Id      = 'vcredist-x64'
        Name    = 'Visual C++ 2015-2022 Redistributable (x64)'
        Url     = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
        FileName= 'vc_redist.x64.exe'
        Args    = @('/install', '/quiet', '/norestart')
        Install = $true
        MinBytes= 10MB
        Signer  = 'CN=Microsoft Corporation'
    },
    @{
        Id      = 'directx'
        Name    = 'DirectX End-User Runtime (web installer)'
        Url     = 'https://download.microsoft.com/download/1/7/1/1718ccc4-6315-4d8e-9543-8e28a4e18c4c/dxwebsetup.exe'
        FileName= 'dxwebsetup.exe'
        Args    = @('/Q')
        Install = $true
        MinBytes= 200KB
        Signer  = 'CN=Microsoft Corporation'
        Note    = 'Web installer - needs a network connection on the target machine.'
    }
)

function Get-AppCatalog { $script:AppCatalog }

function Resolve-WinRarUrl {
    <#
        NOT IN THE CATALOG - kept as the worked example for adding an app whose
        vendor has no stable URL. WinRAR was dropped from the payload.

        WinRAR embeds the version in the filename (winrar-x64-723.exe for 7.23),
        so the link has to be discovered. The English build is the one with no
        language suffix - language editions append a code (723fr, 723ru, ...) -
        hence the pattern anchoring on digits immediately followed by .exe.

        A Resolver returns an object with .Url and (optionally) .Version. It runs
        under Set-StrictMode -Version 2.0 during a real build, which is stricter
        than an interactive test, so exercise any new resolver that way before
        trusting it.
    #>
    param([int]$TimeoutSec = 20)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $page = Invoke-WebRequest -Uri 'https://www.win-rar.com/download.html' -UseBasicParsing `
                -TimeoutSec $TimeoutSec -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -ErrorAction Stop

    # NOT $matches - that is an automatic variable populated by -match, and
    # shadowing it inside a function invites confusing action at a distance.
    $found = [regex]::Matches($page.Content, 'https?://[^"''\s]*/winrar-x64-(\d+)\.exe')
    if (-not $found.Count) {
        throw "Could not find an English x64 WinRAR link on win-rar.com - the page layout may have changed."
    }

    $best = $found | ForEach-Object {
        [pscustomobject]@{ Url = $_.Value; Build = [int]$_.Groups[1].Value }
    } | Sort-Object Build -Descending | Select-Object -First 1

    $version = "$([int]($best.Build / 100)).$('{0:D2}' -f ($best.Build % 100))"
    Write-Log "WinRAR $version discovered ($($best.Url))"
    [pscustomobject]@{ Url = $best.Url; Version = $version }
}

function Test-ExecutableSignature {
    <#
        Confirms the download is Authenticode-signed by who it should be.

        These installers run with admin rights on a customer's machine, so a
        hijacked mirror or a DNS-poisoned aka.ms is worth catching here rather
        than discovering later. All three catalog entries verify clean today:

            vc_redist.x64.exe  CN=Microsoft Corporation
            dxwebsetup.exe     CN=Microsoft Corporation
            winrar-x64.exe     CN=win.rar GmbH
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$ExpectedSigner
    )
    $sig = Get-AuthenticodeSignature -LiteralPath $Path

    if ($sig.Status -ne 'Valid') {
        Write-Log "  rejected: signature status is '$($sig.Status)', expected 'Valid'." 'WARN'
        return $false
    }
    $subject = "$($sig.SignerCertificate.Subject)"
    if ($ExpectedSigner -and $subject -notmatch [regex]::Escape($ExpectedSigner)) {
        Write-Log "  rejected: signed by '$($subject -replace ',.*','')', expected '$ExpectedSigner'." 'WARN'
        return $false
    }
    Write-Log "  signature OK - $($subject -replace ',.*','')"
    $true
}

function Test-DownloadedExecutable {
    <#
        Confirms the download is a Windows executable and not an error page.
        aka.ms and download.microsoft.com both return HTTP 200 with HTML when
        something upstream is wrong, which would otherwise land a 3 KB "file not
        found" page on the stick named vc_redist.x64.exe.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [double]$MinBytes = 100KB
    )
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $item = Get-Item -LiteralPath $Path

    if ($item.Length -lt $MinBytes) {
        Write-Log "  rejected: $($item.Name) is only $(Format-Size $item.Length), expected at least $(Format-Size $MinBytes)." 'WARN'
        return $false
    }
    $header = [byte[]]::new(2)
    $fs = [IO.File]::OpenRead($item.FullName)
    try { $null = $fs.Read($header, 0, 2) } finally { $fs.Dispose() }

    if ($header[0] -ne 0x4D -or $header[1] -ne 0x5A) {   # 'MZ'
        Write-Log "  rejected: $($item.Name) is not a PE executable (no MZ header) - probably an error page." 'WARN'
        return $false
    }
    $true
}

function Get-AppPayload {
    <#
        Downloads every catalog entry into $Destination. Returns a result record
        per app so the caller can report what actually made it onto the stick.
    #>
    param(
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$Only,

        # Deliberately NOT named $OnProgress. PowerShell scriptblocks resolve
        # variables dynamically in the scope that invokes them, so a caller
        # passing a scriptblock that itself calls $OnProgress would resolve that
        # name to THIS parameter - i.e. to itself - and recurse until the stack
        # blows. Giving the parameter a distinct name removes the collision.
        [scriptblock]$ProgressCallback = { param($pct, $label) }
    )
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

    $catalog = if ($Only) { $script:AppCatalog | Where-Object { $Only -contains $_.Id } } else { $script:AppCatalog }
    $results = New-Object System.Collections.Generic.List[object]
    $i = 0

    foreach ($app in $catalog) {
        $i++
        $pct = [int](100 * ($i - 1) / @($catalog).Count)
        & $ProgressCallback $pct $app.Name

        $record = [pscustomobject]@{
            Id = $app.Id; Name = $app.Name; FileName = $app.FileName
            Version = $null; Url = $null; Bytes = 0; Sha256 = $null
            Success = $false; Error = $null
        }

        try {
            $url = $app.Url
            if ($app.ContainsKey('Resolver')) {
                $resolved = & $app.Resolver
                $url = $resolved.Url
                $record.Version = $resolved.Version
            }
            $record.Url = $url

            $target = Join-Path $Destination $app.FileName
            Write-Log "Downloading $($app.Name)..."

            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $ok = $false
            try {
                Start-BitsTransfer -Source $url -Destination $target -ErrorAction Stop
                $ok = $true
            } catch {
                Write-Log "  BITS failed ($($_.Exception.Message)); retrying with a direct request." 'WARN'
                Invoke-WebRequest -Uri $url -OutFile $target -UseBasicParsing -TimeoutSec 120 `
                    -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -ErrorAction Stop
                $ok = $true
            }

            if (-not $ok) { throw "Download produced no file." }
            if (-not (Test-DownloadedExecutable -Path $target -MinBytes $app.MinBytes)) {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                throw "Downloaded file failed validation."
            }

            $expectedSigner = if ($app.ContainsKey('Signer')) { $app.Signer } else { $null }
            if ($expectedSigner -and -not (Test-ExecutableSignature -Path $target -ExpectedSigner $expectedSigner)) {
                Remove-Item -LiteralPath $target -Force -ErrorAction SilentlyContinue
                throw "Signature check failed - refusing to put this installer on the stick."
            }

            $item = Get-Item -LiteralPath $target
            $record.Bytes   = $item.Length
            $record.Sha256  = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
            $record.Success = $true
            Write-Log "  $($app.Name) OK ($(Format-Size $item.Length))" 'OK'
        }
        catch {
            $record.Error = $_.Exception.Message
            Write-Log "  $($app.Name) FAILED: $($record.Error)" 'WARN'
        }

        $results.Add($record) | Out-Null
    }

    & $ProgressCallback 100 'done'
    $results
}

function Write-AppManifest {
    <#
        Emits the apps.json the target-side installer reads, describing only the
        apps that actually downloaded. Anything that failed is simply absent, so
        first logon never tries to run a file that is not there.
    #>
    param(
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)]$Results
    )
    $entries = foreach ($r in ($Results | Where-Object Success)) {
        $app = $script:AppCatalog | Where-Object { $_.Id -eq $r.Id } | Select-Object -First 1
        [ordered]@{
            name    = $r.Name
            match   = $r.FileName
            args    = @($app.Args)
            arch    = 'any'
            install = [bool]$app.Install
            version = $r.Version
            sha256  = $r.Sha256
        }
    }

    $manifest = [ordered]@{
        generated = (Get-Date).ToString('o')
        apps      = @($entries)
    }
    $path = Join-Path $Destination 'apps.json'
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding utf8
    Write-Log "Wrote app manifest with $(@($entries).Count) entry/entries." 'OK'
    $path
}
