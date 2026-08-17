# Unattend.ps1 - generates autounattend.xml.
#
# This reproduces every checkbox Rufus offers (Rufus implements them the same way:
# by writing an autounattend.xml to the root of the stick) and adds the driver and
# payload staging on top.
#
# Passes used:
#   windowsPE   - LabConfig bypasses, WinPE driver load, setup UI language
#   specialize  - time zone, telemetry off
#   oobeSystem  - locale, OOBE page skipping, local account, first-logon commands

function New-UnattendXml {
    param(
        [Parameter(Mandatory)][hashtable]$Options,
        [Parameter(Mandatory)][pscustomobject]$Machine
    )

    $esc = { param($s) [System.Security.SecurityElement]::Escape([string]$s) }

    if ($Options.MatchRegionalOptions) {
        $inputLocale  = & $esc $Machine.InputLocale
        $systemLocale = & $esc $Machine.SystemLocale
        $uiLanguage   = & $esc $Machine.UILanguage
        $userLocale   = & $esc $Machine.UserLocale
        $timeZone     = & $esc $Machine.TimeZone
    } else {
        $inputLocale = '0409:00000409'; $systemLocale = 'en-US'
        $uiLanguage  = 'en-US';         $userLocale   = 'en-US'
        $timeZone    = 'UTC'
    }

    $peCommands = New-Object System.Collections.Generic.List[string]

    if ($Options.BypassHardwareChecks) {
        $labConfig = @{
            BypassTPMCheck        = 1
            BypassSecureBootCheck = 1
            BypassRAMCheck        = 1
            BypassStorageCheck    = 1
            BypassCPUCheck        = 1
        }
        foreach ($k in $labConfig.Keys) {
            $peCommands.Add("reg add HKLM\SYSTEM\Setup\LabConfig /v $k /t REG_DWORD /d $($labConfig[$k]) /f")
        }
    }

    if ($Options.LoadRaidDrivers) {
        # Drive letters are unpredictable in WinPE, so sweep for our marker script
        # instead of hardcoding a path. peload.cmd runs pnputil against the staged
        # driver tree so Setup can see RAID/VMD volumes.
        $drives = 'C D E F G H I J K L M N O P Q R S T U V W X Y Z'
        $peCommands.Add("cmd /c for %d in ($drives) do @if exist %d:\USBPREP\peload.cmd call %d:\USBPREP\peload.cmd")
    }

    $peRunSync = ''
    if ($peCommands.Count) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('            <RunSynchronous>')
        for ($i = 0; $i -lt $peCommands.Count; $i++) {
            [void]$sb.AppendLine('                <RunSynchronousCommand wcm:action="add">')
            [void]$sb.AppendLine("                    <Order>$($i + 1)</Order>")
            [void]$sb.AppendLine("                    <Path>$(& $esc $peCommands[$i])</Path>")
            [void]$sb.AppendLine('                </RunSynchronousCommand>')
        }
        [void]$sb.AppendLine('            </RunSynchronous>')
        $peRunSync = $sb.ToString().TrimEnd()
    }

    $spCommands = New-Object System.Collections.Generic.List[string]
    if ($Options.DisableDataCollection) {
        $spCommands.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f')
        $spCommands.Add('reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" /v AllowTelemetry /t REG_DWORD /d 0 /f')
        $spCommands.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo" /v DisabledByGroupPolicy /t REG_DWORD /d 1 /f')
        $spCommands.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f')
        $spCommands.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent" /v DisableSoftLanding /t REG_DWORD /d 1 /f')
        $spCommands.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v AllowCortana /t REG_DWORD /d 0 /f')
        $spCommands.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search" /v ConnectedSearchUseWeb /t REG_DWORD /d 0 /f')
        $spCommands.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v EnableActivityFeed /t REG_DWORD /d 0 /f')
        $spCommands.Add('reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\System" /v PublishUserActivities /t REG_DWORD /d 0 /f')
    }
    if ($Options.SkipMicrosoftAccount) {
        # Belt-and-braces alongside HideOnlineAccountScreens. Harmless on builds
        # where BypassNRO was removed (24H2+); the local account below is what
        # actually keeps OOBE off the network sign-in path there.
        $spCommands.Add('reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f')
    }

    $spRunSync = ''
    if ($spCommands.Count) {
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine('            <RunSynchronous>')
        for ($i = 0; $i -lt $spCommands.Count; $i++) {
            [void]$sb.AppendLine('                <RunSynchronousCommand wcm:action="add">')
            [void]$sb.AppendLine("                    <Order>$($i + 1)</Order>")
            [void]$sb.AppendLine("                    <Path>$(& $esc $spCommands[$i])</Path>")
            [void]$sb.AppendLine('                </RunSynchronousCommand>')
        }
        [void]$sb.AppendLine('            </RunSynchronous>')
        $spRunSync = $sb.ToString().TrimEnd()
    }

    $userAccounts = ''
    $autoLogon    = ''
    if ($Options.CreateLocalAccount -and $Options.LocalAccountName) {
        $name = & $esc $Options.LocalAccountName
        $pw   = & $esc $Options.LocalAccountPassword
        $userAccounts = @"
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>$name</Name>
                        <DisplayName>$name</DisplayName>
                        <Group>Administrators</Group>
                        <Password>
                            <Value>$pw</Value>
                            <PlainText>true</PlainText>
                        </Password>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
"@
        if ($Options.AutoLogon) {
            $autoLogon = @"
            <AutoLogon>
                <Username>$name</Username>
                <Enabled>true</Enabled>
                <LogonCount>1</LogonCount>
                <Password>
                    <Value>$pw</Value>
                    <PlainText>true</PlainText>
                </Password>
            </AutoLogon>
"@
        }
    }

    $firstLogon = ''
    if ($Options.RunFirstLogonScript) {
        $drives = 'C D E F G H I J K L M N O P Q R S T U V W X Y Z'
        $cmd = "cmd /c for %d in ($drives) do @if exist %d:\USBPREP\firstlogon.cmd call %d:\USBPREP\firstlogon.cmd"
        $firstLogon = @"
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>$(& $esc $cmd)</CommandLine>
                    <Description>Stage drivers and applications from the USB</Description>
                    <RequiresUserInput>false</RequiresUserInput>
                </SynchronousCommand>
            </FirstLogonCommands>
"@
    }

    $protectYourPC = if ($Options.DisableDataCollection) { 3 } else { 1 }
    $hideOnline    = if ($Options.SkipMicrosoftAccount)  { 'true' } else { 'false' }

    $ns = 'xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"'
    $ck = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'

