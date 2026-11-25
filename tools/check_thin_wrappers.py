#!/usr/bin/env python3
"""Thin-wrapper drift guard for the App/ layer.

Pure logic was extracted from App/ into VampireCore (CameraShot, ApplyPlan,
Signals), leaving thin App wrappers that must stay thin: they delegate to
their Core counterpart instead of reimplementing the logic. App/ is an Xcode
project, so no Swift unit test can cover it — this script is the guard.

For each wrapper it checks two things:

  1. Delegation: the file still references its Core symbol (e.g. a wrapper
     with the ``CardListing.merge`` call removed fails).
  2. Size: the file stays under its line budget (a wrapper bloated with
     reimplemented logic fails).

Budgets are current sizes plus small headroom; bump a budget deliberately
when a wrapper legitimately grows, not to silence this check.

Run:  python3 tools/check_thin_wrappers.py [--root DIR]
Exit 0 when every wrapper delegates and fits; exit 1 with a clear message
otherwise. Standard library only.
"""
import argparse
import os
import sys

# Wrapper path (relative to the repo root) -> expected Core symbol(s) that
# prove it still delegates, the Core file that owns the logic, and the max
# line count (current size + small headroom, measured Nov 2026).
WRAPPERS = [
    {
        "path": "App/Camera/SonyCameraClient.swift",
        "symbols": ("CameraPhoto",),
        "core": "VampireCore/Sources/PTP/CameraShot.swift",
        "budget": 220,  # now 176
    },
    {
        "path": "App/Camera/CameraFrameCache.swift",
        "symbols": ("CameraFrameIdentity",),
        "core": "VampireCore/Sources/PTP/CameraShot.swift",
        "budget": 180,  # now 138
    },
    {
        "path": "App/Camera/CameraSessionModel.swift",
        "symbols": ("CardListing",),
        "core": "VampireCore/Sources/PTP/CameraShot.swift",
        "budget": 800,  # now 733
    },
    {
        "path": "App/Apply/ApplyEngine.swift",
        "symbols": ("ApplyPlan",),
        "core": "VampireCore/Sources/CullIntent/ApplyPlan.swift",
        "budget": 90,  # now 58
    },
    {
        "path": "App/Indexing/VisionAnalyzer.swift",
        "symbols": ("SignalAnalysis",),
        "core": "VampireCore/Sources/VampireIndex/Signals.swift",
        "budget": 250,  # now 201
    },
]

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def check_tree(root=REPO):
    """Return a list of violation strings; empty means every wrapper is thin."""
    violations = []
    for spec in WRAPPERS:
        full = os.path.join(root, spec["path"])
        if not os.path.isfile(full):
            violations.append(f"{spec['path']}: missing (expected a thin wrapper here)")
            continue
        with open(full, encoding="utf-8") as f:
            content = f.read()
        lines = len(content.splitlines())
        if lines > spec["budget"]:
            violations.append(
                f"{spec['path']}: {lines} lines exceeds budget of {spec['budget']} "
                f"(logic may be drifting back from {spec['core']})"
            )
        missing = [s for s in spec["symbols"] if s not in content]
        if missing:
            violations.append(
                f"{spec['path']}: no longer references {', '.join(missing)} "
                f"(delegation to {spec['core']} looks removed)"
            )
    return violations


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=REPO, help="repo root to check")
    args = parser.parse_args(argv)
    violations = check_tree(args.root)
    if violations:
        for v in violations:
            print(f"FAIL: {v}", file=sys.stderr)
        return 1
    print(f"OK: {len(WRAPPERS)} thin wrappers delegate to Core and fit their budgets")
    return 0


if __name__ == "__main__":
    sys.exit(main())
