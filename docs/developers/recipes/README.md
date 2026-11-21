# Worked extension recipes

These exercises assume [setup](../setup.md), [your first change](../first-change.md),
and [data/lifecycle](../data-and-lifecycle.md). Each includes a complete patch
against the current source plus tests or manual checks. The patches are teaching
artifacts; they are **not applied to the application in this documentation change**.
Their purpose is to show all the boundaries a small extension crosses.

| Exercise | What you learn | Files changed by its patch |
| --- | --- | --- |
| [Display-only option](display-option.md) | SwiftUI local state, a binding, conditional content, lifetime | Dataset info sheet |
| [Persisted processing parameter](persisted-parameter.md) | Settings, immutable worker input, computation, legacy defaults, XML and replay | Filter model/view, history summary, focused tests |
| [Analysis metric](analysis-metric.md) | Units, validity policy, report schema, UI, CSV/JSON, legacy decoding | Analysis model/engine/sheet and tests |
| [Recording reader](recording-reader.md) | Input validation, normalized data, dispatch, type registration, export/reimport | Reader, dispatcher, open-screen text, type declaration, tests |

## Work safely in a practice checkout

Use a separate clean checkout containing this guide, or a dedicated development
branch whose existing changes you understand. Do not apply an exercise over
unrelated edits in the same files. `git status --short` and `git diff` show what
is already there. No reset/clean command is required for these exercises.

For each recipe, read its patch before applying it. From the checkout root:

```sh
git apply --stat docs/developers/examples/01-display-option.patch
git apply --check docs/developers/examples/01-display-option.patch
git apply docs/developers/examples/01-display-option.patch
git diff -- EVA/IO/DatasetInfoSheet.swift
```

Use the corresponding filename for the other recipes. `--check` validates
applicability without changing files; the next command actually changes source.
If it fails, stop and compare the current code with the documented integration
points instead of forcing the patch. A newer refactor may require updating the
exercise. Newly added test/reader files appear as untracked files in `git status`;
plain `git diff` does not display their contents, so inspect those too.

You may type the changes manually instead. The patch is the complete answer and
provides exact placement; snippets in prose explain the important parts. Preserve
the NIH header when creating a source file. Work through one recipe at a time,
run its checks, and record outcomes before beginning the next one. To discard a
practice checkout later, first preserve any work you intend to keep; these docs
do not prescribe destructive cleanup commands.

## What validation establishes

The [validation record](../guide-validation.md) separates compiled/tested examples
from UI checks and normal-build checks still requiring the full toolchain. A
compiling view is not proof its layout works. A parameter round-trip is not proof
every historical script or batch decision is compatible. Each recipe ends with
the remaining integration checks and a small independent exercise.
