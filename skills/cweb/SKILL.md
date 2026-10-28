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
$cweb '{"action":"navigate","url":"https://portal.example.org/tickets"}'     # reply: "tab":"example"
$cweb '{"action":"getpagetext","tab":"example"}'
$cweb '{"action":"click","tab":"example","by":"CssSelector","value":"button[type=submit]"}'
```

- **One tab per site.** `navigate` without `tab` goes to that site's tab (named after the site: `example` for
  portal.example.org, `linkedin`, `x`), opening it only if there's none. Then pass that name as `"tab"` on every
  command after it. Don't open extra tabs for a site; sessions share its tab and pick up where the last one left it.
- `listtabs` shows every tab. Leave `keepalive-*` tabs alone. Need a second page on the same site at the same time (rare)?
  Pass your own `"tab":"<name>"` on `navigate`.
- The reply is JSON; check `success`. Exit 3 = CWeb is still starting (Chrome reopening its tabs): run it again.
- Default instance is `work`. Use `$cweb personal '<json>'` only when the user says so.
- Long scripts or quotes: build the body in PowerShell and pipe it in:

```bash
pwsh -NoProfile -Command '@{ action = "executescript"; tab = "example"; script = @"
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
