---
name: browser
description: Use loom's shared, logged-in Chromium (CDP on 127.0.0.1:9222) to search Google or read pages that block bots or need a login — YouTube, Reddit, X, news sites — or when web search finds nothing recent. Also how to ask the user to take it over (log in, solve a captcha).
---

# Loom's browser

A Chromium that stays running on this host (`loom-browser.service`), with a
persistent profile: sites the user logged in to stay logged in. It looks like a
normal desktop Chrome, so Google answers it, unlike headless Playwright.
Check it is there: `curl -s 127.0.0.1:9222/json/version`. If not, this host
has none; launch Playwright as usual.

Drive it from Python (if `playwright` won't import, run the script with
`uv run --with playwright python script.py`), in **your own tab**, and close only that tab: other
sessions use the same browser, and the user may be looking at it.

```python
from playwright.sync_api import sync_playwright
with sync_playwright() as p:
    ctx = p.chromium.connect_over_cdp("http://127.0.0.1:9222").contexts[0]
    page = ctx.new_page()
    try:
        page.goto("https://www.google.com/search?hl=en&q=...", wait_until="domcontentloaded")
        print(page.eval_on_selector_all("a h3", "e => e.slice(0, 8).map(h => h.innerText + ' <' + h.closest('a').href + '>')"))
    finally:
        page.close()   # never ctx.close() / browser.close()
```

Read text (`inner_text`) rather than screenshots where you can.

**Navigate like a person: click, don't jump to hrefs.** Sites tie a link to
the page it was shown on (Xiaohongshu's `xsec_token`, Google's redirects), and
a bare URL often gives an empty shell or a login wall. Search from the site's
own search page, scroll, click the card's visible link (`card.locator("a.cover")`,
not the first `<a>`, which may be hidden), read the overlay, Escape back. Keep a
pause of a second or two between pages.

**When a site wants a human** (a login wall, "unusual traffic", "confirm
you're not a bot"): leave that page open on the site, and ask the user to
open **Browser** at the bottom of loom's sidebar and do it there; on a phone
the keyboard button in its header types into the focused field. Their login is
kept in the profile, so ask once per site, not per task. Never type the user's
passwords yourself.

Downloads with cookies, e.g. yt-dlp:
`--cookies-from-browser chromium:~/.local/share/loom-browser/profile`.
