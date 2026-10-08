# Trace32_Auto —— TRACE32 无人化 / 离线分析工作区

> **给新会话的入口说明。** 这个目录里的配置、脚本、Python 库都是**在同一台机器上实测跑通过的**，不是设想。
> 目标是：把 TRACE32 变成一个能由脚本/AI 编排的「纯函数」——
> `f(rt-thread.elf, 内存 dump.bin) → report.json`，不驱动 GUI、不需要调试器。
>
> **公开/私有边界**：本仓库可以公开。客户脚本副本、死机现场夹具、客户报告原件、
> 以及你自己机器的路径**全部不入库**（清单见 §1 与 `.gitignore`）；
> 仓库里只保留**可复现的方法、脚本骨架和实测结论**。

---

## 0. 一句话结论

TRACE32 **可以完全无人化**：

| 要素 | 取值 | 说明 |
|---|---|---|
| 后端 | `PBI=SIM` | 仿真器后端，**不需要任何硬件探头 / 调试器** |
| 界面 | `SCREEN=OFF` | 无窗口，实测 20 秒内窗口标题恒为 `(none)` |
| 授权 | 无需 dongle | 无硬件场景下不弹授权提示（`licenses\` 里本来也只有第三方 OSS 许可） |
| 调用方式 | ① `-s xxx.cmm` 批处理 ② Python RCL over TCP | 两者都已跑通，推荐 ② |
| 结果回收 | 文件契约（`APPEND` / `AREA.OPEN`）或 RCL 返回值 | **不要**依赖进程退出码/stdout |

**唯一一条必须遵守的硬规则：配置文件必须用空行分组。** 见 §3。

---

## 1. 顶层结构

```
Trace32_Auto\
├─ cmm\          底层：无 GUI 的 PRACTICE 内核，只被调用（内附 src_2210\ 待改造副本） ✅+❌
├─ cli\          上层入口：脚本入口（PowerShell + Python）                          ✅
├─ tools\        独立小工具（算哈希、判等价、重建快捷方式）                          ✅
├─ tests\        全部测试只在这一处（唯一入口 tests\run_all.ps1）                   ✅
├─ configs\      起实例用的 .t32 配置（含客户 GUI 原件 sim-gui.t32）                ✅
├─ docs\         文档（docs\rcl-api-notes.md）                                      ✅
├─ attic\        归档：18 个对照/失败配置 + 6 个早期 RCL 试验 + 13 个早期探针 + 7 个原始日志 ✅
├─ third_party\  非本项目所有：客户脚本 vendor\、客户快捷方式、Lauterbach RCL SDK    ❌
├─ ramdump\      2211 死机现场（只读输入）                                          ❌
├─ out\          运行产物：out\runs\（报告）、out\logs\（marker 日志）              ❌
└─ local\        本机真实路径 + 运行时生成的配置/脚本                               ❌
```

调用方向只有一条。**GUI 路径（`third_party\launchers\*.lnk` + `configs\sim-gui.t32`）与脚本路径（`cli\`）平级**，
都往下调 `cmm\`，彼此不互相调用：

```
    third_party\launchers\*.lnk            cli\*.ps1 / cli\*.py
  （客户 GUI 快捷方式，-c sim-gui.t32）  （PowerShell 驱动器 + Python RCL）
              │                                    │
              └───────────────┬────────────────────┘
                              ▼
                        cmm\  无 GUI 内核
                              ▼
        third_party\vendor\2210_trace32\   ← 客户脚本原件（冻结只读）
