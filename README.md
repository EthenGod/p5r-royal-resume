# P5R 皇家版续档

用自己的存档跳过无印最终战，从 12 月 24 日晚的涩谷站前广场继续。续档保留源存档的队伍、等级、装备、人格面具和其他 Coop 进度，补齐丸喜 Coop 10 和第三学期路线条件。

## 一条命令

退出游戏，在 **Windows PowerShell 5.1** 或 **PowerShell 7** 粘贴这行。

```powershell
& ([ScriptBlock]::Create((Invoke-RestMethod -UseBasicParsing 'https://raw.githubusercontent.com/EthenGod/p5r-royal-resume/ba222209c8f5de28ff097dfe4056c635e6022aac/p5r-royal-resume.ps1')))
```

选源槽和目标槽，输入 `y`。完成后打开游戏，读取目标槽。命令固定下载这一版的脚本。[查看脚本](https://github.com/EthenGod/p5r-royal-resume/blob/ba222209c8f5de28ff097dfe4056c635e6022aac/p5r-royal-resume.ps1)

## 适用存档

- Windows Steam 版《女神异闻录 5 皇家版》。
- 需要 12 月 24 日「印象空间最底层」安全屋或最终 Boss 门前的手动存档。
- 续档保留源存档的战前等级和物品，剧情从战后接上。

工具自动查找 Steam 存档。存档目录迁移过的话，可以下载脚本，用 `-SaveDirectory` 指定装有 `DATA01` 等槽位文件夹的路径。

## 备份与恢复

目标槽已有存档时，工具会备份该槽并输出备份位置。备份位于 `savedata` 同级的 `p5r-royal-resume-backups` 文件夹。

要恢复，先退出游戏。将对应备份复制到原槽位文件夹，用它替换 `DATA.DAT`。

## 参考

- Steam 存档封装与校验格式。[fiber-saveutil](https://github.com/zarroboogs/fiber-saveutil)
- PC 存档字段资料。[Change of Heart 存档格式](https://github.com/j0nnyDiGITAL/change-of-heart/blob/main/docs/FORMAT.md)
- 用于确认剧情节点的公开样本。[战后节点](https://gamebanana.com/mods/657059) ／ [同一周目的战前与 1 月存档](https://gamebanana.com/mods/409383)
