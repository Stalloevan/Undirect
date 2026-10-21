# Undirect

Undirect is a privacy-focused web browser for iPhone and iPad. It stops pages from sending you somewhere you did not choose. It also blocks ads and trackers, keeps every site in its own sandbox, and has Tor built in.

It requires iOS or iPadOS 17 or later. Undirect is not on the App Store. You install it by sideloading (see [Installing](#installing)).

## What it does

**No surprise redirects or pop-ups.** Links you tap always work. Anything a page tries to do on its own, such as redirecting you or opening a new window, is blocked unless you trust the site. If an invisible layer covers a page and hijacks your first tap, Undirect passes the tap through to the real link.

**Ad and tracker blocking.** Undirect uses the HaGeZi domain lists (about 44,000 domains on Standard, about 164,000 on Strict) and a small extra list of its own. It also hides common ad slots, removes tracking parameters from links, and rejects cookie banners where the site allows it. You can add or remove domains in Settings under Custom blocklist, and pause blocking for a single site.

**Every site is sandboxed.** Each tab has its own private storage for cookies and site data. One tab cannot read what another tab stored, and the data is deleted when the tab closes. Sites where you chose to stay logged in keep a saved store of their own. Each Tor tab has its own in-memory storage.

**Fingerprinting protection.** Canvas, WebGL, audio, text measurement and element size readings get tiny random changes that differ for every tab. Hardware details such as memory and processor count are hidden. The changes are too small to affect how a page works, but they stop trackers from building a stable ID for your device.

**Other privacy features.**
- Third-party cookies are blocked, and WebRTC IP leaks are blocked.
- Global Privacy Control and Do Not Track are sent.
- Link preview shows a trust score based on what the page loads and on known phishing and malware lists.

**Tor in any tab.** You can switch any tab to Tor, or make every new tab use Tor. Links ending in `.onion` open in Tor automatically.

**Video and audio.** AirPlay, background audio, Picture in Picture and lock screen controls all work. Media never plays automatically.

**Browsing.** Tabs are restored after relaunch. Background tabs are saved as pictures and unloaded when idle to save memory, unless they are playing media or have unsent text. There is a tab sidebar, a new tab page, installable web apps, an immersive mode with no browser interface, and a Share Sheet extension.

**Downloads.** Rules by file type decide where each download goes. A download can be saved to a folder, saved to Photos, previewed, or handed to another app such as Feather or VLC.

**Automation.** You can record what you do on a page and replay it from the Shortcuts app, on a schedule, or each time you visit a site. Passwords are never recorded.

Undirect has no analytics, no accounts and no telemetry.

## Testing and project documents

- `Tools/adblock-test/run.py` checks the blocking rules against known ad and tracker URLs and against sites that must keep working. It runs on every build.
- `Tools/fingerprint-test/run.js` checks that the fingerprint changes stay small, repeat inside a tab, and differ between tabs.
- `Tools/adblock-test/add_case.py` turns a real report into a permanent test. Use `block <url>` when an ad gets through, and `allow <url>` when a site breaks.
- [docs/DEVICE-TESTING.md](docs/DEVICE-TESTING.md) is a checklist to run on a phone.
- [docs/THREAT-MODEL.md](docs/THREAT-MODEL.md) explains who Undirect protects against, and where it does not.

## Limits and warnings

- **Undirect is not Tor Browser.** It uses Apple's WebKit, as every iOS browser must, so it cannot match Tor Browser's resistance to fingerprinting. If your safety depends on anonymity, use Onion Browser or Tor Browser on a computer. Undirect is not affiliated with the Tor Project.
- **Some actions leave Tor.** AirPlay from a Tor tab makes the TV fetch the video over your normal connection. Handing a link to another app also bypasses Tor.
- **Blocking can break sites.** Strict lists and redirect blocking can break logins, payments or video players. Pause blocking or trust the site if that happens.
- **Automations run code on pages.** Only run automations and JavaScript that you understand.
- **Sideloaded software.** Builds are unsigned and come with no warranty. Free Apple ID builds must be re-signed every seven days.
- **iOS limits.** Undirect only protects browsing inside the app. It has no iCloud sync and no browser extensions. DRM-protected video cannot be cast.

## Installing

Changing the `VERSION` file on `main` builds an unsigned `.ipa` with GitHub Actions and publishes it on the Releases page. Install it with a sideloading tool such as Feather, AltStore, SideStore or Sideloadly.

## Building from source

You need a Mac with Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
mkdir -p Frameworks
curl -fsSL -o tor.zip https://github.com/iCepa/Tor.framework/releases/download/v409.12.1/tor-nolzma.xcframework.zip
unzip -q tor.zip -d Frameworks && rm tor.zip
sed -i '' -e 's/VERSION_PLACEHOLDER/0.0/' -e 's/BUILD_PLACEHOLDER/1/' project.yml
xcodegen generate
open Undirect.xcodeproj
```

| Path | Contents |
| --- | --- |
| `Sources/` | The app (Swift, UIKit, WebKit) |
| `Sources/Resources/` | Blocklists and site-reputation lists |
| `ShareExtension/` | The Share Sheet extension |
| `Tools/adblock-test/` | Blocking rule tests |
| `docs/` | Device test checklist and threat model |
| `project.yml` | XcodeGen project definition |
| `VERSION` | The version to release |

## Credits

- [Tor](https://www.torproject.org) through [iCepa Tor.framework](https://github.com/iCepa/Tor.framework)
- Blocklists by [HaGeZi](https://github.com/hagezi/dns-blocklists)
- Themes inspired by [Catppuccin](https://catppuccin.com) and [Nord](https://www.nordtheme.com)