```

> **契约刻意压到最少**（应「防止契约爆炸」的要求）：只有 **2 类**——
> ① `cmm\functions.json`（2211 每个功能的实现只写在这一处，入口模板只认占位符）；
> ② `configs\` 的占位符约定（`__T32_INSTALL__` / `__BSP_DIR__` / `__TMP_DIR__` / `__T32_START_TEMP__`，见 §4.0）。
> 另加 1 份 `tests\ramdump.sha256`（不入库件的哈希，一行一条）。
> **没有** json schema、**没有**插件协议、**没有** manifest 注册表。

### 1.1 逐项导航

| 路径 | 内容 | 用途 | 入库 |
|---|---|---|---|
| `cmm\` | 4 个成品：`restore.cmm`（冒烟链）、`heap_summary.cmm`（2211 堆遍历）、`thread_pick.cmm`（选线程）、`functions.json`（注册表）；另有 `cmm\src_2210\`（待改造的客户副本） | 底层内核；**不含任何 GUI 语句**，可被 GUI 与脚本同时调用 | ✅（`src_2210\` ❌） |
| `cli\run_smoke.ps1` | 一键冒烟（批处理 + RCL 两阶段，带 marker 闸门） | 环境自检，**先跑这个** | ✅ |
| `cli\run_2211_ap.ps1` | 2211 现场全量分析（9 段 → 报告 + 离线堆统计） | 一键出报告（见 §5.1） | ✅ |
| `cli\2211_ap_analyze.cmm.tmpl` | 上面那条链的 CMM 模板（`__CMM_DIR__` 等占位符展开） | 全量入口的骨架 | ✅ |
| `cli\run_2211_func.ps1` | 单功能无 GUI 驱动器（`-List` / `-Func <名>` / `-Func all`） | 逐个功能单独跑、单独留档 | ✅ |
| `cli\2211_ap_func.cmm.tmpl` `cmm\thread_pick.cmm` | 单功能入口骨架 + `select_thread.cmm` 的无 GUI 孪生 | 单功能入口的零件 | ✅ |
| `cli\rcl_smoke.py` | RCL 冒烟测试（带断言，退出码 0/1） | 验证 Python 通道 | ✅ |
| `cmm\functions.json` | 2211 每个 GUI 功能的注册表（**功能的实现只写在这一处**） | 「一个功能，两个入口」的单一真源（见 §5.2） | ✅ |
| `tools\check_entries_equiv.py` | 单功能报告 ↔ 全量报告的等价判定（含覆盖断言） | 证明两个入口等价（`EQUIV-OK`） | ✅ |
| `tools\heap_stats_offline.py` | 纯 Python 读 dump 复算 dlmalloc 链 | 堆统计，自动与 arena 的 `used` 对账 | ✅ |
| `tools\make_shortcuts.ps1` | 在本机重建 `third_party\launchers\*.lnk` | 快捷方式无法入库 | ✅ |
| `tests\run_all.ps1` | **唯一测试入口**：夹具哈希 → 冒烟 → 2211 全量 → 单功能 → 等价判定 | 测试集中在这一处（见 §1.2） | ✅ |
| `tests\verify_ramdump.ps1` | 按 `tests\ramdump.sha256` 逐条校验死机现场 | 证明现场没被改过 | ✅ |
| `tests\smoke\*.markers` | 三条链各自的期望 marker（5 / 12 / 3 条） | 闸门的数据源：**数据与代码分开** | ✅ |
| `tests\ramdump.sha256` | 9 个现场文件的 SHA256（`<hash>  <相对路径>`） | 不入库件的完整性凭据 | ✅ |
| `configs\` | 4 个配置：客户 GUI 原件 `sim-gui.t32` + 3 个无人化配置（`sim-minimal` / `sim-batch` / `sim-rcl-tcp-20000`），每个开头都有中文注释头 | 起实例用（`-c`） | ✅ |
| `attic\logs\` | 原始实测日志（只读证据；第十一轮从 `docs\history\` 移入，让 `docs\` 只留文档） | 复盘 | ✅ |
| `docs\rcl-api-notes.md` | Python RCL 的可用调用、错误原文、接口速查 | §4.4 的出处（原客户报告第 7 节的非客户部分） | ✅ |
| `attic\configs\` | 18 个对照 / 失败配置（`zz*` `v*` `cfg_*` `config_auto`） | **空行分组定律的证据** | ✅ |
| `attic\python\` | 早期 RCL 试验脚本 `rcl_test.py` … `rcl_test6.py` | 迭代痕迹 | ✅ |
| `attic\cmm\` | 13 个早期探针（`s1`–`s5` 符号查询试探、`sym`/`sym2`、`probe1`–`probe4`、`mini`、`gui_test`） | 迭代痕迹 + 铁律 2 的复现件 | ✅ |
| `local\` | 你的真实路径（`paths.psd1`）+ 运行时生成的配置/脚本 | 本机私事 | ❌ |
| `out\runs\2211_ap\<时间戳>\` | 全量产物（报告 + `run.txt` + `heap_offline.txt`） | 结论证据 | ❌ |
| `out\runs\2211_ap_func\<时间戳>\` | 单功能产物（`<功能名>.txt` + `run.txt`） | 结论证据 | ❌ |
| `out\logs\` | 每次运行的 marker 日志 | 独立进度通道（报告被 t32 独占时也能看） | ❌ |
| `third_party\trace32_rcl\` | 解包好的 RCL 1.1.5（`lauterbach_trace32_rcl-1.1.5`） | 免 pip，`sys.path.insert` 即可 import | ❌ 第三方许可 |
| `third_party\launchers\*.lnk` | 客户 GUI 快捷方式**原件** | 内部硬编码绝对路径 + 创建者账号名 | ❌ 用 `tools\` 重建 |
| `third_party\vendor\{2100,2110,2210,3510}_trace32\` | 客户现成的 TRACE32 **GUI** 脚本族（含 `.svn`） | 移植抄写的主要参考，**冻结只读** | ❌ 客户版权 |
| `cmm\src_2210\` | `third_party\vendor\2210_trace32` 的副本（17 件，去掉了 `.svn`） | **留给后期彻底改造**；目前与原件逐字节相同 | ❌ 暂不纳管 |
| `ramdump\2211_deathscene\` | 死机现场数据（`cpu-ap.elf` 25 MB、`IRAM.bin`、`PSRAM.bin`、`ap_ilm/dlm.bin`、`0xC8031000.xip`） | 无人化跑的**只读输入**，冻结 | ❌ 35 MB + 内网痕迹 |
| `LICENSE` `NOTICE` | Apache-2.0 全文 + 版权与归属声明 | 许可（见 §9） | ✅ |

### 1.2 测试怎么跑（`tests\` 是唯一测试路径）

```powershell
cd <repo>
powershell -ExecutionPolicy Bypass -File tests\run_all.ps1          # 全部
powershell -ExecutionPolicy Bypass -File tests\run_all.ps1 -SkipT32 # 只校验现场哈希
```

`run_all.ps1` 依次用子进程跑 5 段，逐段打印退出码，末尾给 `TESTS-OK` / `TESTS-FAILED`：
死机现场 SHA256（9/9）→ 冒烟（5 marker）→ 2211 全量（12 marker）→ 单功能 `-Func all`（11 PASS）→ 两入口等价（`EQUIV-OK`）。
**每个 runner 都有 marker 闸门**：期望的 marker 名单放在 `tests\smoke\*.markers` 里，
少一条就 `exit 1`（不再只看进程退出码这种假绿）。

> ### ★ 冻结边界
> `third_party\vendor\`、`ramdump\` 两处是客户资产副本，**只读**：任何脚本、任何实验都不许写入。
> 本项目**不依赖也不链接**外部的客户启动目录（本机另有一份，不在本仓库），只用本目录内的副本。
> ⚠️ `third_party\launchers\*.lnk` 的 `-c` 参数指向那个外部目录里的 `config_sim.t32`，按上述口径**这三个原始快捷方式不可用**，
> 只能当「客户原本怎么启动」的参考；它们的内部字符串还带着本机绝对路径与创建者账号名，所以**不入库**——
> 要双击启动就用 `tools\make_shortcuts.ps1` 在本机重建（重建版指向下面这份配置）。
> **`configs\sim-gui.t32` 本身可以直接用**：它的 `SYS=__T32_INSTALL__` 指的是**安装目录**（不是那个外部启动目录），
> 运行时替换成真实路径后，`<T32_INSTALL>\bin\windows64\t32mriscv.exe -c <repo>\local\sim-gui.t32` 就能起客户的 GUI 环境。
> 无人化配置应当从这份**派生**（只加 `SCREEN=OFF` + `RCL=NETTCP`），以保证 `SYS=` 与客户一致、不会漂移。
> 根目录只有 **5 个文件**：`README.md`、`LICENSE`、`NOTICE`、`.gitignore`、`.gitattributes`。

---

## 2. 环境事实（实测）

- 安装路径：`__T32_INSTALL__`（占位符，真实值在 `local\paths.psd1`）
  - 版本：**R.2026.02.000190766**（`version.t32` 写着 Release Feb 2026 / Build 187884--190766）
  - 启动器：`bin\windows64\t32marm.exe`（ARM，45.4 MB）；另有 `t32mriscv.exe`、`t32mceva.exe`
  - 远程控制 CLI：`bin\windows64\t32rem.exe`（PE 子系统 = 3，控制台程序）
  - 手册：`<T32_INSTALL>\pdf\{app_remote_control.pdf, app_python.pdf, api_remote_c.pdf, app_t32start.pdf}`
- 生效配置的真实位置是**本目录的 `configs\sim-gui.t32` 一类文件**，
  而**不是**安装根的 `config.t32`（那里面只有 `PRINTER=WINDOWS`）。
  ⇒ 客户既有文档《TRACE32脚本离线分析与远程控制方案.md》说“在 `config.t32` 中添加 RCL/PORT/PACKLEN”**文件指错了**。
- Python：实测 `python --version` = **3.13.2**；**RCL 未通过 pip 安装**（沙箱禁止 pip 建临时目录），
  所以改为直接解包 wheel：`<T32_INSTALL>\demo\api\python\rcl\dist\lauterbach_trace32_rcl-1.1.5-py3-none-any.whl`
  → 已解包到 `third_party\trace32_rcl\`（该 wheel 是纯 Python zip、**无任何 `Requires-Dist` 依赖**）。
- ⚠️ **不要把 `t32marm.exe` 的 stdout/stderr 重定向**：`Start-Process -RedirectStandardOutput/-RedirectStandardError`
  必定失败，报
  `已添加项。字典中的关键字:"NO_PROXY"所添加的关键字:"no_proxy"`
  （环境里同时存在 `NO_PROXY` 与 `no_proxy`）。TRACE32 是 GUI 程序、本来也不写 stdio，
  **一切证据靠脚本自己写文件（`out\logs\`）或 RCL 的返回值**。

---

## 3. ★ 七条铁律（全是踩过的坑）

### 铁律 1：配置文件必须用空行分组
`KEY=VALUE` 之间**必须有空行**，不能全部连排。否则 PowerView 会开一个标题为
`TRACE32 PowerView`（**不带 “for ARM”**）的窗口，`-s` 指定的脚本**从不执行**，进程挂到被杀。
实测对照（同一脚本、每次都从干净状态起）：

| 配置 | 差异 | 结果 |
|---|---|---|
| `attic\configs\zz1.t32` | 客户 `config_sim.t32` 逐字节拷贝 | ✅ exit=0，日志正常 ⇒ 文件名/目录无关 |
| `attic\configs\zz2.t32` | **删掉所有空行** | ❌ 超时、无日志 |
| `attic\configs\zz3.t32` | 删注释、**保留空行** | ✅ exit=0 |
| `attic\configs\zz4.t32` | 删开头两行空行、其余保留 | ✅ exit=0 |
| `attic\configs\config_auto.t32` / `v1_leadblank.t32` | `OS=/ID=/SYS=/PBI=/PRINTER=` 连排 | ❌ 超时或 exit=2、无日志 |

最小可用形态见 `configs\sim-minimal.t32`。

### 铁律 2：无窗口模式下 `DIALOG.*` 会永久挂死
`SCREEN=OFF` 时执行 `DIALOG.OK "..."` **无超时、无报错地永久卡住**，`QUIT` 永远不会到达；
诊断时只表现为“日志少了几行”。`AREA.view` 则无害。
复现脚本：`attic\cmm\gui_test.cmm`（实测 30 秒未退出，日志只写到 `G2-AFTER-AREAVIEW`）。
⇒ **从 GUI 抄脚本时，必须把所有 `DIALOG.*` 删干净。**

### 铁律 3：每次实验前先杀干净 `t32*` 并等待约 4 秒
残留实例会让下一次启动 exit=2 或者直接挂住，且现象和铁律 1 很像，容易误判。

### 铁律 4：跑 TRACE32 的进程树必须对输出目录（`out\logs\`）有写权限
如果 `out\logs\` 不可写（受限沙箱、只读环境、权限不足），**第一条 `APPEND` 就会失败**，
TRACE32 会停在错误对话框上：**既不生成日志、也不退出**。
现象是「批处理超时 + 一条日志都没有」——和铁律 1 长得极像，极易误判。
（这是在把本目录搬到工作区外之后实测撞到的：同一个配置、同一个脚本，
在旧目录能 exit=0，在新目录因为子进程没有写权限就必然超时。）

两个应对，都已落地在这个目录里：
- `cmm\` 下所有脚本的**第一行**都是 `ON ERROR CONTinue`，写不动也不会卡死；
- `cli\run_smoke.ps1` 会显式检测「日志文件缺失」并打印
  `[FAIL] out\logs\restore.log was not created - the script never ran`。

### 铁律 5：相对路径的基准是 **t32 进程的 CWD**（本轮实测确认）
不是 `-c` 配置所在目录，不是 `-s` 脚本所在目录，也不是 `SYS=`。
实测方法：同一份脚本、同一份配置，只改 `-WorkingDirectory`，`APPEND out\logs\x.log` 的落点跟着变；
把 CWD 指到别的目录并预建该目录下的 `out\logs\`，文件就落在那边，仓库根的 `out\logs\` 一条不动。
⇒ 本目录所有 `cmm\` 脚本都写**相对路径** `out\logs\`，所以**必须以仓库根为工作目录启动 t32**
（`cli\run_smoke.ps1` 显式传 `-WorkingDirectory $here`）。
手动跑批处理时先 `cd` 到仓库根，否则标记文件会**安静地**落到别处。

### 铁律 6：`APPEND` **不会自动创建中间目录**，缺目录时静默失败
目标目录不存在时 `APPEND` 直接失败；因为脚本首行是 `ON ERROR CONTinue`，失败是**无声的**——
进程 exit=0、退出码干净、结果全空，看起来像「脚本没执行」。
⚠️ 这条是本轮实测时**先被它骗过一次**才总结出来的：在临时目录里跑相对路径探针，
因为那儿没有 `out\logs\`，写入失败，于是得出了「相对路径不生效」的错误结论。
⇒ `cli\run_smoke.ps1` 会先把 `out\logs\` 建出来；自写脚本时也要先确保目录存在。

### 铁律 7：自研文件的注释写中文，但 `.ps1`/`.psd1` 必须存成 **UTF-8 with BOM**
本仓库自研文件（`cli\`、`cmm\`、`tools\`、`tests\`、`configs\`）的注释一律中文，编码按类型分两档：

| 类型 | 编码 | 原因 |
|---|---|---|
| `.ps1` / `.psd1` | **UTF-8 with BOM** | Windows PowerShell 5.1 读**无 BOM**文件时按 ANSI(GBK) 解码：中文注释变乱码**并直接破坏解析**（实测：本仓库 `local\check_cn_comments.ps1` 就是这么挂的，报一堆 `Unexpected token`） |
| `.py` / `.cmm` / `.tmpl` / `.t32` / `.json` | **UTF-8 without BOM** | Python 3 默认 UTF-8；TRACE32 已能跑含 UTF-8 中文注释的客户脚本（见 §6）；`ConvertFrom-Json` / `Get-Content -Encoding UTF8` 正常 |

- 客户资产（`third_party\`）**一个字都不改**——它们的编码是三态混杂（§6），一次「另存为」就可能毁掉。
- 改这些非 ASCII 文件时一律**保字节**（Latin-1 往返）替换，绝不整篇重写。
- 机械校验：`powershell -ExecutionPolicy Bypass -File local\check_cn_comments.ps1`（该脚本是**本机工具**，不入库；仓库里能复现的是 `tests\run_all.ps1`）
  （非注释行对照 `HEAD`、BOM/编码报告、GBK 乱码探针，全绿打印 `CN-COMMENTS-OK`）。
- **`.t32` 的空行一个字都不许动**（见铁律 1）——改注释时尤其容易手滑。

---

## 4. 怎么用

### 4.0 先填本机路径（首次必做）

仓库里**没有任何本机绝对路径**，只有 4 个占位符；真实路径放在 `local\paths.psd1`（不入库）：

| 占位符 | 出现在 | 含义 |
|---|---|---|
| `__T32_INSTALL__` | `configs\*.t32`（含 `sim-gui.t32`）、`attic\configs\*.t32` | TRACE32 安装目录（含 `bin\windows64\`） |
| `__BSP_DIR__` | `cmm\*.cmm` | RT-Thread BSP 产物目录（`rtthread.bin` **无连字符** + `rt-thread.elf` **有连字符**） |
| `__TMP_DIR__` | `attic\configs\*.t32`（历史对照） | 早期临时工作区 |
| `__T32_START_TEMP__` | `configs\sim-gui.t32` 注释行 | 客户启动目录的 `Temp` |

```powershell
Copy-Item local\paths.psd1.example local\paths.psd1    # 然后按本机情况改里面两行
```

`cli\run_smoke.ps1` 在运行时把占位符替换成本机值，生成 `local\smoke.t32` 与 `local\run_restore.cmm`
（都在 `local\` 下）。替换是**保字节**做的（Latin-1 往返），因为这些模板是**编码三态**的（见 §6）。

### 4.1 一键冒烟（推荐先跑这个）
```powershell
powershell -ExecutionPolicy Bypass -File <repo>\cli\run_smoke.ps1
```
它会走两个阶段并打印 `[PASS]/[FAIL]`：
- 阶段 A：批处理 `-c local\smoke.t32 -s local\run_restore.cmm` → 检查 `out\logs\restore.log` 里的标记
- 阶段 B：起实例 → `cli\rcl_smoke.py` → 做 FLASH 逐字节对齐断言 → 收尾杀进程

> **实测结果（改成本机配置注入后的重跑）**：阶段 A `exit code = 0`，5 个标记全 PASS；
> 阶段 B 4 项断言全 PASS、`SMOKE-ALL-OK`、python 退出码 0；结束后无残留 `t32*` 进程。
> 两个注意点：① 必须让该脚本及其子进程 `t32marm.exe` 对 `out\logs\` 有写权限（见铁律 4）；
> ② 断言里比较读回值要按**整数**比，`hex()` 不做零填充（`0x8003a3d` 就是 `0x08003a3d`）。

### 4.2 手动起一个无窗口实例（跑完自己 `QUIT`，或直接 Kill）
```powershell
$T32 = Join-Path (Import-PowerShellDataFile local\paths.psd1).T32_INSTALL 'bin\windows64\t32marm.exe'
Start-Process -FilePath $T32 -ArgumentList @('-c', "$PWD\local\smoke.t32") `
              -WorkingDirectory $PWD -PassThru      # CWD 必须是仓库根（铁律 5）
# 用完： Get-Process -Name 't32*' | ForEach-Object { $_.Kill() }
```

