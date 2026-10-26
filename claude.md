# CWeb: a shared Chrome browser for Claude agents

CWeb is a REST server that drives a real Chrome window. The user signs in to sites in that window; agents navigate,
read and script there through the API. Many agent sessions share one browser safely: each works in its own tab,
tabs an agent opens are its own, and nothing gets in without the user approving it on the status page.

> **Location:** the examples use `C:\CWeb`. CWeb runs from any folder; `Setup-CWeb` prints the exact paths for your machine.

## Set up on a machine

```powershell
git clone <CWeb repo> C:\CWeb
C:\CWeb\Setup-CWeb.cmd          # or: pwsh -File C:\CWeb\Setup-CWeb.ps1
```

`Setup-CWeb.ps1` checks PowerShell 7, installs the **pinned** Chrome for Testing, ChromeDriver and Selenium versions
from `browser\version.json` (same versions on every machine), unblocks the files, creates the data folder, and checks
itself (a short headless start of the `test` instance). Safe to run again; it skips what's already right.

- **Upgrading Chrome** is deliberate: on one machine run `browser\Update-Browser.ps1 -UpdateSelenium` (with every
  instance stopped), test, commit `browser\version.json`. Other machines `git pull` and run setup again.
- **Data folder elsewhere:** `Setup-CWeb.ps1 -DataRoot D:\CWebData` (moves existing data; every instance stopped).
- **Remove:** `Setup-CWeb.ps1 -Uninstall` lists everything CWeb stored on the machine; `-Uninstall -Yes` removes the
  data folder, the `CWEB_DATA` setting and the downloaded Chrome files. The repo folder itself is left for you.
- Sign-ins can't be copied between machines (Chrome ties them to the Windows user on that machine): sign in once per
  machine, per instance.

**Rules:** never type a password or a one-time code (the user signs in themselves); never write your own page-refresh loop
(the keep-alive does that properly); never put a key in a file, message or log.

---

## For agents: connect and work (start here)

Pick a **client name** for yourself: lowercase, digits and hyphens, `<team>-<role>`, e.g. `support-ticket-triage`.
Use the same name every session; that's what lets you reconnect without asking the user again.

```bash
# 1. Connect (once per session; safe to repeat). Starts the instance if it's down.
/c/CWeb/cweb.sh work support-ticket-triage connect
```

- `"status":"connected"` (exit 0): go ahead.
- `"status":"waiting"` (exit 3): first time for this name. Tell the user: *"Please approve `support-ticket-triage` on
  &lt;the `statusUrl` from the reply&gt; (Access tab)."* Then run `connect` again; it keeps the same request (it waits 90 s per
  call, because tool calls time out). Don't start anything else meanwhile.
- `"status":"denied"` (exit 4): stop and ask the user.

```bash
# 2. Work. One JSON command per call; the reply is JSON.
/c/CWeb/cweb.sh work support-ticket-triage '{"action":"newtab","name":"tickets","url":"https://example.org"}'
/c/CWeb/cweb.sh work support-ticket-triage '{"action":"getpagetext"}'
# Long bodies (scripts with quotes): send on stdin.
cat body.json | /c/CWeb/cweb.sh work support-ticket-triage -
```

Exit codes: 0 ok (check `success` in the reply), 3 waiting, 4 denied, **5 not connected or key revoked: run
`connect` again**, 1 other error. Your key is saved in `<data folder>\<instance>\clients\<client>.key` and passed to
curl privately; you never see or handle it.

From PowerShell scripts:

```powershell
. C:\CWeb\CWeb-Client.ps1
Connect-CWeb -Instance work -Client support-ticket-triage          # returns status connected|waiting|denied|error
Invoke-CWeb  -Instance work -Client support-ticket-triage @{ action = 'gettitle' }
```

**Don't** start `CWeb-Server.ps1` yourself or as a background job of your session; `connect` (or `Start-CWeb.cmd`)
starts it in its own hidden window so it outlives you.

## Sharing one browser

Commands run one at a time across all clients; the server keeps each client's place between them.

- **Your tab.** Every command runs in *your* current tab: the one you opened with `newtab` or chose with
  `switchtab`. Before your first choice, you get the tab in front unless another client owns it.
- **`tab` on any command** runs that one command in another tab (`{"action":"gettitle","tab":"mail"}`) without
  changing your current tab.
