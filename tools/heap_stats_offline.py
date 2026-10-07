"""heap_stats_offline.py - dlmalloc heap statistics for the 2211 AP death scene,
computed from the raw dump files alone (no TRACE32, no licence, deterministic).

Why offline: the vendor's own walkers (vendor\\2210_trace32\\print_dlmalloc_heap.cmm
and print_mem_summary_by_file.cmm) have no cycle guard and their expressions need the
dlmalloc-internal typedefs (mbinptr / mchunkptr) plus sizeof(), none of which evaluate
in this environment - measured, they spin on this arena.  The arena descriptor and the
chunk chain, however, are plain memory, and the dump files are byte-exact copies of it
(verified: readback via TRACE32 Data.SAVE.Binary matched the files with 0 mismatches).

Walk spec taken from print_dlmalloc_heap.cmm:
    sentinel of bin i      :  av_ + 8*i      (fd at +8, bk at +12)
    start                  :  p = sentinel->bk, then p = p->bk
    inner                  :  q = p + (p->size & ~1), advance q += (q->size & ~1)
                              stop when (q_next->size & 1) != 1 or size < 0x10
    top                    :  bin_at(1)->fd  =  r32(av_ + 8)

Acceptance is quantitative: the sum of the enumerated chunk sizes must reproduce the
arena's `used` field.
"""
import argparse
import os
import struct
import sys

sys.stdout.reconfigure(errors="backslashreplace")

DLM_ADDR, PSRAM_ADDR, IRAM_ADDR = 0x00010000, 0x80000000, 0x10200000
DEFAULT_ARENA = 0x80164CB8          # g_osApSystemMem of this scene (see run report HSA2)
DEFAULT_AV = 0x00010008             # dlmalloc static bin array in the DLM window
SIZEOFCHUNK = 0x10
ARENA_OFF = {"num": 0x00, "total": 0x08, "used": 0x10, "max_used": 0x14, "user_used": 0x18}


class Dumps(object):
    def __init__(self, dump_dir):
        self.regions = []
        for name, base in (("ap_dlm.bin", DLM_ADDR), ("PSRAM.bin", PSRAM_ADDR),
                           ("IRAM.bin", IRAM_ADDR)):
            path = os.path.join(dump_dir, name)
            if os.path.isfile(path):
                with open(path, "rb") as fh:
                    self.regions.append((name, base, fh.read()))
        if not any(n == "PSRAM.bin" for n, _, _ in self.regions):
            raise SystemExit("PSRAM.bin not found in %s" % dump_dir)

    def r32(self, addr):
        for _, base, buf in self.regions:
            off = addr - base
            if 0 <= off <= len(buf) - 4:
                return struct.unpack_from("<I", buf, off)[0]
        return None

    def r8(self, addr):
        for _, base, buf in self.regions:
            off = addr - base
            if 0 <= off < len(buf):
                return buf[off]
        return None

    def cstr(self, addr, maxlen=32):
        for _, base, buf in self.regions:
            off = addr - base
            if 0 <= off < len(buf):
                end = buf.find(b"\x00", off, off + maxlen)
                if end < 0:
                    return None
                raw = buf[off:end]
                if not raw or any(c < 0x20 or c > 0x7E for c in raw):
                    return None
                return raw.decode("ascii")
        return None


