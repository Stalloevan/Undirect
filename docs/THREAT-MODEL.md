# Threat model

Undirect's promise: *browse without being tracked or redirected, on iOS, with
no accounts and nothing sent anywhere by the app itself.* This file says who
that protects against, how, and what it does **not** cover. Each claim has a
test. "Confirmed in code" means someone read the source; "To verify" means it
needs a device test and is not yet proven.

## Who the protection is for
| Adversary | In scope? |
|---|---|
| Websites and ad/analytics networks (cookies, fingerprinting, link tracking, redirects) | **Yes** — the main goal |
| Network observer on Wi-Fi / your ISP | **Partly** — only Tor tabs hide *which sites*; normal tabs use the system network and DNS |
| A site learning your real IP | **Tor tabs only** |
| Someone who picks up your unlocked phone | **No app lock yet** |
| Someone with a device backup or forensic image | **Partly** (see "Data at rest") |
| Apple / iOS itself, the WebKit engine, malware on the phone | **No** |
| A state-level adversary correlating Tor traffic | **No** |

## Claims and how each is tested
| # | Claim | Basis | Test |
|---|---|---|---|
| 1 | Ad/tracker domains are blocked in all tabs, including a per-user list | Confirmed in code (content rules + `Tools/adblock-test`) | `python3 Tools/adblock-test/run.py`; d3ward adblock test on device |
| 2 | Tracking parameters and redirect hops are stripped/clicked through | Confirmed in code (URLCleaner, click-through) | Open a link with `utm_`/`fbclid`; check the final URL |
| 3 | Third-party cookies are blocked; analytics cookies are spoofed; non-"kept" sites' cookies are cleared | Confirmed in code (rules, CookieGuard) | Visit a site, close the tab, reopen: logged out. Check Settings → cookie cleanup |
| 4 | Fingerprinting surface is reduced, not eliminated | Confirmed in code (noise on canvas/WebGL/audio, spoofed hardware values) | EFF Cover Your Tracks and browserleaks.com. **Goal: result is stable and common, not unique. Noise can make you *more* unique — this is the least certain claim** |
| 5 | WebRTC can't reveal your IP (when the setting is on) | Confirmed in code (setting) | browserleaks.com/webrtc: no local/public IP leaked |
| 6 | Tor tabs send page traffic through Tor and use a separate, non-persistent data store | Confirmed in code (SOCKS5 `ProxyConfiguration`, `nonPersistent()` store) | check.torproject.org in a Tor tab says "Congratulations"; a normal tab shows your real IP |
| 7 | DNS for Tor tabs goes through Tor, not your resolver | To verify (SOCKS5 with hostnames should do this) | Packet-capture or a router DNS log while loading a Tor tab: no lookups for that site |
| 8 | Nothing leaves Tor tabs outside the proxy (favicons, link previews, preloads) | Partly confirmed (Tor favicons are fetched inside the page; others use a separate session) | Same capture: Tor-tab hosts never appear outside the Tor connection. **Check link-trust previews and Cast relay** |
| 9 | The app sends nothing to the developer or any analytics service | Partly confirmed (no analytics SDKs; log export is manual; but favicon fetches, favorite preloading and the Cast relay do touch the network) | Capture the app's traffic with no browsing: only expected block-list/icon fetches |
| 10 | Tabs left idle are unloaded without leaking content to disk | Confirmed (snapshots are memory-only) | Inspect the app container after a force-quit: no tab images |

## Data at rest (what stays on the phone)
- **Session file** — saved tab URLs/titles/history state, used to restore tabs.
  Tor tabs are saved too unless "close tabs on exit" is set. *Risk: a backup or
  forensic image shows what you had open.* Test: inspect the container.
- **Favicon cache** (`Caches/favicons`) — one icon per visited host, normal
  tabs only. *Risk: reveals hosts you visited, even after cookies are cleared.*
- **Downloads** — in the app's Documents folder, visible in Files.
- **Logs** — in memory/limited; detailed only after a failure; exported only on request.
- **App-switcher snapshot** — iOS captures the screen when you leave the app.
  No blur/cover is applied yet.

## Known gaps (not promises)
1. No app lock or panic/wipe button.
2. Normal tabs aren't hidden from your network or ISP.
3. Favicon cache and saved session reveal browsing to anyone with the device or a backup.
4. No screen cover in the app switcher.
5. Fingerprint noise is untested against real fingerprinting suites.
6. Sideloaded builds expire and need re-signing; there's no update channel.

## Suggested order to close the gaps
1. Run tests 4, 5, 6, 7 on the device and record results here.
2. Favicon cache: keep in memory for Tor, and offer "clear on exit" for normal tabs.
3. Add an app-switcher cover and an optional biometric lock.
4. Add a one-tap "wipe everything" in Settings.