@"
<?xml version="1.0" encoding="utf-8"?>
<!--
    Generated by USBPrepTool on $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    Built on: $($Machine.CpuName) ($($Machine.CpuVendor), $($Machine.Architecture))
    Do not edit by hand unless you know what you are doing - rebuild the stick instead.
-->
<unattend xmlns="urn:schemas-microsoft-com:unattend">

    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" $ck $ns>
            <SetupUILanguage>
                <UILanguage>$uiLanguage</UILanguage>
            </SetupUILanguage>
            <InputLocale>$inputLocale</InputLocale>
            <SystemLocale>$systemLocale</SystemLocale>
            <UILanguage>$uiLanguage</UILanguage>
            <UserLocale>$userLocale</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" $ck $ns>
$peRunSync
        </component>
    </settings>

    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" $ck $ns>
            <TimeZone>$timeZone</TimeZone>
        </component>
        <component name="Microsoft-Windows-Deployment" $ck $ns>
$spRunSync
        </component>
    </settings>

    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" $ck $ns>
            <InputLocale>$inputLocale</InputLocale>
            <SystemLocale>$systemLocale</SystemLocale>
            <UILanguage>$uiLanguage</UILanguage>
            <UserLocale>$userLocale</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" $ck $ns>
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>$hideOnline</HideOnlineAccountScreens>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>$protectYourPC</ProtectYourPC>
                <SkipMachineOOBE>false</SkipMachineOOBE>
                <SkipUserOOBE>false</SkipUserOOBE>
            </OOBE>
$autoLogon
$userAccounts
$firstLogon
        </component>
    </settings>

</unattend>
"@
}

function Write-UnattendToTarget {
    <#
        autounattend.xml is picked up from the root of any removable drive Setup
        can see. Writing it to both partitions costs nothing and removes a class
        of "why did it not apply" failures.
    #>
    param(
        [Parameter(Mandatory)][string]$Xml,
        [Parameter(Mandatory)]$Target
    )
    foreach ($root in $Target.BootRoot, $Target.DataRoot) {
        $path = Join-Path $root 'autounattend.xml'
        # BOM-less UTF-8: Setup's parser is happier without one.
        [System.IO.File]::WriteAllText($path, $Xml, (New-Object System.Text.UTF8Encoding $false))
        Write-Log "Wrote $path" 'OK'
    }
}
