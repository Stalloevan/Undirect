SHOULD_BLOCK = """
https://securepubads.g.doubleclick.net/tag/js/gpt.js
https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js
https://googleads.g.doubleclick.net/pagead/ads?client=ca-pub-1
https://www.googletagmanager.com/gtm.js?id=GTM-XXXX
https://www.google-analytics.com/analytics.js
https://ssl.google-analytics.com/ga.js
https://stats.g.doubleclick.net/j/collect
https://www.googleadservices.com/pagead/conversion.js
https://connect.facebook.net/en_US/fbevents.js
https://www.facebook.com/tr?id=123&ev=PageView
https://analytics.twitter.com/i/adsct
https://static.ads-twitter.com/uwt.js
https://px.ads.linkedin.com/collect
https://snap.licdn.com/li.lms-analytics/insight.min.js
https://analytics.tiktok.com/i18n/pixel/events.js
https://static.hotjar.com/c/hotjar-1.js?sv=6
https://script.hotjar.com/modules.js
https://cdn.mxpnl.com/libs/mixpanel-2-latest.min.js
https://api.mixpanel.com/track
https://cdn.segment.com/analytics.js/v1/abc/analytics.min.js
https://api.segment.io/v1/t
https://js.hs-scripts.com/123.js
https://track.hubspot.com/__ptq.gif
https://www.clarity.ms/tag/abc
https://c.clarity.ms/collect
https://static.criteo.net/js/ld/publishertag.js
https://bidder.criteo.com/cdb
https://cdn.taboola.com/libtrc/unip/loader.js
https://trc.taboola.com/sg/x/log
https://widgets.outbrain.com/outbrain.js
https://log.outbrain.com/loggerServices/widget
https://ib.adnxs.com/ut/v3
https://secure.adnxs.com/getuid
https://sb.scorecardresearch.com/beacon.js
https://c.amazon-adsystem.com/aax2/apstag.js
https://aax-us-east.amazon-adsystem.com/e/dtb/bid
https://cdn.ml314.com/tag.js
https://tags.bluekai.com/site/123
https://px.owneriq.net/stas/s/abc
https://pixel.quantserve.com/pixel
https://secure.quantserve.com/quant.js
https://rtb.openx.net/openrtb/2.5
https://u.openx.net/w/1.0/pd
https://ads.pubmatic.com/AdServer/js/showad.js
https://image6.pubmatic.com/AdServer/UCookieSetPug
https://prebid.rubiconproject.com/prebid
https://fastlane.rubiconproject.com/a/api/fastlane.json
https://tpc.googlesyndication.com/simgad/123
https://ad.doubleclick.net/ddm/trackimp
https://cm.g.doubleclick.net/pixel
https://adservice.google.com/adsid/google/ui
https://pubads.g.doubleclick.net/gampad/ads
https://static.chartbeat.com/js/chartbeat.js
https://ping.chartbeat.net/ping
https://cdn.optimizely.com/js/123.js
https://logx.optimizely.com/v1/events
https://js-agent.newrelic.com/nr-spa-1.min.js
https://bam.nr-data.net/events/1/abc
https://browser.sentry-cdn.com/7.0.0/bundle.min.js
https://api.amplitude.com/2/httpapi
https://cdn.amplitude.com/libs/amplitude-8.min.js
https://cdn.heapanalytics.com/js/heap-1.js
https://heapanalytics.com/h
https://stats.wp.com/e-202001.js
https://pixel.wp.com/g.gif
https://sync.adkernel.com/user-sync
https://match.adsrvr.org/track/cmf/generic
https://insight.adsrvr.org/track/up
https://dis.criteo.com/dis/rtb/appnexus
https://js.driftt.com/include/123/abc.js
https://cdn.mouseflow.com/projects/abc.js
https://script.crazyegg.com/pages/scripts/0001/0001.js
https://tr.snapchat.com/config/com/abc.js
https://sc-static.net/scevent.min.js
https://s.pinimg.com/ct/core.js
https://ct.pinterest.com/v3/
https://bat.bing.com/bat.js
https://bat.r.msn.com/action/0
https://ads.yahoo.com/pixel
https://sp.analytics.yahoo.com/spp.pl
https://udc.yahoo.com/v3/ping
https://ads.reddit.com/api/v2.0/conversions
https://events.reddit.com/v1/register
https://alb.reddit.com/rp.gif
https://www.redditstatic.com/ads/pixel.js
https://pixel-config.reddit.com/pixels/abc/config
https://an.facebook.com/v1/placementbid.json
https://graph.facebook.com/v10.0/activities
https://pagead2.googlesyndication.com:443/pagead/ads
wss://tracking.adsrvr.org/socket
https://x.y.z.doubleclick.net/a/b/c
https://DoubleClick.NET/path
https://doubleclick.net
https://cdn.example.com/static/ads.js
https://news.example.org/assets/pagead.js
https://news.example.org/widget/ads.min.js
https://media.example.net/ad-loader.js
https://media.example.net/ad-manager.js?v=2
https://ipwho.is/
https://ipapi.co/json/
https://ipinfo.io/json?token=abc
https://api.ipify.org?format=json
https://us.i.posthog.com/e/
https://app.posthog.com/decide/
""".split()

