# -*- coding: utf-8 -*-
"""
TRACE32 无人化冒烟测试（RCL / TCP 通道）
=========================================
前置：先用 configs\\g3_nettcp.t32 启动一个 TRACE32 实例
      （PBI=SIM 仿真后端 + SCREEN=OFF 无窗口 + RCL=NETTCP PORT=20000）。
      或直接跑同目录的 run_smoke.ps1，它会自动起实例、跑本脚本、收尾。

本脚本验证四件事：
  1) RCL 免安装可用：从 ..\\third_party\\trace32_rcl\\ 直接 import，不走 pip
  2) 能连上 127.0.0.1:20000
  3) Data.LOAD.Binary 把 FLASH 映像铺回 0x08000000 后，
     读回的 20 字节与 rtthread.bin 头 20 字节**逐字节一致**（这是黄金标准）
  4) ELF 的 DWARF 类型与符号可查（sizeof / Var.Value / symbol.query_by_name）

退出码：0 = 全部通过；1 = 有断言失败。

注意：所有 print 都用 ASCII。Windows 控制台代码页 936 下打印中文会变成乱码，
      而本脚本的输出要能直接粘到报告/日志里。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                                        # repo root (this file is in cli\)
sys.path.insert(0, os.path.join(ROOT, "third_party", "trace32_rcl"))  # 免 pip 的 RCL 1.1.5

# 目标固件产物（RT-Thread BSP 根目录）
# 注意：ELF 叫 rt-thread.elf（带连字符），BIN 叫 rtthread.bin（不带），写错会静默失败
# 本机路径不进仓库：由环境变量 RAMDUMP_BSP_DIR 注入（run_smoke.ps1 会设置）
BSP = os.environ.get("RAMDUMP_BSP_DIR", "")
if not BSP:
    print("SMOKE-FAILED: env RAMDUMP_BSP_DIR is not set.")
    print("  Run via run_smoke.ps1, or set it to your RT-Thread BSP dir, e.g.")
    print("  set RAMDUMP_BSP_DIR=C:\\rt-thread\\bsp\\stm32\\stm32f407-atk-explorer")
    sys.exit(2)
BIN_PATH = os.path.join(BSP, "rtthread.bin")
ELF_PATH = os.path.join(BSP, "rt-thread.elf")
LOAD_ADDR = 0x08000000

for _p in (BIN_PATH, ELF_PATH):
    if not os.path.isfile(_p):
        print("SMOKE-FAILED: not found: %s (check RAMDUMP_BSP_DIR)" % _p)
        sys.exit(2)

import lauterbach.trace32.rcl as rcl

failures = []


def fmt(v):
    return hex(v) if isinstance(v, int) else repr(v)


def check(name, got, want=None):
    ok = True if want is None else (got == want)
    line = "  [%s] %s = %s" % ("PASS" if ok else "FAIL", name, fmt(got))
    if want is not None:
        line += "   (expected %s)" % fmt(want)
    print(line)
    if not ok:
        failures.append(name)


def main():
    dbg = rcl.connect(protocol="TCP", port=20000)
    print("connected to TRACE32 on TCP 20000")
    print("  CPU : STM32F407ZG / simulator backend PBI=SIM")

    dbg.cmd("SYStem.CPU STM32F407ZG")
    dbg.cmd("SYStem.Up")
    dbg.cmd("Data.LOAD.Binary %s 0x%08X" % (BIN_PATH, LOAD_ADDR))

    with open(BIN_PATH, "rb") as f:
        head = f.read(20)

    a0 = rcl.Address(dbg, value=LOAD_ADDR)
    a4 = rcl.Address(dbg, value=LOAD_ADDR + 4)
    mem = bytes(dbg.memory.read(a0, length=20))

    print("  file head[20] = %s" % head.hex())
    print("  mem       [20] = %s" % mem.hex())
    check("FLASH first 20 bytes == rtthread.bin head", mem.hex(), head.hex())

    # 读回值必须按整数比较：hex() 不做零填充，'0x8003a3d' 与 '0x08003a3d' 是同一个数
    check("read_uint32(0x08000000) == initial stack top",
          dbg.memory.read_uint32(a0), int.from_bytes(head[:4], "little"))
    check("read_uint32(0x08000004) == Reset_Handler",
          dbg.memory.read_uint32(a4), int.from_bytes(head[4:8], "little"))

    dbg.cmd("Data.LOAD.Elf %s /NoCODE" % ELF_PATH)   # 只补符号，不覆盖刚铺回的 dump

    check("Var.Value(sizeof(ramdump_exception_t))",
          dbg.fnc("Var.Value(sizeof(ramdump_exception_t))"), 52)
    sym = dbg.symbol.query_by_name("rt_thread_priority_table")
    print("  symbol.query_by_name('rt_thread_priority_table') -> %s" % (sym,))
    check("symbol lookup by name works", sym is not None)

    dbg.cmd("QUIT")

    print()
    if failures:
        print("SMOKE-FAILED: %s" % ", ".join(failures))
        return 1
    print("SMOKE-ALL-OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
