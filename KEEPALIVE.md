# Working CWeb keep-alive requests (for agents)

The user clicks **Keep alive** on a tab when a site keeps signing them out. You hear about it when you `connect`
(`keepAliveRequests` in the reply), or the user asks you to "work the CWeb keep-alive requests". Build a profile for
the site and install it: it's **live at once**, and the user can switch it off on the status page.

`$CWEB` is the CWeb folder in Bash form (the **cweb** skill has the real path); write the real path in each command.
Examples use the instance `work` and the client `keepalive-builder`.

## 1. See what's asked

```bash
$CWEB/cweb.sh keepalive-builder connect     # attaches to the running instance; the reply names it ("instance":"work")
$CWEB/cweb.sh work keepalive-builder '{"action":"keepalive","op":"requests"}'
```

Each request has an `id` and a `site`. `listtabs` shows the tab the user is signed in on (`details` has each url).
Work in that tab with `tab` on each command; don't navigate it away or sign it out.

## 2. Find how the session expires

With `executescript` in that tab, look for one of: a countdown or "session expires" element, an idle timer in the
page's scripts (`timeout`, `idle`, `expire`, `logout`), a token with an expiry in `localStorage` / `sessionStorage`
(a JWT's `exp`), or a keep-alive endpoint the page calls (`performance.getEntriesByType('resource')`).

- **probe()** reads the time left without extending it, and spots the signed-out page.
- **renew()** extends the session the way the site does (its own keep-alive call, an activity event, a light `GET`).
  Never reload or navigate.

Quick check before installing: probe, renew, probe again; the time left should go up. If there's no way to read or
extend the session, decline instead:

```bash
$CWEB/cweb.sh work keepalive-builder '{"action":"keepalive","op":"decline","request":"<id>","note":"No client-side timer and no keep-alive endpoint."}'
```

## 3. Install it

```js
// @name        Example Portal
// @match       ^https://[^/]+\.example\.org/
// @renewBelow  300
// How this site's session expires and why renew() works (a line or two).
var site = {
    probe: function () { /* { loggedOut: true } or { loggedOut: false, remaining: <seconds> } */ },
    renew: function () { /* extend without reloading; return a short description */ }
};
```

- `@match`: the vendor's domain pattern, matching the signed-out page too. `@renewBelow` (seconds): above any warning
  the site shows before signing out.
- No credentials or customer data in the file. Name it after the vendor (`example-portal`); the same name replaces
  the old profile (kept in `keepalive\replaced\`).

```bash
pwsh -NoProfile -Command '@{ action="keepalive"; op="install"; name="example-portal"; request="<id>"; source=(Get-Content -Raw ./example-portal.js) } | ConvertTo-Json -Compress' |
  $CWEB/cweb.sh work keepalive-builder -
```

The server checks the headers and runs `probe()` once on an open tab of the site. If that throws or returns the wrong
shape, nothing is installed and the error says why; fix it and install again. Otherwise it's live on every matching
tab, and the request is closed. Tell the user in a sentence: what expires and how renew() extends it.
