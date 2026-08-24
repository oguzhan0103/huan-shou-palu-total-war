# 《幻兽帕鲁全面战争》安装到游戏说明

如果不确定 Release 中每个附件的用途，请先阅读
[v1.0.5 中文下载与卸载说明](./请先看_幻兽帕鲁全面战争_v1.0.5_下载与卸载说明.md)。

适用版本：`v1.0.5`

兼容目标：Windows Steam 版 Palworld Build `24575825`

验证范围：单人游戏；多人和专用服务器尚未完成验收

## 先看清发布边界

GitHub Release 是 **source-only 开源机制基座**，不是含有全部游戏资产的一键安装
成品。公开附件不包含 Pocketpair 游戏资产、Cooked PAK、UAsset、玩家存档、日志、
UE4SS 本体或本机部署文件。

Release 中的 `runtime-source.zip` 已整理成可复制到 UE4SS 的目录结构，但只包含
第一方 Lua、操作台和作者 SDK。以下三个本地验收使用的 Cooked PAK 不随 GitHub
分发：

```text
Pal/Content/Paks/LogicMods/PalFactionTerritory0.pak
Pal/Content/Paks/~mods/PalFactionTerritory_FactionEconomyShops_P.pak
Pal/Content/Paks/~mods/PalFactionTerritory_RayneMerchant_P.pak
```

没有这些由内容作者依法自行制作的资产包时，地图覆盖层、Cooked 势力面板、自定义
商品表和雷恩 288 图鉴目录等功能不会完整出现。不要把仅安装 Lua 层描述成完整玩家
版。

## 一、安装前准备

1. 使用 Windows Steam 版 Palworld，并确认当前游戏 Build 与 `24575825` 相符。
2. 备份自己的世界存档；建议先在测试世界验证，不要直接进入唯一主存档。
3. 安装与当前 Palworld Build 匹配的 Palworld 专用 UE4SS。项目不在 Release 中
   重新分发 UE4SS。
4. 确认游戏目录中已经存在：

```text
Palworld/Pal/Binaries/Win64/dwmapi.dll
Palworld/Pal/Binaries/Win64/ue4ss/
Palworld/Pal/Binaries/Win64/ue4ss/Mods/
```

5. 安装或更新 Mod 时先完全关闭 Palworld、Steam 游戏进程和 Unreal Editor。

## 二、安装 Core 运行时源码

1. 从 GitHub Release 下载：

```text
PalFactionTerritory0-v1.0.5-build24575825-runtime-source.zip
```

2. 校验同页提供的 SHA-256。
3. 解压 ZIP。把压缩包根目录下的内容复制到：

```text
Palworld/Pal/Binaries/Win64/ue4ss/
```

4. 完成后至少应存在：

```text
Palworld/Pal/Binaries/Win64/ue4ss/Mods/PalFactionTerritory0/enabled.txt
Palworld/Pal/Binaries/Win64/ue4ss/Mods/PalFactionTerritory0/Scripts/main.lua
Palworld/Pal/Binaries/Win64/ue4ss/Mods/PalFactionTerritory0/Scripts/pwft/runtime.lua
```

5. 不要启用或复制 `PalFactionTerritoryQAHarness0`。正式包不需要 QA Harness。
6. 通过 Steam 启动游戏，不要直接运行 Shipping EXE。首次加载后检查
   `Pal/Binaries/Win64/ue4ss/UE4SS.log`，应能看到：

```text
[PalFactionTerritory0] READY
FACTION_PROGRESSION_READY
CONTENT_RUNTIME_READY
```

如果游戏 Build 不一致、UE4SS Hook 缺失或日志持续报错，应退出游戏并移除本 Mod，
等待兼容更新。

## 三、安装完整地图、UI 与商店内容

GitHub 当前不提供上述三个 Cooked PAK。内容作者必须使用合法取得的 Palworld
Modding Kit／UE 工程和自己有权分发的资产生成对应 PAK，再分别放入：

