# CWeb: a shared Chrome browser for Claude agents

CWeb is a REST server that drives a real Chrome window. The user signs in to sites in that window; agents navigate,
read and script there through the API. Many agent sessions share one browser safely: each works in its own tab,
tabs an agent opens are its own, and nothing gets in without the user approving it on the status page.

> **Location:** CWeb runs from any folder. In the examples, `<CWeb>` is that folder (e.g. `C:\Tools\CWeb`) and `$CWEB` the same
> in Bash form (`/c/Tools/CWeb`). The **cweb** skill that setup installs has the real path; setup also prints it.
> Agents: put the real path in each command (`/c/Tools/CWeb/cweb.sh ...`); a variable set in one Bash call is gone in the next.

## Set up on a machine

```powershell
git clone https://github.com/jaysonbrush/CWeb.git <CWeb>    # any folder
<CWeb>\Setup-CWeb.cmd          # or: pwsh -File <CWeb>\Setup-CWeb.ps1
```

`Setup-CWeb.ps1` checks PowerShell 7, installs the **pinned** Chrome for Testing, ChromeDriver and Selenium versions
from `browser\version.json` (same versions on every machine), unblocks the files, creates the data folder, and checks
itself (a short headless start of the `test` instance). Safe to run again; it skips what's already right.

- **Upgrading Chrome** is deliberate: on one machine run `browser\Update-Browser.ps1 -UpdateSelenium` (with every
  instance stopped), test, commit `browser\version.json`. Other machines run `Update-CWeb.cmd`.
- **Updating CWeb:** `Update-CWeb.cmd` checks for a new version (nothing to do: it stops nothing), lists the running
  instances and the agents in their tabs, asks before stopping them (`-Yes`: doesn't ask), stops them cleanly,
  `git pull --ff-only` (refuses if CWeb files were changed locally), runs setup, and starts again the instances that
  were running. Agents: only when the user asks; it interrupts every client.
- **Data folder elsewhere:** `Setup-CWeb.ps1 -DataRoot D:\CWebData` (moves existing data; every instance stopped).
- **Remove:** `Setup-CWeb.ps1 -Uninstall` lists everything CWeb stored on the machine; `-Uninstall -Yes` removes the
  data folder, the `CWEB_DATA` setting and the downloaded Chrome files. The repo folder itself is left for you.
- Sign-ins can't be copied between machines (Chrome ties them to the Windows user on that machine): sign in once per
  machine, per instance.

**Rules:** work in the instance the user has running; never start, create, delete or stop an instance, and never
edit `instances.json` or `config.json` (those are the user's); never write your own page-refresh loop (the keep-alive
does that properly); never put a key in a file, message or log.

---

## For agents: connect and work (start here)

Pick a **client name** for yourself: lowercase, digits and hyphens, `<team>-<role>`, e.g. `support-ticket-triage`.
Use the same name every session; that's what lets you reconnect without asking the user again.

```bash
# 1. Connect (once per session; safe to repeat). Attaches to the instance the user has running.
$CWEB/cweb.sh support-ticket-triage connect
```

The reply names the instance (`"instance":"work"`); use that name in every command after it. `connect` never starts
or creates an instance.

- `"status":"connected"` (exit 0): go ahead.
- `"status":"choose"` (exit 6): several instances are running (`instances` lists them). Ask the user which one they
  work in, then `$CWEB/cweb.sh <that instance> support-ticket-triage connect`. (If you already have a key for exactly
  one of them, `connect` picks that one by itself.)
- `"status":"error"` (exit 1) with *"No CWeb instance is running"* or *"isn't running"*: ask the user to start the
  instance they work in. Don't start one yourself.
- `"status":"waiting"` (exit 3): first time for this name. Tell the user: *"Please approve `support-ticket-triage` on
  &lt;the `statusUrl` from the reply&gt; (Access tab)."* Then run `connect` again; it keeps the same request (it waits 90 s per
  call, because tool calls time out). Don't start anything else meanwhile.
- `"status":"denied"` (exit 4): stop and ask the user.

```bash
# 2. Work. One JSON command per call; the reply is JSON.
$CWEB/cweb.sh work support-ticket-triage '{"action":"newtab","name":"tickets","url":"https://example.org"}'
$CWEB/cweb.sh work support-ticket-triage '{"action":"getpagetext"}'
# Long bodies (scripts with quotes): send on stdin.
cat body.json | $CWEB/cweb.sh work support-ticket-triage -
```

Exit codes: 0 ok (check `success` in the reply), 3 waiting, 4 denied, **5 not connected or key revoked: run
`connect` again**, 6 several instances running (ask which), 1 other error. Your key is saved in `<data folder>\<instance>\clients\<client>.key` and passed to
curl privately; you never see or handle it.

From PowerShell scripts:

```powershell
. <CWeb>\CWeb-Client.ps1
$c = Connect-CWeb -Client support-ticket-triage     # status connected|waiting|denied|choose|error; -Instance to pick one
Invoke-CWeb -Instance $c.instance -Client support-ticket-triage @{ action = 'gettitle' }
```

