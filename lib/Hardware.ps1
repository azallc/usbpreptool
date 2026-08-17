# Hardware.ps1 - detects what the customer is running so the correct RAID driver
# set can be chosen automatically.
#
# This tool is run remotely BY THE CUSTOMER, on the machine being reinstalled.
# That makes local detection authoritative rather than a guess - the box running
# the script is the box the USB will be used on.
#
# Why detection is mandatory here rather than "stage everything and let pnputil
# match": the three AMD RAID sets all claim the same hardware IDs.
#
#     AM4 NVMe  9.3.0.00158 (2020)  VEN_1022&DEV_43BD,7905,7916,7917
#     AM4 SATA  9.3.0.00266 (2021)  VEN_1022&DEV_43BD,7905,7916,7917
#     AM5 both  9.3.2.00255 (2023)  VEN_1022&DEV_43BD,7905,7916,7917 + B000
#
# Offer all three and Windows ranks by DriverVer, so an AM4 board silently gets
# the 2023 AM5 driver. Exactly one set must be wired into the WinPE load.

$script:DriverSets = @{
    'am4-sata' = @{ Label = 'AM4 - SATA RAID';        Version = '9.3.0.00266'; Socket = 'AM4' }
    'am4-nvme' = @{ Label = 'AM4 - NVMe RAID';        Version = '9.3.0.00158'; Socket = 'AM4' }
    'am5'      = @{ Label = 'AM5 - NVMe + SATA RAID'; Version = '9.3.2.00255'; Socket = 'AM5' }
}

function Get-CpuPlatform {
    <#
        Returns vendor and, for AMD, the socket. SocketDesignation is usually
        honest ('AM4'/'AM5'), but OEM boards sometimes report junk, so the CPU
        model is used as a fallback and the AM5-only PCI ID as a cross-check.
    #>
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $bb  = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue

    $vendor = switch -Regex ($cpu.Manufacturer) {
        'Intel'         { 'Intel' }
        'AMD|Authentic' { 'AMD' }
        default         { 'Unknown' }
    }

    $socket     = $null
    $socketFrom = 'none'

    if ($vendor -eq 'AMD') {
        $sd = "$($cpu.SocketDesignation)".Trim()
        if ($sd -match 'AM5') { $socket = 'AM5'; $socketFrom = 'SocketDesignation' }
        elseif ($sd -match 'AM4') { $socket = 'AM4'; $socketFrom = 'SocketDesignation' }

        if (-not $socket) {
            # Ryzen 7000/8000/9000 and Threadripper 7000 are AM5/TR5.
            # Ryzen 1000-5000 are AM4. Model number is the reliable tell.
            $m = [regex]::Match($cpu.Name, 'Ryzen\s+\d\s+(\d{4})')
            if ($m.Success) {
                $series = [int]$m.Groups[1].Value
                if ($series -ge 7000) { $socket = 'AM5' } else { $socket = 'AM4' }
                $socketFrom = 'CPU model'
            }
        }

        # DEV_B000 appears only in the AM5 driver's match list. If the board
        # exposes it, the machine is AM5 regardless of what anything else said.
        $hasB000 = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                     Where-Object { $_.DeviceID -match 'PCI\\VEN_1022&DEV_B000' }).Count -gt 0
        if ($hasB000 -and $socket -ne 'AM5') {
            Write-Log "PCI VEN_1022&DEV_B000 present - overriding socket to AM5 (was '$socket' from $socketFrom)." 'WARN'
            $socket = 'AM5'; $socketFrom = 'PCI DEV_B000'
        }
    }

    [pscustomobject]@{
        Vendor       = $vendor
        CpuName      = $cpu.Name.Trim()
        Socket       = $socket
        SocketSource = $socketFrom
        Board        = if ($bb) { "$($bb.Manufacturer) $($bb.Product)".Trim() } else { 'unknown' }
        RawSocket    = "$($cpu.SocketDesignation)".Trim()
    }
}

function Get-StorageProfile {
    <#
        Works out whether NVMe and/or SATA are present. Needed to choose between
        the two AM4 sets.

        The wrinkle: on a machine already running in RAID mode, Get-PhysicalDisk
        reports BusType 'RAID' for everything and hides the underlying transport.
        PCI class codes still tell the truth - CC_0108 is the NVMe class, CC_0106
        is SATA/AHCI - so those are the fallback.
    #>
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -ne 'USB' })
    $busTypes = @($disks | Select-Object -ExpandProperty BusType -Unique)

    # PCI class codes live in CompatibleID, never in DeviceID. This is the only
    # signal verified to survive RAID mode: on a live AM5 RAID box the controller
    # still advertises PCI\CC_0108 while stornvme sits Stopped and Win32_DiskDrive
    # reports plain SCSI, so neither of those can be trusted here.
    #
    #   CC_0106 SATA/AHCI   CC_0108 NVM controller
    #   CC_0101 IDE         CC_0104 RAID controller
    $classIds = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                  Where-Object { $_.CompatibleID } |
                  ForEach-Object { $_.CompatibleID }) -join ' '

    $nvmeByClass = $classIds -match 'CC_0108'
    $sataByClass = $classIds -match 'CC_0106|CC_0101'

    $hasNvme = ($busTypes -contains 'NVMe') -or $nvmeByClass
    $hasSata = ($busTypes -contains 'SATA') -or $sataByClass

    [pscustomobject]@{
        BusTypes      = $busTypes
        HasNvme       = $hasNvme
        HasSata       = $hasSata
        AlreadyRaid   = ($busTypes -contains 'RAID')
        DiskCount     = $disks.Count
        Detail        = "buses=[$($busTypes -join ',')] nvme=$hasNvme sata=$hasSata"
    }
}

