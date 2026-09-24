# Undirect

A small iOS browser app that loads a single page you paste in, and blocks:

- Automatic / script-driven **cross-domain redirects** on the main frame
- **`window.open()` / `target="_blank"` pop-ups and new tabs**

using a **whitelist policy**: blocking is active on every domain *except* the ones you've
explicitly whitelisted. The domain you type in is trusted automatically for that visit; you
can add more from the in-app Whitelist screen, or tap "Trust Site" while browsing.

Links you tap yourself are always allowed to navigate normally — only redirects/pop-ups the
*page* triggers on its own are blocked.

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
