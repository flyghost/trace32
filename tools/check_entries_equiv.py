#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""check_entries_equiv.py - 证明同一功能的两条入口结果一致。

GUI 入口是 third_party\\vendor\\2210_trace32\\LM620_Restore.cmm（按钮、
DIALOG.*、STOP）。无头入口是 cli\\run_2211_func.ps1，它一次只跑一个功能地驱动
同一批客户脚本。本检查器只回答唯一要紧的问题：单功能运行打印的内容，是否就是
完整运行中该功能打印的内容？

如何比较
  * 完整运行：out\\runs\\2211_ap\\<stamp>\\2211_ap_deathscene.txt（全部 9 个阶段）
  * 单功能  ：out\\runs\\2211_ap_func\\<stamp>\\<function>.txt
  * 两侧做同样的归一化 —— 去掉行尾空白、丢弃空行、丢弃以 '#' 或 '@@@' 开头的行、
    丢弃被两行 '#####' 围栏夹住的**整个 banner 块** —— 然后单功能报告的每一行都必须按
    顺序出现在完整报告中（子序列判定）。顺序很要紧，正是它才能抓出某个功能悄悄打印了
    另一段内容的情况。
  * banner 块必须**整块**丢弃，不能只丢 '#' 开头的行：banner 里那行功能描述是长中文，
    TRACE32 的打印 AREA 会按宽度把它折行，折出来的续行不再以 '#' 开头（第十一轮实测：
    生成件的编码修好之后描述不再退化成 '?'，行变长才触发折行，续行就泄漏进了比对）。
  * kind=python 的功能，与完整运行中同名产物逐字节比较。

判定结果，由 cmm\\functions.json 驱动
  equiv=yes      -> 子序列判定成功即 PASS，失败即 FAIL。
  equiv=partial  -> 该功能的输出等于完整运行中的对应段落加上它自己声明的诊断行时为
                    PARTIAL：注册表条目把它们列为 "allow_prefix"（thread_bt 在搜索
                    时每线程打印一行 THREADPICK:）。PARTIAL 是预期结果，不会让检查
                    失败 —— 但「声明 partial」不是免死金牌：不匹配任何已声明前缀的行
                    一律 FAIL，自身行总数受 --max-drop 约束（默认 64），其余内容仍必须
                    按顺序出现，而完全没有打印任何内容的功能也是 FAIL。
  equiv=no       -> 永不 PASS（最宽也只记为 PARTIAL）。

覆盖度断言（本文件存在的根本原因）
  只遍历它找到的那些 .txt 文件的检查器，分不清「通过的运行」与「残缺的运行」：删掉某个
  功能的输出，循环就根本看不到它。因此 -Func all 理应运行的每个注册表功能都必须有输出
  文件，缺一个就记为 MISSING 并让检查失败。

用法
  python tools\\check_entries_equiv.py
  python tools\\check_entries_equiv.py <func_run_dir> [<master_run_dir>]
  python tools\\check_entries_equiv.py <func_run_dir> <master_run_dir> --max-drop 6
没有任何 FAILED、也没有 MISSING 时退出码为 0，否则为 1。
"""

import json
import os
import sys

# 控制台是 GBK 时，报告里任何 GBK 编不出的字节（例如未匹配行里残留的拉丁-1 字符）
# 会让 print 抛 UnicodeEncodeError，而不是给出判定结果。这里只放宽错误处理、**不换编码**，
# 所以 GBK 能表示的字符（包括中文）仍然正常显示，只有真的编不出的才退化成 '?'。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(errors="replace")
    except (AttributeError, ValueError):
        pass

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FUNC_RUNS = os.path.join(ROOT, "out", "runs", "2211_ap_func")
MASTER_RUNS = os.path.join(ROOT, "out", "runs", "2211_ap")
REGISTRY = os.path.join(ROOT, "cmm", "functions.json")


def newest_dir(parent):
    if not os.path.isdir(parent):
        return None
    names = sorted(d for d in os.listdir(parent) if os.path.isdir(os.path.join(parent, d)))
    return os.path.join(parent, names[-1]) if names else None


FENCE_CHARS = set("#")
BANNER_MAX_LINES = 64


def _is_fence(line):
    """整行只有 '#'、且不短于 8 个字符 —— banner 块的围栏。"""
    return len(line) >= 8 and set(line) <= FENCE_CHARS


def norm_lines(path):
    """读报告后归一化：丢空行、丢 '#' / '@@' 开头的行、丢整块 banner。

    banner 被两行 '#####' 围栏夹住，里面那行功能描述是长中文，TRACE32 的打印 AREA
    会按宽度把它折行，折出来的续行**不再以 '#' 开头** —— 所以只丢 '#' 行是不够的，
    必须把围栏之间的内容整块丢掉。围栏配对只在 64 行以内成立；超时就把开围栏当普通
    行处理，免得到一个残缺报告把后面的真实内容整段吃掉。
    """
    with open(path, "r", encoding="latin-1") as fh:
        raw = [l.rstrip() for l in fh.read().splitlines()]
    out = []
    i = 0
    while i < len(raw):
        line = raw[i]
        if _is_fence(line):
            end = None
            for j in range(i + 1, min(len(raw), i + 1 + BANNER_MAX_LINES)):
                if _is_fence(raw[j]):
                    end = j
                    break
            if end is not None:
                i = end + 1
                continue
        i += 1
        if not line:
            continue
        stripped = line.lstrip()
        if stripped.startswith("#") or stripped.startswith("@@"):
            continue
        out.append(line)
    return out


def subsequence(mine, theirs):
    """返回 (是否全部匹配, 第一个未匹配的行)。贪心按序包含判定。"""
    i = 0
    for line in mine:
        while i < len(theirs) and theirs[i] != line:
            i += 1
        if i == len(theirs):
            return False, line
        i += 1
    return True, None


def subsequence_with_drops(mine, theirs, max_drop, allow_prefix):
    """贪心按序包含判定，允许忽略匹配 allow_prefix 的行。

    只用于声明 equiv=partial 的功能：它们可以在搜索过程中打印自己的诊断行
    （thread_bt 每线程打印一行 THREADPICK:）。不匹配任何已声明前缀的行属于真实
    分歧 -> FAIL。
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
            continue          # 不推进 i：该行视为「不属于本功能」
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
    # -Func all 期望产出什么：所有未被标记 unsafe 的功能
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
                # 已声明 partial：搜索时可以打印自己的诊断行，
                # 但仅限于它声明了前缀的行（allow_prefix）；其余内容仍必须按序被包含，
                # 且自身行总数有上限。
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
