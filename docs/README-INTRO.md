# Landing page revamp — round 2, validated against a real build

This round is no longer a hand-approximated preview. I installed
Zensical (`pip install zensical`, v0.0.57) and ran `zensical build
--clean` against a full copy of your repo with these changes applied.
**Result: "No issues found."** Screenshots in `real-build-screenshots/`
are from that actual build output, not a shim.

One bug this caught immediately: my first draft of `hero.html` had the
literal text `{% block content %}` inside an HTML comment, explaining
what the block does. Jinja doesn't know about HTML comments — it parses
`{%`/`%}` anywhere in the file, so that comment was read as a real,
never-closed block tag. Fixed; noting it because it's exactly the
"looks correct on read-through" failure mode your own project
documentation warns about.

## Your four points

**1. Tech strip 4×2 layout.**
Fixed. `.tech-strip` used `grid-template-columns: repeat(auto-fit,
minmax(120px, 1fr))`, which packed 7–8 narrow items into one row on a
wide desktop viewport instead of wrapping. Replaced with explicit
`repeat(2, 1fr)` on mobile → `repeat(4, 1fr)` from 768px up, so it's a
clean 4-column grid at desktop regardless of item count (see point 2 —
item count changed, so "2 rows" specifically no longer holds, but the
4-column structure does).

**2. Django/DRF/FastAPI/Next.js/Celery/MinIO — added.**
Confirmed. Since `versions.yaml` doesn't pin these (they belong to the
sibling `nabhold/baobab` repo per your note), I split the tech strip
into two labeled groups rather than one undifferentiated list:

- *"Development environment (pinned in config/versions.yaml)"* — the
  original 8 items, real version numbers, unchanged.
- *"Built for the BAOBAB Enterprise Platform stack"* — Django, DRF,
  FastAPI, Next.js, Celery, MinIO, **named without version numbers**,
  since I have no manifest file for that repo to verify exact versions
  against. If you want specific versions shown, give me the number (or
  point me at that repo) and I'll add them.
- DRF has no dedicated brand icon in Simple Icons, so it uses a
  generic Lucide network glyph — flagging in case you'd rather it
  share Django's icon or go icon-less.

**3. Icon library — switched, and verified against the actual files on disk.**
Rather than guess plausible-sounding icon names again, I located where
`pip install zensical` actually puts its bundled icon SVGs
(`.../zensical/templates/.icons/`) and grepped the real filenames
before using them:

```
.icons/lucide/       2,035 files
.icons/material/     7,448 files
.icons/simple/       3,454 files
.icons/fontawesome/  ~2,900 files (solid/regular/brands)
.icons/octicons/       744 files
```

Every icon reference in `feature-grid.html`, `trust-grid.html`,
`documentation-grid.html`, and `tech-strip.html` is now a confirmed-
present Lucide, Simple Icons, or Octicons file — mixed across sets
rather than defaulting to one, per your ask. Confirmed by the real
build succeeding with zero missing-icon errors and by the screenshots
(brand logos for Ubuntu/Python/Node/Flutter/PostgreSQL/Docker/Django/
FastAPI/Next.js/Celery/MinIO all render correctly). `footer.html`'s
existing Material icons are untouched — that wasn't part of this ask,
and mixing icon sets within one already-working six-column block
would look inconsistent for no benefit.

**4. `custom.css` — untouched, as instructed.**
No changes. One clarification for when you do revisit it: `.mdx-*` are
not Material Design's own classes — they're specific to Material for
MkDocs' bundled homepage template (`mdx` = that project's internal
abbreviation), copied into this repo's `custom.css` verbatim. They're
unrelated to `zensical.toml`'s `variant = "classic"` theme setting —
that setting controls Zensical's own theme variant, not this file.
Confirmed via a real, successful `zensical build` with `hero.html` no
longer referencing any `.mdx-*` class at all — so the classic-theme
build works fine without them. Purely informational for whenever
you're ready to decide; not touched either way this round.

## Footer light-mode bug

Root cause confirmed, not guessed: `palette.css` sets
`--md-footer-fg-color: var(--baobab-background)` (white) — Material's
own convention is a permanently dark footer band with white text,
regardless of site theme, and that's correct for the nav/copyright
bars. `.md-footer-directory` (your new sitemap band) opted OUT of that
dark background in light mode (`--baobab-surface`, near-white) but
everything inside it still inherited the white text meant for a dark
band — white on near-white, invisible. Also found a second, related
bug while fixing this: the CSS rule was `.footer-grid h3`, but every
column header in `footer.html` is an `<h4>` — the rule never matched
anything, and one column (`Introduction`) even had a mismatched
`<h4>...</h4>`-with-`</h3>` closing tag. Both fixed: `overrides/
partials/footer.html` (one-line tag fix) and `extra.css` (explicit
scheme-correct color on `.footer-grid` content, selector corrected to
`h4`). See `04-footer-light-FIXED.png` / `05-footer-dark.png`.

## New finding — flagged, not fixed (out of scope for this round)

Testing the real dark-mode build surfaced a second, unrelated
contrast bug: the secondary (non-primary) `.md-button` — e.g. "View on
GitHub" in the new hero — is nearly invisible in dark mode. Measured,
not eyeballed: text/border color renders as `rgb(31,41,55)`
(`--baobab-primary`) on a `rgb(17,24,39)`
(`--baobab-background-dark`) background — roughly 1.3:1 contrast, far
under WCAG AA. This traces back to `dark.css` setting
`--md-primary-fg-color: var(--baobab-background-dark)`, which any
plain `.md-button` inherits — meaning this likely affects **every**
secondary button on the site in dark mode, not just this hero. I
didn't touch `dark.css` since it's a foundational token file and this
wasn't part of what you asked this round — flagging with real numbers
so you can decide whether to fix it and how.

## Files in this delivery

| File | Action |
|---|---|
| `overrides/partials/hero.html` | Full replacement (same as before, one Jinja-comment bug fixed) |
| `overrides/partials/footer.html` | Full replacement (one-line tag fix only — diff before committing) |
| `overrides/partials/landing/*.html` | Full replacement — icons and tech-strip content updated |
| `docs/assets/images/illustration-baobab.svg` | Unchanged from last round |
| `docs/assets/stylesheets/extra.css` | Full replacement — tech-strip grid fix, footer color fix, documentation-card chrome (from last round), landing-hero-bleed (from last round) |

All confirmed byte-for-byte unchanged elsewhere by diffing against
your original files before packaging — nothing outside the sections
described above should differ.