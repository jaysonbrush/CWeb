# CWeb: a shared Chrome browser for Claude agents

CWeb drives a real Chrome window the user is signed in to. Every Claude session and script on this machine can use it
with one command: if it isn't running it starts, if Chrome was closed or lost it reopens with its tabs, and the sites
the user flagged stay signed in on their own. Nothing to connect, approve or babysit.

> **Location:** CWeb runs from any folder. In the examples, `<CWeb>` is that folder (e.g. `C:\Scripts\Modules\CWeb`) and
> `$CWEB` the same in Bash form (`/c/Scripts/Modules/CWeb`). The **cweb** skill that setup installs has the real path.
> Agents: put the real path in each command; a variable set in one Bash call is gone in the next.

## For agents (start here)

```bash
$CWEB/cweb.sh '{"action":"navigate","tab":"tickets","url":"https://example.org"}'
$CWEB/cweb.sh '{"action":"getpagetext","tab":"tickets"}'
cat body.json | $CWEB/cweb.sh -              # long bodies (scripts with quotes) on stdin
$CWEB/cweb.sh personal '<json>'              # the personal instance, only when the user says so
```

- **Always pass `"tab":"<name>"`**, a name of your own. `navigate` (or `newtab`) with a new name opens that tab; the
  same name later goes back to it. Without `tab`, a command runs in the current tab (the last one used).
- The reply is JSON: check `success`. Exit codes: 0 reply received, 3 CWeb is still starting (Chrome reopening its
  tabs; run the command again), 1 error.
- Tabs the user opened are named after their site (`listtabs`). Read them; ask before changing them. Leave
  `keepalive-*` tabs alone: they're CWeb's.
- "Keep <site> alive": follow **`KEEPALIVE.md`** right then. Never write your own refresh loop.
- Keep waits short (a few seconds, then retry): commands run one at a time for everyone.
- Don't stop CWeb, don't edit `instances.json` or `config.json`, and never print or save the key.

From PowerShell scripts:

```powershell
. <CWeb>\CWeb-Client.ps1
Invoke-CWeb @{ action = 'navigate'; tab = 'tickets'; url = 'https://example.org' }   # -Instance personal for the other one
```

Old forms still work (`cweb.sh <client> connect`, `cweb.sh <instance> <client> '<json>'`, `Connect-CWeb`), so older
automation keeps running; nothing needs connecting any more.

## Set up, update, remove

```powershell
git clone https://github.com/jaysonbrush/CWeb.git <CWeb>    # any folder
<CWeb>\Setup-CWeb.cmd
```

Setup checks PowerShell 7, installs the **pinned** Chrome for Testing, ChromeDriver and Selenium from
`browser\version.json`, creates the data folder, installs the cweb skill, and checks that Chrome starts. Safe to rerun.

