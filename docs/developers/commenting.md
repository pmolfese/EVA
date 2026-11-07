# Comments and readability conventions

Explain what a reader cannot safely infer from names and types. Short, obvious helpers do not need a paragraph for every line. Existing licensing, attribution and method provenance must remain intact when moving source.

## Boundary contracts

For a nontrivial entry point, document its purpose and caller, input/output shape and units, invalid-input behavior, side effects and actor/task ownership. Place field-specific units and optional-value meanings beside the declaration. Include one tiny example when it resolves ambiguity more directly than prose.

For `[[Float]]`, write the axes: `data[channel][sample]`. For a flat matrix, give the index formula: row-major `row * columnCount + column`, column-major `column * rowCount + row`. If a routine converts layouts, explain the conversion beside the call. Distinguish physical coordinates from normalized display coordinates.

State whether a range includes its endpoint; whether a time denotes onset, center or end; and how a conversion rounds. State whether an empty/zero/nil result means no estimate, no change, no data or failure. Do not silently make documentation promise validation that the implementation does not perform.

## Algorithms and concurrency

Put a short stage outline before a long algorithm. Map important equation symbols to local names, identify normalization and padding conventions, and explain tolerances. A publication citation identifies the method; it does not explain the local representation. Keep conventional mathematical variable names where they make an equation easier to recognize.

For tasks, describe the immutable request snapshot, cancellation checks, result ownership and publication actor. For unsafe memory, describe the borrow lifetime and element layout. For Metal, describe each buffer, thread-to-output mapping, valid extents and the corresponding CPU computation.

## Structure and history

Start a file with its current responsibility and its principal consumer. Put the current invariant before an incident narrative. Keep a concise regression explanation when it prevents a subtle bug from returning, and link maintained developer documentation for broader background.

Split by responsibilities and independent inputs/outputs. Line counts are review prompts, not quotas. Generated tables, explicit dispatch switches and numerical kernels can be legitimate exceptions. Do not replace clear loops with dense collection chains or split a single equation into scattered trivial helpers.

## Review questions

Can the intended reader explain the file's purpose, data dimensions, state owner, failure/cancellation behavior and one test of its contract? Verify the answers against code. A higher comment count is not evidence of improved understanding.
