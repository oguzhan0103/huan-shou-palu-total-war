# Build 24575825 商会 companion JSON 边界实机复核

- 结果：`PASS`（商人登记与外接 JSON 写入）
- 日期：2026-08-23
- 游戏版本：v1.0.3.101283 / Steam Build 24575825

## 通过摘要

1. 7 个商人商会势力柜台全部完成 `catalog=true` 登记，另有 1 次盗猎集团特殊商人登记；覆盖 7 个不同人类势力。
2. 原报错点 `pwft.faction.eternal_pyre` 本轮完成 `merchant-registered` 与商店绑定，未再出现 `event-encode-failed`。
3. 当前世界会话连续写入 25 个 companion 事件（序号 1–25），其中 8 个 `merchant-registered`、15 个 `merchant-shop-opened`。
4. 当前 UE4SS 日志中 companion 记录失败、状态复制失败和公共投影降级标记均为 0。
5. 测试后 SaveGames 384/384、Mod State 12/12 从预检快照恢复，哈希差异均为 0；正式运行时 76 个文件继续与源码及部署清单一致。

## 边界

本轮验证的是商人生成／登记事件可以稳定写入外接 JSON 侧车，不是商店购买、出售、好感度结算或玩家主观交互验收。标题页仍显示此前异常留下的通用 Mod 提示；当前日志没有生成新的 companion 错误，因此没有把该提示当作本轮失败，也没有把它宣称为视觉验收通过。

公开仓库只保留机器可读摘要，不包含完整 UE4SS 日志、玩家存档、Mod State 或本机绝对路径。

```powershell
python tools/verify_companion_commerce_live_evidence.py
```
