#!/usr/bin/env python3
"""Inject a <noscript> SEO snapshot into every DC page, in place.

This does NOT touch each page's <x-dc> template at all — support.js's boot()
permanently consumes <x-dc> to mount its React tree, so any script that
replaces <x-dc> with the rendered output breaks the live site for real users
(no more componentDidMount, no timers, no hover handlers). Instead, this
script renders each route in a real browser and inserts the result as a
<noscript data-dc-prerendered="1"> block right after </x-dc>. Browsers with
JS enabled never parse <noscript> contents into the live DOM, so real users
see exactly what they see today; crawlers that don't execute JS see real text.

Run locally after editing page content, review the diff, commit the result.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time
from pathlib import Path
from urllib.parse import quote

from playwright.sync_api import sync_playwright

COMPONENTS = {
    "Header.dc.html",
    "Footer.dc.html",
    "BlogPost.dc.html",
    "InfoPage.dc.html",
    "ProductPage.dc.html",
}

NOSCRIPT_OPEN = '<noscript data-dc-prerendered="1">'
NOSCRIPT_RE = re.compile(
    r'\n?<noscript data-dc-prerendered="1">.*?</noscript>\n?',
    re.DOTALL,
)
DATA_DC_TPL_RE = re.compile(r'\s*data-dc-tpl="\d+"')
DATA_SC_NAME_RE = re.compile(r'\s*data-sc-name="[^"]*"')

# With JS disabled, the raw <x-dc> template renders as-is (dc-import never
# resolves, so the header is simply missing) right above the real content in
# our <noscript> block below. This hides the raw template in that one case —
# real (JS-enabled) visitors never see a <noscript>-scoped rule at all, so
# this has zero effect on them.
HEAD_GUARD = '<noscript data-dc-noscript-guard="1"><style>x-dc{display:none}</style></noscript>'
HEAD_GUARD_RE = re.compile(
    r'\n?<noscript data-dc-noscript-guard="1">.*?</noscript>\n?',
    re.DOTALL,
)


def ensure_head_guard(source: Path) -> None:
    text = source.read_text(encoding="utf-8")
    text = HEAD_GUARD_RE.sub("", text)

    marker = "</head>"
    idx = text.find(marker)
    if idx == -1:
        print(f"  SKIP head guard (no </head> found): {source.name}", file=sys.stderr)
        return

    new_text = text[:idx] + HEAD_GUARD + "\n" + text[idx:]
    source.write_text(new_text, encoding="utf-8")


def slug_for(source: Path) -> str:
    name = source.name[:-8]
    slug = "-".join(
        "".join(char.lower() if char.isalnum() else " " for char in name).split()
    )
    return slug


def routes_for(root: Path) -> list[tuple[str, Path]]:
    routes = [("", root / "index.html")]
    for source in sorted(root.glob("*.dc.html")):
        if source.name not in COMPONENTS:
            routes.append((slug_for(source), source))
    return routes


def clean_fragment(html: str) -> str:
    html = DATA_DC_TPL_RE.sub("", html)
    html = DATA_SC_NAME_RE.sub("", html)
    return html.strip()


XDC_OPEN_RE = re.compile(r"<x-dc(?:\s[^>]*)?>")


def inject_noscript(source: Path, fragment: str) -> bool:
    text = source.read_text(encoding="utf-8")
    text = NOSCRIPT_RE.sub("", text)

    # Insert BEFORE <x-dc>, not after </x-dc>. A non-rendering text extractor
    # (a crawler that doesn't run JS or apply CSS) reads the file top to
    # bottom — putting the clean, real content first means it's read before
    # the raw template's leftover `{{ }}` placeholder text, instead of after.
    # This doesn't touch <x-dc> or affect real (JS-enabled) visitors at all.
    match = XDC_OPEN_RE.search(text)
    if not match:
        print(f"  SKIP (no <x-dc> found): {source.name}", file=sys.stderr)
        return False

    insert_at = match.start()
    block = f"{NOSCRIPT_OPEN}{fragment}</noscript>\n"
    new_text = text[:insert_at] + block + text[insert_at:]
    source.write_text(new_text, encoding="utf-8")
    return True


def render_route(playwright, base_url: str, route: str) -> str | None:
    path = "/" if not route else f"/{quote(route)}/"
    browser = playwright.chromium.launch(headless=True)
    try:
        page = browser.new_page(viewport={"width": 1440, "height": 900})
        page.goto(f"{base_url}{path}", wait_until="commit", timeout=15_000)

        page.wait_for_function(
            """() => {
                const root = document.querySelector('#dc-root');
                if (!root) return false;
                if (document.querySelectorAll('.sc-placeholder').length > 0) return false;
                if (document.querySelectorAll('.sc-logic-error').length > 0) return false;
                return document.body.innerText.trim().length > 300;
            }""",
            timeout=20_000,
        )
        page.wait_for_load_state("networkidle", timeout=10_000)

        # Settle IntersectionObserver / requestAnimationFrame-gated content
        # (e.g. InfoPage.dc.html's stats counter) before capturing.
        page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
        page.wait_for_timeout(2000)

        root = page.locator("#dc-root")
        return root.inner_html()
    except Exception as error:  # noqa: BLE001
        print(f"  FAILED to render {path}: {error}", file=sys.stderr)
        return None
    finally:
        browser.close()


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Inject prerendered <noscript> SEO snapshots into DC pages."
    )
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument(
        "--only", help="Only process routes whose slug contains this substring."
    )
    args = parser.parse_args()

    root = Path(__file__).resolve().parent
    server = subprocess.Popen(
        [sys.executable, str(root / "dev_server.py"), "--port", str(args.port)],
        cwd=root,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        time.sleep(0.5)
        if server.poll() is not None:
            raise RuntimeError("dev_server.py exited before rendering started")

        base_url = f"http://127.0.0.1:{args.port}"
        routes = routes_for(root)

        # Always applied to every page, regardless of --only, since it's a
        # cheap static text fix unrelated to rendering.
        for _, source in routes:
            ensure_head_guard(source)

        if args.only:
            routes = [(slug, src) for slug, src in routes if args.only in slug]

        ok, failed = 0, []
        with sync_playwright() as playwright:
            for slug, source in routes:
                label = slug or "/"
                print(f"Rendering {label} ({source.name})", flush=True)
                html = render_route(playwright, base_url, slug)
                if html is None:
                    failed.append(label)
                    continue
                fragment = clean_fragment(html)
                if inject_noscript(source, fragment):
                    ok += 1

        print(f"\nDone: {ok} injected, {len(failed)} failed.")
        if failed:
            print("Failed routes:", ", ".join(failed))
            sys.exit(1)
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()


if __name__ == "__main__":
    main()
