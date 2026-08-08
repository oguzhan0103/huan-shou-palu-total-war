# PalMultiOtomo0

一个与 `PalFactionTerritory0` 完全独立的 UE4SS Lua 原型，用于验证：

- 原版主帕鲁继续由玩家正常操控；
- 额外召唤一只队伍帕鲁作为纯 AI 战斗随从；
- 再次按键只收回这只辅助帕鲁；
- 不写存档，不修改游戏 PAK，不使用每帧轮询。

## 当前原型操作

1. 先按原版方式放出一只主帕鲁。
2. 每按一次 `F6`：再召唤一只辅助帕鲁，最多增加 4 只。
3. 按 `F7`：逐只收回全部辅助帕鲁，保留原版主帕鲁。

如果第 2 格是当前主帕鲁、空位、死亡或不可用，原型会在其他队伍格中寻找第一个可用对象。当前版本支持把队伍其余 4 只全部放出；多人同步、骑乘切换、伙伴技能和自动补位暂不纳入本轮。

## 安全边界

- 独立目录：`ue4ss\Mods\PalMultiOtomo0`
- 只响应 `F6`/`F7`，没有 Tick/高频 Hook。
- 召唤使用官方 `BP_OtomoPalHolderComponent_C:ActivatePalByHandle`。
- 收回使用官方 `BP_OtomoPalHolderComponent_C:Inactivate Otomo By Handle`。
- 不会以 `InactivateAllOtomo` 作为失败兜底，避免误收回主帕鲁。
- 不修改角色、队伍或世界存档。

## 校验与安装

```powershell
.\scripts\verify.ps1
.\scripts\install-dev.ps1
.\scripts\check-deployment.ps1
```

安装脚本要求游戏已关闭。部署后必须从 Steam 启动游戏，再进行 F6 实机测试。

## 日志

日志位于：

`E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\UE4SS.log`

筛选关键字：

`[PalMultiOtomo0]`
