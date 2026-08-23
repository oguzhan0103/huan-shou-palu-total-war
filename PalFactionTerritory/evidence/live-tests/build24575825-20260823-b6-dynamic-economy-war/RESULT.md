# B6 动态经济与经济战争实机证据

日期：2026-08-23

Build：Steam 24575825 / v1.0.3.101283

结论：`PASS`

本证据关闭 `docs/50` 的 B6：真实资源事件会刷新已驻场的七个商会柜台；雷恩金属矿供应从 150 降到 50 时，金属锭售价／库存变为 `280 / 25`；降到 49 后转为采购，采购价／额度为 `290 / 62`，原生出售行置为售罄。短缺状态依次进入 `trade_requested → threat → war`。

完整退出并重启游戏后，同一 `oguzhan` profile 读回资源量 49、战争状态和账本 revision 2。补给恢复到 150 后，已驻场同一商人原生行回到 `240 / 66`，冲突依次变为 `ceasefire → stable`，最终步骤为 `complete`。测试过程没有生成第二套固定商会，也没有写入 Palworld 原生存档或货币。

第一次尝试在当前 Build 发现 `ProductArray` 是 UE4SS `TArray` 而不是 Lua table，动态更新失败关闭并保留静态商店。本轮修复改为优先使用 `GetArrayNum()` 和一基索引，第二次完整重跑通过。此失败没有被从历史中删除。

公开材料：

- `verification.json`：结构化验收、恢复与证据边界；
- `b6-economy-war-excerpt.log`：去本机路径的两进程关键时序；
- `tools/verify_b6_dynamic_economy_live_evidence.py`：自动证据校验器。

完整 UE4SS 日志、State、SaveGames 预检快照和可恢复隔离目录保留在私有测试输出，不进入仓库。Steam 云开关已恢复开启，但 Steam 当时仍显示“云过期”；没有选择任何云端／本地覆盖操作，权威本地快照保持逐文件零差异。
