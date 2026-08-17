# DiskPrep.ps1 - GPT split layout: FAT32 boot partition + NTFS data partition.
#
# Why split? Most UEFI firmware has no NTFS driver, so a pure-NTFS stick will not
# boot without a shim (this is what Rufus's hidden UEFI:NTFS partition is for).
# FAT32 also caps files at 4 GB, and install.wim is usually larger. Splitting
# solves both with no third-party binaries:
#
#   Partition 1  FAT32  ~1 GB   label WPT_BOOT   everything except sources\install.*
#   Partition 2  NTFS   rest    label WPT_DATA   sources\install.*, drivers, apps
#
# WinPE boots from the FAT32 partition, then scans attached volumes for
# \sources\install.wim and finds it on the NTFS partition.

$script:BootLabel = 'WPT_BOOT'
$script:DataLabel = 'WPT_DATA'
$script:BootPartitionSizeMB = 1024

function Get-CandidateUsbDisk {
    <#
        Removable and USB-attached fixed disks only. System disks are excluded
        outright - this tool wipes what it is pointed at.
    #>
    Get-Disk | Where-Object {
        $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem
    } | ForEach-Object {
        [pscustomobject]@{
            Number      = $_.Number
            Model       = $_.FriendlyName
            SizeBytes   = $_.Size
            SizeText    = Format-Size $_.Size
            BusType     = $_.BusType
            PartStyle   = $_.PartitionStyle
            IsReadOnly  = $_.IsReadOnly
            Display     = "Disk {0} - {1} ({2})" -f $_.Number, $_.FriendlyName, (Format-Size $_.Size)
        }
    } | Sort-Object Number
}

function Initialize-UsbTarget {
    <#
        Wipes the disk and lays down the two-partition GPT scheme.
        Returns the two drive letters.
    #>
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [int]$BootSizeMB = $script:BootPartitionSizeMB
    )

    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if ($disk.IsBoot -or $disk.IsSystem) {
        throw "Refusing to touch disk $DiskNumber - it is the boot or system disk."
    }
    if ($disk.BusType -ne 'USB') {
        throw "Refusing to touch disk $DiskNumber - bus type is '$($disk.BusType)', not USB."
    }
    if ($disk.Size -lt 8GB) {
        throw "Disk $DiskNumber is only $(Format-Size $disk.Size). A Windows 11 stick needs at least 8 GB."
    }

    Write-Log "Wiping disk $DiskNumber ($($disk.FriendlyName), $(Format-Size $disk.Size))" 'WARN'

    Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Remove-Partition -Confirm:$false -ErrorAction SilentlyContinue

    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
    Start-Sleep -Seconds 2

    # Clear-Disk removes the partitions but leaves the disk INITIALIZED with its
    # existing partition style - it does not return it to RAW. Calling
    # Initialize-Disk unconditionally therefore fails with "The disk has already
    # been initialized" on any disk that was already GPT, which is most sticks.
    # Re-read the state and take the branch that applies.
    $disk = Get-Disk -Number $DiskNumber
    switch ($disk.PartitionStyle) {
        'RAW' {
            Initialize-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop
            Write-Log "Disk initialized as GPT (was RAW)." 'OK'
        }
        'GPT' {
            Write-Log "Disk is already GPT - partitions cleared, keeping the scheme." 'OK'
        }
        default {
            # MBR, or anything else: convert rather than re-initialise.
            Set-Disk -Number $DiskNumber -PartitionStyle GPT -ErrorAction Stop
            Write-Log "Disk converted from $($disk.PartitionStyle) to GPT." 'OK'
        }
    }
    Start-Sleep -Seconds 2

    $disk = Get-Disk -Number $DiskNumber
    if ($disk.PartitionStyle -ne 'GPT') {
        throw "Disk $DiskNumber is '$($disk.PartitionStyle)' after preparation, expected GPT."
    }

    $bootPart = New-Partition -DiskNumber $DiskNumber -Size ($BootSizeMB * 1MB) -AssignDriveLetter -ErrorAction Stop
    Start-Sleep -Seconds 2
    Format-Volume -Partition $bootPart -FileSystem FAT32 -NewFileSystemLabel $script:BootLabel `
                  -Confirm:$false -Force -ErrorAction Stop | Out-Null
    Write-Log "Partition 1 formatted FAT32 ($BootSizeMB MB, label $script:BootLabel)" 'OK'

    $dataPart = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter -ErrorAction Stop
    Start-Sleep -Seconds 2
    Format-Volume -Partition $dataPart -FileSystem NTFS -NewFileSystemLabel $script:DataLabel `
                  -Confirm:$false -Force -ErrorAction Stop | Out-Null
    Write-Log "Partition 2 formatted NTFS (remaining space, label $script:DataLabel)" 'OK'

    # Re-read: drive letters are assigned asynchronously.
    Start-Sleep -Seconds 2
    $parts = Get-Partition -DiskNumber $DiskNumber | Where-Object DriveLetter | Sort-Object PartitionNumber
    if ($parts.Count -lt 2) { throw "Expected 2 lettered partitions on disk $DiskNumber, found $($parts.Count)." }

    $result = [pscustomobject]@{
        DiskNumber = $DiskNumber
        BootRoot   = "$($parts[0].DriveLetter):\"
        DataRoot   = "$($parts[1].DriveLetter):\"
        BootLabel  = $script:BootLabel
        DataLabel  = $script:DataLabel
    }
    Write-Log "Boot partition: $($result.BootRoot)   Data partition: $($result.DataRoot)" 'OK'
    return $result
}