- **Update:** `Update-CWeb.cmd` stops running instances cleanly (asks first; `-Yes` doesn't), pulls, runs setup, and
  starts them again. Agents: only when the user asks.
- **Upgrading Chrome** is deliberate: `browser\Update-Browser.ps1 -UpdateSelenium` on one machine (instances stopped),
  test, commit `browser\version.json`.
- **Data folder elsewhere:** `Setup-CWeb.ps1 -DataRoot D:\CWebData`. **Remove:** `Setup-CWeb.ps1 -Uninstall [-Yes]`.
- Sign-ins can't be copied between machines (Chrome ties them to the Windows user): sign in once per machine.
  Keep-alive scripts can: **Copy** on one machine's status page, **Add** on the other's.

## Instances

| Instance | Port | |
|---|---|---|
| `work` | 9380 | The default: what `cweb.sh` uses unless told otherwise. |
| `personal` | 9390 | Optional, its own profile and sign-ins. Only when the user asks. |

Each instance is a separate Chrome profile with its own port and status page. The defaults are in `instances.json`
(in git, no secrets); `<data folder>\config.json` can override per machine. Optional per-instance settings: `label`,
`startUrl`, `hidden` (headless), `showServerWindow`, `keepAlive` (`enabled`, `tickSeconds`, `maxCheckSeconds`).

## Settings

`<data folder>\config.json`, edited by hand (never in git), applies on the next start:

```json
{ "portFallback": true, "instances": { "work": { "port": 9480 } } }
```

`portFallback` (default on): if another program holds the port, the server takes the next free one and records it in
`<data folder>\<instance>\server.json`, where `cweb.sh`, the client and the launcher find it.

## Status page

`http://127.0.0.1:<port>/status` (this machine only). Point the user there instead of pasting status into chat.

- **Keep-alive:** each site with its state (signed in / signed out / error), time left, last renewal; **Copy**,
  **Remove**; **Add** (paste a script); renewals and warnings.
- **Tabs:** open a tab (in the background), every tab with **Close**.
- **Commands:** the last 200 commands (client, action, tab, target, time, result). Never typed text or script bodies.
- Header: instances (**Start** a stopped one), **Stop server**, and **Open Chrome** when it's closed.

## Keep-alive

Each flagged site has a script in `<data folder>\keepalive\<site>.js` (shared by all instances, never in git) and its
own tab, `keepalive-<site>`, which CWeb opens in the background from the script's `@url`. Between API requests CWeb
runs the script's `probe()` there over DevTools (no tab is switched to), and `renew()` when the session is running low.
Signed out: the status page shows it red; the user signs in on that tab and it's kept from then on. If Chrome was
closed, the next check reopens it.

Adding a site (`keepalive` `op: add`, or **Add** on the status page) tests it on the live site and saves it only if it
works. How to write one: **`KEEPALIVE.md`**.

## API

`POST http://127.0.0.1:<port>/api`, header `X-CWeb-Key: <key>` (optional `X-CWeb-Client: <name>` for the command
list), JSON body with `action`. Use `cweb.sh` / `Invoke-CWeb` rather than building requests by hand. Any action takes
`tab`.

| Group | Action | Parameters | Notes |
|---|---|---|---|
| Navigation | `navigate` | `url` | Waits for the load. A new `tab` name opens that tab. |
| | `back` / `forward` / `refresh` | | |
| Page | `gettitle` / `geturl` / `getpagesource` | | |
| | `getpagetext` | `by`, `value` (optional) | Visible text of the page or an element. |
| | `screenshot` | `filePath` | |
| | `getalllinks` / `getallforms` | | |
| Tabs | `newtab` | `name`, `url` | Opens it (or goes to it, if that name is open). Unnamed tabs are named after their site. |
| | `switchtab` | `name` | Makes it the current tab. |
| | `closetab` | | Closes `tab` (or the current one). |
| | `listtabs` | | `tabs` (names) and `details` (`name`, `title`, `url`, `keepAlive`). |
| Elements | `findelement` / `findelements` | `by`, `value` | |
| | `click` | `by`, `value`, `timeout` (default 5) | Scrolls into view, retries while covered or not ready. |
| | `sendkeys` | `by`, `value`, `text`, `clear` | |
| | `gettext` / `getattribute` (`attribute`) / `getelementhtml` / `getelementinfo` | `by`, `value` | |
| | `hover` | `by`, `value` | |
| | `selectoption` | `by`, `value`, `selectBy` (Text/Value/Index), `option` | Fires `input` + `change`. |
| | `scroll` | `direction` (Up/Down/Top/Bottom/ToElement), `pixels`, `by`, `value` | |
| Frames | `switchtoframe` | `frameId` / `frameName` / `frameIndex` / `default: true` | Remembered per tab. |
| Waiting | `wait` | `timeout` (30) | Page load. |
| | `waitforelement` | `by`, `value`, `timeout` (30), `visible` | Keep short. |
| | `waitforurl` | `contains` / `matches` / `changed`, `timeout` | |
| Script | `executescript` | `script`, `arguments` | `return` a value; it comes back in `result`. |
| Alerts | `acceptalert` (`promptText`) / `dismissalert` / `getalerttext` | | |
| Cookies | `getcookies` (`name`) / `setcookie` (`name`, `value`, `domain`, `path`) / `deletecookie` (`name`) | | |
| Window | `getwindowsize` / `setwindowsize` (`width`, `height`) / `maximize` | | Affects everyone's window. |
| Keep-alive | `keepalive` | `op`: `status` (default) / `add` (`source`) / `remove` (`site`) / `check` | See **Keep-alive**. |
| Browser | `status` | | Version, browser state. (`start` / `stop` exist; don't use them: Chrome opens by itself.) |

Locators (`by`): `Id`, `Name`, `ClassName`, `TagName`, `CssSelector`, `XPath`, `LinkText`, `PartialLinkText`.

## Security

- Everything listens on `127.0.0.1` only.
- The API needs this machine's key, `<data folder>\cweb.key`: random, made on first use, readable only by the Windows
  user who runs CWeb. `cweb.sh` and `CWeb-Client.ps1` read it and pass it on stdin / in a header, so it never shows on
  a command line, in output or in a log. Other Windows users on the machine can't use CWeb.
- Web pages can't reach it: the API needs a custom header (a CORS preflight, never approved) and refuses requests with
  an `Origin`; the status page sends no CORS headers and its actions need their own header.
- Known limit: any program running as the user can use CWeb, by design (the user's own sessions and scripts).

## Starting, stopping, restarting

- **Start:** nothing to do: the first command starts it. By hand: `Start-CWeb.cmd [instance]` (if the server runs but
  doesn't answer, it offers to restart it, Chrome closed cleanly first).
- **Chrome closed, crashed or disconnected:** the next command (or keep-alive check) closes what's left cleanly and
  reopens Chrome with its tabs and sign-ins. One failed start isn't retried for a minute.
- **Stop:** the status page's **Stop server** (Chrome closes cleanly, sign-ins kept). Only when the user asks.
- **Restart** after changing server code: stop, then any command. Tabs come back and are re-named after their site, so
  agents open their named tabs again with `navigate`.

## Files and data

| Path (repo) | What |
|---|---|
| `CWeb-Server.ps1` | The server: API, tabs, status page |
| `CWeb-KeepAlive.ps1` | Keep-alive: site scripts, their tabs, checks, add/remove |
| `CWeb-DevTools.ps1` | Reads tabs, runs scripts, opens/closes background tabs over Chrome's DevTools |
| `CWeb-Common.ps1` | Instances, data folder, key, start/stop helpers |
| `CWeb-Client.ps1`, `cweb.sh` | How scripts and agents use it (start it if needed, send the key) |
| `Setup-CWeb.*`, `Update-CWeb.*`, `Start-CWeb.*`, `Test-CWeb.ps1` | Setup, update, launcher, file check |
| `instances.json`, `status.html`, `KEEPALIVE.md` | Default instances, status page, how to write a keep-alive script |
| `browser\` | Core browser module (`Browser-Functions.ps1`, `Update-Browser.ps1`); Chrome, ChromeDriver, Selenium (not in git) |
| `skills\cweb\SKILL.md` | Template of the cweb skill; setup installs it with this folder's path filled in |
| `VERSION` | The version (history below) |

Everything CWeb stores is in **one data folder outside the repo**: `%USERPROFILE%\CWebData`, or the folder in the
user environment variable `CWEB_DATA`. Not under AppData on purpose: the Claude desktop app (MSIX) redirects AppData,
so agents and the server would see different folders.

- `cweb.key` (the API key), `config.json`, `instances.json` (instances this machine added), `keepalive\` (site scripts),
  `scripts\` (profiles of standalone scripts).
- Per instance, `<data folder>\<instance>\`: `profile\` (Chrome profile, sign-ins), `server.json` (port, process ID,
  version; no key), `logs\` (`server-<date>.log`, one `chromedriver-<date>-<time>.log` per start, `launcher-<date>.log`;
  kept 7 days).

## Chrome details

- **Profile self-repair** before each start: ends leftover automation Chrome on *exactly* this profile (never the
  user's own Chrome); a profile from a newer Chrome is set aside; a crashing profile is set aside once.
- **Fingerprint:** `navigator.webdriver` is false, no "controlled by automated software" banner. No CAPTCHA solving.
- **Window title:** `CWeb <label>`. **Network drive:** Chrome starts with `--no-sandbox`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Exit 3, "is starting" | Chrome is reopening its tabs: run the command again. |
| "No tab named 'x'" | Open it with `navigate` (`tab` + `url`), or `listtabs`. |
| "Chrome didn't start: ..." | `<data folder>\<instance>\logs\server-<date>.log` and that start's ChromeDriver log; the status page shows the error. |
| 401 Unauthorized | Something other than `cweb.sh` / `Invoke-CWeb` sent the request without the key. |
| Keep-alive site "signed out" | Sign in on its `keepalive-<site>` tab in the CWeb window. |
| Keep-alive site "error" | The script fails on the site now (the site changed): ask an agent to fix it (`KEEPALIVE.md`) and add it again. |
| "Chrome module not found" / Chrome missing | Run `Setup-CWeb.cmd`. |
| Commands are slow | Another session is in a long wait; commands run one at a time. |
| "Port … is in use by another program" | Give the instance another `port` in `config.json`, or turn `portFallback` on. |

## CWeb versions

`VERSION` holds the CWeb version (`YYYY.MM.DD.NNN`). **Bump it whenever you change CWeb**, and add a line here.

| Version | Changes |
|---|---|
| 2026.10.28.025 | **Simpler, and it runs itself.** No `connect`, client names, keys to approve, tab ownership or Origin rules: `cweb.sh '<json>'` uses `work`, starts it if it isn't running, and sends this machine's key (`<data folder>\cweb.key`, readable only by the user) on its own. If Chrome is closed, crashes or loses ChromeDriver, the next command reopens it with its tabs. Commands take `tab`; `navigate` with a new name opens that tab. Keep-alive runs without agents: each site's script (`@url` added) gets its own background tab that CWeb checks and renews; the agent the user asks writes the script and `op: add` tests it live before saving. Status page: keep-alive sites with Copy / Add / Remove, tabs, commands; the Access tab, requests, drafts and per-instance on/off are gone. The `test` instance, + New / Delete instances and leftover profiles are gone; setup checks Chrome on a throwaway profile instead. Old `connect` forms still work, and clients from older versions (their own copy of `CWeb-Client.ps1` or `cweb.sh`) get this machine's key automatically through the old `/attach` handshake, with nothing to approve. |
| 2026.10.28.024 | When no instance is running (after a reboot, say), an agent's `connect` starts `work` and attaches to it, instead of asking the user. It still never creates an instance and never starts one while another runs; one agent starts it at a time. While Chrome opens its tabs `connect` replies `waiting` (exit 3) "is starting": run it again. |
| 2026.10.28.023 | A closed Chrome no longer breaks the server. Before, once Chrome's window was closed or Chrome exited, every status request failed ("array index evaluated to null"), so the launcher thought the server was down, started a second one that exited at once, and waited 2 minutes. Now the server notices, the status page says so and has **Open Chrome**, and `Start-CWeb` reopens it. `Start-CWeb` also offers to restart a server that runs but doesn't answer (Chrome closed cleanly first), stops waiting at once if a new server exits, and waits up to 6 minutes for Chrome to restore many tabs. `Update-CWeb` stops a server that isn't answering too. Chrome writes only errors to the ChromeDriver log, and the startup file check no longer fills the server log with `Zone.Identifier` errors. |
| 2026.10.27.022 | ChromeDriver logs warnings and errors only. Every version before logged every command and reply in full (about 1 GB a day per instance); those day files (`chromedriver-<date>.log`) are deleted on the next start. ChromeDriver logs are kept 7 days like the other logs. |
| 2026.10.27.021 | Clean Chrome shutdown and restart. Stopping (status page, updates) closes Chrome the way its own Exit does and waits until it has exited, so the next start never says Chrome didn't shut down correctly; if ChromeDriver doesn't answer, Chrome is closed over its DevTools port, and `Update-CWeb`'s force-stop closes Chrome cleanly before ending the server. Restarts reopen the last session's tabs and session sign-ins (`--restore-last-session`: Chrome had been resetting the preference CWeb set). Starts wait up to 330 s for ChromeDriver instead of 60 s; a start that still fails closes the Chrome it opened. One ChromeDriver log per start, kept 3 days. |
| 2026.10.27.020 | Keep-alive no longer switches tabs: checks, renewals and the install-time `probe()` run over Chrome's DevTools connection, so no tab comes to the front and agents' tabs stay put. `probe()`/`renew()` may return a promise. Any API reply can carry a `keepAliveTask` (a site the user flagged, handed to one client at a time for 15 minutes): agents install it without asking the user. |
| 2026.10.26.019 | Keep-alive install messages name the tab once (they said `tab tab x`). |
| 2026.10.26.018 | Access: sessions of one client no longer push each other out (a session whose request another session collected uses the saved key instead of asking again; a re-approval adds a key instead of replacing one; a bad key is only removed if no session saved a newer one). Keep-alive: agents hear about requests in the `connect` reply and install profiles with `op: install`, live at once after one `probe()` on the site's tab (no draft review; `op: draft` installs too). Shorter `KEEPALIVE.md`. |
| 2026.10.26.017 | **Delete** for instances on the status page (asks first, stops it, keeps its profile as a leftover). Agents attach only to the running instance: `cweb.sh <client> connect` picks it (exit 6 `choose` when several run), and `connect` never starts or creates one. Status-page actions now need the page's own `Origin`. `Invoke-CWeb` needs `-Instance`. |
| 2026.10.26.016 | `Update-CWeb.cmd`: asks before stopping running instances (`-Yes` to skip), stops them cleanly, pulls, runs setup, restarts what was running. README **Update** section. Location-agnostic: setup installs the cweb skill with this machine's CWeb folder filled in (`-Uninstall` removes it), and the docs no longer assume `C:\CWeb`. |
| 2026.10.26.015 | Data folder default moved from `%LOCALAPPDATA%\CWeb` to `%USERPROFILE%\CWebData`: the Claude desktop app (MSIX) redirects AppData, so agents and the server saw different folders. Old folder still used until `Setup-CWeb.cmd` moves it. |
| 2026.10.26.014 | Settings file `<data folder>\config.json`: custom port per instance, `portFallback` (next free port when one is taken), `firstPort`. Clients find a moved server through `server.json`. Setup's location note fixed. |
| 2026.10.26.013 | First public release. |
