import WebKit

enum WebEngine {

    static func makeConfiguration(tor: Bool) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = tor ? TorManager.shared.dataStore : .default()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.allowsInlineMediaPlayback = true
        // No autoplaying video/audio: faster pages, less data.
        config.mediaTypesRequiringUserActionForPlayback = .all
        config.defaultWebpagePreferences.preferredContentMode = .mobile
        return config
    }

    /// Installs every Undirect script on a (non-popup) tab's content controller.
    /// Our scripts run in an isolated content world so pages can't see or tamper with them.
    static func installScripts(on controller: WKUserContentController, messageName: String, tor: Bool) {
        let world = WKContentWorld.defaultClient
        func add(_ source: String, mainFrameOnly: Bool, world: WKContentWorld) {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                  forMainFrameOnly: mainFrameOnly, in: world))
        }
        add(viewportFallbackScript, mainFrameOnly: false, world: world)
        add(darkThemeScript, mainFrameOnly: false, world: world)
        add(agentScript(messageName: messageName), mainFrameOnly: false, world: world)
        add(pickerScript(messageName: messageName), mainFrameOnly: true, world: world)
        add(ElementHideStore.shared.scriptSource(), mainFrameOnly: false, world: world)
        if Settings.shared.autoHandleCookieBanners {
            add(consentAutoHandlerScript, mainFrameOnly: false, world: world)
        }
        // One page-world shield covering WebRTC, privacy signals and
        // fingerprinting, applied to every frame *and* to any same-origin
        // iframe a script creates (fingerprinters use fresh iframes to read
        // unpatched APIs).
        let webrtc = tor || Settings.shared.blockWebRTC
        let gpc = Settings.shared.sendGPC
        let fp = tor || Settings.shared.fingerprintProtection
        if webrtc || gpc || fp {
            add(shieldScript(webrtc: webrtc, gpc: gpc, fingerprint: fp, tor: tor), mainFrameOnly: false, world: .page)
        }
    }

    /// Per-launch random seed for fingerprint noise: stable within a session
    /// (so a page reading its own canvas twice gets the same answer and
    /// doesn't break), different every launch and for every site — so the
    /// resulting fingerprint can't link visits together.
    private static let fingerprintSeed = UInt32.random(in: 1...UInt32.max)

    /// Privacy shield. Where a test page scores "exposed" for any value it
    /// can read, the most effective defense is making APIs genuinely absent
    /// (reported as unavailable) rather than returning fake-but-plausible
    /// values, which still count — so hardware/media APIs are removed, while
    /// canvas/WebGL/audio (which can't be removed without breaking pages) get
    /// per-site, per-launch noise that makes the fingerprint unlinkable.
    private static func shieldScript(webrtc: Bool, gpc: Bool, fingerprint: Bool, tor: Bool) -> String {
        """
        (function () {
          var CFG = { webrtc: \(webrtc), gpc: \(gpc), fp: \(fingerprint), tor: \(tor) };
          if (window.__undirectShield) return;
          window.__undirectShield = true;
          var done = new WeakSet();
          var host = location.hostname || '';
          var seed = \(fingerprintSeed) >>> 0;
          for (var i = 0; i < host.length; i++) { seed ^= host.charCodeAt(i); seed = Math.imul(seed, 16777619) >>> 0; }
          function mix(i) {
            var x = (seed ^ Math.imul(i + 1, 2654435761)) >>> 0;
            x ^= x >>> 16; x = Math.imul(x, 73244475) >>> 0; x ^= x >>> 16;
            return x >>> 0;
          }
          function def(o, k, v) { try { Object.defineProperty(o, k, { get: function () { return v; }, configurable: true }); } catch (e) {} }
          function drop(o, k) {
            if (!o) return;
            try { delete o[k]; } catch (e) {}
            try { if (k in o) Object.defineProperty(o, k, { value: undefined, configurable: true, writable: true }); } catch (e) {}
          }

          function protect(w) {
            if (!w || done.has(w)) return;
            try { if (!w.Navigator) return; } catch (e) { return; }
            done.add(w);
            var N = w.Navigator.prototype;

            if (CFG.webrtc) {
              ['RTCPeerConnection', 'webkitRTCPeerConnection', 'RTCDataChannel', 'RTCSessionDescription',
               'RTCIceCandidate', 'RTCRtpSender', 'RTCRtpReceiver'].forEach(function (k) { drop(w, k); });
              drop(N, 'mediaDevices');
            }
            if (CFG.gpc) {
              def(N, 'globalPrivacyControl', true);
              def(N, 'doNotTrack', '1');
            }
            if (CFG.fp) fingerprint(w, N);
            if (CFG.tor) torUniform(w, N);
            hookFrames(w);
          }

          function fingerprint(w, N) {
            // Hardware hints: absent rather than faked.
            ['hardwareConcurrency', 'deviceMemory', 'maxTouchPoints', 'getGamepads', 'getBattery',
             'connection', 'bluetooth', 'usb', 'hid', 'serial', 'xr'].forEach(function (k) { drop(N, k); });
            drop(N, 'mediaDevices');

            // Canvas: tiny deterministic per-site noise on read-back.
            function noisify(img) {
              var d = img.data;
              if (d.length > 16000000) return img;
              for (var i = 0; i < d.length; i += 4) {
                var v = mix(i);
                if ((v & 15) === 0) { var c = i + ((v >>> 4) % 3); d[c] = d[c] ^ 1; }
              }
              return img;
            }
            var C2D = w.CanvasRenderingContext2D && w.CanvasRenderingContext2D.prototype;
            if (C2D) {
              var getImageData = C2D.getImageData;
              C2D.getImageData = function () { return noisify(getImageData.apply(this, arguments)); };
              var copy = function (canvas) {
                try {
                  var cw = canvas.width, ch = canvas.height;
                  if (!cw || !ch || cw * ch > 4000000) return null;
                  var c = w.document.createElement('canvas'); c.width = cw; c.height = ch;
                  var ctx = c.getContext('2d');
                  ctx.drawImage(canvas, 0, 0);
                  ctx.putImageData(noisify(getImageData.call(ctx, 0, 0, cw, ch)), 0, 0);
                  return c;
                } catch (e) { return null; }
              };
              var HC = w.HTMLCanvasElement.prototype;
              var toDataURL = HC.toDataURL, toBlob = HC.toBlob;
              HC.toDataURL = function () { var c = copy(this); return toDataURL.apply(c || this, arguments); };
              HC.toBlob = function () { var c = copy(this); return toBlob.apply(c || this, arguments); };
            }

            // WebGL: hide the GPU-identifying extension entirely, noise read-back.
            function patchGL(P) {
              if (!P) return;
              var ge = P.getExtension, gse = P.getSupportedExtensions, gp = P.getParameter, rp = P.readPixels;
              P.getExtension = function (name) {
                if (String(name).toLowerCase() === 'webgl_debug_renderer_info') return null;
                return ge.apply(this, arguments);
              };
              P.getSupportedExtensions = function () {
                var list = gse.apply(this, arguments) || [];
                return list.filter(function (n) { return String(n).toLowerCase() !== 'webgl_debug_renderer_info'; });
              };
              P.getParameter = function (p) {
                if (p === 37445 || p === 37446) return null;
                return gp.apply(this, arguments);
              };
              P.readPixels = function () {
                var r = rp.apply(this, arguments);
                var px = arguments[6];
                if (px && px.length) { for (var i = 0; i < px.length; i += 4) { if ((mix(i) & 15) === 0) px[i] = px[i] ^ 1; } }
                return r;
              };
            }
            patchGL(w.WebGLRenderingContext && w.WebGLRenderingContext.prototype);
            patchGL(w.WebGL2RenderingContext && w.WebGL2RenderingContext.prototype);

            // Audio: inaudible (~-140 dB) noise on analysis read-back.
            if (w.AudioBuffer) {
              var gcd = w.AudioBuffer.prototype.getChannelData, seen = new WeakSet();
              w.AudioBuffer.prototype.getChannelData = function () {
                var data = gcd.apply(this, arguments);
                if (!seen.has(data)) {
                  seen.add(data);
                  for (var i = 0; i < data.length; i += 97) data[i] += ((mix(i) & 255) - 128) * 1e-9;
                }
                return data;
              };
            }
            if (w.AnalyserNode) {
              var gffd = w.AnalyserNode.prototype.getFloatFrequencyData;
              w.AnalyserNode.prototype.getFloatFrequencyData = function (arr) {
                gffd.apply(this, arguments);
                for (var i = 0; i < arr.length; i++) arr[i] += ((mix(i) & 255) - 128) * 1e-6;
              };
            }

            // Fonts: document.fonts.check only confirms fonts the page itself
            // loaded as web fonts, so it can't be used to probe installed ones.
            var FFS = w.FontFaceSet && w.FontFaceSet.prototype;
            if (FFS && FFS.check) {
              var chk = FFS.check;
              FFS.check = function (font) {
                try {
                  var s = String(font).toLowerCase(), web = [];
                  this.forEach(function (f) { web.push(String(f.family).split('"').join('').split("'").join('').toLowerCase()); });
                  for (var i = 0; i < web.length; i++) { if (web[i] && s.indexOf(web[i]) !== -1) return chk.apply(this, arguments); }
                  return false;
                } catch (e) { return chk.apply(this, arguments); }
              };
            }

            // Where you came from: hide cross-site referrers from scripts.
            try {
              var ref = w.document.referrer;
              if (ref && new URL(ref).hostname !== w.location.hostname) def(w.Document.prototype, 'referrer', '');
            } catch (e) {}
          }

          // Tor tabs look like every other Tor user: UTC and en-US.
          function torUniform(w, N) {
            def(N, 'language', 'en-US');
            def(N, 'languages', ['en-US', 'en']);
            w.Date.prototype.getTimezoneOffset = function () { return 0; };
            var ro = w.Intl.DateTimeFormat.prototype.resolvedOptions;
            w.Intl.DateTimeFormat.prototype.resolvedOptions = function () { var r = ro.apply(this, arguments); r.timeZone = 'UTC'; return r; };
          }

          // Same-origin iframes created by script get the same protection the
          // moment anyone touches them.
          function hookFrames(w) {
            try {
              var IF = w.HTMLIFrameElement && w.HTMLIFrameElement.prototype;
              if (!IF) return;
              var cw = Object.getOwnPropertyDescriptor(IF, 'contentWindow');
              var cd = Object.getOwnPropertyDescriptor(IF, 'contentDocument');
              if (cw && cw.get) Object.defineProperty(IF, 'contentWindow', {
                configurable: true, enumerable: cw.enumerable,
                get: function () { var v = cw.get.call(this); try { protect(v); } catch (e) {} return v; }
              });
              if (cd && cd.get) Object.defineProperty(IF, 'contentDocument', {
                configurable: true, enumerable: cd.enumerable,
                get: function () { var v = cd.get.call(this); try { if (v) protect(v.defaultView); } catch (e) {} return v; }
              });
            } catch (e) {}
          }

          protect(window);
        })();
        """
    }

    // MARK: Scripts

    /// Plain, low-risk dark theme (no page-wide filters).
    /// Pages that don't declare their own viewport meta tag fall back to a
    /// ~980px desktop-width layout and render zoomed out to fit — standard
    /// mobile-Safari behavior, but not what people expect from a phone
    /// browser. This adds a sensible `width=device-width` default, but only
    /// when the page has no viewport tag of its own, so a page's deliberate
    /// viewport settings (including odd ones like user-scalable=no) are
    /// never overridden. Watches for <head> directly instead of waiting for
    /// DOMContentLoaded, since by then the page would already have rendered
    /// once at the wrong scale.
    private static let viewportFallbackScript = """
    (function () {
      function hasViewport() { return !!document.querySelector('meta[name="viewport" i]'); }
      function insert(head) {
        if (hasViewport()) return;
        var meta = document.createElement('meta');
        meta.setAttribute('name', 'viewport');
        meta.setAttribute('content', 'width=device-width, initial-scale=1');
        head.insertBefore(meta, head.firstChild);
      }
      if (document.head) { insert(document.head); return; }
      var root = document.documentElement || document;
      var mo = new MutationObserver(function () {
        if (document.head) { insert(document.head); mo.disconnect(); }
      });
      mo.observe(root, { childList: true, subtree: true });
    })();
    """

    private static let darkThemeScript = """
    (function () {
      var css = ':root{color-scheme:dark}html{background-color:#121217 !important}body{background-color:transparent;color:#dcdce4}';
      function inject() {
        if (document.getElementById('undirect-dark-theme')) return;
        var s = document.createElement('style');
        s.id = 'undirect-dark-theme';
        s.textContent = css;
        (document.head || document.documentElement).appendChild(s);
      }
      if (document.documentElement) inject();
      else document.addEventListener('DOMContentLoaded', inject, { once: true });
    })();
    """

    /// Auto-rejects and hides cookie-consent banners, so you never see one.
    /// Recognizes the handful of big consent-management platforms (OneTrust,
    /// Cookiebot, Didomi, Quantcast/IAB TCF, Osano, Termly) plus a generic
    /// selector list for everything else, and calls each platform's own
    /// "reject non-essential" API where one exists rather than just hiding
    /// the banner blind. Turn off in Settings to see banners normally.
    private static let consentAutoHandlerScript = """
    (function () {
      var selectors = [
        '#onetrust-banner-sdk', '#onetrust-consent-sdk', '.onetrust-pc-dark-filter',
        '#CybotCookiebotDialog', '#CybotCookiebotDialogBodyUnderlay',
        '.qc-cmp2-container', '.fc-consent-root', '#sp_message_container', '[class^="sp_message_container"]',
        '.didomi-popup-container', '#didomi-host', '.didomi-consent-popup-backdrop',
        '.osano-cm-window', '.osano-cm-dialog', '.termly-styles-consent-container',
        '#cookiescript_injected', '.cc-window', '.cc-banner', '#cookie-law-info-bar',
        '#cookieConsentContainer', '.cookie-consent', '.cookie-banner', '.cookie-notice',
        '#cookie-notice', '.cookiebar', '#cookiebar', '.truste_box_overlay',
        '#truste-consent-track', '.tp-modal-overlay', '#gdpr-consent-tool-wrapper',
        '#usercentrics-root', '#usercentrics-cmp-ui', '.uc-banner-overlay',
        '#consent_blackbar', '#axeptio_overlay', '.axeptio_widget',
        '[class*="cookie-consent" i]', '[id*="cookie-consent" i]', '[class*="cookiebanner" i]',
        '[aria-label*="cookie" i][role="dialog"]'
      ];

      function rejectKnownCMPs() {
        try { if (window.Cookiebot && Cookiebot.submitCustomConsent) Cookiebot.submitCustomConsent(false, false, false); } catch (e) {}
        try { if (window.OneTrust && OneTrust.RejectAll) OneTrust.RejectAll(); } catch (e) {}
        try {
          if (window.didomiOnReady && didomiOnReady.push) {
            didomiOnReady.push(function (Didomi) { try { Didomi.setUserDisagreeToAll(); } catch (e) {} });
          }
        } catch (e) {}
        try {
          if (typeof window.__tcfapi === 'function') {
            window.__tcfapi('setGdprApplies', 2, function () {}, 0);
          }
        } catch (e) {}
        try { if (window.__cmp) window.__cmp('setConsent', null, function () {}, false); } catch (e) {}
        try { if (window.Osano && Osano.cm && Osano.cm.denyAll) Osano.cm.denyAll(); } catch (e) {}
        try { if (window.UC_UI && UC_UI.rejectAllConsents) UC_UI.rejectAllConsents(); } catch (e) {}
        try { if (window._axcb) window._axcb.push(function (axeptio) { axeptio.on('ready', function () { axeptio.userDeny && axeptio.userDeny(); }); }); } catch (e) {}
      }

      // Some CMPs (notably a few Google/IAB TCF integrations) render inside
      // an open shadow root specifically to dodge plain querySelectorAll-
      // based hiding. Walk into every open shadow root too, not just the
      // light DOM.
      function forEachRoot(root, fn) {
        fn(root);
        var all = root.querySelectorAll ? root.querySelectorAll('*') : [];
        for (var i = 0; i < all.length; i++) {
          if (all[i].shadowRoot) forEachRoot(all[i].shadowRoot, fn);
        }
      }

      function hideKnown(root) {
        var sel = selectors.join(',');
        try {
          var els = root.querySelectorAll(sel);
          for (var j = 0; j < els.length; j++) els[j].style.setProperty('display', 'none', 'important');
        } catch (e) {}
      }

      // Catch-all for banners not in the known list: a fixed/sticky,
      // reasonably large, high-stacked element whose own text reads like a
      // cookie/consent notice. Capped text length and z-index/position
      // requirements keep this from matching ordinary page content.
      function looksLikeConsentOverlay(el) {
        if (!el || !el.getBoundingClientRect) return false;
        var rect = el.getBoundingClientRect();
        if (rect.width < window.innerWidth * 0.4 || rect.height < 32 || rect.height > window.innerHeight * 0.9) return false;
        var style = window.getComputedStyle(el);
        if (style.position !== 'fixed' && style.position !== 'sticky') return false;
        var z = parseInt(style.zIndex, 10);
        if (isNaN(z) || z < 100) return false;
        if (style.display === 'none' || style.visibility === 'hidden') return false;
        var text = (el.innerText || '').trim();
        if (!text || text.length > 2500) return false;
        return /cookie|consent|gdpr|ccpa|privacy preferences|we (use|value) your data|accept all|manage preferences|personali[sz]ed ads/i.test(text);
      }

      function hideHeuristic(root) {
        var candidates = root.querySelectorAll ? root.querySelectorAll('body > div, body > section, body > aside, [role="dialog"], [role="alertdialog"]') : [];
        for (var i = 0; i < candidates.length; i++) {
          if (looksLikeConsentOverlay(candidates[i])) {
            candidates[i].style.setProperty('display', 'none', 'important');
          }
        }
      }

      function hide() {
        forEachRoot(document, function (root) {
          hideKnown(root);
          hideHeuristic(root);
        });
        // Many banners lock page scroll while shown; undo that once hidden.
        if (document.documentElement) document.documentElement.style.overflow = '';
        if (document.body) document.body.style.overflow = '';
      }

      function run() { hide(); rejectKnownCMPs(); }
      if (document.documentElement) run(); else document.addEventListener('DOMContentLoaded', run, { once: true });

      var observer = new MutationObserver(function () {
        clearTimeout(window.__undirectConsentDebounce);
        window.__undirectConsentDebounce = setTimeout(hide, 250);
      });
      function observe() {
        if (document.documentElement) observer.observe(document.documentElement, { childList: true, subtree: true });
      }
      if (document.documentElement) observe(); else document.addEventListener('DOMContentLoaded', observe, { once: true });

      // Banners frequently arrive late via their own async script; keep trying briefly.
      [400, 1000, 2000, 4000, 7000].forEach(function (t) { setTimeout(run, t); });
    })();
    """


    /// Reports real taps, password submissions and blocked resource loads, and
    /// implements the click-through used to get past redirect/ad overlays.
    private static func agentScript(messageName: String) -> String {
        #"""
        (function () {
          if (window.__undirectAgent) return;
          window.__undirectAgent = true;
          var NAME = '\#(messageName)';
          var isTop = (window.top === window);
          function post(m) { try { window.webkit.messageHandlers[NAME].postMessage(m); } catch (e) {} }

          if (isTop) {
            document.addEventListener('touchstart', function (e) {
              if (window.__undirectPicking) return;
              var t = e.changedTouches && e.changedTouches[0];
              if (!t) return;
              window.__undirectTapEl = e.target;
              post({ type: 'tap', x: t.clientX, y: t.clientY });
            }, { capture: true, passive: true });
            document.addEventListener('click', function (e) {
              if (window.__undirectPicking || !e.isTrusted) return;
              window.__undirectTapEl = e.target;
              post({ type: 'tap', x: e.clientX, y: e.clientY });
            }, true);
          }

          function checkLogin() {
            try {
              var pw = document.querySelectorAll('input[type=password]');
              for (var i = 0; i < pw.length; i++) {
                if (pw[i].value && pw[i].value.length > 0) { post({ type: 'login' }); return; }
              }
            } catch (e) {}
          }
          document.addEventListener('submit', checkLogin, true);
          document.addEventListener('click', function (e) {
            var b = e.target && e.target.closest && e.target.closest('button, input[type=submit], [role=button]');
            if (b) checkLogin();
          }, true);
          document.addEventListener('keydown', function (e) {
            if (e.key === 'Enter' && e.target && e.target.type === 'password') checkLogin();
          }, true);

          var failed = [], timer = null;
          document.addEventListener('error', function (e) {
            var t = e.target;
            if (!t || t === window) return;
            var u = t.currentSrc || t.src || t.href;
            if (!u || typeof u !== 'string') return;
            try {
              var h = new URL(u, location.href).hostname;
              if (!h) return;
              failed.push(h);
              if (!timer) timer = setTimeout(function () {
                post({ type: 'failed', hosts: failed });
                failed = []; timer = null;
              }, 1000);
            } catch (_) {}
          }, true);

          window.__undirectClickThrough = function (x, y) {
            var el = document.elementFromPoint(x, y);
            if (!el) return null;
            var prev = window.__undirectTapEl;
            var same = prev && (el === prev || (el.contains && el.contains(prev)) || (prev.contains && prev.contains(el)));
            var a = el.closest ? el.closest('a[href]') : null;
            if (!same && a && a.href && a.href.indexOf('javascript:') !== 0) return { href: a.href };
            window.__undirectTapEl = el;
            var o = { bubbles: true, cancelable: true, clientX: x, clientY: y, view: window };
            ['pointerdown', 'mousedown', 'pointerup', 'mouseup', 'click'].forEach(function (type) {
              try {
                var C = (type.indexOf('pointer') === 0 && window.PointerEvent) ? PointerEvent : MouseEvent;
                el.dispatchEvent(new C(type, o));
              } catch (e) {}
            });
            return { dispatched: true };
          };
        })();
        """#
    }

    /// Element picker used by "Hide element…".
    private static func pickerScript(messageName: String) -> String {
        #"""
        (function () {
          if (window.__undirectPicker) return;
          var NAME = '\#(messageName)';
          var box = null, current = null;
          function post(m) { try { window.webkit.messageHandlers[NAME].postMessage(m); } catch (e) {} }
          function esc(s) { return (window.CSS && CSS.escape) ? CSS.escape(s) : s.replace(/[^a-zA-Z0-9_-]/g, '\\$&'); }
          function good(n) { return n && n.length < 40 && !/\d{3,}/.test(n) && !/^(css|sc|jsx|emotion|svelte)-/.test(n); }
          function part(el) {
            var tag = el.tagName.toLowerCase();
            if (el.id && good(el.id)) return '#' + esc(el.id);
            var cls = Array.prototype.filter.call(el.classList, good).slice(0, 3).map(function (c) { return '.' + esc(c); }).join('');
            var p = tag + cls;
            var parent = el.parentElement;
            if (parent && !cls) {
              var same = Array.prototype.filter.call(parent.children, function (c) { return c.tagName === el.tagName; });
              if (same.length > 1) p += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
            }
            return p;
          }
          function selectorFor(el) {
            var parts = [], e = el;
            for (var i = 0; i < 6 && e && e !== document.body && e !== document.documentElement; i++) {
              var p = part(e);
              parts.unshift(p);
              if (p.charAt(0) === '#') break;
              try { if (document.querySelectorAll(parts.join(' > ')).length === 1) break; } catch (_) {}
              e = e.parentElement;
            }
            return parts.join(' > ');
          }
          function describe(el) {
            var r = el.getBoundingClientRect();
            var d = el.tagName.toLowerCase();
            if (el.id) d += '#' + el.id;
            else if (el.classList.length) d += '.' + el.classList[0];
            return d + ' (' + Math.round(r.width) + '×' + Math.round(r.height) + ')';
          }
          function highlight(el) {
            if (!box) {
              box = document.createElement('div');
              box.style.cssText = 'position:fixed;z-index:2147483647;pointer-events:none;border:2px solid #ff5c8a;background:rgba(255,92,138,0.25);border-radius:4px;';
              document.documentElement.appendChild(box);
            }
            var r = el.getBoundingClientRect();
            box.style.left = r.left + 'px'; box.style.top = r.top + 'px';
            box.style.width = r.width + 'px'; box.style.height = r.height + 'px';
          }
          function info() { return current ? { selector: selectorFor(current), label: describe(current) } : null; }
          function swallow(e) {
            if (!window.__undirectPicking) return;
            e.stopImmediatePropagation();
            if (e.type === 'click') {
              e.preventDefault();
              var el = document.elementFromPoint(e.clientX, e.clientY);
              if (!el || el === document.documentElement || el === document.body || el === box) return;
              current = el;
              highlight(el);
              var i = info();
              post({ type: 'pick', selector: i.selector, label: i.label });
            }
          }
          ['click', 'mousedown', 'mouseup', 'pointerdown', 'pointerup', 'touchstart', 'touchend'].forEach(function (t) {
            document.addEventListener(t, swallow, true);
          });
          window.__undirectPicker = {
            start: function () { window.__undirectPicking = true; current = null; },
            parent: function () {
              if (current && current.parentElement && current.parentElement !== document.body && current.parentElement !== document.documentElement) {
                current = current.parentElement;
                highlight(current);
              }
              return info();
            },
            hide: function () { if (current) current.style.setProperty('display', 'none', 'important'); this.stop(); },
            stop: function () { window.__undirectPicking = false; current = null; if (box) { box.remove(); box = null; } }
          };
        })();
        """#
    }
}
