# Device test checklist

Most changes since v3.18 have been checked only by the CI build and by logs you sent back. This list is the pass or fail test for the latest releases. Run each check on the phone and write PASS or FAIL in the Result column. For every FAIL, export the log from Settings and send it with a short note. Detailed logs are kept only when something fails.

## Speed (v3.36)

| Check | Pass if | Result |
| --- | --- | --- |
| Cold launch with about 10 saved tabs | The visible tab appears quickly and the other tabs do not slow launch | |
| Relaunch with a Tor tab saved | The Tor tab loads, and the log shows Tor ready sooner than before | |
| First page load right after launch | Ads and trackers are already blocked | |
| Scroll a long page and open the tab sidebar | No stutter | |

## Background tabs and memory (v3.37)

| Check | Pass if | Result |
| --- | --- | --- |
| Launch with several tabs and wait one minute | The log shows "Background tabs ready" | |
| Switch to a background tab | Its picture appears at once, then the live page replaces it | |
| Open the tab overview | Thumbnails show real pages | |
| Play a video, switch away, wait 12 minutes | The tab stays loaded and keeps playing | |
| Type half a message in a form, switch away, wait 12 minutes | The text is still there | |
| Open about 10 tabs, leave them 12 minutes, return to an idle one | The log shows "Unloaded", and the tab reloads from its picture | |
| Compare memory before and after warm-up | Memory is clearly lower after warm-up. If not, report it | |
| Set "Load other tabs in background" to Off | Other tabs load only when opened | |
| Close a tab while others are loading | No crash and no stuck spinner | |

## Blocking (v3.38 and v3.39)

| Check | Pass if | Result |
| --- | --- | --- |
| Open a news site with many ads | Few ads and no large empty gaps | |
| Block a domain in Custom blocklist, then open it | It does not load. After you remove it, it loads | |
| Allow a domain that a list blocks | Its requests go through. After you remove it, it is blocked again | |
| Block and then allow the same name | The newest choice wins and no entry is duplicated | |
| Check the log after changing the list | It reports the same number of lists compiled as expected | |
| Watch YouTube, log in with Facebook, open an Instagram profile | All three work | |
| Tap an email or affiliate link | It still reaches its destination | |
| Open a site with a cookie banner | The banner is rejected and the page still scrolls | |
| Run the d3ward ad block test page | Most items are blocked. Report any that are not with `add_case.py block <url>` | |

## Sandboxing and fingerprinting (v3.40)

| Check | Pass if | Result |
| --- | --- | --- |
| Log in to a site in one tab, then open the same site in a second tab | The second tab is logged out | |
| Use the browser, close the tab, and open the site again | You are logged out, unless the site is under Kept Logins | |
| Log in to a site, accept "keeping you logged in", close the tab, open the site in a new tab | The new tab is still logged in | |
| Open a Cloudflare protected site, pass the check, close the tab, open it again | You are not asked to verify again | |
| Settings, Clear website data | All tabs and kept sites are logged out | |
| Open a Tor tab and a normal tab on the same site | They do not share any login | |
| Open an installed web app, log in, quit the app, reopen it | The web app is still logged in | |
| Visit coveryourtracks.eff.org in two different tabs | The two tabs report different canvas and audio hashes | |
| Use a site that measures text, such as an online editor | Layout and text wrapping look normal | |
| Open a new blank tab, type the address of a kept login site | You are logged in (the saved cookies are copied into the new tab) | |
| Check that the first launch after updating keeps your kept logins | Kept sites are still logged in | |

## When something looks wrong in daily use

Run `python3 Tools/adblock-test/add_case.py block <url>` when an ad got through, or `add_case.py allow <url>` when a site broke. The case becomes a permanent test.
