# Build 24575825 唯一帕鲁原生交付实机验收

- 结果：`PASS`
- 时间：2026-08-22 17:54:24 +08:00
- 游戏版本：v1.0.3.101283 / Steam Build 24575825
- 世界：`oguzhan` / `E0D5ECDC46B379829F8F31A729ACFD92`
- QA delivery：`qa.native-pal-delivery.g4.r1`
- 物种：`Anubis`，等级 1
- 唯一个体：`pal-00000000000000000000000000000001-8E0F25AB4226BF458C679D91DC9EE50C`

## 通过条件

1. `SpawnNPCForServer` 只创建一次；首帧 identity 未就绪时保留同一句柄重试，没有重复生成。
2. 500 ms 后取得稳定 `PalInstanceID`。
3. `PalCaptureSuccess` 第一次提交即接受。
4. 玩家 Pal 仓库第一次回读即找到完全相同的 individual key。
5. 最终结果为 `native-pal-delivery-live-test-verified`。
6. `directContainerMutation=false`，没有直接改 Pal 容器。
7. 主世界十秒探针执行后没有再次出现 EngineTick `Hook threw exception`。

## 原始日志身份

- 原始位置：`E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\UE4SS.log`
- 退出后字节数：315873
- SHA-256：`3574D89EB7A345F3E8F43E538ACD0432493195EF149B2ED5FEF854A421C9938A`
- 项目内关键摘录：`acceptance-log-excerpt.txt`

## 存档与正式配置恢复

- 测试前快照：`<ProjectWorkspace>\outputs\live-test-preflight\build24575825-20260822-174857366\snapshot\SaveGames`
- 快照文件数：363
- 测试后变更存档隔离：`<ProjectWorkspace>\outputs\live-test-save-quarantine\20260822-175545-unique-pal-native-delivery-success-build24575825\<SteamUserId>`
- 恢复校验：预期 363、实际 363、哈希差异 0、额外文件 0。
- `uniquePalNativeDeliveryLiveTest.enabled` 已恢复 `false`。
- 正式部署脚本随后再次通过：75 个运行时文件与清单及当前源码一致。

## 边界

这证明当前 Build 的单只 Pal 原生创建、捕获和同一 individual 仓库回读路线可用。它不等于正式赎金商品、P2 世界效果 Provider、城市毁灭或完整唯一帕鲁战役已经完成；这些生产绑定仍保持失败关闭。
