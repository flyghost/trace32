# tests\baseline —— 改造前的"我方快照"（设计文档 §11.3 的 oracle B）

**为什么有这个目录**：改造引擎（`cmm\src_2210\`）之前，必须先把"改造前**我们自己**的输出"冻结下来。
没有它，"我没有改坏"就只是一句记忆；有了它，才能做逐字节 / 规范化 diff。

**三份清单各管一件事**：

| 清单 | 冻结的是 | 回答的问题 |
| --- | --- | --- |
| `tests\ramdump.sha256` | 客户给的死机现场 9 件（只读输入） | 输入有没有被改坏？ |
| `tests\vendor.sha256` | 客户脚本原件 68 件（只读参考） | 客户原件有没有被改坏？ |
| `tests\baseline\`（本目录） | **我们自己**的输出 17 个条目（S2 之后重建） | 我们的输出有没有变？ |

## 快照内容（2026-10 第十四轮 S2 之后重建，14 个全文 + 3 个 sha256 摘要）

| 目录 | 内容 | 来源运行 |
| --- | --- | --- |
| `2211_ap\` | `2211_ap_deathscene.txt.sha256`（2121 行，摘要）、`heap_offline.txt`、`run.txt` | `out\runs\2211_ap\20261009-193919` |
| `2211_ap_func\` | 12 个单功能报告 + `heap_offline.txt` + `run.txt`；其中 `all_thread_bt.txt.sha256`（530 行）与 `mem_trace.txt.sha256`（1313 行）是摘要 | `out\runs\2211_ap_func\20261009-193926` |

**这次为什么重建**（"预期差异"必须写明理由，否则基线会慢慢失去意义）：
① S2 给三处堆遍历加了边界 ⇒ 报告里多出/少掉 `### ...` 诊断行，且 `mem_trace`、`mem_summary` 从
"跑不完"变成有真实表格（新增 `mem_summary.txt`）；② 分析入口由 9 段扩到 11 段 ⇒ 报告更长；
③ `run.txt` 多出 `engine : cmm\src_2210 ...` 与 `frozen : third_party\vendor\2210_trace32 ...` 两行；
④ 三个 runner 读 marker 文件改用 UTF-8（原先 `H00START` 被静默漏掉）；
⑤ **报告头部会把注册表 `cmm\functions.json` 的 `desc` 原样打出来** —— 所以改 `desc` / `note` 的文案
也会让 `mem_trace` / `mem_summary` 的基线失效（2026-10-09 实测：差异只落在报告第 4 行）。这类
"文案进了产物"的差异同样是**预期差异**，处理方式一样：`-Update` 重建 + 把理由写在这里。

**`-Update` 写出的是规范化之后的正文**（LF、仓库路径→`__REPO__`、时间戳→`__STAMP__`、`sec=`→`__SEC__ `）。
所以重建后，原先"手工净化过、但没有规范化"的快照会显示为 Modified —— 那是**规范化**，不是内容变化。

## ★ 大文件只存 sha256 摘要（公开仓库边界）

规范化后超过 **20000 字符**的快照只入库一行：

```
<sha256>  <文件名>  <行数> lines
```

文件名是 `<NAME>.txt.sha256`，比较时用同一套规范化算 sha256，字节相同性照样可判。
理由：报告来自客户的死机现场，含客户内部符号名 / 源文件名 / 堆内容，而本仓库是**公开**的；
小文件保留全文，因为人眼 diff 才是它存在的意义。要强制存全文（本地做深度 diff）加 `-KeepText`。

**重建基线只能用它自己**：`tests\compare_baseline.ps1 -Update`（规范化只有一处实现，别处不要手写替换表）。
重建后**必须把理由写进本节**。

## 环境指纹（对比"改坏"必须同环境）

- **TRACE32**：`t32mriscv.exe` ProductVersion `R.2026.02.000190766`（`t32mceva.exe` 是 `R.2025.09.000186888`）
- **ELF**：`ramdump\2211_deathscene\cpu-ap.elf` sha256
  `76970747f8f69c839d5edb003edddf4892386ccf9ccccc9033b93a29e33662f6`（25439692 B，与 `tests\ramdump.sha256` 首行一致）
- **输入夹具**：`ramdump\2211_deathscene\` 9 件，见 `tests\ramdump.sha256`
- **客户原件**：`third_party\vendor\` 68 件，见 `tests\vendor.sha256`
- **引擎**：`cmm\src_2210\`（客户 2210 原件的工程内工作副本；`run.txt` 的 `engine` 行）

## 怎么用（改造之后）

1. 跑一次全量与 `-Func all`（`tests\run_all.ps1` 的第 5、6 段）。
2. 跑 `tests\compare_baseline.ps1`（第 7 段）与基线逐文件比：**字节相同**最好；
   只多出 `### ...` 诊断行算"规范化相同"（要记下来）；其余差异必须能解释 —— 解释不了的就算改坏。
3. 若确认差异是**预期的改进**（例如堆遍历的 stop 原因变了），**先 `-Update` 重建并在上面写明理由**再继续重构；
   否则基线会慢慢失去意义。

## 刻意不放进来的东西

- `out\logs\*.log`（marker 进度通道）：它们随运行时间戳变化，价值在"跑完没跑完"；
  marker 的**期望值**另有契约（`tests\smoke\*.markers`，共 5 + 15 + 3 条）。
- `heap_by_file.txt`：派生大表，可由 `-Func heap` 或 `tools\heap_stats_offline.py` 随时重现。