SHOULD_ALLOW = """
https://www.google.com/search?q=cats
https://accounts.google.com/signin
https://www.gstatic.com/images/branding/product/1x/gmail_48dp.png
https://fonts.googleapis.com/css2?family=Inter
https://fonts.gstatic.com/s/inter/v12/x.woff2
https://www.youtube.com/watch?v=abc
https://i.ytimg.com/vi/abc/hqdefault.jpg
https://rr1---sn-abc.googlevideo.com/videoplayback
https://github.com/Stalloevan/Undirect
https://raw.githubusercontent.com/a/b/main/x.js
https://avatars.githubusercontent.com/u/1
https://en.wikipedia.org/wiki/Ad_blocking
https://upload.wikimedia.org/wikipedia/commons/a/a.png
https://www.apple.com/iphone/
https://developer.apple.com/documentation
https://cdn.jsdelivr.net/npm/react@18/umd/react.production.min.js
https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js
https://unpkg.com/react@18/umd/react.production.min.js
https://www.reddit.com/r/privacy
https://old.reddit.com/r/ios
https://i.redd.it/abc.jpg
https://www.nytimes.com/
https://static01.nyt.com/images/a.jpg
https://www.bbc.co.uk/news
https://news.ycombinator.com/
https://stackoverflow.com/questions/1
https://cdn.sstatic.net/Js/stub.en.js
https://www.amazon.com/dp/B0
https://m.media-amazon.com/images/I/a.jpg
https://www.netflix.com/browse
https://www.twitch.tv/
https://duckduckgo.com/?q=privacy
https://proton.me/mail
https://signal.org/
https://www.torproject.org/
https://check.torproject.org/
https://mozilla.org/
https://addons.mozilla.org/
https://cloudflare.com/
https://challenges.cloudflare.com/turnstile/v0/api.js
https://www.paypal.com/signin
https://checkout.stripe.com/c/pay/abc
https://js.stripe.com/v3/
https://www.dropbox.com/
https://slack.com/
https://zoom.us/j/123
https://www.spotify.com/
https://open.spotify.com/
https://example.com/
https://example.com/advertising-guidelines.html
https://example.com/downloads/pagead-notes.txt
https://example.com/assets/loads.js
https://example.com/uploads.js
https://example.com/radio/ads.json
https://example.com/headline.js
https://notdoubleclick.net/
https://doubleclick.net.example.com/
https://example.com/?u=https://doubleclick.net/
https://example.com/ads.json
https://example.com/pagead.json
https://example.com/ads.jsx
https://www.facebook.com/
https://www.facebook.com/trending
https://graph.facebook.com/v10.0/me
https://connect.facebook.net/en_US/sdk.js
https://www.redditstatic.com/desktop2x/img/a.png
https://s.pinimg.com/images/a.png
https://www.pinterest.com/
https://www.linkedin.com/feed/
https://cdn.segmentify.com/x.js
https://www.msn.com/
https://www.twitter.com/home
https://help.yahoo.com/
""".split()


# Added in v3.39 -----------------------------------------------------------
# Blocked everywhere (ads, verification, pop-unders, telemetry, SDK endpoints).
REQUESTED_FULL = """fls-na.amazon.com criteo.com mgid.com propellerads.com applovin.com api.vungle.com pubmatic.com
live.chartboost.com contextweb.com stackadapt.com pangleglobal.com doubleverify.com pixel.adsafeprotected.com
static.adsafeprotected.com insightexpressai.com rs.fullstory.com cdn.siftscience.com bcp.crwdcntrl.net
sync-tm.everesttech.net o0.ingest.sentry.io browser-intake-datadoghq.com rum.browser-intake-datadoghq.com popads.net
popcash.net clickadu.com exoclick.com juicyads.com xp.apple.com ngfts.lge.com vortex.data.microsoft.com
firebase-settings.crashlytics.com cdn.dynamicyield.com st.dynamicyield.com events.launchdarkly.com
clientstream.launchdarkly.com sdk.iad-01.braze.com cdn.onesignal.com api.onesignal.com static.klaviyo.com a.klaviyo.com
track.customer.io cd.connatix.com capi.connatix.com vid.connatix.com s.innovid.com prd.jwpltx.com""".split()

# Blocked as page resources only; opening them (or framing them) must still work.
REQUESTED_RESOURCE_ONLY = """ads.microsoft.com tagmanager.google.com ads.x.com ads.huawei.com s.youtube.com eu.posthog.com
analytics.pinterest.com widgets.pinterest.com widget.intercom.io appsflyer.com app.appsflyer.com app.adjust.com bnc.lt
kochava.com control.kochava.com partnerstack.com api.partnerstack.com click.mailchimp.com www.anrdoezrs.net www.dpbolvw.net
www.tkqlhce.com shareasale.com www.awin1.com zenaps.com prf.hn t.pepperjamnetwork.com go.skimresources.com
redirector.skimresources.com go.redirectingat.com redirect.viglink.com mssl.fwmrm.net geolocation.onetrust.com
privacyportal.onetrust.com fundingchoicesmessages.google.com""".split()

# Requested but deliberately NOT blocked: blocking them breaks video playback,
# logins, embeds, or the cookie-banner handling. Must load as script AND as page.
REQUESTED_LEFT_ALONE = """redirector.googlevideo.com dai.google.com ssl.p.jwpcdn.com connect.facebook.net graph.facebook.com
graph.instagram.com i.instagram.com consent.cookiebot.com consentcdn.cookiebot.com consent.trustarc.com sdk.privacy-center.org
cdn.privacy-mgmt.com app.usercentrics.eu cmp.inmobi.com cmp.osano.com quantcast.com""".split()

# Facebook/Instagram/VK tracking is blocked by path; the rest of those hosts keeps working.
PATH_BLOCKED = ["https://connect.facebook.net/signals/config/123", "https://connect.facebook.net/en_US/fbds.js",
                "https://vk.com/rtrg?p=VK-RTRG-1", "https://vk.com/rtrg"]
PATH_ALLOWED = [("https://vk.com/feed", "document"), ("https://vk.com/id1", "document"), ("https://vk.com/js/api/openapi.js", "script"),
                ("https://connect.facebook.net/en_US/sdk.js", "script"), ("https://graph.facebook.com/v18.0/me?access_token=x", "raw")]
