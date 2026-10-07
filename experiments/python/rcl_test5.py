import sys, traceback
sys.path.insert(0, r"__PYLIBS_DIR__")
import lauterbach.trace32.rcl as rcl
print("pkg exports:", [m for m in dir(rcl) if not m.startswith("_")])
dbg = rcl.connect(protocol="TCP", port=20000)
dbg.cmd("SYStem.CPU STM32F407ZG"); dbg.cmd("SYStem.Up")
dbg.cmd(r"Data.LOAD.Binary __RTTHREAD_ROS__\bsp\stm32\stm32f407-atk-explorer\rtthread.bin 0x08000000")
dbg.cmd(r"Data.LOAD.Elf __RTTHREAD_ROS__\bsp\stm32\stm32f407-atk-explorer\rt-thread.elf /NoCODE")
for expr in ["rcl.Address(0x08000000)", "dbg.address(0x08000000)"]:
    try:
        a = eval(expr)
        print("ADDR-OBJ", expr, "->", a)
        print("MEM20 =", bytes(dbg.memory.read(a, length=20)).hex())
        print("MEM-API-OK")
        break
    except Exception as e:
        print("FAIL", expr, type(e).__name__, e)
print("QUERY:", dbg.symbol.query_by_name("g_ramdump_exception"))
print("RCL-DONE")
dbg.cmd("QUIT")