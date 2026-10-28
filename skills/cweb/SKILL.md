---
name: cweb
description: Use CWeb, the shared Chrome browser the user is signed in to, to work with websites (navigate, read pages, fill forms, run page scripts), and to keep sites signed in. Use when asked to use the browser, CWeb, "activate chrome", "keep <site> alive", or do anything on a website that needs the user's sign-ins.
allowed-tools: Bash, Read, Write
user-invocable: true
---

<!-- Template for the cweb skill: installed by CWeb setup into ~/.claude/skills/cweb/ with the CWeb folder filled in
     ({{CWEB_WIN}}\skills\cweb\SKILL.md). Edit the template; setup replaces the installed copy. -->

# CWeb

A real Chrome window the user is signed in to, shared by every session. One command does everything; if CWeb isn't
running, it starts it first. Nothing to connect or approve.

```bash
cweb={{CWEB}}/cweb.sh
$cweb '{"action":"navigate","tab":"tickets","url":"https://example.org"}'
$cweb '{"action":"getpagetext","tab":"tickets"}'
$cweb '{"action":"click","tab":"tickets","by":"CssSelector","value":"button[type=submit]"}'
```

- **Always pass `"tab":"<name>"`**, a name of your own for your work. `navigate` with a new name opens that tab.
  `listtabs` shows every tab; tabs the user opened are named after their site. Read them; ask before changing them.
  Leave `keepalive-*` tabs alone.
- The reply is JSON; check `success`. Exit 3 = CWeb is still starting (Chrome reopening its tabs): run it again.
- Default instance is `work`. Use `$cweb personal '<json>'` only when the user says so.
- Long scripts or quotes: build the body in PowerShell and pipe it in:

```bash
pwsh -NoProfile -Command '@{ action = "executescript"; tab = "tickets"; script = @"
return [...document.querySelectorAll("table tr")].map(tr => tr.innerText);
"@ } | ConvertTo-Json -Compress' | $cweb -
```

## Keep a site signed in

When the user says "keep <site> alive": follow `{{CWEB_WIN}}\KEEPALIVE.md` now, in this conversation. You write a small
script, CWeb tests it on the live site and runs it from then on. Never write your own refresh loop.

## Actions

`navigate` (`url`), `gettitle`, `geturl`, `getpagetext`, `findelement(s)` / `click` / `sendkeys` / `gettext` /
`getattribute` (`by`, `value`), `selectoption`, `waitforelement`, `switchtoframe`, `executescript` (`script`; returns
what it `return`s, in `result`), `screenshot` (`filePath`), `listtabs`, `closetab`, `getcookies`, `keepalive`.
Locators (`by`): `Id`, `Name`, `ClassName`, `TagName`, `CssSelector`, `XPath`, `LinkText`, `PartialLinkText`.
Keep waits short (a few seconds, then retry): commands run one at a time. More: `{{CWEB_WIN}}\claude.md`.
