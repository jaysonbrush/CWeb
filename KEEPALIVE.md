# Working CWeb keep-alive requests (for agents)

The user clicks **Keep alive** on a tab in a CWeb status page when a site keeps signing them out. That files a request
for the site's address. Your job: work out how that site's session expires and write a profile that keeps it alive,
**as a draft**. A draft never runs until the user reviews it and clicks **Enable**.

Use `cweb.sh` (or `Invoke-CWeb`) as an approved client of the instance the request is on. Examples use `work` and the
client name `keepalive-builder`.

## 1. See what's asked

```bash
/c/CWeb/cweb.sh work keepalive-builder connect
/c/CWeb/cweb.sh work keepalive-builder '{"action":"keepalive","op":"requests"}'
```

Each open request has an `id` and a `site` (e.g. `https://portal.example.org`). Find the tab the user is signed in on:
`listtabs` (its `details` show each tab's url). **Work in that tab, but don't navigate it away or sign it out**: it's
the user's session. Read with `tab` set on each request; ask the user first before anything that changes the page.

## 2. Find out how the session expires (read only)

Look, don't act. With `executescript` in that tab:
- A countdown or "session expires" element on the page.
- An idle timer in the page's scripts (search loaded script text for `timeout`, `idle`, `expire`, `logout`).
- A token with an expiry in `localStorage` / `sessionStorage` (often a JWT: decode the middle part for `exp`).
- A keep-alive or "session remaining" endpoint the page polls (check `performance.getEntriesByType('resource')`).

You need two things:
- **probe()**: reads the time left **without** extending it, and spots the signed-out page. Confirm by calling it
  twice a minute apart: the number must go down, not reset.
- **renew()**: extends the session the way the site itself does (its own keep-alive call, a synthetic activity event,
  a light `GET` the server counts as activity). **Never reload the page or navigate.** Prove it: probe, renew,
  probe again; the time left must go up.

If you can't find a safe, read-only probe or a renewal that's proven to work, don't guess. Decline with a note:

```bash
/c/CWeb/cweb.sh work keepalive-builder '{"action":"keepalive","op":"decline","request":"<id>","note":"No client-side timer; session is a server cookie with no keep-alive endpoint."}'
```

## 3. Write the profile

Format (if the machine already has profiles, in `<data folder>\keepalive\`, read one first):

```js
// @name        Example Portal
// @match       ^https://[^/]+\.example\.org/
// @renewBelow  300
// How this site's session expires and why renew() works (a few lines).
var site = {
    probe: function () { /* read only: { loggedOut: true } or { loggedOut: false, remaining: <seconds> } */ },
    renew: function () { /* extend without reloading; return a short description */ }
};
```

Rules:
- `@match` names the **vendor's** domain pattern (`[^/]+\.example\.com`), never a customer's own host name, and also
  matches the signed-out page so `probe()` can report `loggedOut`.
- `@renewBelow` (seconds) is bigger than any warning the site shows before signing out.
- No credentials, no customer data, no logging of page content.
- File name = the vendor, lowercase with hyphens (`example-portal`). Same name as an existing profile = a
  replacement; the user sees that before enabling.

## 4. Submit the draft

Put the source in a JSON body file (quotes and newlines survive) and send it on stdin:

```bash
pwsh -NoProfile -Command '@{ action="keepalive"; op="draft"; name="example-portal"; request="<id>"; source=(Get-Content -Raw ./example-portal.js) } | ConvertTo-Json -Compress' |
  /c/CWeb/cweb.sh work keepalive-builder -
```

The server checks the headers and saves it to `<data folder>\keepalive\drafts\example-portal.js`. The request shows **draft
ready** on the status page. Then tell the user, in a sentence or two: what expires, how probe reads it, how renew
extends it, and what you proved. The user reviews and enables it on the status page (Keep-alive tab).