### 4.3 批处理跑一份 CMM（不需要先起实例）
```powershell
cd <repo>                                              # 铁律 5
& "$((Import-PowerShellDataFile local\paths.psd1).T32_INSTALL)\bin\windows64\t32marm.exe" `
  -c local\smoke.t32 -s local\run_restore.cmm
```
脚本末尾必须有 `QUIT`，否则进程不退出。
被强杀的进程树还有可能在 `cmm\` 里留下 `out\logs\` 写了一半的日志（铁律 6）。

### 4.4 Python RCL（推荐）
```python
import sys, os; sys.path.insert(0, r"<repo>\third_party\trace32_rcl")
import lauterbach.trace32.rcl as rcl
dbg = rcl.connect(protocol="TCP", port=20000)      # 需先用 local\smoke.t32 起实例
dbg.cmd("SYStem.CPU STM32F407ZG"); dbg.cmd("SYStem.Up")
dbg.cmd(r"Data.LOAD.Binary %s 0x08000000" % os.environ["RAMDUMP_BSP_DIR"] + r"\rtthread.bin")
a = rcl.Address(dbg, value=0x08000000)             # ⚠️ 必须传 Address 对象，不能传 int
print(bytes(dbg.memory.read(a, length=20)).hex())
dbg.fnc("Var.Value(sizeof(ramdump_exception_t))")  # 52
```
BSP 路径走环境变量 `RAMDUMP_BSP_DIR`（`cli\run_smoke.ps1` 会设置），不写死在代码里。
已知可用/不可用的调用、错误原文，见 [`docs\rcl-api-notes.md`](docs/rcl-api-notes.md)（第十轮从已删除的客户报告第 7 节里提炼）；最简可用示例见 `cli\rcl_smoke.py`。

### 4.5 两个实例并行
需要同时跑两个实例时，复制一份 `configs\` 里的配置、把 `PORT=` 改成另一个端口（例如 20001）即可，实测互不干扰。

---

## 5. 已实测跑通的能力（证据）

- **无硬件离线分析成立**：`PBI=SIM` 下 `SYStem.CPU STM32F407ZG` + `SYStem.Up` 都成功。
- **★ 逐字节对齐（黄金标准）**：`Data.LOAD.Binary rtthread.bin 0x08000000` 之后

  | 地址 | TRACE32 读回 | `rtthread.bin` 头 8 字节 |
  |---|---|---|
  | `D:0x08000000` | `0x10001230` | `30 12 00 10` |
  | `D:0x08000004` | `0x08003A3D` | `3d 3a 00 08` |

  完整 20 字节（RCL 读回）=`301200103d3a00088d3a0008bd020008ddff0008`，与文件逐字节一致
  ⇒ 铺回地址与读回都正确。
- **DWARF 类型可用**：`Var.Value(sizeof(ramdump_exception_t))` = **0x34 = 52**
  （ramdump 的异常结构体可以被 TRACE32 直接解析）。
- **符号可用**：`dbg.symbol.query_by_name("g_ramdump_exception")` → `g_ramdump_exception D:0x20003aac 52`；
  `rt_thread_priority_table D:0x2000396c 256`（256 = 32 优先级 × 8 字节指针），地址与 `rt-thread.map` 一致。
- **两种传输通道都通**：`RCL=NETASSIST` → 只开 **UDP 20000**；`RCL=NETTCP` → **TCP 20000 LISTENING**。
- **文件契约可靠**：`APPEND <路径> "文本"` 在脚本中途出错时也已落盘；
  `AREA.Create/OPEN REPORT &file` 可把之后所有 `PRINT` 写进文件。
  （注意：被强杀时 `APPEND` 的最后一行可能丢，**不能仅凭缺行判定失败**。）

### 5.1 ★ 2211 AP 死机现场的无人化提取（实跑）

`cli\run_2211_ap.ps1` 用**客户 2210 的原始脚本**（`third_party\vendor\2210_trace32\`，一个字节都没改）
分析 2211 现场，全程无 GUI、无人工点击：`exit=0`、约 **1 秒**。

| 环节 | 做法 |
|---|---|
| 绕开 GUI | 17 个脚本里只有 `LM620_Restore.cmm`（27 处 `DIALOG` + `STOP`）和 `select_thread.cmm`（4 处 `DIALOG` + `STOP`）含交互，其余 15 个可直接串起来调用 |
| 入口 | `cli\2211_ap_analyze.cmm.tmpl` → 展开成 `local\run_2211_ap.cmm`，9 段：restore / sysinfo / errinfo / thread / backtrace+frame / 全线程回溯 / mailbox / thread-swap / heap |
| 进度 | 13 个 marker 写进 `out\logs\2211ap-<时间戳>.log`（独立通道：报告被 t32 独占时也能看进度） |
| 产物 | `out\runs\2211_ap\<时间戳>\` 下的 `2211_ap_deathscene.txt`（355 行）、`run.txt`（provenance + ELF SHA256）、`heap_offline.txt` |

现场读数（`out\runs\2211_ap\20261007-171208\`）：

- `ERRINFO: "AP Assert. File: dlmalloc.c, Line: 1138, PC: 0xC0265232"`
- 异常帧回溯：`osAssertHandler → 0x8011C472`、`dlMalloc → 0xC0265232`、`osMallocTrace → 0xC026575E`
  ⇒ **断言是在分配路径里触发的**（`osMallocTrace` → `dlMalloc` → 断言）。
- 线程表、全线程回溯、mailbox 表都完整；`show_thread_swap.cmm` 只出 3 行（该脚本本身信息量极低）。
- **★ 堆（离线复算，`tools\heap_stats_offline.py`）**：arena `0x80164CB8`（`g_osApSystemMem`）、
  `total=0x188640`(1607232 B)、`used=0x17CEC0`(1560256 B，**97.1 %**)、`max_used=0x17CFE0`(1560544 B，97.1 %)、
  `user_used=0x134A99`(1264281 B，78.7 %)；按块首的 owner 标记汇总：**`timer` 949240 B（60.8 %）**、
  `main` 231400 B、`sua0` 165720 B、`ImsMain` 100352 B … ⇒ 定时器任务占了大头，堆已接近耗尽。
- **强自检**：离线链枚举出 6028 个已用块，`Σ chunk size = 0x17CE08`，与 arena 的 `used = 0x17CEC0`
  只差 **184 B（比值 0.9999）**；另外 TRACE32 `Data.SAVE.Binary` 读回的 DLM/ILM/PSRAM
  与夹具文件**逐字节一致（0 mismatch）** ⇒ 装载与遍历都可信。

**做不到的部分（如实记）**：客户的 `print_dlmalloc_heap.cmm` / `print_mem_summary_by_file.cmm`
在这个 arena 上会**静默自旋**（自由链无环守卫、内层无 `size==0` 守卫），而它们依赖的
dlmalloc 内部 typedef（`mbinptr`/`mchunkptr`）与 `sizeof(...)` 在本环境**不求值**
（实测：用到它们的整行都不输出）⇒ 逐块 `Mem Leak Info` 表**无法从 CMM 复现**。
旁证：客户自己的 golden 里 `Memory Summary By File` 段**一行数据都没有**（段头之后直接接下一段），
且该固件把这个「来源」字段记成**任务名**（`timer`/`main`/…）而不是客户脚本在比较的 `.c` 文件名。
⇒ 堆这条线走「arena 描述符（CMM 读）+ chunk 链（Python 离线复算）」两条腿，都能对账。

### 5.2 ★ 一个功能，两个入口（GUI 按钮 ↔ 无 GUI 入口）

结论：**客户脚本一行都不用改，就能让每个按钮都多一个无 GUI 入口**。GUI 的 11 个按钮背后是
15 个纯脚本，其中只有两个文件含交互（`LM620_Restore.cmm` 的对话框、`select_thread.cmm` 的选线程
下拉框）；把对话框换成命令行参数，每个按钮就变成一个独立入口，两个入口调用的是**同一批客户脚本**。

| 功能 | GUI 按钮（`third_party\vendor\2210_trace32\LM620_Restore.cmm`） | 无 GUI 入口 | 调用的客户脚本 | 等价 |
|---|---|---|---|---|
| load | LOAD（L47-48 → `load_ramdump` L209-251） | `-Func load` | `restore.cmm` + `show_sysinfo.cmm` + `errinfo.cmm` | PASS，且**比按钮更全**：GUI 的 SYSINFO/ERRINFO 只进 `dyntext` 字段，永不落文件 |
| show_thread | ShowThread（L56-60） | `-Func show_thread` | `show_thread.cmm` | PASS |
| backtrace | BackTrace（L62-69） | `-Func backtrace` | `backtrace.cmm` + `frame.cmm` | PASS |
| thread_bt | ThreadBT（L71-83，先弹选线程框） | `-Func thread_bt -Thread <名>` | `thread_pick.cmm`（我们的）+ `backtrace.cmm` + `frame.cmm` | PARTIAL（多出 `THREADPICK:` / `Thread:` 两行头，正是客户选择器的等价物） |
| all_thread_bt | AllThreadBT（L85-89） | `-Func all_thread_bt` | `show_all_backtrace.cmm` | PASS |
| mailbox | MSG Box（L91-95，按钮名与脚本名不一致） | `-Func mailbox` | `show_mailbox.cmm` | PASS |
| mem_trace | MemTrace（L97-108） | `-Func mem_trace` | `show_ap_meminfo.cmm` | **不安全**：自由链无环守卫，实测自旋 |
| mem_summary | MemSummary（L110-121） | `-Func mem_summary` | `show_ap_meminfo_sum.cmm` | **不安全**：内层无 `size==0` 守卫 |
| thread_swap | ThreadSwap（L123-127） | `-Func thread_swap` | `show_thread_swap.cmm` | PASS |
| heap | （**没有这个按钮**） | `-Func heap` | `heap_summary.cmm`（我们的） | 替代上面两个不安全按钮 |
| sysinfo / errinfo | （`dyntext` 字段，L51/L54，不落文件） | `-Func sysinfo` / `-Func errinfo` | `show_sysinfo.cmm` / `errinfo.cmm` | PASS |
| heap_offline | （GUI 根本做不到） | `-Func heap_offline` | 无（纯 Python） | 与全量 run 的 `heap_offline.txt` **逐字节相同** |

```powershell
powershell -ExecutionPolicy Bypass -File cli\run_2211_func.ps1 -List              # 看注册表（13 个功能）
powershell -ExecutionPolicy Bypass -File cli\run_2211_func.ps1 -Func show_thread  # 只跑一个功能
powershell -ExecutionPolicy Bypass -File cli\run_2211_func.ps1 -Func all -TimeoutSec 120
python tools\check_entries_equiv.py                                                   # 证明两个入口等价
```

实测（`out\runs\2211_ap_func\20261007-213816`，11 个安全功能，总耗时约 50 s）：全部 `[PASS]`；
`python tools\check_entries_equiv.py` 对全量 run `out\runs\2211_ap\20261007-213553` 判定 **`EQUIV-OK`**
（10 个 PASS + `thread_bt` 按预期 PARTIAL）。`-Func all` **主动跳过** `mem_trace` / `mem_summary` 这两个
实测会自旋的功能（要单独跑就 `-Func <名>`，或 `-IncludeUnsafe` 全跑）。

**模块化的关键不是多写脚本，而是「功能的实现只写一遍」**：每个功能的 PRACTICE 语句体只存在于
`cmm\functions.json`，入口模板只认占位符 ⇒ 加/改一个功能 = 改一行 JSON，不动模板、不动 runner、
不动客户脚本。

> ⚠️ 本轮实测到一条会**静默出错**的 PRACTICE 坑（写在这里，因为 `thread_bt` 就靠它）：
> `do script.cmm "&want"` 传进去的是**带引号**的 `"idle"`，等值判断永远不成立；`do script.cmm &want`
> 才是 `idle`。文件路径用带引号的形式之所以没出事，是因为 TRACE32 打开文件时会剥掉引号——
> **字符串比较不会**。所以传宏给 `do` 时**不要加引号**（线程名带空格的名字这条路走不通，已记在
> `cmm\thread_pick.cmm` 的注释里）。
> 另一条：打印 AREA 的宽度会**截断**长行（全量用 `120.`，实测 119 列封顶），两个入口的 AREA 宽度
> 必须一致，否则同一句话在两边长度不同——第一条 `EQUIV-FAILED` 就是这么抓出来的。

---

## 6. 现成可抄的素材（在本目录 / 安装目录里）

- `third_party\vendor\2110_trace32\restore.cmm`（52 行，客户生产脚本）= **离线加载链模板**：
  `ENTRY &ramdump_path &elf_file` → `SYStem.CPU …` / `SYStem.Up` → 逐区域 `Data.LOAD.Binary <file> <addr>`
  → `Data.LOAD.Elf &elf_file /NoCODE /RelPath`（只取符号）→ `&frame=Var.Value(exc_trace)`
  → `do frame.cmm &frame`。证明 **CMM 可以命令行传参、可以完全脚本化**。
  它读的是参数给的 dump 目录，**自己不写任何东西**——写盘只发生在 GUI 包装层（见 §6.1），
  所以绕过 GUI 层就同时保住了夹具的只读性。
- `third_party\vendor\2110_trace32\frame.cmm` = 从 dump 里的栈帧恢复寄存器，用的就是
  `Register.Set PC Var.Value(((struct rt_hw_stack_frame*)&cpu_frame)->… )`
  ⇒ **Cortex-M4 版主要是字段改名**（`r0-r3/r12/lr/pc/xpsr`）。
- `third_party\vendor\2110_trace32\backtrace.cmm` 靠解码返回地址前的指令位（RISC-V 专用）过滤假回溯 ⇒ Thumb-2 版**必须重写**。
- `<T32_INSTALL>\demo\arm\etc\ramdump\ramdump.cmm`（33862 B / **1125 行**）= **Lauterbach 官方 ARM ramdump 脚本**，
  厂商设计意图就是“离线 dump + 在仿真器里还原”（内含 `IF !SIMULATOR() → PRINT %ERROR` 守卫），
  并用 `ENTRY %LINE &sArguments` + `&bDialog` 做「GUI 弹窗 / 命令行直跑」双模。**尚未精读，是首选参考。**
- `<T32_INSTALL>\demo\practice\logfile\area_log.cmm`（60 行）= 输出落盘官方姿势
  （`AREA.OPEN REPORT &filename` + `IF (SYStem.Mode()==0)` 当断言）。
- `<T32_INSTALL>\demo\practice\unittest\lbtest.cmm` + `test_example_minimal.cmm` = **自带单元测试框架**，
  断言宏 `A_TRUE / A_FALSE / A_NUM_EQ / A_STR_EQ`，用例骨架
  `PRIVATE &func &args &result` / `ENTRY &func %LINE &args` / `GOSUB &func &args` / `ENTRY %LINE &result` / `ENDDO &result`。
- ⚠️ **编码是三态混杂，不是「一律 GBK」**（已逐个文件实测）：

  | 范围 | 编码 | 证据 |
  |---|---|---|
  | `third_party\vendor\3510_trace32\`（全 18 个文件） | **纯 ASCII** | 无一个高位字节 |
  | 客户 RTOS 任务配置 `.t32`、`*_Restore.cmm`、`print_*`、`show_ap/cp_meminfo`、`show_mailbox`、`show_thread` | **GBK** | 那份 `.t32` 有 7588 个非 ASCII 字节且非 UTF-8 |
  | 各 `*_restore/frame/backtrace/errinfo`、`show_sysinfo`、`select_*` | **UTF-8** | 含中文注释且能通过严格 UTF-8 解码 |

  同一个词「脚本」在 `third_party\vendor\2210_trace32\restore.cmm` 里显示为 `脚本`（UTF-8），
  在 `show_thread_swap.cmm` 里显示为 `½Å±¾`（GBK 被按 UTF-8 读）——
  **一次「用编辑器另存」就可能毁掉注释或让解析器报错。** 必须改这些模板时，用**保字节**替换
  （decode/encode 都走 Latin-1），不要用普通「另存为」。
- 我方自研文件则相反：注释**全部中文**，且 `.ps1`/`.psd1` 存成 **UTF-8 with BOM**
  （Windows PowerShell 5.1 会把无 BOM 文件按 ANSI/GBK 读，非 ASCII 会直接毁掉解析）——见铁律 7。

### 6.1 ★ 无 GUI 化的支点：客户脚本是「GUI 包装层 + 纯 CLI 内核」两层

```
<平台>_Restore.cmm        ← 只有这层是 GUI：DIALOG.AREA / DIALOG.DISABLE / STOP
  └─ do &cpu_name"_restore.cmm"   ENTRY &ramdump_path &elf_file   ← 这层本来就能命令行传参
       └─ do &cpu_name"_frame.cmm" / "_backtrace.cmm" / "_errinfo.cmm"   ← 纯 PRINT，无 GUI
