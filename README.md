# Undirect

A privacy-first web browser for iPhone and iPad that **stops pages from sending you somewhere you didn't choose**: no surprise redirects, no pop-ups, no new tabs opening by themselves. On top of that it blocks ads and trackers, has **Tor built in** (per tab, no separate app or VPN), and can be driven end-to-end from the **Shortcuts** app.

Requires iOS / iPadOS 17 or later. Undirect is sideloaded — it isn't on the App Store (see [Installing](#installing)).

---

## What sets it apart

- **Redirects and pop-ups are blocked by default, everywhere.** Links you tap yourself always work; what a page tries to do *on its own* — bouncing you to another site, opening a pop-up or a new tab — is blocked unless you've trusted that site. Most browsers only block the obvious pop-ups.
- **Tor in any tab, one tap away.** Each tab is either normal or Tor. Tor tabs use a separate in-memory data store, so their cookies and site data are never written to disk and disappear when the app quits; `.onion` links open in Tor automatically, and Tor sleeps and recovers cleanly when you switch apps or networks.
- **Full browser automation without code.** Record what you do on a page, then replay it from the Shortcuts app, on a schedule, or automatically every time you visit a site.
- **Downloads go where you want.** Per-file-type rules can save to a folder, to Photos, preview in place, or hand the link straight to another app (for example an `.ipa` to Feather, or a video to VLC).
- **No analytics, no accounts, no telemetry.** The only third-party code is Tor itself.

## Features

### Redirect and pop-up protection
- Blocks script-driven cross-site redirects and every kind of new-window request (`window.open`, `target="_blank"`, form pop-ups).
- **Click-through:** many "redirect" pages are an invisible layer that hijacks your first tap. Undirect blocks what the layer tried to do and passes your tap through to the real link underneath.
- **Site exceptions:** one list (Settings › Site exceptions) for sites you trust with redirects and pop-ups, and sites where ad blocking is paused. Add from the tab's long-press menu or by hand.

