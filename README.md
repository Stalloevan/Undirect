# Undirect

A small iOS browser app that loads a single page you paste in, and blocks:

- Automatic / script-driven **cross-domain redirects** on the main frame
- **`window.open()` / `target="_blank"` pop-ups and new tabs**

using a **whitelist policy**: blocking is active on every domain *except* the ones you've
explicitly whitelisted. The domain you type in is trusted automatically for that visit; you
can add more from the in-app Whitelist screen, or tap "Trust Site" while browsing.

Links you tap yourself are always allowed to navigate normally — only redirects/pop-ups the
*page* triggers on its own are blocked.

## Features

- **Back / forward navigation** — toolbar buttons at the bottom of the browser screen,
  enabled/disabled based on `WKWebView`'s actual back-forward list.
- **Session persistence** — the current page's URL and full `WKWebView` interaction state
  (scroll position, history, form state) are saved whenever the app backgrounds, and
  restored on the next launch. This specifically fixes the app "forgetting" what site you
  were on after iOS purges it from the background under memory pressure (common on an
  iPhone 13 mini's 4 GB RAM) — without this, a cold relaunch always started over at Home.
- **Click-through for ad-interstitial layers** — many "redirect" pages are really an
  invisible tap-catching overlay: your first tap opens an ad/pop-up *and* the overlay
  removes itself, so the *next* tap at the same spot would reach the real link
  underneath. Undirect never lets the ad/redirect through, but when a block follows a
  real recent tap, it resends a synthetic tap at the same coordinates (up to 4 times,
  stopping as soon as a resend triggers no further block) — so that overlay gets
  "clicked through" automatically without ever honoring the thing it was trying to do.
- **Dark theme** — a plain, low-risk dark theme: `color-scheme: dark` (so well-behaved
  modern sites apply their own proper dark styling) plus safe background/text color
  defaults for the rest. An earlier version tried to approximate a specific palette
  (Catppuccin) using the common CSS `filter: invert()` "force dark mode" trick, which
  forces the whole page into one pixel-inverted composited layer — a known source of
  WKWebView instability on complex pages, and the likely cause of crashes on tap. This
  version avoids that entirely.
- **Compact header** — no iOS large-title bar; just a standard nav bar, to keep more of
  the small screen for the page itself.
- Shared `WKProcessPool` across all web views (main browser + any whitelisted pop-ups) for
  faster loads and consistent cookies/session state between them.

## Why not a Safari Extension?

iOS Safari Web Extensions cannot intercept top-level `window.location` redirects the way
this app can (Apple doesn't expose that navigation hook to WebExtensions on iOS), so a true
Safari extension can't fully deliver this behavior. The `SafariBlocker` project this was
inspired by is a **jailbreak tweak** (Theos/Tweak.xm hooking private Safari APIs), which only
works on a jailbroken device. This app reimplements the same idea legitimately, as a
standalone `WKWebView`-based browser, using public `WKNavigationDelegate` /
`WKUIDelegate` APIs.

## Building

Requires a Mac with Xcode. Project files are generated with
[XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` (avoids hand-committing
a fragile `.xcodeproj`):

```bash
brew install xcodegen
xcodegen generate
open Undirect.xcodeproj
```

## Installing without a paid Apple Developer account

The included GitHub Actions workflow (`.github/workflows/build.yml`) builds an **unsigned**
IPA and uploads it as a build artifact / release asset (run it manually via the Actions tab,
or push a tag like `v1.0`).

An unsigned IPA can't be installed by tapping it — it needs to be *signed* with an Apple ID
during install. Use one of:

- **Sideloadly** (Windows/Mac, free) — drag the IPA in, sign in with any free Apple ID, install.
- **AltStore** (Windows/Mac, free) — same idea, plus it can auto-refresh the 7-day signature.
- **Xcode** directly — open the generated project, plug in your iPhone, hit Run (requires the
  device's UDID to be registered, which Xcode does for you with a free Apple ID).

Free Apple ID signatures expire after **7 days** and need re-signing/re-installing. If you
have a paid Apple Developer Program membership ($99/yr), add your team ID / signing
certificate / provisioning profile as repo secrets and the workflow can be extended to
produce an ad-hoc signed IPA that lasts a full year instead — say the word and I'll wire
that up.

## Known limitations

- This is a **separate browser**, not a Safari extension — it only protects pages you open
  inside Undirect, not Safari itself.
- Blocking looks at the destination *domain*, not deep content analysis — a malicious site
  redirecting within a whitelisted domain (e.g. an ad network subdomain you whitelisted)
  will not be blocked.
- Tested against the general WKWebView APIs available on iOS 17+; iOS 18.7.8 on iPhone 13
  mini is covered by this deployment target.
