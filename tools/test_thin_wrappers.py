#!/usr/bin/env python3
"""Unit tests for the thin-wrapper drift guard (tools/check_thin_wrappers.py).

Pure logic was extracted from App/ into VampireCore, leaving thin App
wrappers that must stay thin — but App/ is an Xcode project, so no Swift
unit test can cover it. The checker stands in: it asserts each wrapper
still references its Core symbol and stays under its line budget. These
tests pin the checker itself down:

  - real tree: the checker passes against the actual checkout (if this
               fails, a wrapper really did drift and needs slimming, or a
               budget needs a deliberate bump)
  - delegation removed: a temp-dir copy of a wrapper with its Core symbol
               reference stripped must fail the check
  - bloated wrapper: a temp-dir copy padded past its budget must fail

Run:  python3 tools/test_thin_wrappers.py
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS = os.path.join(REPO, "tools")
CHECKER = os.path.join(TOOLS, "check_thin_wrappers.py")

sys.path.insert(0, TOOLS)
import check_thin_wrappers


def copy_wrappers_to_temp():
    """Mirror the five wrapper files into a temp dir, return its path."""
    root = tempfile.mkdtemp(prefix="thin-wrappers-test-")
    for spec in check_thin_wrappers.WRAPPERS:
        src = os.path.join(REPO, spec["path"])
        dst = os.path.join(root, spec["path"])
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(src, dst)
    return root


class ThinWrapperCheckerTest(unittest.TestCase):
    def test_real_tree_passes(self):
        violations = check_thin_wrappers.check_tree(REPO)
        self.assertEqual(violations, [], f"real tree must pass, got: {violations}")
        proc = subprocess.run(
            [sys.executable, CHECKER], capture_output=True, text=True, cwd=REPO
        )
        self.assertEqual(proc.returncode, 0, f"checker must exit 0:\n{proc.stderr}")
        self.assertIn("OK", proc.stdout)

    def test_wrapper_with_delegation_removed_fails(self):
        # Strip the Core symbol reference from one wrapper: the delegation
        # the checker guards is gone, so it must fail naming that file.
        root = copy_wrappers_to_temp()
        try:
            target = os.path.join(root, "App/Apply/ApplyEngine.swift")
            with open(target, encoding="utf-8") as f:
                content = f.read()
            self.assertIn("ApplyPlan", content, "precondition: wrapper references ApplyPlan")
            with open(target, "w", encoding="utf-8") as f:
                f.write(content.replace("ApplyPlan", "DeletedPlan"))
            violations = check_thin_wrappers.check_tree(root)
            self.assertTrue(
                any("ApplyEngine" in v and "ApplyPlan" in v for v in violations),
                f"expected a delegation violation for ApplyEngine, got: {violations}",
            )
            proc = subprocess.run(
                [sys.executable, CHECKER, "--root", root],
                capture_output=True, text=True,
            )
            self.assertNotEqual(proc.returncode, 0, "checker must exit nonzero")
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_wrapper_bloated_past_budget_fails(self):
        # Pad one wrapper past its budget with reimplemented-looking logic.
        root = copy_wrappers_to_temp()
        try:
            spec = next(
                s for s in check_thin_wrappers.WRAPPERS
                if s["path"] == "App/Apply/ApplyEngine.swift"
            )
            target = os.path.join(root, spec["path"])
            with open(target, encoding="utf-8") as f:
                before = len(f.read().splitlines())
            with open(target, "a", encoding="utf-8") as f:
                for i in range(spec["budget"] - before + 1):
                    f.write(f"// reimplemented logic line {i}\n")
            violations = check_thin_wrappers.check_tree(root)
            self.assertTrue(
                any("ApplyEngine" in v and "exceeds budget" in v for v in violations),
                f"expected a budget violation for ApplyEngine, got: {violations}",
            )
            proc = subprocess.run(
                [sys.executable, CHECKER, "--root", root],
                capture_output=True, text=True,
            )
            self.assertNotEqual(proc.returncode, 0, "checker must exit nonzero")
        finally:
            shutil.rmtree(root, ignore_errors=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
