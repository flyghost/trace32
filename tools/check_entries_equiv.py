#!/usr/bin/env python3
# -*- coding: ascii -*-
"""check_entries_equiv.py - prove that one function has two equal entries.

The GUI entry is third_party\\vendor\\2210_trace32\\LM620_Restore.cmm (buttons,
DIALOG.*, STOP). The headless entry is cli\\run_2211_func.ps1, which drives the
SAME customer scripts one function at a time. This checker answers the only
question that matters: does a single-function run print what the full run printed
for that function?

How it compares
  * the full run   : out\\runs\\2211_ap\\<stamp>\\2211_ap_deathscene.txt  (all 9 stages)
  * one function   : out\\runs\\2211_ap_func\\<stamp>\\<function>.txt
  * both sides are normalised the same way - trailing whitespace stripped, blank
    lines dropped, lines starting with '#' or '@@@' dropped - and then every line
    of the single-function report must appear in the full report IN ORDER
    (subsequence test). Order matters because it is what catches a function that
    silently printed a different section.
  * kind=python functions are compared byte for byte against the full run's
    artefact of the same name.

Verdicts, driven by cmm\\functions.json
  equiv=yes      -> PASS when the subsequence test succeeds, FAIL when it does not.
  equiv=partial  -> PARTIAL when the function's output is the full run's section plus its
                    own declared diagnostic lines: the registry entry lists them as
                    "allow_prefix" (thread_bt prints one THREADPICK: line per thread while
                    searching). PARTIAL is an expected result and does not fail the check -
                    but "declared partial" is not a free pass: a line that does not match a
                    declared prefix is FAIL, the total number of own lines is bounded by
                    --max-drop (default 64), everything else must still appear in order,
                    and a function that printed nothing at all is FAIL.
  equiv=no       -> never PASS (reported as PARTIAL at worst).

Coverage assertion (why this file exists at all)
  A checker that only walks the .txt files it finds cannot tell a passing run from
  an incomplete one: delete a function's output and the loop simply never sees it.
  So every registry function that -Func all is supposed to run must have an output
  file, and a missing one is reported as MISSING and fails the check.

Usage
  python tools\\check_entries_equiv.py
  python tools\\check_entries_equiv.py <func_run_dir> [<master_run_dir>]
  python tools\\check_entries_equiv.py <func_run_dir> <master_run_dir> --max-drop 6
Exit code 0 when nothing FAILED and nothing is MISSING, 1 otherwise.
"""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FUNC_RUNS = os.path.join(ROOT, "out", "runs", "2211_ap_func")
MASTER_RUNS = os.path.join(ROOT, "out", "runs", "2211_ap")
REGISTRY = os.path.join(ROOT, "cmm", "functions.json")


def newest_dir(parent):
    if not os.path.isdir(parent):
        return None
    names = sorted(d for d in os.listdir(parent) if os.path.isdir(os.path.join(parent, d)))
    return os.path.join(parent, names[-1]) if names else None


def norm_lines(path):
    with open(path, "r", encoding="latin-1") as fh:
        raw = fh.read().splitlines()
    out = []
    for line in raw:
        line = line.rstrip()
        if not line:
            continue
        if line.lstrip().startswith("#") or line.lstrip().startswith("@@"):
            continue
        out.append(line)
    return out


def subsequence(mine, theirs):
    """Return (matched, first_unmatched). Greedy in-order containment."""
    i = 0
    for line in mine:
        while i < len(theirs) and theirs[i] != line:
            i += 1
        if i == len(theirs):
            return False, line
        i += 1
    return True, None


def subsequence_with_drops(mine, theirs, max_drop, allow_prefix):
    """Greedy in-order containment that may ignore lines matching allow_prefix.

    Used only for functions declared equiv=partial: they are allowed to print their own
    diagnostic lines while searching (thread_bt prints one THREADPICK: line per thread).
    A line that does not match a declared prefix is a real divergence -> FAIL.
    """
    i = 0
    dropped = []
    for line in mine:
        j = i
        while j < len(theirs) and theirs[j] != line:
            j += 1
        if j == len(theirs):
            if not any(line.startswith(p) for p in allow_prefix):
                return False, dropped, line
            dropped.append(line)
            if len(dropped) > max_drop:
                return False, dropped, line
            continue          # do not advance i: the line is treated as "not ours"
        i = j + 1
    return True, dropped, None


