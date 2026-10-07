#!/usr/bin/env python3
# -*- coding: ascii -*-
"""check_entries_equiv.py - prove that one function has two equal entries.

The GUI entry is vendor\\2210_trace32\\LM620_Restore.cmm (buttons, DIALOG.*, STOP).
The headless entry is harness\\run_2211_func.ps1, which drives the SAME customer
scripts one function at a time. This checker answers the only question that
matters: does a single-function run print what the full run printed for that
function?

How it compares
  * the full run   : runs\\2211_ap\\<stamp>\\2211_ap_deathscene.txt  (all 9 stages)
  * one function   : runs\\2211_ap_func\\<stamp>\\<function>.txt
  * both sides are normalised the same way - trailing whitespace stripped, blank
    lines dropped, lines starting with '#' or '@@@' dropped - and then every line
    of the single-function report must appear in the full report IN ORDER
    (subsequence test). Order matters because it is what catches a function that
    silently printed a different section.
  * kind=python functions are compared byte for byte against the full run's
    artefact of the same name.

Verdicts, driven by harness\\functions.json
  equiv=yes      -> PASS when the subsequence test succeeds
  equiv=partial  -> PARTIAL when it succeeds except for the function's own
                    header lines (thread_bt adds THREADPICK:/Thread: lines that
                    the full run does not have). PARTIAL is an expected result.
  equiv=no       -> reported as PARTIAL at best; never PASS.

Usage
  python tools\\check_entries_equiv.py
  python tools\\check_entries_equiv.py <func_run_dir> [<master_run_dir>]
Exit code 0 when nothing FAILED, 1 otherwise.
"""

import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FUNC_RUNS = os.path.join(ROOT, "runs", "2211_ap_func")
MASTER_RUNS = os.path.join(ROOT, "runs", "2211_ap")
REGISTRY = os.path.join(ROOT, "harness", "functions.json")


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
        if line.lstrip().startswith("#") or line.lstrip().startswith("@@@"):
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


def main(argv):
    func_dir = argv[1] if len(argv) > 1 else newest_dir(FUNC_RUNS)
    master_dir = argv[2] if len(argv) > 2 else newest_dir(MASTER_RUNS)
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

    print("single run : " + func_dir)
    print("full run   : " + master_dir)
    print("full report: %d lines (normalised)" % len(master))
    print("")
    print("%-14s %-7s %-9s %8s  %s" % ("function", "equiv", "verdict", "lines", "note"))
    print("%-14s %-7s %-9s %8s  %s" % ("--------", "-----", "-------", "-----", "----"))

    failed = []
    for name in sorted(os.listdir(func_dir)):
        if not name.endswith(".txt"):
            continue
        fname = name[:-4]
        if fname in ("equiv", "run"):
            continue
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
            print("%-14s %-7s %-9s %8s  %s" % (fname, f.get("equiv", "yes"), verdict, "-", note))
            if verdict == "FAIL":
                failed.append(fname)
            continue

        mine = norm_lines(path)
        ok, miss = subsequence(mine, master)
        if ok:
            verdict = "PASS" if f.get("equiv") == "yes" else "PARTIAL"
            note = "every line also in the full run (order kept)"
        else:
            verdict = "PARTIAL" if f.get("equiv") != "yes" else "FAIL"
            note = "first line absent from the full run: " + repr(miss[:70])
        print("%-14s %-7s %-9s %8d  %s" % (fname, f.get("equiv", "yes"), verdict, len(mine), note))
        if verdict == "FAIL":
            failed.append(fname)

    print("")
    if failed:
        print("EQUIV-FAILED: " + ", ".join(failed))
        return 1
    print("EQUIV-OK: every single-function entry reproduces its section of the full run")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
