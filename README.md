# CWeb

A shared Chrome browser for Claude agents. You sign in to sites in a CWeb Chrome window; agents work in it through a
local API, each in its own tab, and only after you've approved them.

Agents: read [`claude.md`](claude.md); it also holds the version history.

## Set up

Needs 64-bit Windows 10/11 and PowerShell 7 (`winget install --id Microsoft.PowerShell --source winget`).

```powershell
git clone <CWeb repo> C:\CWeb
C:\CWeb\Setup-CWeb.cmd
```

Setup downloads the pinned Chrome for Testing, ChromeDriver and Selenium (the versions in `browser\version.json`, the
same on every machine), creates the data folder and checks itself. Run it again any time; it only fixes what's
missing. The examples use `C:\CWeb`; CWeb runs from any folder, and setup prints the exact paths for your machine.

- **Where your data lives:** one folder outside the repo, `%USERPROFILE%\CWebData` (profiles and sign-ins, agent keys,
  logs, instances you added). `Setup-CWeb.ps1 -DataRoot D:\CWebData` moves it. Never inside the repo, so git can't
  delete or upload it, and not under AppData, which the Claude desktop app redirects.
- **Upgrading from 2026.10.26.014 or earlier:** those kept the data in `%LOCALAPPDATA%\CWeb`. Stop every instance,
  `git pull`, and run `Setup-CWeb.cmd` again: it moves the data (sign-ins, keys, approvals) to the new folder.
- **Remove everything:** `Setup-CWeb.ps1 -Uninstall` lists what CWeb stored; `-Uninstall -Yes` removes it.
- **New Chrome version:** run `browser\Update-Browser.ps1 -UpdateSelenium` on one machine, test, commit
  `browser\version.json`; the other machines pull and run setup.

## Use it

1. **Start an instance:** double-click `Start-CWeb.cmd` (the `work` instance), or run `Start-CWeb.cmd personal`.
   A Chrome window titled **CWeb Work** opens. Sign in to the sites you need.
2. **Open the status page:** http://127.0.0.1:9380/status (each instance has its own port; the page links them, and
   the launcher prints the address).
3. **Approve agents:** an agent connects with `cweb.sh work <its-name> connect`. Its request shows as a banner on the
   status page; **Approve** it on the **Access** tab. It keeps working (and reconnecting in later sessions) until you
   **Revoke** it.

That's all. Agents can't start a second server, can't use another instance without a separate approval, and can't
change a tab another agent opened.

## The status page

- **Instances:** switch between instances, **Start** a stopped one, **+ New** to create one (its own Chrome profile:
  you sign in separately). The New panel also lists **leftover profiles** of removed instances (Restore or Delete).
- **Tabs:** every tab, who owns it, who's working in it, how long its session has left, and its keep-alive control.
- **Commands:** what every agent did, and when.
- **Keep-alive:** turn a site's keep-alive on or off for this instance; review agent-written **drafts** (View source,
  **Enable**, **Discard**); see requests.
- **Access:** approve or deny agents; revoke approved ones.
- **Stop server:** closes the Chrome window (sign-ins are kept) and stops the server.

## Staying signed in

CWeb ships with no site profiles. To stay signed in to a site,
click **Keep alive** on its tab, then ask an agent to *"work the CWeb keep-alive requests"*. It writes a profile as a
**draft**; nothing runs until you click **Enable** on the Keep-alive tab.

## Instances

Defaults in `instances.json`: `work` (9380), `personal` (9390), `test` (9399, headless, for testing CWeb). Instances
you add with **+ New** are kept in the data folder, not the repo, so each machine can have its own without git changes.
Each instance keeps its profile, logs and keys in `<data folder>\<instance>\`. Sign-ins don't move between machines:
sign in once on each.

## Settings and ports

`<data folder>\config.json` holds this machine's settings (setup creates it with the defaults):

```json
{
  "portFallback": true,
  "firstPort": 9380,
  "instances": { "work": { "port": 9480 } }
}
```

- **Custom port:** add the instance under `instances` with its `port`, then restart it.
- **Port already in use:** with `portFallback` on (the default), CWeb moves to the next free port and tells you
  (launcher and status page). Agents still find it. Turn it off to have CWeb refuse to start instead.
- **`firstPort`:** where **+ New** starts looking for a free port.

Details: the **Settings** section of [`claude.md`](claude.md).

## Security

- Only this machine can reach CWeb; websites can't drive it or read anything from it.
- Every agent needs your approval; each gets its own key, stored by CWeb only as a fingerprint. Keys never go into
  git, docs, chat or logs.
- Agents never type passwords. You sign in yourself.

## Files

See the **Files and data** section of [`claude.md`](claude.md). A Claude skill for agents is in `skills\cweb\` (copy that folder into a Claude skills folder).