def main(argv):
    rest = list(argv[1:])
    max_drop = 64
    if "--max-drop" in rest:
        k = rest.index("--max-drop")
        try:
            max_drop = int(rest[k + 1])
        except (IndexError, ValueError):
            print("--max-drop needs an integer")
            return 1
        rest = rest[:k] + rest[k + 2:]
    args = [a for a in rest if not a.startswith("--")]
    func_dir = args[0] if len(args) > 0 else newest_dir(FUNC_RUNS)
    master_dir = args[1] if len(args) > 1 else newest_dir(MASTER_RUNS)
    if not func_dir or not os.path.isdir(func_dir):
        print("no function run directory found under " + FUNC_RUNS)
        return 1
    if not master_dir or not os.path.isdir(master_dir):
        print("no full run directory found under " + MASTER_RUNS)
        return 1

    master_file = os.path.join(master_dir, "2211_ap_deathscene.txt")
    if not os.path.isfile(master_file):
        print("missing " + master_file)
        return 1
    master = norm_lines(master_file)

    with open(REGISTRY, "r", encoding="utf-8") as fh:
        reg = json.load(fh)
    funcs = {f["name"]: f for f in reg.get("functions", [])}
    # what -Func all is expected to produce: every function that is not marked unsafe
    expected = sorted(n for n, f in funcs.items() if f.get("safe") is not False)

    print("single run : " + func_dir)
    print("full run   : " + master_dir)
    print("full report: %d lines (normalised)" % len(master))
    print("")
    print("%-14s %-7s %-9s %8s  %s" % ("function", "equiv", "verdict", "lines", "note"))
    print("%-14s %-7s %-9s %8s  %s" % ("--------", "-----", "-------", "-----", "----"))

    failed = []
    missing = []
    counts = {"PASS": 0, "PARTIAL": 0, "FAIL": 0}

    present = set()
    for name in sorted(os.listdir(func_dir)):
        if not name.endswith(".txt"):
            continue
        fname = name[:-4]
        if fname in ("equiv", "run"):
            continue
        present.add(fname)
        f = funcs.get(fname, {"equiv": "yes", "kind": "t32"})
        path = os.path.join(func_dir, name)

        if f.get("kind") == "python" or name == "heap_offline.txt":
            ref = os.path.join(master_dir, name)
            if not os.path.isfile(ref):
                verdict, note = "FAIL", "missing reference " + name
            else:
                with open(path, "rb") as a, open(ref, "rb") as b:
                    same = a.read() == b.read()
                verdict = "PASS" if same else "FAIL"
                note = "byte-identical to the full run" if same else "differs from the full run"
            counts[verdict] += 1
            print("%-14s %-7s %-9s %8s  %s" % (fname, f.get("equiv", "yes"), verdict, "-", note))
            if verdict == "FAIL":
                failed.append(fname)
            continue

        mine = norm_lines(path)
        declared = f.get("equiv", "yes")
        if not mine:
            verdict, note = "FAIL", "printed nothing (empty report)"
        else:
            ok, miss = subsequence(mine, master)
            if ok:
                verdict = "PASS" if declared == "yes" else "PARTIAL"
                note = "every line also in the full run (order kept)"
            elif declared == "yes":
                verdict, note = "FAIL", "first line absent from the full run: " + repr(miss[:70])
            else:
                # declared partial: it may print its own diagnostic lines while searching,
                # but only ones whose prefix it declares (allow_prefix); the rest must still
                # be contained in order, and the total number of own lines is bounded.
                allow = f.get("allow_prefix", [])
                ok2, dropped, miss2 = subsequence_with_drops(mine, master, max_drop, allow)
                if ok2 and dropped:
                    verdict = "PARTIAL"
                    note = ("%d own line(s) (%s), rest in order"
                            % (len(dropped),
                               ", ".join(sorted(set(d.split(":")[0] + ":" for d in dropped)))))
                elif ok2:
                    verdict = "FAIL"
                    note = "declared partial but printed no own line (allow_prefix unused)"
                else:
                    verdict = "FAIL"
                    if allow:
                        note = "diverges beyond allow_prefix: " + repr(miss2[:70])
                    else:
                        note = "diverges (no allow_prefix declared): " + repr(miss2[:70])
        counts[verdict] += 1
        print("%-14s %-7s %-9s %8d  %s" % (fname, declared, verdict, len(mine), note))
        if verdict == "FAIL":
            failed.append(fname)

    for name in expected:
        if name not in present:
            missing.append(name)

    print("")
    present_expected = [n for n in expected if n in present]
    print("coverage: expected %d functions from cmm\\functions.json, found %d"
          % (len(expected), len(present_expected)))
    if missing:
        print("MISSING (no output file, so not compared): " + ", ".join(missing))
    print("EQUIV-COUNT pass=%d partial=%d fail=%d missing=%d"
          % (counts["PASS"], counts["PARTIAL"], counts["FAIL"], len(missing)))

    if failed or missing:
        print("EQUIV-FAILED: " + ", ".join(sorted(set(failed + missing))))
        return 1
    print("EQUIV-OK: every single-function entry reproduces its section of the full run")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
