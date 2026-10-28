# Keep a site signed in (for agents)

When the user says "keep <site> alive", do it now, in that conversation. CWeb runs it from then on by itself; you're not
needed again. `$CWEB` is the CWeb folder in Bash form (the **cweb** skill has the real path).

## 1. Find how the session expires

Open the site (`{"action":"navigate","url":"https://app.example.com/"}`, which goes to its tab); the user is
already signed in there. With `executescript` in that tab, look for: a countdown or "session expires" element,
an idle timer in the page's scripts (`timeout`, `idle`, `expire`, `logout`), a token with an expiry in `localStorage` /
`sessionStorage` (a JWT's `exp`), or a keep-alive endpoint the page calls (`performance.getEntriesByType('resource')`).
No timer at all: renew on a cadence (a light signed-in request every few hours) and track it in `localStorage`.

## 2. Write the script

```js
// @name        Example Portal
// @url         https://app.example.com/
// @match       ^https://([^/]+\.)?example\.com/
// @renewBelow  300
// How this site's session expires and why renew() works (a line or two).
var site = {
    probe: function () { /* { loggedOut: true } or { loggedOut: false, remaining: <seconds> } -- reads only */ },
    renew: function () { /* extend without reloading or navigating; return a short description */ }
};
```

- `@url`: the page CWeb keeps open for the site, in its own background tab (`keepalive-<name>`).
- `@match`: the site's pages, including its signed-out page. `@renewBelow`: renew when fewer seconds are left.
- `probe()` and `renew()` may return a promise. No credentials in the file.

## 3. Add it

```bash
pwsh -NoProfile -Command '@{ action="keepalive"; op="add"; source=(Get-Content -Raw ./example-portal.js) } | ConvertTo-Json -Compress' |
  $CWEB/cweb.sh -
```

CWeb opens the site's tab, runs `probe()`, then `renew()` and `probe()` again on the live site. If any of that fails,
nothing is saved and the error says why: fix it and add again. If it works, it's saved and running before the reply.
The same `@name` again replaces the site's script. Tell the user in a sentence what expires and how renew() extends it.

Other ops: `{"action":"keepalive"}` lists the sites and their state; `"op":"remove","site":"<id>"` removes one (only when
the user asks); `"op":"check"` checks them all now.
