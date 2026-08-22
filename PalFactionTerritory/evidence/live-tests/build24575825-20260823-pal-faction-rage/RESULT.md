# Build 24575825 帕鲁部落狂暴 B2 实机验收

- 结果：`PASS`（原生字段与作用域门）
- 日期：2026-08-23
- 游戏版本：v1.0.3.101283 / Steam Build 24575825
- 范围：B2 Predator、不可捕获、双倍 HP／伤害及目标排除

## 通过摘要

1. 中央／东南群岛的 11 个自然生成野生帕鲁逐个完成原生字段读回：`Predator false→true`、HP 与伤害倍率 `1→2`、生成类型 `0→8`、不可捕获 `false→true`，最大 HP 原始值逐个精确翻倍。
2. 首轮审计为 `applied=4 verified=4 excluded=6 failed=0`；玩家和 5 个拥有／工作帕鲁全部在写入前排除且字段保持原值。
3. 后续自然流入的 7 个目标继续通过；全过程只处理原生初始化事件中的当前精确 Actor，`broadScan=false`、等级门关闭、加载对象协调关闭。
4. 安装目录临时强制 mask miss 的独立负对照中，8 个自然野生帕鲁均以 `outside-pal-faction-island` 排除；稳定审计摘要为 `applied=0 verified=0 excluded=14 failed=0`，字段全部保持原值。该对照不是一次自然地理位置采样，不能改写成“玩家实地走到岛外”。
5. 测试结束后 SaveGames 385/385、Mod State 12/12 从预检快照恢复且哈希差异为 0；正式 76 文件重新部署，临时 mask 与 B2／审计／探针开关全部还原。

## 边界

本轮证明原生属性写入、精确读回和作用域门，没有直接拍摄战斗演出或实际投球捕获失败。F7 QA 探针虽然注册成功，但本机另一已安装 Mod 同时占用 F7，本轮没有产生探针样本，因此不计为通过证据。实机还暴露了与 B2 无关的 companion commerce JSON 编码错误；该问题单独保留，不能算入 B2 成功，也没有导致 B2 字段读回失败。

公开仓库只保留机器可读摘要，不包含完整 UE4SS 日志、玩家存档、Mod State 或本机绝对路径。本结果是代理执行的技术验收，不冒充用户主观验收。

```powershell
python tools/verify_pal_faction_rage_live_evidence.py
```
