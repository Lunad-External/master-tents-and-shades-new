# Before you change anything — read this

Every page on this site (`index.html`, `*.dc.html`) contains two parts:

1. **`<x-dc>...</x-dc>`** — the real template. This is what `support.js` boots
   into an interactive React app in the browser. Edit content here.
2. **`<noscript data-dc-prerendered="1">...</noscript>`** — a generated,
   fully-rendered text snapshot of the same page, inserted right after
   `</x-dc>`. This exists so crawlers that don't execute JavaScript (Bing,
   GPTBot, ClaudeBot, PerplexityBot, link-preview bots, etc.) can read real
   content instead of empty template markup. It is invisible to every normal
   visitor — browsers with JavaScript enabled never render `<noscript>`
   contents.

**Never hand-edit the `<noscript>` block.** It's generated output and will be
silently overwritten the next time `prerender.py` runs. If it goes out of sync
with the real content above it, crawlers will see stale/wrong text.

## Workflow for any content change

1. **Edit the page as normal** — only touch what's inside `<x-dc>...</x-dc>`.

2. **Stage your changes and commit normally:**
   ```
   git add .
   git commit -m "Describe the change"
   ```

   Once the one-time setup below is complete, the `pre-commit` hook detects
   staged page changes and regenerates the matching snapshot automatically.
   It stages the generated HTML into the same commit. If rendering fails, the
   commit stops so stale crawler content cannot be committed.

   The hook runs only during `git commit`, not during `git add`. Commits that
   contain only documentation or deployment changes skip prerendering.

3. **Manual fallback, when needed:**
   ```
   python3 prerender.py --only <slug>
   ```
   Example: edited `Arcum Tent.dc.html` → `python3 prerender.py --only arcum-tent`.
   Changed several pages, or unsure of the slug? Just run `python3 prerender.py`
   with no flag — it regenerates all pages and is safe to re-run any time
   (it replaces the existing `<noscript>` block rather than stacking a new one).
   It starts its own local server internally — you don't need anything else
   running first.

4. **Check the diff matches your edit:**
   ```
   git diff "Arcum Tent.dc.html"
   ```
   Confirm only the `<noscript>` block changed, and its text reflects your
   edit — not stale, not empty/placeholder-looking.

5. **Spot-check it live before committing:**
   ```
   python3 dev_server.py --port 8000
   ```
   (Not `python -m http.server` — that has no route mapping and will 404 on
   every clean URL like `/about/`. `dev_server.py` mirrors what production
   nginx does.)

   With JavaScript **enabled** (normal browsing), open the page and confirm:
   - your edit displays correctly
   - the header dropdown still opens on hover
   - the homepage hero image still auto-rotates (if you touched the homepage)
   - no new errors in the browser console (F12)

   Optional — see exactly what a non-JS crawler sees: DevTools (F12) →
   Settings → Preferences → "Disable JavaScript" → reload. You should see
   plain, readable text matching your edit. Re-enable JavaScript after.

6. **Commit the source edit and the regenerated `<noscript>` block together,
   as one change.** Never commit them separately — a content edit without its
   matching snapshot regen is exactly how the crawler-visible content goes
   stale.

7. **Deploy as usual** via `deploy.sh` — nothing about deploy changed for this.

## One-time Git hook setup

Run this once from PowerShell in the repository:

```
.\setup-git-hooks.ps1
```

This configures the repository to use the versioned `.githooks/pre-commit`
script. Each clone needs this setup once. After that, `git push` sends the
already-synchronized commit; no post-push regeneration is needed.

The hook requires Python and the Playwright dependencies used by
`prerender.py`. If a relevant file has unstaged edits, the hook stops and asks
you to stage or stash them first, preventing unstaged content from entering a
commit accidentally.

## Adding or renaming a page

- **New page**: after step 2 generates its snapshot, also add its URL to
  `sitemap.xml` by hand — `prerender.py` doesn't touch the sitemap.
- **Renamed page** (filename change): the slug changes too. Update any
  internal links pointing to the old slug and `sitemap.xml`'s entry — same as
  today, unrelated to prerendering.

## If you forget step 2

Nothing breaks for real visitors — the `<x-dc>` path is completely
independent of the `<noscript>` block. The only consequence is crawlers keep
seeing outdated text until you next run `prerender.py` and deploy.
