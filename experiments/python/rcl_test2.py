import sys
sys.path.insert(0, r"__PYLIBS_DIR__")
from lauterbach.trace32.rcl import connect
proto = sys.argv[1] if len(sys.argv) > 1 else "UDP"
try:
    dbg = connect(protocol=proto, port=20000)
except Exception as e:
    print("CONNECT-FAIL", proto, type(e).__name__, e)
    sys.exit(2)
print("CONNECTED", proto, dbg)
try:
    dbg.cmd("SYStem.CPU STM32F407ZG")
    dbg.cmd("SYStem.Up")
    dbg.cmd(r"Data.LOAD.Binary __RTTHREAD_ROS__\bsp\stm32\stm32f407-atk-explorer\rtthread.bin 0x08000000")
    dbg.cmd(r"Data.LOAD.Elf __RTTHREAD_ROS__\bsp\stm32\stm32f407-atk-explorer\rt-thread.elf /NoCODE")
    print("VEC0 =", int(dbg.fnc("Data.Long(D:0x08000000)")))
    print("VEC1 =", int(dbg.fnc("Data.Long(D:0x08000004)")))
    print("SIZEOF_EXC =", int(dbg.fnc("sizeof(ramdump_exception_t)")))
    print("MAGIC =", int(dbg.fnc("Var.Value(g_ramdump_exception.magic)")))
    mem = dbg.memory.read(0x08000000, 8)
    print("MEM8 =", bytes(mem).hex())
    print("RCL-ALL-OK")
except Exception as e:
    print("CMD-FAIL", type(e).__name__, e)
finally:
    try: dbg.cmd("QUIT")
    except Exception: pass