```text
Palworld/Pal/Content/Paks/LogicMods/
Palworld/Pal/Content/Paks/~mods/
```

完整目录应为：

```text
Pal/Content/Paks/LogicMods/PalFactionTerritory0.pak
Pal/Content/Paks/~mods/PalFactionTerritory_FactionEconomyShops_P.pak
Pal/Content/Paks/~mods/PalFactionTerritory_RayneMerchant_P.pak
```

不要从不明来源下载同名 PAK，也不要覆盖 `Pal-Windows.pak` 或其他原版 PAK。

## 四、可选：多帕鲁扩展

下载 `PalworldTotalWar-v1.0.4-OfficialAddons-source.zip`，在压缩包中找到
`PalMultiOtomo0`，复制到：

```text
Palworld/Pal/Binaries/Win64/ue4ss/Mods/PalMultiOtomo0/
```

完成后应存在 `PalMultiOtomo0/enabled.txt`。当前 Build `24575825` 的重新实机确认
仍待完成，因此该扩展应视为可选功能。

## 五、可选：本地 Ollama NPC 对话

1. 安装 Rust 工具链和 Ollama。
2. 下载 AI 源码包，进入 `PalAgentDialogue` 目录执行：

```powershell
cargo build --release
```

3. 设置 `PAL_AGENT_EXECUTABLE` 指向自行构建的 sidecar；需要时设置
   `PAL_AGENT_CHARACTER_PACK` 和 `PAL_AGENT_MODEL`。
4. 执行 Core 包中的：

```text
Companion/start-companion.cmd
```

5. 操作台只监听本机回环地址。模型输出只能显示对话和白名单建议，任何确定性选择
   仍须玩家确认。

## 六、更新与卸载

更新前关闭游戏，然后用新版本完整替换：

```text
ue4ss/Mods/PalFactionTerritory0/
```

推荐从 v1.0.5 Release 下载：

```text
PalworldTotalWar-v1.0.5-Quick-Uninstall.zip
```

解压后双击 `快速卸载_幻兽帕鲁全面战争.cmd`。工具会自动定位游戏目录、列出精确
删除目标，并等待玩家输入大写 `UNINSTALL`；执行前会把 Mod 自有 `State` 备份到
`文档/PalFactionTerritory-UninstallBackups/`。默认只删除：

```text
ue4ss/Mods/PalFactionTerritory0/
ue4ss/Mods/PalFactionTerritoryQAHarness0/
Pal/Content/Paks/LogicMods/PalFactionTerritory0.pak
Pal/Content/Paks/~mods/PalFactionTerritory_FactionEconomyShops_P.pak
Pal/Content/Paks/~mods/PalFactionTerritory_RayneMerchant_P.pak
```

工具不会删除 Palworld 存档、Steam 云存档、UE4SS、`dwmapi.dll`、其他 Mod、原版
PAK 或可选 `PalMultiOtomo0`。需要手工卸载时也只能删除上述本项目目标；不要删除
或改写 Palworld 原版 PAK。

## 七、下载者应选择哪个附件

| 附件 | 适用对象 | 能否直接得到完整游戏效果 |
|---|---|---|
| `Core-source.zip` | 开发者、内容作者 | 否；是完整机制源码 |
| `runtime-source.zip` | 已安装 UE4SS 的测试者 | 只能安装 Lua 层；仍缺 Cooked PAK |
| `Quick-Uninstall.zip` | 已安装本项目、需要快速移除的玩家 | 只卸载本项目并备份 Mod State |
| `OfficialAddons-source.zip` | 多帕鲁扩展测试者 | 可复制 UE4SS Mod，但当前 Build 复验待完成 |
| `AIExperimental-source.zip` | 本地模型开发者 | 需自行编译 Rust sidecar |

项目主页：<https://github.com/oguzhan0103/huan-shou-palu-total-war>
