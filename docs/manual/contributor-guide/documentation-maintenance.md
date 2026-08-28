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

- Build the docs with `mkdocs build --strict`.
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

## GitHub Pages

This repository includes a GitHub Actions workflow that builds the MkDocs site and deploys it to GitHub Pages. In the repository settings, configure Pages to use **GitHub Actions** as the source.
