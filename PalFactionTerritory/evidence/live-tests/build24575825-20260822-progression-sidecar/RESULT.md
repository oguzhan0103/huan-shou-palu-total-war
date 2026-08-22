# Build 24575825 势力进度侧车持久化 B0 实机验收

- 结果：`PASS`
- 日期：2026-08-22
- 游戏版本：v1.0.3.101283 / Steam Build 24575825
- 验收对象：同一世界／玩家 profile 的完整进程重启、主文件损坏回退、跨世界隔离、测试后恢复

## 通过条件

1. 同一世界和玩家身份连续完成两次完整游戏进程启动、进世界、返回标题和退出；两次均为 `sidecarReason=active:primary`，revision 保持 2。
2. 两次重启之间耐久玩法状态差异为 0；只允许两个世界运行期 generation 在重新绑定时各增加 1。
3. 游戏关闭后故意写入无效主 JSON，保留有效 `.bak`；下次进入同一世界明确命中 `sidecarReason=active:backup`。
4. 备份 revision 2 被恢复为有效主文件；损坏主文件旋转为 `.bak`，恢复后没有 `FACTION_PROGRESSION_RECOVERY_BLOCKED`。
5. State 中同时存在两个不同 world GUID 的独立 progression 文件，文件名和 profile key 不相同，没有跨世界共用同一载荷。
6. 测试完成后，指定世界存档 56 个文件和 Mod State 12 个文件均恢复到测试前快照，哈希差异均为 0；游戏进程已关闭。

## 可复核证据

- 机器可读摘要：`verification.json`
- 公开验收器：`tools/verify_progression_sidecar_live_evidence.py`
- 原始 State、完整日志和测试后存档只保留在私有验收目录，不进入公开仓库。

## 边界

这次实机结果关闭蓝图 B0。它证明 Mod 自有侧车可以按可靠世界／玩家身份恢复、从备份自愈并隔离不同世界；不等于游戏对所有剩余 B 类机制或玩家主观体验已经验收。Mod 仍保持 `enableSaveWrites=false`，测试中的 Palworld 自动存档已用测试前快照恢复。