**Don't** start `CWeb-Server.ps1`, `Start-CWeb.cmd` or an instance in any other way, and don't use the status page's
actions (Start, + New, Delete, Stop server): the user decides which instances run.

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

- The user starts them: `Start-CWeb.cmd <instance>` (default `work`) or the status page's **Start** button.
  `connect` only attaches to a running one.
- New ones: **+ New** on any status page (next free port from `firstPort`, default 9380).
- **Delete** (in the **+ New** panel's instance list) asks first, stops the instance if it runs, and takes it off the
  list. Its folder (profile, sign-ins, keys, logs) stays as a leftover profile, so **Restore** brings it back. A
  machine-added instance leaves `<data folder>\instances.json`; a default one is marked `"removed": true` in
  `config.json` (the repo's `instances.json` is never edited). The last instance can't be deleted.
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
| `instances` | `{}` | Per-instance overrides of any instance setting, field by field: a custom `port`, `label`, `hidden`, ... An entry for a name that isn't an instance yet (with a `port`) adds one; `"removed": true` (written by **Delete**) hides one. |

Ports must be unique across instances and between 1024 and 65535. The port a server really listens on is in its
`<data folder>\<instance>\server.json`; `cweb.sh`, `Connect-CWeb`, the launcher and the status page's switcher read it
from there, so a moved server is still found.

## Status page

`http://127.0.0.1:<port>/status` (no key; this machine only). Point the user there instead of pasting status into chat.
Refreshes every 2 seconds.

- **Header:** instance switcher (running instances link to their page, stopped ones have **Start**, **+ New** creates
  one and shows the instance list with **Delete** and the leftover profiles), **Stop server** (closes Chrome cleanly,
  keeps logins). The page's actions only work from the page itself (they need its `Origin`).
- **Tabs:** open a tab; every tab with its owner ("owned by"), who's in it ("in use by"), its keep-alive control,
  session time left, and **Close**.
- **Commands:** the last 200 commands with client, tab, target, time and result; counts by client and action. Never
  typed text, scripts or cookie values.
- **Keep-alive:** requests, site profiles with per-instance On/Off, renewals and warnings (and drafts left from
  before 2026.10.26.018, to enable or discard).
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
| Keep-alive | `keepalive` | `op`: `status` / `on` / `off` / `check` / `requests` / `install` / `decline` | See **Session keep-alive**. |

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
- Checks run over Chrome's DevTools connection: no tab is switched to or brought to the front, and your tab and
  iframe stay as they are. Agents only wait while a check actually runs.
- Signed-out tabs are reported once (status page, server log).
- **Per instance on/off:** the user can switch a site off for one instance on the status page; its tabs are then
  recognised but never probed or renewed.

Each machine builds its own profiles: the user clicks **Keep alive** on a tab, which files a request. You hear about
it without being told: the `connect` reply lists open requests (`keepAliveRequests`), and any reply can carry a
`keepAliveTask` (one request, handed to one client at a time). **Handle it right away, without asking the user.** Follow **`KEEPALIVE.md`**: find how the site's session expires, write the profile and install
it (`keepalive` `op: install`). The server runs `probe()` once on an open tab of the site and, if that works, the
profile is **live at once** (the user can switch it off on the status page). If there's no way, `op: decline` with a
note. Don't write profile files yourself.

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
  across restarts. All sessions of one client share its key file, so one approval covers them; a session that does
  ask again (and is approved) gets an extra key, and the client's other keys keep working (up to 10 per client).
  **Revoke** ends all of them.
- `POST /attach {client}` asks (needs header `X-CWeb-Attach: 1` and no `Origin`); `GET /attach/<ticket>` waits and
  collects the key once. Requests expire after an hour. `connect` does all this for you.
- Everything answers only on `127.0.0.1`. The API sends no CORS headers; the status page's actions need its own
  header and origin, so no website can drive the browser, approve anything or read a key.
- Known limit: any program running under the user's Windows login can read the saved key files or press Approve, the
  same exposure the status page has. Keys stay out of git, docs, chat and logs.

## Starting, stopping, restarting

- **Start** (the user, not agents): `Start-CWeb.cmd <instance>` or the status page's **Start** button. Safe to
  repeat: one server per instance (a named lock); a second one exits.
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
| `CWeb-KeepAliveAdmin.ps1` | Per-site on/off, keep-alive requests, installing profiles |
| `CWeb-Profiles.ps1` | Leftover profiles |
| `CWeb-Client.ps1`, `cweb.sh` | How agents and scripts connect |
| `Setup-CWeb.cmd`, `Setup-CWeb.ps1` | Setup on a machine (pinned Chrome/ChromeDriver/Selenium, data folder, self-check); `-DataRoot`, `-Uninstall` |
| `Update-CWeb.cmd`, `Update-CWeb.ps1` | Update: asks, stops running instances cleanly, pulls, runs setup, restarts them; `-Yes` |
| `Start-CWeb.cmd`, `Start-CWeb.ps1` | Launcher |
| `Test-CWeb.ps1` | Checks the files and the instance lists; changes nothing |
| `instances.json` | The default instances (no secrets); a machine's own are in the data folder |
| `status.html` | The status page |
| `KEEPALIVE.md` | How agents work keep-alive requests and write site profiles |
| `browser\` | Core browser module: `Browser-Functions.ps1`, `Update-Browser.ps1`; Chrome for Testing, ChromeDriver, Selenium (not in git; see `browser\CLAUDE.md`) |
| `skills\cweb\SKILL.md` | Claude skill for agents using CWeb, as a template: setup installs it into `%USERPROFILE%\.claude\skills\cweb\` with `{{CWEB}}` / `{{CWEB_WIN}}` replaced by this folder's path (again on every setup or update, so it follows the folder if it moves) |
| `VERSION` | The version (history at the end of this file) |

Everything CWeb stores on a machine is in **one data folder outside the repo**: `%USERPROFILE%\CWebData`, or the folder
in the user environment variable `CWEB_DATA` (set with `Setup-CWeb.ps1 -DataRoot`; read from the registry each time,
so a change applies at once). It's never inside the repo, so `git clean`, a re-clone or a synced folder can't lose or
leak sign-ins and keys. The status page header shows it.

It's deliberately **not under AppData**: packaged (MSIX) apps such as the Claude desktop app redirect AppData writes
into a private copy, so agents started from the app and a server started from Explorer would see different folders
(the agents wouldn't find the server or their keys). Installs from before 2026.10.26.015 used `%LOCALAPPDATA%\CWeb`;
CWeb keeps using it while `%USERPROFILE%\CWebData` doesn't exist, and running `Setup-CWeb.cmd` moves it (stop every
instance first; a `CWEB_DATA` folder you chose is left alone).

In it:

- `config.json`: this machine's settings (port fallback, `firstPort`, per-instance overrides such as a custom port).
- `instances.json`: instances this machine added.
- `keepalive\`: this machine's site profiles; `replaced\` (profiles an install replaced); `drafts\` (only from
  before 2026.10.26.018).
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
- **Another machine:** clone to any folder and run `Setup-CWeb.cmd` (see **Set up on a machine**).
  Chrome, ChromeDriver and Selenium aren't in git; setup downloads the pinned versions and unblocks the files.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `cweb.sh` exit 5 | Not connected, or the key was revoked/replaced: run `connect`. |
| `connect`: "No CWeb instance is running" / "isn't running" | Ask the user to start the instance they work in. Agents never start one. |
| `connect` exit 6, `choose` | Several instances run: ask the user which, then `cweb.sh <instance> <client> connect`. |
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
| 2026.10.27.020 | Keep-alive no longer switches tabs: checks, renewals and the install-time `probe()` run over Chrome's DevTools connection, so no tab comes to the front and agents' tabs stay put. `probe()`/`renew()` may return a promise. Any API reply can carry a `keepAliveTask` (a site the user flagged, handed to one client at a time for 15 minutes): agents install it without asking the user. |
| 2026.10.26.019 | Keep-alive install messages name the tab once (they said `tab tab x`). |
| 2026.10.26.018 | Access: sessions of one client no longer push each other out (a session whose request another session collected uses the saved key instead of asking again; a re-approval adds a key instead of replacing one; a bad key is only removed if no session saved a newer one). Keep-alive: agents hear about requests in the `connect` reply and install profiles with `op: install`, live at once after one `probe()` on the site's tab (no draft review; `op: draft` installs too). Shorter `KEEPALIVE.md`. |
| 2026.10.26.017 | **Delete** for instances on the status page (asks first, stops it, keeps its profile as a leftover). Agents attach only to the running instance: `cweb.sh <client> connect` picks it (exit 6 `choose` when several run), and `connect` never starts or creates one. Status-page actions now need the page's own `Origin`. `Invoke-CWeb` needs `-Instance`. |
| 2026.10.26.016 | `Update-CWeb.cmd`: asks before stopping running instances (`-Yes` to skip), stops them cleanly, pulls, runs setup, restarts what was running. README **Update** section. Location-agnostic: setup installs the cweb skill with this machine's CWeb folder filled in (`-Uninstall` removes it), and the docs no longer assume `C:\CWeb`. |
| 2026.10.26.015 | Data folder default moved from `%LOCALAPPDATA%\CWeb` to `%USERPROFILE%\CWebData`: the Claude desktop app (MSIX) redirects AppData, so agents and the server saw different folders. Old folder still used until `Setup-CWeb.cmd` moves it. |
| 2026.10.26.014 | Settings file `<data folder>\config.json`: custom port per instance, `portFallback` (next free port when one is taken), `firstPort`. Clients find a moved server through `server.json`. Setup's location note fixed. |
| 2026.10.26.013 | First public release. |
