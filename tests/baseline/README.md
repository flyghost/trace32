# tests\baseline —— 改造前的"我方快照"（设计文档 §11.3 的 oracle B）

**为什么有这个目录**：改造引擎（`cmm\src_2210\` → `platforms\2210\`）之前，必须先把"改造前**我们自己**的输出"
冻结下来。没有它，"我没有改坏"就只是一句记忆；有了它，才能做逐字节 / 规范化 diff。

**三份清单各管一件事**：

| 清单 | 冻结的是 | 回答的问题 |
| --- | --- | --- |
| `tests\ramdump.sha256` | 客户给的死机现场 9 件（只读输入） | 输入有没有被改坏？ |
| `tests\vendor.sha256` | 客户脚本原件 68 件（只读参考） | 客户原件有没有被改坏？ |
| `tests\baseline\`（本目录） | **我们自己**改造前的输出 15 个文件 | 我们的输出有没有变？ |

## 快照内容（2026-10 第十四轮抓取，未改造的引擎）

| 目录 | 文件 | 来源运行 |
| --- | --- | --- |
| `2211_ap\` | `2211_ap_deathscene.txt`（24721 B，全量 9 段报告）、`heap_offline.txt`（1962 B）、`run.txt`（1217 B） | `out\runs\2211_ap\20261008-172244` |
| `2211_ap_func\` | 11 个单功能报告 + `heap_offline.txt` + `run.txt`（共 12 件，34502 B） | `out\runs\2211_ap_func\20261008-172250` |

## 环境指纹（对比"改坏"必须同环境）

- **TRACE32**：`t32mriscv.exe` ProductVersion `R.2026.02.000190766`（`t32mceva.exe` 是 `R.2025.09.000186888`）
- **ELF**：`ramdump\2211_deathscene\cpu-ap.elf` sha256
  `76970747f8f69c839d5edb003edddf4892386ccf9ccccc9033b93a29e33662f6`（25439692 B，与 `tests\ramdump.sha256` 首行一致）
- **输入夹具**：`ramdump\2211_deathscene\` 9 件，见 `tests\ramdump.sha256`
- **客户原件**：`third_party\vendor\` 68 件，见 `tests\vendor.sha256`

## 怎么用（改造之后）

1. 跑一次全量与 `-Func all`（`tests\run_all.ps1` 的第 5、6 段）。
2. 与 `tests\baseline\` **逐文件**比：**字节相同**最好；只多出 `### ...` 诊断行算"规范化相同"（要记下来）；
   其余差异必须能解释 —— 解释不了的就算改坏。
3. 若确认差异是**预期的改进**（例如堆遍历加了边界后 stop 原因变了），**先更新本目录并写明理由**再继续重构；
   否则基线会慢慢失去意义。

## 刻意不放进来的东西

- `out\logs\*.log`（marker 进度通道）：它们随运行时间戳变化，价值在"跑完没跑完"；
  marker 的**期望值**另有契约（`tests\smoke\*.markers`），不在这里。
- `heap_by_file.txt`：改造前那次运行的堆遍历第一步就停了（`HEAPWALK-AP steps=1 printed=0`），
  基线里也就不该有这个文件 —— 加上边界之后它才会出现，那正是 S2 要验收的差异。