function Copy-WindowsSource {
    <#
        Splits the ISO across the two partitions.
        Everything except sources\install.* goes to FAT32; install.* goes to NTFS.
    #>
    param(
        [Parameter(Mandatory)][string]$IsoRoot,
        [Parameter(Mandatory)]$Target
    )

    $ok = Copy-TreeWithProgress -Source $IsoRoot -Destination $Target.BootRoot `
            -ExcludeFiles @('install.wim','install.esd') -Label 'boot files'
    if (-not $ok) { throw "Failed to copy boot files to $($Target.BootRoot)." }

    $srcSources = Join-Path $IsoRoot 'sources'
    $dstSources = Join-Path $Target.DataRoot 'sources'
    if (-not (Test-Path $dstSources)) { New-Item -ItemType Directory -Path $dstSources -Force | Out-Null }

    $installImage = Get-ChildItem -Path $srcSources -Filter 'install.*' -File |
                    Where-Object { $_.Extension -in '.wim', '.esd' } | Select-Object -First 1
    if (-not $installImage) { throw "No install.wim or install.esd found in $srcSources." }

    Write-Log "Copying $($installImage.Name) ($(Format-Size $installImage.Length)) to the NTFS partition - this is the slow part."
    Copy-Item -Path $installImage.FullName -Destination $dstSources -Force -ErrorAction Stop
    Write-Log "$($installImage.Name) copied." 'OK'

    # Setup on some builds wants a matching sources\ layout on the volume it finds
    # install.wim on. These two are tiny and make the scan reliable.
    foreach ($helper in 'boot.wim', 'setup.exe') {
        $p = Join-Path $srcSources $helper
        if ((Test-Path $p) -and ((Get-Item $p).Length -lt 4GB)) {
            Copy-Item -Path $p -Destination $dstSources -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-UsbTargetSpace {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)][double]$RequiredBytes
    )
    $size = (Get-Disk -Number $DiskNumber).Size
    $needed = $RequiredBytes + ($script:BootPartitionSizeMB * 1MB) + 512MB   # headroom
    if ($size -lt $needed) {
        throw "Disk $DiskNumber holds $(Format-Size $size) but this build needs about $(Format-Size $needed)."
    }
    $true
}