```

⇒ **不需要重写客户脚本，只要绕过 GUI 包装层**；而 `DIALOG.*` 在 `SCREEN=OFF` 下必挂（铁律 2），所以这层**必须**绕过。

`&cpu_name` 的取值来源有两套，别混：入口用 `OS.PEF()` 取可执行文件名
（`t32mriscv.exe`→`risc-v`、`t32mceva.exe`→`ceva`，见 `third_party\vendor\2100_trace32\` 下的入口脚本），
或按 ELF 文件名（`cpu-ap.elf`→`ap`、`cpu-cp.elf`→`cp`，见 2110/2210/3510）。
2110/2210 的 per-core 文件**不带前缀**（就叫 `restore.cmm`/`frame.cmm`），3510/2100 则带 `ap_`/`cp_`/`risc-v_`/`ceva_` 前缀。

**启动器必须配对**（`.lnk` 佐证）：`2100`/`2110`/`2210`/`3510` 装的都是 RISC-V（`SYStem.CPU RV32`/`RV64` + `Register.Set PRV`），
要用 `bin\windows64\t32mriscv.exe`；带 CEVA 核的那两代用 `t32mceva.exe`；
只有 RT-Thread/STM32F407 那条线用 `t32marm.exe`。
（**这条是推断，尚未实测**——跑一次即可确认。）

另注：`third_party\vendor\2110_trace32\` 与 `third_party\vendor\2210_trace32\` 之间有 **11 个文件逐字节相同**（`backtrace/errinfo/frame/restore/select_thread/print_smallheap/show_all_backtrace/show_ap_meminfo/show_cp_meminfo/show_mailbox/show_sysinfo`），
说明 2210 是 2110 的分支演进；2210 独有 `print_mem_summary_by_file.cmm`、`show_ap_meminfo_sum.cmm`、`show_thread_swap.cmm`。
`show_thread_swap.cmm` 用 `//` 当注释（PRACTICE 注释是 `;`）、`&time2`/`&time_irq_idle` 未 `LOCAL` ⇒ **疑似坏文件，别当模板抄**。

