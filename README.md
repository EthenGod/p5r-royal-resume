# P5R 皇家版续档

用自己的存档接上皇家版第三学期。可以从 12 月 24 日的档跳过无印最终战，也可以给较早的档补开皇家线。

## 一条命令

退出游戏，在 **Windows PowerShell 5.1** 或 **PowerShell 7** 粘贴这行。每次运行都会从 GitHub 的 `main` 分支下载最新脚本。

```powershell
& ([ScriptBlock]::Create((Invoke-RestMethod -UseBasicParsing ('https://api.github.com/repos/EthenGod/p5r-royal-resume/contents/p5r-royal-resume.ps1?ref=main&run=' + [guid]::NewGuid().ToString('N')) -Headers @{ Accept = 'application/vnd.github.raw+json' } -ErrorAction Stop).TrimStart([char]0xFEFF)))
```

输入源档左侧方括号里的编号，例如 `[15]` 就输入 `15`。先看「将执行的操作」，再输入目标槽编号。输入 `y` 应用，完成后进游戏读取目标槽。[查看本命令使用的脚本](https://github.com/EthenGod/p5r-royal-resume/blob/main/p5r-royal-resume.ps1)

目标表列出 1–16 号槽的存档内容和空槽。有可写入的空槽时，回车会选第一个。只读的存档仍可作源档，选目标槽时会跳过。

## 哪些源档能用

- **12/24 无印最终战区域**。印象空间最底层或通往无印最终 Boss 的区域。工具会把进度接到战后的涩谷站前广场，保留源档的队伍、等级、装备、人格面具和其他 Coop。
- **12/24 涩谷战后档**。从相同的保存点继续，补齐皇家线条件。
- **11/17 已开启丸喜 Coop 的普通存档**。丸喜升到 Coop 9，11/18 正常触发满级剧情。
- **11/18 到 12/23 的可用存档**。直接补开皇家线，从原日期和地点继续，后续战斗照常进行。

通关存档用于开启二周目。要续接原周目，请找更早的手动档。看到「可以直接读取」的提示时，在游戏里加载原档即可。

## 找不到存档时

工具写入 **Windows Steam 版**的编号槽，默认在 `%APPDATA%\SEGA\P5R\Steam` 查找。游戏可装在任意磁盘。首次启动后，先在游戏里手动存一次档，游戏就会建立存档目录。

- 自动查找失败时，输入 `savedata`、它的上级目录，或某个编号槽里的 `DATA.DAT`。选源档时按 `P` 也可以换目录。
- 选源档时按 `F`，可读取单独备份的存档文件，包括保留 PC 存档封装的解密副本。
- 在未安装游戏的电脑处理备份时，可以先建一个名为 `savedata` 的空文件夹作为目标，再用 `F` 选源档。
- 在一行命令末尾加上 `-SaveDirectory 'D:\P5R备份\savedata'`，可直接指定存档目录。请把示例路径换成你的目录。

## 备份与恢复

目标槽已有存档时，工具会备份该槽并输出备份位置。备份位于存档目录同级的 `p5r-royal-resume-backups` 文件夹。写入前会重新核对源档和目标槽。检测到变化时，工具会提示重新运行。

要恢复，先退出游戏。例如要恢复 1 号槽，找到以 `-DATA01.DAT` 结尾的对应备份，将副本命名为 `DATA.DAT`，用它替换 `savedata\DATA01\DATA.DAT`。

## 参考

- Steam 存档封装与校验格式。[fiber-saveutil](https://github.com/zarroboogs/fiber-saveutil)
- PC 存档字段资料。[Change of Heart 存档格式](https://github.com/j0nnyDiGITAL/change-of-heart/blob/main/docs/FORMAT.md)
- 用于确认剧情节点的公开样本。[战后节点](https://gamebanana.com/mods/657059) ／ [同一周目的战前与 1 月存档](https://gamebanana.com/mods/409383)