- **Ownership.** A tab you open with `newtab` is yours. Others can **read** it (titles, text, elements, cookies) but
  can't navigate, click, type, hover, scroll, run scripts, set cookies, handle alerts or close it in your tab: they get
  *"Tab 'x' belongs to …"*. `releasetab` makes your tab shared again. Tabs the user opens by hand are shared.
  **Open your own tab for your work**; read the user's tabs with `tab` and ask before changing them.
- **Iframes.** Your `switchtoframe` position is remembered per tab, for you only, and restored before your next
  command (also after keep-alive passes). Navigating resets it.
- **Closed tabs.** If your tab is closed (by you, the user on the status page, or anyone), your next command fails with
  *"Your tab was closed"*. Run `listtabs`, then `switchtab`. You're never moved silently.
- **Background tabs run at full speed** (Chrome's background throttling is off), so you can work in a tab that isn't
  in front. Switching tabs does bring the tab to the front for a moment.
- **Keep waits short.** A 30 s `waitforelement` holds up every other client for 30 s. Prefer short timeouts and retry.
- Replies carry `tab` (the tab the command ran in). `listtabs` returns `tabs` (names) and `details`
  (`name`, `owner`, `mine`, `url`).

## Instances

Each instance is a separate browser: its own Chrome profile and sign-ins, port, keys, approvals and status page.
The defaults are in `instances.json` in this folder (in git, no secrets). Instances a machine adds (**+ New**) go in
`<data folder>\instances.json`, never the repo's, so they don't show up as git changes. Both lists, and the
`instances` section of `<data folder>\config.json` (see **Settings**), are merged field by field; a machine's own
entry wins over a default of the same name.

| Instance | Port | Notes |
|---|---|---|
| `work` | 9380 | The main instance (default for `Start-CWeb.cmd` and the docs) |
| `personal` | 9390 | |
| `test` | 9399 | Headless; for testing CWeb itself |

- Start one: `Start-CWeb.cmd <instance>` (default `work`), the status page's **Start** button, or `connect`.
- New ones: **+ New** on any status page (next free port from `firstPort`, default 9380).
- A client approved on one instance has no access to another. Connect to each separately.
- Optional per-instance settings: `label`, `startUrl`, `hidden` (headless), `showServerWindow`, `keepAlive`
  (`enabled`, `tickSeconds`, `maxCheckSeconds`).
- `scripts` is reserved (standalone scripts use `<data folder>\scripts`).
- The ports above are the configured ones. A running server may be on another (see **Settings**); `connect` replies
  with the real `statusUrl`, and the status page header shows the port.

## Settings

`<data folder>\config.json`: this machine's settings, edited by hand (setup writes the defaults; never in git).
Changes apply the next time an instance starts.

```json
{
  "portFallback": true,
  "firstPort": 9380,
  "instances": { "work": { "port": 9480 } }
}
```

| Setting | Default | What |
|---|---|---|
| `portFallback` | `true` | If another program holds an instance's port, the server takes the next free port (up to 100 higher) that no instance is configured for, and says so in its log, the launcher and the status page header. `false`: it doesn't start, and the server log says which port is taken. |
| `firstPort` | `9380` | Where **+ New** starts looking for a free port. |
| `instances` | `{}` | Per-instance overrides of any instance setting, field by field: a custom `port`, `label`, `hidden`, ... An entry for a name that isn't an instance yet (with a `port`) adds one. |

Ports must be unique across instances and between 1024 and 65535. The port a server really listens on is in its
`<data folder>\<instance>\server.json`; `cweb.sh`, `Connect-CWeb`, the launcher and the status page's switcher read it
from there, so a moved server is still found.

## Status page

`http://127.0.0.1:<port>/status` (no key; this machine only). Point the user there instead of pasting status into chat.
Refreshes every 2 seconds.

- **Header:** instance switcher (running instances link to their page, stopped ones have **Start**, **+ New** creates
  one and shows leftover profiles), **Stop server** (closes Chrome cleanly, keeps logins).
- **Tabs:** open a tab; every tab with its owner ("owned by"), who's in it ("in use by"), its keep-alive control,
  session time left, and **Close**.
- **Commands:** the last 200 commands with client, tab, target, time and result; counts by client and action. Never
  typed text, scripts or cookie values.
- **Keep-alive:** drafts waiting for review, requests, site profiles with per-instance On/Off, renewals and warnings.
- **Access:** requests waiting for approval (**Approve** / **Deny**; a banner shows on every tab while anyone waits)
  and approved clients with last use and **Revoke**.

## API

`POST http://127.0.0.1:<port>/api`, header `X-API-Key: <client key>`, JSON body with `action`. Use `cweb.sh` /
`Invoke-CWeb` rather than building requests by hand. Every action except the browser/tab ones below takes `tab`.

| Group | Action | Parameters | Notes |
|---|---|---|---|
| Browser | `start` | `hidden`, `persist` (default true), `stealth` (default true) | The server opens Chrome itself on launch; only needed after `stop`. Always the instance's profile. |
| | `stop` | | Closes Chrome for everyone. Ask the user first. |
| | `status` | | Version, browser state, your tab's URL and title. |
| Navigation | `navigate` | `url` | Waits for the load. |
| | `back` / `forward` / `refresh` | | |
| Page | `gettitle` / `geturl` / `getpagesource` | | |
| | `getpagetext` | `by`, `value` (optional) | Visible text of the page or an element. |
| | `screenshot` | `filePath` | |
| | `getalllinks` / `getallforms` | | |
| Tabs | `newtab` | `url`, `name` (optional) | You own it; it becomes your tab. Unnamed tabs are named after their site. |
| | `switchtab` | `name` | Changes your current tab. |
| | `closetab` | | Closes your tab (or `tab`), if you may write to it. |
| | `listtabs` | | `tabs` + `details`. Names any tab seen for the first time. |
| | `releasetab` | `tab` (optional) | Makes your tab shared. |
| Elements | `findelement` / `findelements` | `by`, `value` | |
| | `click` | `by`, `value`, `timeout` (default 5) | Scrolls into view, retries while covered or not ready. |
| | `sendkeys` | `by`, `value`, `text`, `clear` | |
| | `gettext` / `getattribute` (`attribute`) / `getelementhtml` / `getelementinfo` | `by`, `value` | |
| | `hover` | `by`, `value` | |
| | `selectoption` | `by`, `value`, `selectBy` (Text/Value/Index), `option` | Fires `input` + `change`. |
| | `scroll` | `direction` (Up/Down/Top/Bottom/ToElement), `pixels`, `by`, `value` | |
| Frames | `switchtoframe` | `frameId` / `frameName` / `frameIndex` / `default: true` | Remembered per tab, per client. |
| Waiting | `wait` | `timeout` (30) | Page load. |
| | `waitforelement` | `by`, `value`, `timeout` (30), `visible` | Keep short (see above). |
| | `waitforurl` | `contains` / `matches` / `changed`, `timeout` | |
| Script | `executescript` | `script`, `arguments` | `return` a value; it comes back in `result`. |
| Alerts | `acceptalert` (`promptText`) / `dismissalert` / `getalerttext` | | |
| Cookies | `getcookies` (`name`) / `setcookie` (`name`, `value`, `domain`, `path`) / `deletecookie` (`name`) | | |
| Window | `getwindowsize` / `setwindowsize` (`width`, `height`) / `maximize` | | Affects everyone's window. |
| Keep-alive | `keepalive` | `op`: `status` / `on` / `off` / `check` / `requests` / `drafts` / `draft` / `decline` | See **Session keep-alive**. |

Locators (`by`): `Id`, `Name`, `ClassName`, `TagName`, `CssSelector`, `XPath`, `LinkText`, `PartialLinkText`.

**Escaping:** for anything with quotes (scripts), build the body in a file or in PowerShell (`ConvertTo-Json`) and
send it on stdin (`cweb.sh … -`) or with `Invoke-CWeb`. Don't fight shell quoting inline.

## Tab names

`switchtab` and `tab` take names. Tabs the user opens, that Chrome restores, or that are opened without a name are named
after their site (`portal.example.org` → `example`; repeats get `-2`, `-3`), on the keep-alive's 30-second pass or
at once on `listtabs`. A name is kept even if the tab navigates elsewhere. When the user says "I opened a tab", run
`listtabs` and check `status` with `tab` to confirm it's the page they mean.

## Session keep-alive

The server keeps the user signed in on every tab whose site has a profile in `<data folder>\keepalive\`, so
sessions don't time out while you work elsewhere. On by default; nothing to start.

- It runs **between** API requests, never during one. Each profile's `probe()` reads the real time left without
  changing anything; only when it's under `@renewBelow` does `renew()` extend the session the site's own way. It
  never reloads a page, so form input and dialogs survive.
- Each tab is checked shortly before it needs renewing, and at least every 10 minutes. Your own activity on a site
  counts; the next probe sees it.
- A check switches to the tab (it comes to the front for a moment), then back. Your tab and iframe are restored before
  your next command.
- Signed-out tabs are reported once (status page, server log). The user signs in again; you never type passwords.
- **Per instance on/off:** the user can switch a site off for one instance on the status page; its tabs are then
  recognised but never probed or renewed.

**CWeb ships with no site profiles.** Each machine builds its own: the user clicks **Keep alive** on a tab, which
files a request. When they ask you to "work the CWeb keep-alive requests", follow **`KEEPALIVE.md`**: study the site
read-only, prove a renewal works, and submit a **draft** (`keepalive` `op: draft`). Drafts sit in
`<data folder>\keepalive\drafts\` and never run until the user clicks **Enable**, which moves the draft into
`<data folder>\keepalive\`. If there's no safe way, `op: decline` with a note. Don't write profile files yourself.

Profile format, for reference:

```js
// @name        Example Portal
// @match       ^https://[^/]+\.example\.org/
// @renewBelow  300
// How this site's session expires and why renew() works (keep it short).
var site = {
    probe: function () { /* read only: { loggedOut: true } or { loggedOut: false, remaining: <seconds> } */ },
    renew: function () { /* extend without reloading; return a short description */ }
};
```

`@match` names the vendor's domain pattern, never a customer's host, and also matches the signed-out page. No
credentials, no customer data.

## Access and security

- Nothing can use an instance's API without a key from the user's **Approve**. Keys are per client, random, handed out
  once, and stored by the server only as SHA-256 fingerprints (`approvals.json`). An approval lasts until **Revoke**,
  across restarts. Asking again with an approved name and being approved replaces the old key.
- `POST /attach {client}` asks (needs header `X-CWeb-Attach: 1` and no `Origin`); `GET /attach/<ticket>` waits and
  collects the key once. Requests expire after an hour. `connect` does all this for you.
- Everything answers only on `127.0.0.1`. The API sends no CORS headers; the status page's actions need its own
  header and origin, so no website can drive the browser, approve anything or read a key.
- Known limit: any program running under the user's Windows login can read the saved key files or press Approve, the
  same exposure the status page has. Keys stay out of git, docs, chat and logs.

## Starting, stopping, restarting

- **Start:** `Start-CWeb.cmd <instance>` (from Bash: `cmd.exe //c start "" "C:\\CWeb\\Start-CWeb.cmd" work`),
  the status page's **Start** button, or `cweb.sh <instance> <client> connect`. Safe to repeat: one server per
  instance (a named lock); a second one exits.
- **Stop:** the status page's **Stop server** (closes Chrome cleanly, logins kept). From a script:
  `curl -s -X POST http://127.0.0.1:<port>/status/stopserver -H "X-Status-Request: 1" -H "Origin: http://127.0.0.1:<port>" -d '{}'`.
  Only when the user asks: it stops the browser for every client.
- **Restart** after changing server code: stop, then start. Chrome may restore its tabs; they're auto-named, so run
  `listtabs` before opening duplicates. Keep-alive profiles and `status.html` are re-read live and need no restart.
  Approvals survive; clients' current tabs and ownership don't (handles change), so clients `switchtab` again.

## Files and data

In this folder (the repo):

| Path | What |
|---|---|
| `CWeb-Server.ps1` | The server: API, status page, keep-alive, tab sharing |
| `CWeb-Common.ps1` | Instance lookup, start helpers, `New-CWebInstance` (shared by server, launcher, client) |
| `CWeb-Access.ps1` | Attach, approve/deny/revoke, keys |
| `CWeb-KeepAliveAdmin.ps1` | Per-site on/off, keep-alive requests, drafts |
| `CWeb-Profiles.ps1` | Leftover profiles |
| `CWeb-Client.ps1`, `cweb.sh` | How agents and scripts connect |
| `Setup-CWeb.cmd`, `Setup-CWeb.ps1` | Setup on a machine (pinned Chrome/ChromeDriver/Selenium, data folder, self-check); `-DataRoot`, `-Uninstall` |
| `Start-CWeb.cmd`, `Start-CWeb.ps1` | Launcher |
| `Test-CWeb.ps1` | Checks the files and the instance lists; changes nothing |
| `instances.json` | The default instances (no secrets); a machine's own are in the data folder |
| `status.html` | The status page |
| `KEEPALIVE.md` | How agents work keep-alive requests and write site profiles |
| `browser\` | Core browser module: `Browser-Functions.ps1`, `Update-Browser.ps1`; Chrome for Testing, ChromeDriver, Selenium (not in git; see `browser\CLAUDE.md`) |
| `skills\cweb\SKILL.md` | Claude skill for agents using CWeb: copy the `cweb` folder into a Claude skills folder (e.g. `%USERPROFILE%\.claude\skills\`) |
| `VERSION` | The version (history at the end of this file) |

Everything CWeb stores on a machine is in **one data folder outside the repo**: `%LOCALAPPDATA%\CWeb`, or the folder
in the user environment variable `CWEB_DATA` (set with `Setup-CWeb.ps1 -DataRoot`; read from the registry each time,
so a change applies at once). It's never inside the repo, so `git clean`, a re-clone or a synced folder can't lose or
leak sign-ins and keys. The status page header shows it. In it:

- `config.json`: this machine's settings (port fallback, `firstPort`, per-instance overrides such as a custom port).
- `instances.json`: instances this machine added.
- `keepalive\`: this machine's site profiles; `drafts\` (waiting for review), `replaced\` (profiles a draft replaced).
- `_deleted\`: deleted leftover profiles, kept 30 days.
- `scripts\`: profiles of standalone scripts using `browser\Browser-Functions.ps1`.
- One folder per instance, `<data folder>\<instance>\`:

| Path | What |
|---|---|
| `profile\` | The Chrome profile (sign-ins). `profile.bak-<time>` after an import. |
| `server.json` | "Here I am": port, process ID, version, start time. No key. |
| `approvals.json` | Approved clients: fingerprints only. |
| `clients\<client>.key` | Keys saved by `connect` (`.ticket` while waiting). |
| `keepalive-sites.json`, `keepalive-requests.json` | Sites switched off here; keep-alive requests. |
| `logs\` | `server-<date>.log` (one line per command: `[time] client action [tab] target ms`), `chromedriver-<date>.log`, `launcher-<date>.log`, `import-*.log`. Kept 7 days. |

CWeb writes nothing outside the data folder and the repo's `browser\` downloads.

## Chrome details

- **Profile self-repair** (before each start): ends leftover automation Chrome holding *exactly* this profile (never
  another tool's or the user's own Chrome); a profile written by a newer Chrome than the bundled one is set aside
  (`.bak-chrome<ver>-<time>`); if Chrome still crashes, the profile is set aside once and restored if a fresh one
  crashes too. Backups older than 30 days are removed.
- **Fingerprint:** `navigator.webdriver` is false and there's no "controlled by automated software" banner; `stealth`
  (default on) patches a few more tells. No CAPTCHA solving: the user handles those.
- **Window title:** `CWeb <label>`, so instances are easy to tell apart.
- **Network drive:** run from a mapped/UNC path, Chrome starts with `--no-sandbox` (it crashes otherwise).
- **Another machine:** clone to `C:\CWeb` and run `Setup-CWeb.cmd` (see **Set up on a machine**).
  Chrome, ChromeDriver and Selenium aren't in git; setup downloads the pinned versions and unblocks the files.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cweb.sh` exit 5 | Not connected, or the key was revoked/replaced: run `connect`. |
| `connect` keeps saying waiting | The user hasn't approved yet; remind them of the Access tab. Requests expire after an hour; `connect` asks again. |
| "Tab 'x' belongs to …" | Open your own tab with `newtab`, or ask the owner/the user. |
| "Your tab was closed" | `listtabs`, then `switchtab`. |
| "No tab named 'x'" | `listtabs`; a tab still on Chrome's new-tab page has no name until it loads a site. |
| Server didn't start | `<data folder>\<instance>\logs\server-<date>.log` and `chromedriver-<date>.log`. Chrome's start error is also on the status page. |
| "Chrome module not found" / Chrome missing | Run `Setup-CWeb.cmd`. |
| Commands are slow | Another client is in a long wait; commands run one at a time. |
| Status page "isn't running" | Start the instance; reload. If its port was taken, it may be on another: the launcher prints the address. |
| "Port … is in use by another program" (server log) | Give the instance another `port` in `<data folder>\config.json`, or set `portFallback` to `true`. |

## CWeb versions

`VERSION` holds the CWeb version (`YYYY.MM.DD.NNN`). **Bump it whenever you change CWeb**, and add a line here.

| Version | Changes |
|---|---|
| 2026.10.26.014 | Settings file `<data folder>\config.json`: custom port per instance, `portFallback` (next free port when one is taken), `firstPort`. Clients find a moved server through `server.json`. Setup's location note fixed. |
| 2026.10.26.013 | First public release. |
