# Device test checklist

Nothing after v3.18 has been compiled or run anywhere except CI and the device
logs you've sent back. This is the pass/fail list for the latest releases.
Run it on the phone, mark each line, and send back any **FAIL** with a log
export (Settings → export log). Logs are only kept in detail when something fails.

Legend: ☐ not tried · ✅ pass · ❌ fail (note what you saw)

## v3.36 — speed
| | Check | Pass if |
|---|---|---|
| ☐ | Cold launch with ~10 saved tabs | The visible tab appears quickly; the others don't hold up launch |
| ☐ | Force-quit, relaunch with a Tor tab saved | Tor tab loads; log shows Tor ready sooner than before |
| ☐ | First page load right after launch | Ads/trackers are still blocked (no ad flashes in) |
| ☐ | Scroll a long page, open the tab sidebar | No stutter |

## v3.37 — background tabs and memory
| | Check | Pass if |
|---|---|---|
| ☐ | Launch with several tabs, wait ~1 min | Log: `Background tabs ready: N loaded and pictured` |
| ☐ | Switch to a background tab | Its picture shows instantly, then the live page replaces it |
| ☐ | Tab overview | Thumbnails show real pages, not blanks |
| ☐ | Play a video, switch away, wait 12 min | Tab stays loaded and keeps playing; log says `Kept … (media)` |
| ☐ | Type half a message in a form, switch away, wait 12 min | Text is still there; log says `Kept … (unsent text)` |
| ☐ | Open ~10 tabs, leave 12+ min, return to an idle one | Log shows `Unloaded … after N min idle`; the tab reloads and shows its picture |
| ☐ | Memory (Xcode → Debug navigator, or Settings → battery/storage) | Resident memory is clearly lower after warm-up than with all tabs live. **If not, tell me:** the next step is destroying idle web views |
| ☐ | Settings → Load other tabs in background = Off | Other tabs don't load until opened |
| ☐ | Tor tab in the background | Loads after the normal tabs; no leak to the open network |
| ☐ | Close a tab mid-warm-up | No crash, no stuck spinner |

## v3.38 / v3.39 — blocking
| | Check | Pass if |
|---|---|---|
| ☐ | Open a news site with heavy ads | Fewer ads and no empty-box gaps beyond what hiding already did |
| ☐ | Settings → Custom blocklist → Block `example.org`, open it | Blocked page/failed load; remove it, page loads again |
| ☐ | Allow a domain a list blocks (e.g. `criteo.com`) | Requests to it go through; remove it and it's blocked again |
| ☐ | Block then Allow the same name | Newest choice wins; no duplicates in either list |
| ☐ | Log after changing the list | `Content rules compiled: N/N lists` (N matches, nothing failed) |
| ☐ | YouTube video plays, a Facebook login works, an Instagram profile opens | All fine (these hosts are deliberately left alone) |
| ☐ | An email/affiliate link (click.mailchimp.com etc.) | Still reaches its destination |
| ☐ | A site with a cookie banner | Auto-rejected as before; page not scroll-locked |
| ☐ | https://d3ward.github.io/toolz/adblock.html | Mostly red/blocked; note any that get through → `Tools/adblock-test/add_case.py block <url>` |

## Anything that looks wrong in real use
Run `python3 Tools/adblock-test/add_case.py block <url>` (an ad got through) or
`... allow <url>` (a site broke). That records it as a permanent regression test.
