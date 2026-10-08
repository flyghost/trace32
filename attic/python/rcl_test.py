import sys, traceback
sys.path.insert(0, r"__PYLIBS_DIR__")
from lauterbach.trace32.rcl import connect
dbg = None
try:
    dbg = connect(port=20000)
except Exception as e:
    print("connect(port) failed:", type(e).__name__, e)
    dbg = connect(protocol="TCP", port=20000)
print("CONNECTED", dbg)
dbg.cmd("SYStem.CPU STM32F407ZG")
dbg.cmd("SYStem.Up")
dbg.cmd(r"Data.LOAD.Binary __RTTHREAD_ROS__\bsp\stm32\stm32f407-atk-explorer\rtthread.bin 0x08000000")
dbg.cmd(r"Data.LOAD.Elf __RTTHREAD_ROS__\bsp\stm32\stm32f407-atk-explorer\rt-thread.elf /NoCODE")
v = dbg.fnc("Data.Long(D:0x08000000)")
print("VEC0 =", v)
print("VEC0_INT =", int(v))
print("SZ =", int(dbg.fnc("sizeof(ramdump_exception_t)")))
print("MAGIC =", int(dbg.fnc("Var.Value(g_ramdump_exception.magic)")))
mem = dbg.memory.read(0x08000000, 8)
print("MEM8 =", bytes(mem).hex())
print("RCL-ALL-OK")