# tools\

## Fido.ps1 — the ISO downloader

This is what makes "get me a Windows ISO" bearable for a non-technical person.
Fido is the PowerShell script Rufus itself calls when you press its **DOWNLOAD**
button. It queries Microsoft's own software-download API and returns a genuine,
Microsoft-signed, time-limited direct link to the official ISO. No browser, no
Media Creation Tool, no "which of these seventeen pages is the download".

**It is fetched automatically.** You do not need to install anything here — the
first launch downloads it, and later launches refresh it when the cached copy is
more than a few days old.

## How the auto-update works

On launch, `Update-Fido` runs before the window appears:

| Situation | What happens |
|---|---|
| No local copy | Downloads it. Blocks until done — it's ~100 KB. |
| Copy checked < `-FidoMaxAgeDays` ago (default 3) | Network skipped entirely. |
| Copy is older than that | Fetches, compares SHA-256, replaces only if changed. |
| Network down / GitHub unreachable | Logs a warning, keeps the cached copy. Never blocks a build. |
| Microsoft changed their API mid-session | Pressing **Download** catches Fido's failure, force-refreshes, and retries once. |

That last row is the one that matters. Fido breaking is discovered at exactly the
moment you need it, so the failure path pulls the newest version and retries
rather than making you go find out what happened.

## What it will not do

Auto-updating a script that then gets executed is a supply-chain surface, so the
fetch is deliberately narrow:

- **Fixed URL, hardcoded in `lib\FidoUpdate.ps1`.** It is never read from config
  and never followed from a redirect chain (max 2 redirects, HTTPS, TLS 1.2).
- **The payload is validated before it replaces anything.** It must be over
  20 KB, not be HTML, contain the markers a real Fido has (`param(`, `Win`,
  `GetUrl`, a Microsoft download endpoint), and parse as valid PowerShell.
  Captive portals and proxy error pages return HTTP 200 with an HTML body — that
  check is not theoretical.
- **The old copy is kept** as `Fido.ps1.bak`. If upstream ships something broken,
  **Roll back** in the GUI restores it.
- **Every version installed is recorded** in `Fido.state.json` with its SHA-256
  and the time it was fetched, so there is an audit trail of what ran.

A failed or rejected download never stamps `LastChecked`, so the next launch
retries instead of waiting out the staleness window.

## Turning it off

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File USBPrepTool.ps1 -NoFidoUpdate
```

The cached copy still works. To pin a version permanently, use `-NoFidoUpdate`
and put the copy you want in this folder yourself:

```bash
curl -L -o tools/Fido.ps1 https://raw.githubusercontent.com/pbatard/Fido/master/Fido.ps1
```

Adjust the staleness window instead of disabling it entirely with
`-FidoMaxAgeDays 14`, or `-FidoMaxAgeDays 0` to check on every launch.

## Checking what you have

```bash
powershell -NoProfile -Command "Get-Content tools\Fido.state.json"
```

Compare the recorded SHA-256 against github.com/pbatard/Fido if you want to
verify independently. Fido is a single readable script — worth a skim.

## Using Fido directly

```bash
powershell -NoProfile -ExecutionPolicy Bypass -File tools\Fido.ps1 -Win 11 -Rel Latest -Ed "Windows 11 Home/Pro/Edu" -Lang English -Arch x64 -GetUrl
```

Drop `-GetUrl` and it downloads the file itself instead of printing the link.
Run it with no arguments for an interactive picker.

### `-Lang` uses Fido's vocabulary, not locale names

This one will catch you out. `-Lang` takes Fido's own list, so `English` means
US English and `English International` means en-GB. `"English (United States)"`
is **not** valid and fails with *"Invalid Windows language provided."*

The valid values change with each Windows release, so query them rather than
hardcoding:

```bash
powershell -NoProfile -Command ". .\lib\Common.ps1; . .\lib\IsoSource.ps1; Get-FidoOptions -ToolsDir .\tools -List Lang"
```

`-List Ed` and `-List Rel` work the same way. As of Fido 1.70 the only edition
offered is `Windows 11 Home/Pro/Edu` — the Home/Pro split happens at install
time, not download time.

When Fido fails, the tool logs Fido's own error text verbatim rather than
guessing at a cause. If you see *"Fido said: ..."* in the log, that message is
from Fido and is usually specific enough to act on directly.

## If it all goes wrong

The **Browse...** button in the GUI never touches the network. Point it at any
Windows ISO you already have and the rest of the build is identical.
