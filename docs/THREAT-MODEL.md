# Threat model

Undirect aims to let you browse without being tracked or redirected, on iOS, with no accounts and nothing sent to the developer. This document says who it protects against, how, and where it does not. Each claim has a test. "Confirmed in code" means the source was read. "To verify" means a device test is still needed.

## Who it protects against

| Adversary | Covered |
| --- | --- |
| Websites and ad networks (cookies, fingerprinting, link tracking, redirects) | Yes. This is the main goal. |
| A site learning your real IP address | Only in Tor tabs |
| A network observer or your internet provider | Only in Tor tabs. Normal tabs use the system network and DNS. |
| One site reading what another site stored | Yes. Every tab and every saved site has its own storage. |
| Someone who holds your unlocked phone | No. There is no app lock, and none is planned. |
| Someone with a backup or forensic image of the phone | Partly. See "Data kept on the phone". |
| Apple, WebKit bugs, or malware on the phone | No |
| An adversary who can correlate Tor traffic | No |

## Claims and tests

| Number | Claim | Basis | Test |
| --- | --- | --- | --- |
| 1 | Ad and tracker domains are blocked in all tabs, including your own list | Confirmed in code | Run `Tools/adblock-test/run.py`, then the d3ward test page on the device |
| 2 | Tracking parameters and redirect hops are removed | Confirmed in code | Open a link with `utm_` or `fbclid` and check the final address |
| 3 | Third-party cookies are blocked, analytics cookies are replaced with random values | Confirmed in code | Check cookies after visiting a news site |
| 4 | Each tab has private storage that is deleted when the tab closes | Confirmed in code | Log in, close the tab, open the site again. You should be logged out. |
| 5 | Two tabs never share storage, even on the same site | Confirmed in code | Log in on one tab. A second tab on the same site should be logged out. |
| 6 | Only sites you chose to keep (Kept Logins) or that passed a Cloudflare check keep data | Confirmed in code | Inspect Settings, Kept Logins. Close and reopen those sites and others. |
| 7 | Fingerprint values change for every tab | Confirmed in code | Compare coveryourtracks.eff.org results in two tabs |
| 8 | The fingerprint changes do not break pages | To verify | Use editors, maps, games and charts and watch for layout problems |
| 9 | WebRTC does not reveal your IP address when the setting is on | Confirmed in code | Visit browserleaks.com/webrtc |
| 10 | Tor tabs send page traffic through Tor and use in-memory storage | Confirmed in code | check.torproject.org in a Tor tab, and in a normal tab for comparison |
| 11 | DNS for Tor tabs goes through Tor | To verify | Capture network traffic while loading a Tor tab. No lookup for that site should appear. |
| 12 | Nothing outside Tor carries Tor tab traffic (favicons, previews, preloading, AirPlay) | Partly confirmed | Same capture. AirPlay from a Tor tab leaves Tor by design. |
| 13 | The app sends nothing to the developer | Partly confirmed | Capture traffic with no browsing. Only icon and list requests should appear. |
| 14 | Idle tabs are unloaded without writing their content to disk | Confirmed in code | Inspect the app container after quitting. It should hold no tab images. |

## How fingerprint randomization works

Each tab gets its own random seed. The seed changes small values that trackers hash but pages do not need exactly:

- Canvas and WebGL pixel read-backs, and audio analysis output
- Text widths from measureText
- Element sizes from getBoundingClientRect and getClientRects
- The order of WebGL extensions, and the reported storage quota

The same input always gives the same output inside one tab, so pages stay consistent. Changes are far smaller than one pixel. Hardware details (memory, processor count, battery, sensors) are hidden because pages rarely need them. Values that change how a page behaves are left alone: language, time zone, screen size, pixel ratio and the user agent. This reduces tracking by hash. It does not make Undirect look like every other browser, so a determined site can still compare behavior.

## Data kept on the phone

- **Saved tabs.** Addresses, titles and history state are saved to restore tabs. Tor tabs are saved too unless "close tabs on exit" is on.
- **Saved site stores.** Sites under Kept Logins keep cookies and storage. Sites that passed a Cloudflare check keep only the clearance cookie.
- **Favicon cache.** One icon per visited host is saved for normal tabs. It can reveal which hosts you visited.
- **Downloads.** They are saved in the app's Documents folder and are visible in Files.
- **Logs.** Detailed logs are kept only after a failure and are exported only when you ask.

## Known gaps

1. There is no app lock, panic wipe or app switcher cover. These are not planned.
2. Normal tabs are visible to your network and internet provider.
3. The favicon cache and saved tabs show browsing to anyone with the phone or a backup.
4. Fingerprint changes are untested against real fingerprinting services (claims 7 and 8).
5. Sideloaded builds expire and must be re-signed. There is no update channel.
6. Each tab uses its own storage, so many open tabs use more memory than one shared store did.

## Suggested next steps

1. Run tests 7, 8, 9, 10 and 11 on the device and record the results here.
2. Keep the favicon cache in memory for Tor tabs and add a clear-on-exit option for normal tabs.
3. Test fingerprint results with EFF Cover Your Tracks and browserleaks.com.
