# Writing Documentation With An LLM

LLMs can help create a manual quickly, but scientific software documentation needs careful boundaries. Treat the model as a drafting partner, not as the source of truth.

## What To Give The LLM

Provide concrete source material:

- Current README and release notes
- Screenshots of the current UI
- A list of supported file formats
- Known limitations and untested paths
- Example workflows from real lab use
- Terminology preferred by the project
- Any claims that must be avoided

The more specific the input, the less the model has to guess.

## Good Tasks For An LLM

- Turn rough notes into a manual outline.
- Draft tutorial steps from a known workflow.
- Convert README material into user-guide pages.
- Create checklists for review and export.
- Identify places where screenshots are needed.
- Harmonize terminology across pages.
- Produce a documentation review checklist.

## Risky Tasks

Be careful when asking an LLM to:

- Invent default parameters.
- Describe exact UI labels it has not seen.
- Explain algorithms without checking source files and citations.
- Recommend clinical, diagnostic, or publication standards.
- Claim a format is fully supported without test evidence.
- Write tutorials for workflows that have not been run end to end.

## A Practical Workflow

1. Ask the LLM to make a manual outline from the repository.
2. Mark each page as user guide, tutorial, reference, or developer note.
3. Draft pages from existing source material only.
4. Add **Verify in app** callouts for exact UI details.
5. Run each tutorial against the current build.
6. Replace uncertain text with screenshots, exact labels, and tested outcomes.
7. Review scientific claims with a domain expert.
8. Keep a changelog of documentation updates per release.

## Prompt Pattern

Use prompts that force uncertainty to stay visible:

```text
Draft a user-facing tutorial for EVA's epoching workflow using only the attached
README and screenshots. Do not invent parameter defaults. Mark any exact UI label,
menu path, or screenshot need with "Verify in app".
```

## Review Checklist

- Does every tutorial begin with a concrete goal?
- Can a new user follow the steps without reading source code?
- Are exact UI labels verified from the current app?
- Are untested formats labeled honestly?
- Are automated scores described as aids rather than truth?
- Are algorithmic claims tied to implementation notes or citations?
- Are screenshots current?
- Is the raw data preservation story clear?
