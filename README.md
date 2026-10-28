# CWeb

A shared Chrome browser for Claude agents. You sign in to sites in a CWeb Chrome window once; every Claude session and
script on your machine can then use it with one command. It starts itself, reopens Chrome if it closes, and keeps the
sites you flag signed in.

Agents: read [`claude.md`](claude.md); it also holds the version history.

## Set up

Needs 64-bit Windows 10/11 and PowerShell 7 (`winget install --id Microsoft.PowerShell --source winget`).

```powershell
git clone https://github.com/jaysonbrush/CWeb.git    # into any folder
.\CWeb\Setup-CWeb.cmd
```

Setup downloads the pinned Chrome for Testing, ChromeDriver and Selenium (the versions in `browser\version.json`, the
same on every machine), creates the data folder and checks itself. Run it again any time; it only fixes what's
missing. CWeb runs from any folder (yours, Downloads, anywhere); setup prints the paths for your machine and installs the **cweb** Claude skill with them, so agents find it on their own.

- **Where your data lives:** one folder outside the repo, `%USERPROFILE%\CWebData` (profiles and sign-ins, the API key,
  keep-alive scripts, logs). `Setup-CWeb.ps1 -DataRoot D:\CWebData` moves it. Never inside the repo, so git can't
  delete or upload it, and not under AppData, which the Claude desktop app redirects.
- **Remove everything:** `Setup-CWeb.ps1 -Uninstall` lists what CWeb stored; `-Uninstall -Yes` removes it.
- **New Chrome version:** run `browser\Update-Browser.ps1 -UpdateSelenium` on one machine, test, commit
  `browser\version.json`; the other machines run `Update-CWeb.cmd`.

## Update

Double-click `Update-CWeb.cmd` in the CWeb folder. It:

1. Checks for a new version. If there's none, it stops nothing and exits.
2. Lists the running instances and **asks before stopping them**: stopping closes
   their Chrome windows (sign-ins and open tabs come back when they restart) and interrupts those agents.
3. Stops them cleanly, pulls the new version (`git pull --ff-only`: it never overwrites changes you made here),
   runs setup (new Chrome if the pin changed, data moves, self-check), and starts again the instances that were
   running.

`Update-CWeb.cmd -Yes` does the same without asking, for scripts. What changed in each version is at the end of
[`claude.md`](claude.md).

- **First update from 2026.10.26.015 or earlier:** those versions don't have `Update-CWeb.cmd` yet. Stop every
  instance (status page: **Stop server**), run `git pull`, then `Setup-CWeb.cmd`. From then on, use
  `Update-CWeb.cmd`.
- **From 2026.10.26.014 or earlier**, setup also moves the data from the old `%LOCALAPPDATA%\CWeb` to
  `%USERPROFILE%\CWebData` (sign-ins, keys and approvals come along).
- **Installed from a zip, not git:** download the new version over the folder, then run `Setup-CWeb.cmd`.

## Use it

1. **Sign in once:** double-click `Start-CWeb.cmd` (or let any agent start it). A Chrome window titled **CWeb Work**
   opens. Sign in to the sites you need.
2. **That's it.** Agents use it with `cweb.sh '<json>'`. If CWeb isn't running, that starts it; if Chrome was closed
   or crashed, it reopens with your tabs. Nothing to approve or connect.
3. **Status page:** http://127.0.0.1:9380/status shows the sites kept signed in, the open tabs and what agents did.

## Staying signed in

Tell any Claude session *"keep <site> alive"*. It works out how the site's session expires and writes a short script;
CWeb tests it on the live site, saves it and from then on keeps the site signed in by itself, in its own background
tab. If a site signs you out anyway, it shows red on the status page: sign in on its tab again.

Keep-alive scripts stay on this machine (never in git). To use one on another machine: **Copy** on this status page,
**Add** on the other's.

## Instances

`work` (9380) is the default. `personal` (9390) is a separate Chrome profile with its own sign-ins, used only when you
tell an agent to. Each keeps its profile and logs in `<data folder>\<instance>\`. Sign-ins don't move between
machines: sign in once on each.

## Settings and ports

`<data folder>\config.json` holds this machine's settings (setup creates it with the defaults):

```json
{
  "portFallback": true,
  "instances": { "work": { "port": 9480 } }
}
```

- **Custom port:** add the instance under `instances` with its `port`, then restart it.
- **Port already in use:** with `portFallback` on (the default), CWeb moves to the next free port and tells you
  (launcher and status page). Agents still find it. Turn it off to have CWeb refuse to start instead.
Details: the **Settings** section of [`claude.md`](claude.md).

## Security

- Only this machine can reach CWeb, and only programs running as you: the API needs the key in
  `<data folder>\cweb.key`, which only your Windows user can read. `cweb.sh` passes it on its own; it never appears in
  commands, output or logs.
- Websites can't drive CWeb or read anything from it.

## Files

See the **Files and data** section of [`claude.md`](claude.md). The Claude skill for agents (`skills\cweb\`) is installed by
setup into `%USERPROFILE%\.claude\skills\cweb\`, with this machine's CWeb folder filled in.
