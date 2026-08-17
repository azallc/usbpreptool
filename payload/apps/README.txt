This folder is for EXTRA installers you supply yourself.
========================================================

The standard payload downloads itself from the vendors at build time - you do
not need to put it here:

  Visual C++ 2015-2022 Redistributable x64   aka.ms/vs/17/release/vc_redist.x64.exe
  DirectX End-User Runtime                   download.microsoft.com/.../dxwebsetup.exe

That list lives in lib\AppFetch.ps1 ($AppCatalog). Add entries there rather than
dropping files here, so every stick gets current installers instead of whatever
was on someone's disk.

Each download must pass two checks or it is discarded: it has to be a real PE
executable, and it has to be Authenticode-signed by the expected vendor (set
Signer on the catalog entry). Installers run with admin rights on a customer's
machine, so an unsigned or wrongly-signed download fails the build.

apps.json is GENERATED
----------------------
Do not hand-write it. It is produced at build time from what actually downloaded
successfully, so the target never tries to install a file that is not on the
stick. A stale template here used to overwrite the real one - that is why it is
gone.

The Defender problem
--------------------
Microsoft Defender classifies Defender Control as HackTool:Win32/DefenderControl
and will delete it out from under you *while the build is copying it*. That is
not a bug in this tool.

Drop dControl.exe in this folder and the default behaviour ("Stage
Defender-flagged tools as .bin") renames it to dControl.bin on the USB.
Defender's on-access scanner ignores it, so the copy survives and the file
arrives intact.

To use it on the target you must either:
  a) rename it back to .exe manually and add a Defender exclusion yourself, or
  b) tick "Restore them to .exe on the target", which makes the first-logon
     script add an exclusion for C:\USBPrep\Apps and rename it automatically.

Option (b) leaves the finished machine with a permanent Defender exclusion. That
is a real reduction in protection - tick it deliberately, not by habit.

Adding an auto-downloaded app instead
-------------------------------------
In lib\AppFetch.ps1, add to $AppCatalog:

    @{
        Id      = 'something'
        Name    = 'Something'
        Url     = 'https://vendor/something-setup.exe'
        FileName= 'something-setup.exe'
        Args    = @('/S')
        Install = $true
        MinBytes= 1MB
    }

If the vendor has no stable URL, add a Resolver function instead of Url - see
Resolve-WinRarUrl for the pattern.

Common silent switches: /S (NSIS), /VERYSILENT /NORESTART (Inno Setup),
/quiet /norestart (MSI and most Microsoft redists), /qn (msiexec).
