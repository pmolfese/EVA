# Developed by P. Molfese, National Institutes of Health (NIH).
#
# This software is a "work of the United States Government" prepared by a federal
# employee as part of official duties. As such, it is not subject to copyright
# protection within the United States (17 U.S.C. § 105). International copyrights
# may apply.
"""Regression checks for documentation drift detection and site-link relocation."""
import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parents[1]


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), SCRIPTS / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


check = load("check-developer-docs")
sync = load("sync-planning-docs")


class DeveloperDocumentationTests(unittest.TestCase):
    def test_link_checker_reports_missing_files_headings_and_private_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            other = root / "other.md"
            other.write_text("# Valid Heading\n")
            page = root / "index.md"
            page.write_text("[ok](other.md#valid-heading)\n[bad](other.md#missing)\n"
                            "[gone](gone.swift)\n[private](/Users/someone/code.swift)\n"
                            "```md\n[example](not-a-real-file)\n```\n"
                            "   ````md\n   ```\n   [nested](also-not-a-file)\n   ````\n")
            errors = check.check_links(root, [page])
            self.assertEqual(len(errors), 3)
            self.assertTrue(any("missing heading" in e for e in errors))
            self.assertTrue(any("machine-specific" in e for e in errors))

    def test_heading_ids_match_duplicate_and_code_heading_rules(self):
        self.assertEqual(check.heading_ids("# A & B\n## A & B\n```sh\n# Not a title\n```\n"),
                         {"a--b", "a--b-1"})

    def test_inventory_detects_new_sources_and_header_drift(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            (root / "EVA").mkdir()
            source = root / "EVA/One.swift"
            source.write_text("// Original contract\nstruct One {}\n")
            initial = check.inventory_text(root)
            self.assertIn("EVA/One.swift", initial)
            source.write_text("// Changed contract\nstruct One {}\n")
            self.assertNotEqual(initial, check.inventory_text(root))
            (root / "EVA/Two.swift").write_text("struct Two {}\n")
            self.assertIn("EVA/Two.swift", check.inventory_text(root))
            (root / "unrelated").mkdir()
            (root / "unrelated/local.swift").write_text("struct Local {}")
            self.assertNotIn("local.swift", check.inventory_text(root))

    def test_site_rewriter_maps_pages_sources_patches_and_preserves_examples(self):
        source = sync.ROOT / "docs/developers/README.md"
        destination = sync.DEST / "developers/index.md"
        mapping = sync.source_destinations()
        text = ("[setup](setup.md#one)\n[code](../../EVA/Core/SignalSelection.swift)\n"
                "[patch](examples/01-display-option.patch)\n"
                "```md\n[keep](setup.md)\n```\n[web](https://example.org/a)\n")
        result = sync.rewrite_links(text, source, destination, mapping)
        self.assertIn("(setup.md#one)", result)
        self.assertIn("(https://github.com/pmolfese/EVA/blob/main/EVA/Core/SignalSelection.swift)", result)
        self.assertIn("(examples/01-display-option.patch)", result)
        self.assertIn("```md\n[keep](setup.md)\n```", result)
        self.assertIn("(https://example.org/a)", result)

    def test_roadmap_to_developer_guide_stays_internal(self):
        result = sync.rewrite_links("[plan](docs/developers/onboarding-milestones.md)",
                                    sync.ROOT / "ROADMAP.md", sync.DEST / "roadmap.md",
                                    sync.source_destinations())
        self.assertEqual(result, "[plan](developers/onboarding-milestones.md)")

    def test_fenced_shell_comments_are_not_demoted(self):
        result = sync.demote_headings("# Title\n# Section\n```sh\n# Comment\n```\n")
        self.assertIn("\n## Section\n", result)
        self.assertIn("```sh\n# Comment\n```", result)


if __name__ == "__main__":
    unittest.main()