> **客户标识说明**：`third_party\vendor\` 不入库，所以本文对平台一律用**目录编号**指代
> （`2100`/`2110`/`2210`/`3510`），不写客户产品名、项目代号与供应商名称；
> 平台 ↔ 产品名的对照与客户版权头出处**不再保存在本仓库**（第十轮删掉了 `private\`），
> 需要时从 `third_party\vendor\` 各目录的 `.cmm` 版权头与 `.svn\wc.db` 里查。

---

## 7. 下一步 / 已知缺口

1. **TRACE32 没有 RT-Thread 内核感知。**
   `<T32_INSTALL>\demo\arm\kernel\` 下有 67 个 RTOS 目录（freertos / threadx / ucos / liteos / zephyr …）**没有 rtthread**，
   整个安装目录按文件名搜 `rt[-_]?thread` **零命中**。
   ⇒ 线程列表 / 每线程栈用量 / 全线程回溯**必须自己写**。
   先例：客户为自研 RTOS 手写的 `<平台>_trace32\` 下的 `.men`(13045 B) + `.t32`(37132 B) 菜单与任务配置。
2. **五段管线的状态**：[1] 构建/烧录/触发 = 已有；[2] `tests\ramdump.sha256` = **已有**（第七轮补上，记录
   `ramdump\` 各文件的路径与 SHA256——因为死机现场本身不入库，靠它离线核对）；
   [3] 传输自检 = **缺**（`cli\rcl_smoke.py` 的 FLASH 逐字节断言是最小可用版本，可扩成全片自检）；
   [4] 分析 = **已有**（2211 AP 现场已跑通，见 §5.1，并已拆成 11 个单功能入口、双入口等价已判定，见 §5.2；
   只有「逐块内存来源表」复现不了，原因见 §5.1）；
   [5] 断言判定 = **半有**（第七轮补上「marker 闸门」：三条链各自的期望 marker 存 `tests\smoke\*.markers`，
   少一条即 `exit 1`，见 §1.2；`tools\check_entries_equiv.py` 也加了覆盖断言，缺一个功能就是 `FAIL`。
   **仍缺**内容级断言——把报告与基线做归一化 diff；基线应当是**本仓库自己产出并经人工确认的报告**（`out\runs\`），
   第十一轮已删掉从 `ramdump\` 复制出来的那份冗余 `tests\expected\` 副本）。
3. **官方 `ramdump.cmm`（1125 行）还没精读**，Cortex-M 移植前值得先读。
4. **Session 0（无人登录）场景未验证**：若走计划任务“不管用户是否登录运行”或做成服务才需要验证。
   用户始终在已登录桌面跑自动化的话，这条不适用。
5. 自动化机器上 TRACE32 的**并发实例数 / 授权上限**未确认（仿真模式下未见限制）。

---

## 8. 附：本目录写入历史

> 下面是逐轮记录（历史原文保留）。被后续轮次改掉的路径以**最后一轮**为准——例如 `gui\config_sim.t32`
> 在第七轮建立、第十轮并入 `configs\sim-gui.t32`；`fixtures\` 在第五轮命名、第十轮改名 `ramdump\`。

- **搬运**：把旧临时工作区（`rt-thread-ros` 下的 `trace32_tmp\`）里的分析产物搬运/重编到本目录，
  并把 `cmm\` 内脚本的输出路径从旧的 `trace32_tmp\out` 统一改为本目录的 `out\logs\`。
- **加固并重跑验证**：① `cmm\` 下 12 个以 `APPEND` 开头的脚本，首行统一插入 `ON ERROR CONTinue`；
  ② `cli\rcl_smoke.py` 的断言改为按整数比较、输出改为纯 ASCII。
- **架构整理（第二轮）**：口径改为「**不依赖、不链接**外部的客户启动目录，只用本目录内的副本，
  副本只作参考/夹具，**禁止修改**」。据此：① 4 个芯片目录**原样**搬入 `third_party\vendor\`（保留原目录名，
  搬迁后逐项 MD5 与搬迁前一致）；② `examples\2211\` → `fixtures\2211_deathscene\`（拉平多余的一层 `2211\`）；
  ③ 从夹具**复制出**基线 `tests\expected\2211_ap_PrintData.txt`；④ §1 导航表重写 + 新增「★ 冻结边界」，
  §6 纠正「客户 `.cmm` 一律 GBK」的错误说法并补 §6.1 两层结构。
- **架构整理（第三轮）**：把客户 GUI 启动件收进 `launchers\`（`config_sim.t32` + 3 个 `.lnk`，原样搬入）；
  第七轮再拆开：`config_sim.t32` → `gui\`（我方源码层），3 个 `.lnk` → `third_party\launchers\`（非我方资产）。
- **Git 纳管（第四轮）**：
  ① 建立公开/私有边界：客户报告原件与敏感信息排查记录移入 `private\`；`third_party\vendor\`、`fixtures\`、`tests\expected\`、
     `third_party\trace32_rcl\`、`local\`、`private\`、`third_party\launchers\*.lnk` 全部 `gitignore`；客户标识从本文正文移除；
  ② **本机路径参数化**：全库 131 处带盘符的绝对路径改成 4 个占位符（`__T32_INSTALL__`/`__BSP_DIR__`/
     `__TMP_DIR__`/`__T32_START_TEMP__`），真实值收进不入库的 `local\paths.psd1`；
     替换用**保字节**脚本做（Latin-1 往返），以兼容三态编码；替换顺序必须先长后短，
     因为安装目录那串路径同时是「本工作区目录名」与「客户启动目录名」的前缀；
  ③ `cli\run_smoke.ps1` 改为「读 `local\paths.psd1` → 生成 `local\smoke.t32` + `local\run_restore.cmm` →
     以仓库根为 CWD 启动 t32」；`cli\rcl_smoke.py` 的 BSP 路径改走环境变量 `RAMDUMP_BSP_DIR`；
     不可参数化的 `.lnk` 改由 `tools\make_shortcuts.ps1` 在本机重建；
  ④ 本轮实测确认了**铁律 5、铁律 6** 两条新规律（相对路径按进程 CWD 解析；`APPEND` 不建目录且静默失败）；
  ⑤ 改造后**重跑冒烟全绿**：阶段 A 5/5 PASS、阶段 B 全 PASS、`SMOKE-ALL-OK`、退出码 0。
- **2211 现场提取（第五轮）**：新增 `cli\`（`run_2211_ap.ps1` + `2211_ap_analyze.cmm.tmpl`
  + `heap_summary.cmm`）与 `tools\heap_stats_offline.py`，用客户 2210 的原始脚本把 2211 AP 死机现场
  无 GUI 提取成 txt（见 §5.1）。过程中实测确认了几条规律：① 打印 AREA 只在 **16 KB 缓冲满或 `AREA.Close`**
  时落盘，强杀会丢掉最后一个 16 KB 块之后的内容（所以链路必须跑完，且得有边界）；
  ② `((osDlmalloc_t *)&<符号>)->字段` 只在符号名写成**字面量**时可用，经 `do` 宏参数传进来再读会返回原始字节串；
  ③ 没有 `SYStem.Up` 时一切内存读（`Data.Long`、`Var.Value`）都**静默失败**（独立探针必须先跑 `restore.cmm`）；
  ④ （第六轮已收窄）当时以为「`PRINTF` 带数值参数不出字」，其实客户脚本自己就在用
  `PRINTF "=>THREAD:%16s  Struct:0x%08x" Var.String(...) &addr`，能正常出字；真正不吃的是把 `&宏`
  直接当 `%` 的实参，以及把 `+FORMAT.HEX(...)` 拼进 `APPEND`。稳妥写法仍是 `PRINT "…"+FORMAT.HEX(...)`。
  期间自建的临时探针（`heap_walk.cmm`、`summarize_heap.py`、`probe_*.cmm`、`out\runs\_probe\`）**已全部删除**。
- **一个功能，两个入口（第六轮）**：新增 `cmm\functions.json`（注册表：13 个功能，PRACTICE 语句体
  **只写这一处**）、`cli\2211_ap_func.cmm.tmpl`（单功能入口骨架）、`cmm\thread_pick.cmm`
  （`select_thread.cmm` 的无 GUI 孪生，同一套 `g_osThreadList` 遍历 + 同样的名字等值匹配）、
  `cli\run_2211_func.ps1`（`-List` / `-Func <名>` / `-Func all`）、`tools\check_entries_equiv.py`
  （子序列包含判定，证明单功能报告就是全量报告里那一段）。实测 11 个安全功能全 PASS、`EQUIV-OK`，
  `mem_trace`/`mem_summary` 由 `-Func all` 主动跳过（见 §5.2）。本轮又实测出三条规律：
  ① `do script.cmm "&x"` 传进去的是**带引号的字符串**（等值判断必不成立），`do script.cmm &x` 才对——
  文件路径之所以没事，是 TRACE32 打开文件时剥引号；② 打印 AREA 的宽度会**截断**长行（`120.` 实测 119 列
  封顶），两个入口必须用同一宽度；③ `IF ("字面量"=="&宏")` 的字符串等值判断本身是好用的（这正是
  `select_thread.cmm` 的写法）。踩坑过程：第一版模板里 `__FUNC_BODY__` 先于 `__SCRIPT_DIR__` 被替换，
  导致生成脚本里留着 `do __SCRIPT_DIR__\show_thread.cmm`（全部功能零输出）⇒ 改为**先展开 body 再展开模板**，
  并加一道「展开后不得残留 `__…__`」的断言。
- **顶层重组（第七轮）**：按「源码 / 测试 / 素材 / 产物 / 文档」重排顶层，并**收敛契约**。
  ① 分区：`third_party\`（客户脚本族 `vendor\` + 3 个客户 `.lnk` + 解包好的 RCL SDK）、
  `src_2210\`（客户 2210 脚本的一份副本，去掉 `.svn`，留给后期彻底改造，暂不纳管）、
  `fixtures\`（夹具，原地不动）、`out\`（`runs\` + `logs\`）、`attic\`（原 `experiments\`）、
  `docs\`（原 `logs\history\`）、`tests\`（**唯一的测试路径**）；
  ② 两层拆分落地：`cmm\` = 无 GUI 内核（只被调用），`gui\` 与 `cli\` = **平级**的两个上层入口，
  都往下调 `cmm\`（`gui\config_sim.t32` 来自原 `launchers\`；三个 runner 与两个模板来自原 `harness\`，
  `rcl_smoke.py` 来自原 `python\`）；
  ③ **契约 4 类 → 2 类**：删掉根 `manifest.json`（其语义并入 `tests\fixtures.sha256`），
  2211 功能注册表只留 `cmm\functions.json`，marker 期望值从代码里搬进 `tests\smoke\*.markers`；
  ④ **补三条门禁**（此前有「假绿」，见下）：marker 断言（冒烟 5 / 全量 13 / 单功能 3）、
  `check_entries_equiv.py` 的覆盖断言（缺功能即 FAIL）、`tests\run_all.ps1` 统一入口；
  ⑤ **忽略规则去锚定**：保护性规则一律写成 `**/<名字>/`（`**/third_party/`、`**/src_2210/`、
  `**/tests/expected/`、`**/logs/*.log`…），并保留旧名（`**/vendor/`、`**/golden/`、`**/pylibs/`）
  作为兼容防线 ⇒ 目录改名或下移一层后规则仍然命中（用 `git check-ignore -v --no-index` 逐条实测过）。
  搬迁前后做了**内容级校验**：442 个文件（含不入库件）的 relpath→SHA256 快照，搬完全部对得上，
  只有本轮刻意修改的两个文件哈希变了。
  ⑥ **踩到的坑（本轮新规律）**：`run_smoke.ps1` 原来用 `Split-Path -Parent $MyInvocation.MyCommand.Path`
  取仓库根——脚本一下移到 `cli\` 就指错，必须改用 `$PSScriptRoot`；三个 runner 原来只看进程退出码，
  阶段失败也 `exit 0`（比如冒烟阶段 A 0/5 marker 仍返回成功），现在改为**按 marker 判定**；
  `run_smoke.ps1` 原来给 `-ArgumentList` 传的是未加引号的数组，路径含空格就会静默失败，现已显式加引号；
  非 ASCII 文件（`.cmm` 三态编码、GBK/UTF-8 混杂）一律用 **Latin-1 保字节**方式改路径，绝不用 UTF-8 重写。
- `attic\logs\` 是搬运前的原始日志（第十一轮从 `docs\history\` 移入，只读证据）；`out\logs\` 里的是在本目录重跑产生的（不入库）。
- 遗留的可选清理项（**未删**，它们是分析证据）：`attic\` 下 18 个对照/失败配置与 6 个早期 RCL 试验脚本。
- 外部的 TRACE32 安装目录与客户启动目录**全程未被修改**。
- **注释中文化（第八轮）**：把 35 个纯 ASCII 的自研文件（`cli\` 3 个 runner + 2 个模板、`cmm\` 16 个脚本
  + 注册表、`configs\` 5 个（其中 2 个早期样本后来删掉了，见第九轮）+ `gui\config_sim.t32`、`tests\` 2 个、`tools\` 3 个、`local\paths.psd1.example`）
  的英文注释全改成中文，**代码与输出文本一个字节没动**——`.ps1`/`.psd1` 存成 UTF-8 with BOM，
  `.py`/`.cmm`/`.t32`/`.tmpl`/`.json` 保持 UTF-8 无 BOM（理由见铁律 7）。
  验收不是靠眼睛看，而是三条机械闸门：
  ① PowerShell 用 `[Parser]::ParseInput` 比 **HEAD vs 当前的非注释 token 序列**（注释是 `Comment` token，剔除后必须逐 token 相同，
  这样连「输出字符串被顺手改了」也能抓到）；② `.cmm`/`.t32`/`.tmpl` 剔除 `;` 注释行后与 `HEAD` 逐行比对（含空行，
  等于同时守住铁律 1 的空行分组）；③ `cmm\functions.json` 用 `json.load` 比结构（只允许 `desc`/`note`/`unsafe_reason`
  这类人读文本变，键名、`cmd`/`body`/`safe`/`allow_prefix` 必须逐字相同）。
  三条全绿 + `tests\run_all.ps1` 全量回归通过才算完。
- **`configs\` 整理（第九轮）**：给留下的 3 个启动配置各加了一段中文注释头（`;` 注释行 + 一个空行，
  再接原来那几组 `KEY=VALUE`，**原有字节一个没动**）；删掉两个只被文档引用的早期样本
  `g1_full.t32`（`RCL=NETASSIST` 20000）与 `g4_port20001.t32`（`NETASSIST` 20001）——同类形态在
  `attic\configs\` 的对照配置与 git 历史里仍可查，并行实例的做法改写成"复制一份、改 `PORT=`"。
  本轮同时把三个配置按用途改名：`sim-minimal.t32` / `sim-batch.t32` / `sim-rcl-tcp-20000.t32`
  （`sim-` 前缀标明后端是模拟器 `PBI=SIM`；旧名 `m1_min` / `g5_screenoff` / `g3_nettcp` 不再使用）。
  顺带实测确认：**TRACE32 的 `.t32` 配置能吃 UTF-8 中文注释**。加注释头后 `tests\run_all.ps1` 全绿
  （冒烟走 `sim-rcl-tcp-20000`、2211 走 `sim-batch`）；另外用 `gui\config_sim.t32`（注释夹在各组之内）单独起了
  一次带界面的实例，`-s` 脚本正常执行、进程自己退出 0（探针日志 `CN-T32-CONFIG-OK`）⇒ 上一轮把该文件
  的注释翻成中文没有破坏客户那条 GUI 启动路径。
- **顶层目录收敛（第十轮）**：按「一个目录一件事」把五处含糊命名收拢，**内容一律不动**（只搬位置、改名、改引用）：
  ① `gui\config_sim.t32` → **`configs\sim-gui.t32`**（客户 GUI 原件归到配置目录，`gui\` 目录取消 ⇒ 顶层少一个目录）；
  ② `fixtures\` → **`ramdump\`**（`fixtures` 是测试圈行话，现场就叫 dump；`.gitignore` 第 7 块同步换成 `**/ramdump/`）；
  ③ `cmm\` 里 13 个**无代码引用**的早期探针（`s1`–`s5` 符号查询试探、`sym`/`sym2`、`probe1`–`probe4`、`mini`、
     `gui_test`）→ **`attic\cmm\`**；`cmm\` 只剩 4 个被引用的成品（`restore.cmm`、`heap_summary.cmm`、
     `thread_pick.cmm`、`functions.json`）⇒ 每个名字都自解释；
  ④ 顶层 `src_2210\` → **`cmm\src_2210\`**（用户决定：待改造的客户副本就近放在内核目录里；`.gitignore` 用的是
     反锚定规则 `**/src_2210/`，换了位置照样命中、照样不入库）；
  ⑤ `private\`（客户报告原件 14 节 HTML + 敏感信息排查记录）**删除**；其中唯一被本文引用的内容（RCL 可用调用与
     错误原文）提炼成 **`docs\rcl-api-notes.md`** 入库；平台↔产品名对照随之不再保留（需要时从 `third_party\vendor\`
     各目录的 `.cmm` 版权头与 `.svn\wc.db` 里查）。删除前把两份原件复制到本仓之外的临时目录留作最后一手。
  配套改动：`tests\fixtures.sha256` → `tests\ramdump.sha256`、`tests\verify_fixtures.ps1` → `tests\verify_ramdump.ps1`
  （输出标记改 `RAMDUMP-OK`/`RAMDUMP-FAILED`）、`tests\run_all.ps1`、`.gitignore` 第 5/6/7/9 块与文件头注释、
  `tools\make_shortcuts.ps1`、`cli\run_2211_ap.ps1`、`cli\run_2211_func.ps1`、
  `cli\2211_ap_analyze.cmm.tmpl`、`configs\sim-gui.t32`（加了注释头交代来历，原有字节没动）。
  验收：搬迁前后 **610 个文件**（含不入库件）的 relpath→SHA256 快照逐条对得上（零丢失）；
  `git check-ignore -v --no-index` 逐条实测 `ramdump/`、`cmm/src_2210/`、`private/` 仍被忽略、该入库的仍可跟踪；
  最后跑 `tests\run_all.ps1` 全量回归。
- **第十一轮（三处边界收口 + 一个活 bug）**：用户复盘 `docs\history\`、`local\`、`tests\expected\` 三处后定下：
- ① `docs\history\` → **`attic\logs\`**：运行日志属历史证据，与 `attic\` 里的失败配置同类，`docs\` 只留文档。
  因 `attic\` 不在 `logs\` 的白名单里，`.gitignore` 第 3 块补 `!**/attic/logs/*.log` 与 `!**/attic/logs/*.txt`。
- ② **删掉 `tests\expected\`**（2.8 MB，与 `ramdump\2211_deathscene\ap_PrintData.txt` 逐字节相同：
  SHA256 都是 `04c86256…b3df`）。它当初的动机是「夹具既是输入又是输出、会被覆盖」，而改成 headless 后这个前提已不成立；
  且**没有任何代码把它当期望值**——现在的判据是 marker 闸门（5/12/3 条）+ 堆遍历自检 + 双入口等价。
  `tests\ramdump.sha256` 由 10 条减到 9 条。将来做内容级断言时，基线要用**本仓库自己产出的报告**（`out\runs\`），不是客户手点的 txt。
- ③ **修一个活 bug**：`cli\run_2211_func.ps1` 的展开函数用 `[Encoding]::GetEncoding(28591)`（Latin-1）写盘，
  而源（`configs\sim-batch.t32`、`cmm\functions.json`）是 UTF-8 且含中文注释 ⇒ 每个非 Latin-1 字符被写成 `?`
  （实测 `local\func_*.cmm` 308–372 个、`local\sim-batch.t32` 93 个）。命令都是 ASCII，所以回归照绿、**静默**；
  但注释全毁，且将来若有中文 `PRINT` 文本会被吃掉。改为 `Write-Utf8`（`UTF8Encoding($false)`，无 BOM）写回，重跑 `-Func all` 复核 `?` 归零。
- ④ 清掉 `local\` 里 6 类一次性残留：`commit_msg_*.txt` ×4、`migration_snapshot\`、`snap_pre\`/`snap_post\`、
  `g5_screenoff.t32`（改名前）、`gui_probe.t32`/`gui_probe.cmm`/`probe_cn.cmm`（临时探针）。
  留在 `local\` 的只有：`paths.psd1`(+`.example`)、`check_cn_comments.ps1`、`check_py_ast.py` 与运行时生成的 `smoke.t32`/`run_restore.cmm`/`analyze.t32`/`run_2211_ap.cmm`/`sim-batch.t32`/`func_*.cmm`。
- ⑤ **顺带查掉等价检查器的一个隐患**：`tools\check_entries_equiv.py` 的归一化只丢 `#` 开头的行，
  而 banner 里那行功能描述是长中文 —— 编码修好后行变长，TRACE32 的打印 AREA 会把它**折行**，
  折出来的续行不以 `#` 开头，于是泄漏进比对，4 个功能被误判 `FAIL`（此前描述退化成 `?`、行短、不折行，
  所以这个隐患一直没暴露）。改为「两行 `#####` 围栏之间的 banner **整块丢弃**」（围栏只在 64 行内配对，
  防止残缺报告吃掉正文）；另外把 stdout/stderr 放宽成 `errors="replace"`，
  免得报告里出现 GBK 编不出的字节时 `print` 直接抛 `UnicodeEncodeError` 而不是给判定结果。
  修完：`EQUIV-OK`（pass=10 partial=1 fail=0 missing=0），`tests\run_all.ps1` 五段全绿 `TESTS-OK`。

---

## 9. 许可

本仓库以 **Apache License 2.0** 发布：全文见 [LICENSE](LICENSE)，版权与归属声明见 [NOTICE](NOTICE)。

许可证只覆盖**本仓库内的内容**（脚手架、脚本、实测结论与文档）。
`third_party\vendor\`（客户 TRACE32 脚本）、`ramdump\`（死机现场数据）与 `third_party\trace32_rcl\`（Lauterbach RCL SDK）
**都不在本仓库内**，各自的权利归属不变——见 §1 与 `.gitignore`。
