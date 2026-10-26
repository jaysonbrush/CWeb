---
name: cweb
description: Use CWeb, the shared Chrome browser the user is signed in to, to work with websites (navigate, read pages, fill forms, run page scripts). Use when asked to use the browser, CWeb, "activate chrome", or do anything on a website that needs the user's sign-ins.
allowed-tools: Bash, Read, Write
user-invocable: true
---

<!-- Template for the cweb skill: installed by CWeb setup into ~/.claude/skills/cweb/ with the CWeb folder filled in
     ({{CWEB_WIN}}\skills\cweb\SKILL.md). Edit the template; setup replaces the installed copy. -->

# CWeb

CWeb is a REST server that drives a real Chrome window the user signs in to. Several agents share it; each works in its
own tab. Full reference: `{{CWEB_WIN}}\claude.md`. Read it before anything beyond the basics below.
If `cweb.sh` or Chrome is missing on this machine, CWeb isn't set up: ask the user (setup is `Setup-CWeb.cmd`).

## 1. Connect

Pick a client name (`<team>-<role>`, lowercase, e.g. `support-ticket-triage`) and keep it across sessions.

```bash
{{CWEB}}/cweb.sh support-ticket-triage connect
```

It attaches to the instance the user has running. The reply names it (`"instance":"work"`): use that name in every
command below.

- `connected`: carry on.
- `waiting`: ask the user to approve your name at the `statusUrl` in the reply (Access tab), then run `connect` again.
- `denied`: stop and ask the user.
- `choose` (exit 6): several instances are running. Ask the user which one they work in, then
  `{{CWEB}}/cweb.sh <instance> support-ticket-triage connect`.
- `error` with "No CWeb instance is running" or "isn't running": ask the user to start the instance they work in.

Never start, create, delete or stop an instance (no `Start-CWeb.cmd`, no status-page actions), and never edit
`instances.json` or `config.json`: the user decides which instances run.

## 2. Work in your own tab

```bash
cweb={{CWEB}}/cweb.sh
$cweb work support-ticket-triage '{"action":"newtab","name":"tickets","url":"https://example.org"}'
$cweb work support-ticket-triage '{"action":"getpagetext"}'
$cweb work support-ticket-triage '{"action":"click","by":"CssSelector","value":"button[type=submit]"}'
```

- Commands run in **your** tab. Add `"tab":"<name>"` to run one command elsewhere; `listtabs` shows all tabs.
- Tabs others opened are read-only for you. Tabs the user opened are shared: read them, ask before changing them.
- Exit code 5 = not connected or key revoked: run `connect` again.

## 3. Scripts and quotes

Don't fight shell escaping. Build the body in PowerShell and send it on stdin:

```bash
pwsh -NoProfile -Command '@{ action = "executescript"; script = @"
var rows = [];
document.querySelectorAll("table tr").forEach(function (tr) { rows.push(tr.innerText); });
return rows;
"@ } | ConvertTo-Json -Compress' | {{CWEB}}/cweb.sh work support-ticket-triage -
```

`executescript` returns whatever the script `return`s, in `result`.

## Rules

- Never write a refresh loop; the keep-alive keeps sessions alive.
- Keep waits short (`timeout` of a few seconds, then retry): every other agent waits while yours runs.
- Never print or save a key.

## Common actions

`navigate` (`url`), `gettitle`, `geturl`, `getpagetext`, `findelement(s)` / `click` / `sendkeys` / `gettext` /
`getattribute` (`by`, `value`), `selectoption`, `waitforelement`, `switchtoframe`, `executescript`, `screenshot`
(`filePath`), `newtab`, `switchtab`, `listtabs`, `closetab`, `releasetab`.
Locators (`by`): `Id`, `Name`, `ClassName`, `TagName`, `CssSelector`, `XPath`, `LinkText`, `PartialLinkText`.
