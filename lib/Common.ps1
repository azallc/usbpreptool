# Common.ps1 - logging, elevation, small shared helpers.

# Both must be initialized at load: the entry point runs under
# Set-StrictMode -Version 2.0, where reading a never-set variable is a hard error.
$script:LogFile        = $null
$script:StatusCallback = $null

function Initialize-Log {
    param([string]$Directory)
    if (-not (Test-Path $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $script:LogFile = Join-Path $Directory ("usbpreptool-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
    Write-Log "Log started. Host: $env:COMPUTERNAME  User: $env:USERNAME  PS: $($PSVersionTable.PSVersion)"
}

function Write-Log {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )
    $line = "{0:HH:mm:ss} [{1,-5}] {2}" -f (Get-Date), $Level, $Message
    if ($script:LogFile) { Add-Content -Path $script:LogFile -Value $line -Encoding utf8 }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
    if ($script:StatusCallback) { & $script:StatusCallback $Message $Level }
}

function Set-StatusCallback {
    param([scriptblock]$Callback)
    $script:StatusCallback = $Callback
}

function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PrepMachineInfo {
    <#
        Facts about the machine the USB is being built ON. Used to seed defaults
        (locale, keyboard, time zone) and to show the operator what they are on.
        This is NOT what determines driver selection - that happens on the target.
    #>
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $langList = Get-WinUserLanguageList
    $primary = $langList | Select-Object -First 1

    [pscustomobject]@{
        CpuName        = $cpu.Name.Trim()
        CpuVendor      = switch -Regex ($cpu.Manufacturer) {
                            'Intel' { 'Intel' }; 'AMD|Authentic' { 'AMD' }; default { $cpu.Manufacturer }
                         }
        Cores          = $cpu.NumberOfCores
        Threads        = $cpu.NumberOfLogicalProcessors
        Architecture   = switch ($cpu.Architecture) {
                            0 { 'x86' }; 5 { 'ARM' }; 9 { 'x64' }; 12 { 'ARM64' }; default { "Unknown($($cpu.Architecture))" }
                         }
        OSArchitecture = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
        SystemLocale   = (Get-WinSystemLocale).Name
        UserLocale     = (Get-Culture).Name
        UILanguage     = (Get-WinSystemLocale).Name
        InputLocale    = if ($primary -and $primary.InputMethodTips.Count) { $primary.InputMethodTips[0] } else { '0409:00000409' }
        TimeZone       = (Get-TimeZone).Id
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return "{0:N2} TB" -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return "{0:N2} GB" -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return "{0:N1} MB" -f ($Bytes / 1MB) }
    return "{0:N0} KB" -f ($Bytes / 1KB)
}

function Copy-TreeWithProgress {
    <#
        Robocopy wrapper. Returns $true on success. Robocopy exit codes below 8
        are informational, not failures.
    #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeFiles = @(),
        [string[]]$ExcludeDirs  = @(),
        [string]$Label = 'files'
    )
    if (-not (Test-Path $Destination)) { New-Item -ItemType Directory -Path $Destination -Force | Out-Null }

    $args = @($Source, $Destination, '/E', '/R:2', '/W:2', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    if ($ExcludeFiles.Count) { $args += '/XF'; $args += $ExcludeFiles }
    if ($ExcludeDirs.Count)  { $args += '/XD'; $args += $ExcludeDirs }

    Write-Log "Copying $Label : $Source -> $Destination"
    $null = & robocopy.exe @args
    $code = $LASTEXITCODE
    # robocopy uses exit codes 0-7 for success variants (1 = files copied), which
    # would otherwise leave $LASTEXITCODE non-zero and make a healthy run look
    # like a failure to anything checking it afterwards.
    $global:LASTEXITCODE = 0
    if ($code -ge 8) {
        Write-Log "robocopy failed for $Label (exit $code)" 'ERROR'
        return $false
    }
    Write-Log "Copied $Label (robocopy exit $code)" 'OK'
    return $true
}
