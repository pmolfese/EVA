# Keep the developer guide current

**Goal:** update documentation alongside code and verify the repository and
published-site versions without maintaining two copies. Start from the
[developer index](README.md); use the [acceptance walkthrough](acceptance-walkthrough.md)
to check whether the prose works for a newcomer.

## Authoring and publication locations

Edit developer Markdown and tutorial patches under `docs/developers/`. The
existing [`sync-planning-docs.py`](../../scripts/sync-planning-docs.py) mirrors
that tree, the roadmaps, and design references into the Git-ignored
`docs/manual/development/` before MkDocs builds. A developer `README.md` becomes
`index.md` at its mirrored location. Tutorial `.patch` files are copied unchanged
so the published guide can link to them too.

During synchronization, links between mirrored pages remain internal, manual
links point to the manual, and source/project files outside the site link to
their GitHub paths. Fenced code examples retain their original text. The generated
pages include an authoring-location notice. Do not edit the mirrored copies;
the next sync replaces them. The sync command removes/rebuilds the generated
development subtree, so it must not hold hand-written work.

## Local check sequence

Run from the repository root, with documentation dependencies installed in a
Python environment (see `requirements-docs.txt`):

```sh
python3 scripts/check-developer-docs.py
python3 -m unittest discover -s scripts/tests -p 'test_developer_docs.py'
python3 scripts/sync-planning-docs.py
python3 scripts/sync-planning-docs.py --check
python3 -m mkdocs build --strict
```

Then preview with `python3 -m mkdocs serve`. Check the Developer Guide tab,
subsystem/reference navigation, a recipe's patch link, a source-code link, the
readability table, and the architecture/lifecycle diagrams. Inspect the page on
a narrow viewport as well as a desktop; a successful build is not a visual review.

## What each automated check means

| Check | Detects | Does not prove |
| --- | --- | --- |
| Developer link/anchor check | Missing relative files/headings and machine-specific home-directory links in developer pages | External URL availability or correctness of an explanation. |
| Generated inventory comparison | New/removed source files, changed extracted declarations or leading header fingerprints in the declared scope | That a synopsis explains every function or algorithm accurately. |
| Source contracts | Missing literal entry-point names listed in [source-contracts.json](source-contracts.json) | Full Swift type checking or semantic compatibility. |
| Tutorial `git apply --check` | A patch no longer applies to the current source | The patched code compiles, passes tests, or has correct UI behavior. |
| Tooling regression tests | Broken link detection, inventory drift detection, source/page/patch relocation, fenced-example preservation | App behavior or scientific correctness. |
| Sync `--check` | Missing, stale, or orphaned generated documents/assets | That the current authoring prose is accurate. |
| Strict MkDocs build | Site/navigation/build warnings treated as failures | An independent beginner can finish the instructions. |

The checker is intentionally read-only unless `--write-inventory` is requested.
The source inventory covers product/test/tool source roots and listed code
extensions; excluded fixtures/assets/build output are explained at its top.
It includes new unignored files, so run it before committing a new source file.
An untracked scratch file under a source root is also visible and should be moved
out of the product tree if it is not intended to ship.

## When source changes

1. Update the affected [feature map](features.md), subsystem descriptions,
   lifecycle/compatibility explanation and recipes as appropriate. Follow the
   changed call sites; a matching filename alone is not a contract review.
2. Refresh the generated catalog after reviewing the change:

   ```sh
   python3 scripts/check-developer-docs.py --write-inventory
   ```

3. If a tutorial patch drifts, update it against a separate current checkout and
   preserve the exercise's goal. Read the diff, compile it, and rerun its tests.
   Do not suppress the checker or regenerate a patch merely to make the gate green.
4. Run the check sequence above. Update [validation](guide-validation.md) with
   the actual tool versions, test outcomes, and unexecuted checks.

Readability ratings are assessments, not generated metrics. Preserve the original
score when adding a corrected score, state what was reassessed, and do not assign
improvement to files that have not been reviewed. Repairing a link does not
justify changing a readability score.

## Continuous integration and publication

The [documentation workflow](../../.github/workflows/docs.yml) checks developer
pages and affected source/tool changes, including pull requests. It runs the
checker/tooling tests, synchronizes, verifies synchronization, and builds strictly.
Pull requests build/check; the deployment job is restricted to non-PR runs on
`main`. A successful local build does not mean a remote workflow ran or the
public site was deployed. Review the actual workflow result after merging.

Ubuntu documentation CI cannot execute macOS SwiftUI/Metal tutorial tests. Run
those on a configured Mac using the commands in each recipe and retain their
results. The CPU-only isolated validation recorded during guide development is
not a permanent replacement for normal Xcode build, UI, GPU, and release checks.

## Review the guide as a learning tool

Ask the reader to explain ownership, units, failure behavior, and why each test
exists. Collect the exact point where the prose required outside help. Improve
that chapter rather than adding an unexplained exception to a checklist. The
[acceptance walkthrough](acceptance-walkthrough.md) supplies a concrete script
and evidence form. Rerun the affected part after changing setup, persistence,
project membership, or a tutorial's API.
