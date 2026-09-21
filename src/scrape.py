"""Scraper for https://quotes.toscrape.com/scroll using Playwright."""

import json
import os

from playwright.sync_api import sync_playwright

URL = "https://quotes.toscrape.com/scroll"
OUT_DIR = os.environ.get("OUT_DIR", os.path.join(os.path.dirname(__file__), "..", "out"))
OUT_FILE = os.path.join(OUT_DIR, "result.json")


def main() -> None:
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page()
        page.goto(URL, wait_until="networkidle")

        # Данные подгружаются JS по мере скролла, поэтому скроллим,
        # пока появляются новые цитаты.
        stable_rounds = 0
        previous = -1
        quote_count = 0

        while stable_rounds < 3:
            page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
            page.wait_for_load_state("networkidle")
            quote_count = page.locator(".quote").count()

            if quote_count == previous:
                stable_rounds += 1
            else:
                stable_rounds = 0
            previous = quote_count

        quotes = page.eval_on_selector_all(
            ".quote",
            """elements => elements.map(q => ({
                text: q.querySelector('.text')?.textContent.trim() ?? null,
                author: q.querySelector('.author')?.textContent.trim() ?? null,
                tags: [...q.querySelectorAll('.tag')].map(t => t.textContent.trim()),
            }))""",
        )
        browser.close()

    if not quotes:
        raise RuntimeError("No quotes were scraped")

    os.makedirs(OUT_DIR, exist_ok=True)
    with open(OUT_FILE, "w", encoding="utf-8") as f:
        json.dump(quotes, f, ensure_ascii=False, indent=2)
        f.write("\n")
    print(f"Saved {len(quotes)} quotes to {OUT_FILE}")


if __name__ == "__main__":
    main()