# 《幻兽帕鲁全面战争》v1.0.6 联机测试预览安装、更新与卸载

兼容目标：Windows Steam 版 Palworld Build `24575825`
发布形式：source-only 开源机制基座／多人联机预览
联机测试总说明：[请先看 v1.0.6 多人联机测试任务书](./请先看_幻兽帕鲁全面战争_v1.0.6_多人联机测试任务书.md)
稳定版说明：[v1.0.5 下载与卸载说明](./请先看_幻兽帕鲁全面战争_v1.0.5_下载与卸载说明.md)

## 一、发布边界

公开运行包包含第一方 UE4SS Lua、外接操作台、作者 SDK 和快速卸载工具，不包含：

- UE4SS 本体；
- Pocketpair 游戏资产或原版 PAK；
- 本地验收使用的 Cooked UAsset/PAK；
- 玩家存档、Mod State、日志或本机部署证据。

因此公开包可以安装机制源码，但缺少以下内容作者自行构建的三个 PAK 时，地图覆盖层、
Cooked 势力面板、自定义经济商品和雷恩全图鉴商店不会完整出现：

```text
Pal/Content/Paks/LogicMods/PalFactionTerritory0.pak
Pal/Content/Paks/~mods/PalFactionTerritory_FactionEconomyShops_P.pak
Pal/Content/Paks/~mods/PalFactionTerritory_RayneMerchant_P.pak
```

## 二、安装前准备

1. 完全退出 Palworld 和 Unreal Editor。
2. 确认当前 Steam Build 为 `24575825`。
3. 备份重要世界存档，优先在测试世界验证。
4. 自行安装与当前 Palworld 匹配的专用 UE4SS；Release 不重新分发 UE4SS。
5. 确认游戏目录存在：

```text
Palworld/Pal/Binaries/Win64/dwmapi.dll
Palworld/Pal/Binaries/Win64/ue4ss/Mods/
```

## 三、安装 v1.0.6 联机测试运行时

1. 下载：

```text
PalFactionTerritory0-v1.0.6-build24575825-runtime-source.zip
```

2. 使用同页 `.sha256.json` 校验压缩包。
3. 解压后，把压缩包根目录下的内容复制到：

```text
Palworld/Pal/Binaries/Win64/ue4ss/
```

4. 安装后至少应存在：

```text
ue4ss/Mods/PalFactionTerritory0/enabled.txt
ue4ss/Mods/PalFactionTerritory0/Scripts/main.lua
ue4ss/Mods/PalFactionTerritory0/Scripts/pwft/runtime.lua
ue4ss/快速卸载_幻兽帕鲁全面战争.cmd
```

5. 通过 Steam 启动游戏。日志中应能看到：

```text
[PalFactionTerritory0] READY
FACTION_PROGRESSION_READY
CONTENT_RUNTIME_READY
MULTIPLAYER_AUTHORITY_READY
```

不要安装或启用 `PalFactionTerritoryQAHarness0`。正式包中的 B1/B2/A9/B7 QA 热键和
外部命令文件入口默认关闭。

联机测试时，两台电脑必须使用同一个预发布标签或完整提交号。测试结束后双击
`CommunityTestTools/收集联机测试证据.cmd`，按任务书提交两边的脱敏证据包。

## 四、更新

1. 退出游戏。
2. 备份以下目录中的 `State`（可选）：

```text
ue4ss/Mods/PalFactionTerritory0/State/
```

3. 用新版完整替换 `ue4ss/Mods/PalFactionTerritory0/`，不要只覆盖个别 Lua。
4. 将新版快速卸载工具一并复制到 UE4SS 根目录。

## 五、快速卸载

普通玩家双击：

```text
ue4ss/快速卸载_幻兽帕鲁全面战争.cmd
```

工具先预览精确目标；只有输入大写 `UNINSTALL` 后才执行。默认删除：

- `ue4ss/Mods/PalFactionTerritory0/`；
- 误装的 `ue4ss/Mods/PalFactionTerritoryQAHarness0/`；
- 上述三个项目专属 PAK（存在才删除）。

如检测到 Mod 自有 `State`，会先备份到：

```text
文档/PalFactionTerritory-UninstallBackups/日期-时间/
```

工具明确保留：Palworld SaveGames、Steam 云存档、UE4SS、`dwmapi.dll`、其他 Mod、
原版 PAK、可选扩展 `PalMultiOtomo0` 和卸载备份。详细参数见
[`player-tools/卸载说明.md`](./player-tools/卸载说明.md)。

如果只想单独下载卸载工具，使用 Release 附件：

```text
PalworldTotalWar-v1.0.5-Quick-Uninstall.zip
```

## 六、开发者与内容作者

- `AuthorSDK/minimal-content-pack/`：无剧情内容包示例；
- `AuthorSDK/contracts/`：版本化机器合同；
- `AuthorSDK/validate-content-pack.ps1`：内容包校验入口；
- `Companion/start-companion.cmd`：可选本地操作台；
- Core 不替内容作者编写剧情、任务正文、领主姓名或最终奖励表。

开发者验证：

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verify-mod0.ps1
powershell -ExecutionPolicy Bypass -File .\tools\test_quick_uninstall.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\build-mod0-package.ps1
```

快速卸载测试只在自动创建的临时假游戏目录执行，不会卸载开发机上的真实 Mod。