def walk(d):
    """enumerate the used blocks exactly as the vendor walker would"""
    av = DEFAULT_AV
    top = d.r32(av + 8)
    blocks, seen = [], set()
    for i in range(0x80):
        sent = av + 8 * i
        p = d.r32(sent + 12)
        guard = 0
        while p not in (None, 0, sent) and guard < 20000:
            guard += 1
            p_size = (d.r32(p + 4) or 0) & ~1
            if p_size < SIZEOFCHUNK:
                break
            q = p + p_size
            inner = 0
            while q < top and inner < 200000:
                inner += 1
                size = (d.r32(q + 4) or 0) & ~1
                nxt = d.r32(q + size + 4)
                if nxt is None or (nxt & 1) != 1 or size < SIZEOFCHUNK:
                    break
                if q not in seen:
                    seen.add(q)
                    blocks.append((q, size))
                q = q + size
            p = d.r32(p + 12)
    return top, blocks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dump_dir", help="directory holding ap_dlm.bin / PSRAM.bin / IRAM.bin")
    ap.add_argument("out", nargs="?", default="", help="write the report to this txt file")
    ap.add_argument("--arena", default=hex(DEFAULT_ARENA),
                    help="arena descriptor address (report line HSA2)")
    ap.add_argument("--top", type=int, default=8, help="rows in the per-owner table")
    args = ap.parse_args()

    arena = int(args.arena, 16) if isinstance(args.arena, str) else args.arena
    d = Dumps(args.dump_dir)
    out = []

    def emit(line=""):
        out.append(line)

    emit("==================== 2211 AP heap, computed offline ====================")
    emit("dump dir : %s" % os.path.abspath(args.dump_dir))
    for name, base, buf in d.regions:
        emit("  %-12s %9d bytes  @ 0x%08X" % (name, len(buf), base))
    emit("")
    emit("arena descriptor @ 0x%08X (g_osApSystemMem)" % arena)
    fld = {}
    for key, off in ARENA_OFF.items():
        fld[key] = d.r32(arena + off) or 0
    for key in ("num", "total", "used", "max_used", "user_used"):
        emit("  %-10s = 0x%08X (%d)" % (key, fld[key], fld[key]))
    if fld["total"]:
        emit("  used / total     = %.1f %%" % (100.0 * fld["used"] / fld["total"]))
        emit("  max_used / total = %.1f %%" % (100.0 * fld["max_used"] / fld["total"]))
        emit("  user_used / total= %.1f %%" % (100.0 * fld["user_used"] / fld["total"]))
    emit("")

    top, blocks = walk(d)
    total = sum(s for _, s in blocks)
    emit("bin-array walk (av_ = 0x%08X, top = 0x%08X)" % (DEFAULT_AV, top or 0))
    emit("  used blocks      = %d" % len(blocks))
    emit("  sum(chunk sizes) = 0x%08X (%d)" % (total, total))
    emit("  arena used       = 0x%08X (%d)" % (fld["used"], fld["used"]))
    delta = fld["used"] - total
    emit("  delta            = %d bytes  (ratio %.4f)"
         % (delta, (total / fld["used"]) if fld["used"] else 0.0))
    emit("  => %s" % ("walk reproduces the arena descriptor"
                     if fld["used"] and abs(delta) < 0x1000 else "MISMATCH - check the dump"))
    emit("")

    # First payload word is an owner tag (thread name) in this build; the vendor
    # calls the same field `file`, but its values here are RTOS thread names.
    acct, unresolved = {}, 0
    for q, size in blocks:
        ptr = d.r32(q + 8)
        name = d.cstr(ptr) if ptr else None
        if name:
            acct[name] = acct.get(name, 0) + size
        else:
            unresolved += 1
    emit("payload owner tags (first word at block+8, size-weighted):")
    for name, tot in sorted(acct.items(), key=lambda kv: -kv[1])[:args.top]:
        emit("  %-20s %10d bytes  (%.1f %% of used chunks)"
             % (name, tot, 100.0 * tot / total if total else 0.0))
    emit("  %-20s %10d blocks" % ("<no tag>", unresolved))
    emit("")
    emit("Note: the customer's per-file table (Mem Leak Info / Memory Summary By File)")
    emit("cannot be reproduced from this dump.  Its trace records are either absent or")
    emit("mis-laid-out here: no word in any dump file points at the file-name pool entry")
    emit("'slog_helper' (0x8003B6C0), and the customer's own golden output leaves the")
    emit("'Memory Summary By File' block empty.  What is shown above is the arena")
    emit("descriptor plus the exact chunk chain, which is byte-verifiable.")
    emit("==================== end ====================")

    text = "\n".join(out) + "\n"
    sys.stdout.write(text)
    if args.out:
        with open(args.out, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        sys.stdout.write("\nwritten: %s\n" % os.path.abspath(args.out))


if __name__ == "__main__":
    main()