### Ad, tracker and annoyance blocking
- Domain blocklists from [HaGeZi](https://github.com/hagezi/dns-blocklists): Standard (~44k domains) or Strict (~164k), compiled into Safari-grade content-blocking rules.
- Hides common ad slots, plus a picker to hide any element on a page permanently.
- Strips tracking parameters (`utm_*`, `fbclid`, `gclid`, and site-specific ones) from links.
- Auto-dismisses cookie consent banners, rejecting where the site allows it.
- **Link preview with a trust score:** long-press a link to preview it, along with a score based on what the page loads and known phishing, malware and scam lists.

### Anti-tracking
- Fingerprinting protection (canvas, WebGL and audio noise; generic hardware values).
- Blocks WebRTC IP leaks (always on in Tor tabs).
- Sends Global Privacy Control and Do Not Track.
- Blocks third-party cookies and IP-lookup/analytics services; can feed analytics scripts fake IDs instead.
- Clears other sites' data when a tab closes, when you leave the app, or never — while keeping you signed in to sites you choose.

### Tor
- Embedded Tor ([iCepa Tor.framework](https://github.com/iCepa/Tor.framework)); turn any tab into a Tor tab, or make every new tab use Tor.
- New Tor identity from the page menu or Shortcuts.
- Tor progress shows in the address bar; pages that failed while Tor reconnected reload automatically.

### Video and audio
- **AirPlay** to an Apple TV or AirPlay-compatible TV or speaker, from the video's own button or ⋯ › Cast with AirPlay. Keeps playing while you use other apps or lock your phone.
- **Cast with AirPlay relays the video through your phone.** The TV fetches it from Undirect, which fetches it from the site with your tab's own cookies (and through Tor in Tor tabs). This works for sites that refuse requests from the TV, and for players that stream through `blob:` addresses. The phone and TV must be on the same Wi-Fi, and the phone stays involved for as long as you watch.
- Background audio and Picture in Picture.
- Lock-screen and Control Center controls (play/pause, skip 15 seconds, scrubbing).
- Sites' own fullscreen players are supported.
- Video and audio never autoplay.

### Browsing
- Tab sidebar on either side, with a minimal mode that tucks away; tabs and their history are restored after relaunch.
- New tab page with favorites, installed web apps, blocking statistics and Tor status.
- **Web apps:** install a site as an app that opens in its own window.
- **Immersive mode:** the page with no browser interface at all. Three-finger tap, the tab menu, or a Shortcut; three-finger tap again to leave.
- Opens HTML files and web archives from Files or the share sheet.
- Share sheet extension: "Open in Undirect" from any app.
- Choice of search engine (DuckDuckGo, Startpage, Brave, Mojeek, Ecosia, Google, Bing, or custom) and themes (Catppuccin, Nord, Retro).

### Downloads
- Rules by file type (images, video, audio, PDFs, archives, documents, IPAs, and more) that decide where each download goes: ask, Undirect's Downloads folder, a folder you pick in Files, Photos, preview, or the share sheet.
- **Send to a specific app:** hands the link to the app before anything downloads. Presets include Feather, AltStore, TrollStore, VLC, Infuse, nPlayer, Safari, Chrome, Firefox and Edge; or run a Shortcut, or use any app's URL scheme.

### Automation and Shortcuts
- **Recorder:** ⋯ › Record Automation, then use the page normally. Taps, typing, menu choices and Enter are saved as steps. Passwords are never stored.
- **Editor:** reorder, edit or add steps; find elements by their visible text or a CSS selector; mark steps to take input from a shortcut.
- **Run on every visit:** an automation can run by itself whenever a page on its site loads.
- **Shortcuts actions:** Run Automation, Open URL (normal or Tor), Go to URL, Back/Forward/Reload, Wait for Page or Element, Tap Element, Type Text, Choose Menu Option, Scroll, Run JavaScript, Get Page Details, Get Elements, Screenshot Page, Get/Switch/Close Tabs, New Tor Identity, Clear Browsing Data, Add/Get Favorites, Open Immersive.

---

## Disclaimers

- **Undirect is not Tor Browser.** It uses Apple's WebKit, which every iOS browser must, so it can't match Tor Browser's anti-fingerprinting. A determined site may still tell Undirect users apart. If your safety depends on anonymity, use [Onion Browser](https://onionbrowser.com) or Tor Browser on a computer, and follow the Tor Project's guidance. Undirect is not affiliated with or endorsed by the Tor Project.
- **Some actions leave Tor.** When you AirPlay from a Tor tab, the TV fetches the video itself over your normal connection. "Send to a specific app" and opening links in other apps also bypass Tor (download hand-offs are refused from Tor tabs for this reason).
- **Blocking can break sites.** Strict blocklists, redirect blocking and cookie-banner handling occasionally break logins, payments or video players. Pause blocking or trust the site for that one site.
- **Automations run code on web pages.** Only run automations and JavaScript you understand, especially on sites where you're signed in.
- **Sideloaded software.** Builds are unsigned and come with no warranty. Signing services, certificates and sideloading tools are third-party products with their own terms and risks.
- **Third-party lists.** Ad/tracker blocklists are from HaGeZi (GPL-3.0); site-reputation lists come from community sources and can be wrong in both directions. A good trust score doesn't make a page safe.
- **Your responsibility.** Use Undirect in line with the laws where you live and the terms of the sites you visit.

## Limitations (iOS rules, not choices)

- Only protects browsing inside Undirect; it doesn't change Safari.
- No iCloud sync of tabs, history or passwords, and no browser extensions.
- Password AutoFill works through the iOS keyboard, but not as smoothly as in Safari.
- Videos protected with DRM, and sites that stream in the DASH format, can't be cast; Screen Mirroring still works for those.

---

## Installing

Changing the `VERSION` file on `main` (or pushing a `v*` tag) builds an **unsigned** `.ipa` with GitHub Actions, creates the matching `v` tag, and attaches the IPA to a new release on the [Releases](../../releases) page. Install it with any sideloading tool that signs apps, for example:

- **Feather** with your own certificate, on the device.
- **AltStore** or **SideStore** with a free Apple ID (re-sign every 7 days).
- **Sideloadly** from a Mac or PC.

## Building from source

Requires a Mac with Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
# Tor.framework isn't committed; the CI workflow downloads it into Frameworks/
mkdir -p Frameworks
curl -fsSL -o tor.zip https://github.com/iCepa/Tor.framework/releases/download/v409.12.1/tor-nolzma.xcframework.zip
unzip -q tor.zip -d Frameworks && rm tor.zip
# project.yml has version placeholders the CI fills in from the tag
sed -i '' -e 's/VERSION_PLACEHOLDER/0.0/' -e 's/BUILD_PLACEHOLDER/1/' project.yml
xcodegen generate
open Undirect.xcodeproj
```

Project layout:

| Path | What's there |
| --- | --- |
| `Sources/` | The app (Swift, UIKit, WebKit) |
| `Sources/Resources/` | Bundled blocklists and site-reputation lists |
| `ShareExtension/` | The "Open in Undirect" share sheet extension |
| `project.yml` | XcodeGen project definition |
| `VERSION` | The version to release; bumping it publishes a new release |
| `.github/workflows/build.yml` | CI that builds the unsigned IPA and publishes releases |

## Credits

- [Tor](https://www.torproject.org) via [iCepa Tor.framework](https://github.com/iCepa/Tor.framework)
- Blocklists by [HaGeZi](https://github.com/hagezi/dns-blocklists)
- Themes inspired by [Catppuccin](https://catppuccin.com) and [Nord](https://www.nordtheme.com)
