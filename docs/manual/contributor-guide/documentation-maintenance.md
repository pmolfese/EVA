# Documentation Maintenance

## Recommended Structure

Use four documentation types:

- **User guide** pages explain features and concepts.
- **Tutorials** walk through complete tasks.
- **Reference** pages list facts such as supported formats and glossary terms.
- **Contributor notes** explain how to maintain the docs.

This structure keeps a manual from turning into one long README.

## Release Checklist

Before publishing a release:

- Build the docs with `python3 scripts/sync-planning-docs.py && mkdocs build --strict`.
- Run each tutorial against the current app.
- Update screenshots that show changed UI.
- Update supported formats and limitations.
- Check links.
- Confirm release notes and documentation agree.

## Screenshot Guidelines

- Capture the actual app, not mockups.
- Prefer task-relevant screenshots over decorative images.
- Avoid screenshots containing sensitive participant data.
- Name files after the page or workflow they support.
- Replace screenshots when controls move or labels change.

## How The Site Is Built

The site is MkDocs with the Material theme. `docs_dir` is `docs/manual`.

`ROADMAP.md`, `ROADMAP_COMPLETE.md` and `docs/design/` are authored at the
repository root, so GitHub renders them and code comments can cite stable paths.
MkDocs cannot read outside `docs_dir`, so `scripts/sync-planning-docs.py`
mirrors them into `docs/manual/development/` and rewrites their cross-links for
the site layout. Those copies are git-ignored generated artifacts — **edit the
root files, never the copies.**

```bash
python3 scripts/sync-planning-docs.py    # required before any build
mkdocs serve                             # preview at 127.0.0.1:8000/EVA/
mkdocs build --strict                    # what CI runs
```

Skipping the sync fails the build, because the `nav` entries for the Development
tab point at files that would not exist. `--check` reports staleness without
writing.

Two MkDocs settings exist for these pages specifically:

- `toc.slugify` uses `pymdownx.slugs.slugify` so heading anchors match GitHub's.
  The roadmap is read in both places and its `#2-processing--cleaning` style
  links must resolve in both; Python-Markdown's default slug would collapse
  `A & B` to `a-b` where GitHub produces `a--b`.
- `pymdownx.tasklist` renders the roadmap's several hundred `- [ ]` items as
  checkboxes rather than literal text.

## GitHub Pages

This repository includes a GitHub Actions workflow that builds the MkDocs site and deploys it to GitHub Pages. In the repository settings, configure Pages to use **GitHub Actions** as the source.