function Select-RaidDriverSet {
    <#
        Picks exactly one AMD set, or declares that no automatic set applies.

        Intel is deliberately excluded. Intel VMD/RST driver packages are
        board- and generation-specific and shipping a wrong one is worse than
        shipping none, so Intel machines get a clear instruction to supply the
        driver manually instead of a silent bad guess.
    #>
    param(
        [pscustomobject]$Platform = (Get-CpuPlatform),
        [pscustomobject]$Storage  = (Get-StorageProfile)
    )

    $result = [pscustomobject]@{
        SetId       = $null
        Label       = $null
        Automatic   = $false
        Vendor      = $Platform.Vendor
        Socket      = $Platform.Socket
        Reason      = ''
        NeedsManual = $false
        Guidance    = ''
    }

    if ($Platform.Vendor -eq 'Intel') {
        $result.NeedsManual = $true
        $result.Reason = 'Intel platform - automatic RAID driver selection is disabled by design.'
        $result.Guidance = @(
            'Intel RST/VMD drivers are specific to the board and CPU generation, and'
            'loading the wrong one is worse than loading none. Download the F6 package'
            'for this exact machine (the "f6flpy-x64" zip from the board or laptop'
            'vendor support page), extract it, and point the Drivers folder at it.'
        ) -join ' '
        Write-Log $result.Reason 'WARN'
        return $result
    }

    if ($Platform.Vendor -ne 'AMD') {
        $result.Reason = "Unrecognised CPU vendor '$($Platform.Vendor)' - no RAID drivers will be loaded automatically."
        $result.NeedsManual = $true
        Write-Log $result.Reason 'WARN'
        return $result
    }

    switch ($Platform.Socket) {
        'AM5' {
            $result.SetId = 'am5'
            $result.Reason = "AM5 detected via $($Platform.SocketSource). The AM5 package covers both NVMe and SATA."
        }
        'AM4' {
            if ($Storage.HasNvme) {
                $result.SetId = 'am4-nvme'
                $result.Reason = "AM4 detected via $($Platform.SocketSource); NVMe present ($($Storage.Detail))."
            } else {
                $result.SetId = 'am4-sata'
                $result.Reason = "AM4 detected via $($Platform.SocketSource); no NVMe found, using the SATA set ($($Storage.Detail))."
            }
            if ($Storage.HasNvme -and $Storage.HasSata) {
                $result.Reason += ' Both NVMe and SATA are present - AM4 ships separate packages, so NVMe was preferred as the likely boot device. Override if the target array is SATA.'
            }
        }
        default {
            $result.Reason = "AMD CPU but the socket could not be determined (SocketDesignation reported '$($Platform.RawSocket)'). Pick a set manually."
            $result.NeedsManual = $true
            Write-Log $result.Reason 'WARN'
            return $result
        }
    }

    $result.Label     = $script:DriverSets[$result.SetId].Label
    $result.Automatic = $true
    Write-Log "RAID driver set: $($result.Label) [$($result.SetId)] - $($result.Reason)" 'OK'
    return $result
}

function Get-DriverSetIds { $script:DriverSets.Keys | Sort-Object }

function Get-DriverSetLabel {
    param([Parameter(Mandatory)][string]$SetId)
    if ($script:DriverSets.ContainsKey($SetId)) { $script:DriverSets[$SetId].Label } else { $SetId }
}

function Write-HardwareReport {
    <#
        A single readable block for the log and the GUI. When a remote support
        session goes wrong, this is the first thing worth having.
    #>
    param(
        [pscustomobject]$Platform,
        [pscustomobject]$Storage,
        [pscustomobject]$Selection
    )
    $lines = @(
        "CPU        : $($Platform.CpuName)"
        "Vendor     : $($Platform.Vendor)$(if ($Platform.Socket) { " / socket $($Platform.Socket) (from $($Platform.SocketSource))" })"
        "Board      : $($Platform.Board)"
        "Storage    : $($Storage.Detail), $($Storage.DiskCount) disk(s)$(if ($Storage.AlreadyRaid) { ' - already in RAID mode' })"
        "RAID set   : $(if ($Selection.SetId) { "$($Selection.Label) [$($Selection.SetId)]" } else { 'none - manual drivers required' })"
        "Reason     : $($Selection.Reason)"
    )
    foreach ($l in $lines) { Write-Log $l }
    $lines -join "`n"
}
