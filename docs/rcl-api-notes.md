# Python RCL 通道：可用调用与踩过的坑

> 来源：原 `private\TRACE32无人化分析报告.html` 第 7 节（该报告含客户身份信息，第十轮已从仓库删除）。
> 这里只保留**与客户无关的 API 事实**——它们是 `cli\rcl_smoke.py` 的写法依据，
> 也是 README §4.4「错误原文」的出处。所有条目都是实测过的，不是查文档抄的。

## 1. 装 RCL（免 pip、免联网）

| 项 | 实测结果 |
|---|---|
| wheel 位置 | `<T32_INSTALL>\demo\api\python\rcl\dist\lauterbach_trace32_rcl-1.1.5-py3-none-any.whl` |
| 依赖 | 纯 Python 的 zip，**无 `Requires-Dist`**（零依赖） |
| `pip install` | 本机失败：沙箱禁止 pip 在 `<本机临时目录>\dsh-*` 建/删临时目录 |
| 可用替代 | `[System.IO.Compression.ZipFile]::ExtractToDirectory($whl, "<repo>\third_party\trace32_rcl")`，然后 `sys.path.insert(0, …)` —— 解包即用，不需要联网、不需要 pip |

## 2. 连上

```python
from lauterbach.trace32.rcl import connect
dbg = connect(protocol="TCP", port=20000)     # UDP 同样成功
```

前置条件：t32 实例以带 `RCL=NETTCP`（或 `NETASSIST`）+ `PORT=20000` 的配置启动（见 `configs\sim-rcl-tcp-20000.t32`）。

## 3. 已验证可用的调用

```python
dbg.cmd("SYStem.CPU STM32F407ZG")
dbg.cmd("SYStem.Up")
dbg.cmd("Data.LOAD.Binary <bin> 0x08000000")
dbg.cmd("Data.LOAD.Elf <elf> /NoCODE")
dbg.fnc("Data.Long(D:0x08000000)")
dbg.symbol.query_by_name("g_ramdump_exception")
#  → g_ramdump_exception D:0x20003aac 52
a = rcl.Address(dbg, value=0x08000000)
dbg.memory.read(a, length=20)
dbg.cmd("QUIT")
```

## 4. 踩过的坑（错误原文照抄）

```python
# ① sizeof 不能当函数调
dbg.fnc("sizeof(ramdump_exception_t)")
#  FunctionError: no function 'SIZEOF' exists
#  - don't use commands as functions
#  → 正确写法：dbg.fnc("Var.Value(sizeof(ramdump_exception_t))")

# ② 必须传 Address 对象，不能传 int
dbg.memory.read(0x08000000, length=20)
#  AssertionError: assert isinstance(address, Address)

# ③ cmd() 成功也返回 None，别拿它当布尔值
```

## 5. 接口速查

- `Address` 构造：`rcl.Address(dbg, value=0x08000000)`；或 `Address.from_string(dbg, "D:0x08000000")`。
- `dbg` 暴露的服务：`address, breakpoint, cmd, cmm, directaccess, fnc, get_message, get_state, memory, practice, print, register, symbol, variable, ping, go/go_up/step*`。
- `dbg.symbol` 只有 `query_by_address`、`query_by_name`。
- 内存 API：`read/write(address, *, length=/value, width=)` + `read_uint8/16/32/64` 等全套类型化接口 + `MemoryAccessBundle` / `DirectAccessBundle`（批量搬运）。

最简可用示例见 [`cli\rcl_smoke.py`](<../cli/rcl_smoke.py>)；它的断言（逐字节读回 + `read_uint32` + `symbol.query_by_name`）就是上表的落地版。
