# 商会 Companion JSON 边界修复与实机复核（2026-08-23）

## 1. 结论

2026-08-23 B2 实机测试发现的商会 companion 事件编码问题已修复，并在同一 Steam Build 24575825 的既有 `oguzhan` 世界完成最小化实机复核。

本轮证明：7 个商人商会势力商人和 1 个盗猎集团特殊商人可以完成登记，外接侧车连续写入 25 个 JSONL 事件；原失败势力永炎同心会已覆盖，当前日志没有 companion 编码、复制或投影降级标记。

## 2. 原因

旧链路把进程内运行时表直接交给外接 JSON 侧车：

- `merchant-registered` 携带完整 `metadata`；运行时元数据可能混入回调或 UE4SS 包装对象；
- 状态发布递归使用 `pairs`，遇到带 `__pairs` 的运行时表会触发元方法；
- B2 正向日志因此出现一次 `json.lua:16` 编码失败，负对照日志出现一次 `companion_ledger.lua:12` 状态复制失败。

这不是商人生成、柜台行或商店绑定路线失败，而是“游戏内对象 → 游戏外 JSON”边界不够严格。

## 3. 修复

### 3.1 商人事件显式投影

`commerce_bridge.lua` 继续在进程内保留完整商人元数据，只向外接事件公开 6 个文档化字段：

- `mode`
- `commercialTruce`
- `merchantOrganisationId`
- `representedFactionId`
- `economyCatalogBinding`
- `source`

回调、userdata 和其他内部对象不会进入 `merchant-registered`。

### 3.2 Companion 公共边界

`companion_ledger.lua` 新增公共事件／状态投影入口：

- 只保留 JSON 原生标量和普通表；
- 使用原始 `next`／`rawget`，不触发运行时 `__pairs`；
- 函数、userdata、thread、循环引用和非有限数字不会越界；
- 投影发生时返回数量、首个字段路径和原因，运行时会明确记录；
- 原严格 `record`／`publish` 仍保持失败关闭，不把非法输入静默合法化。

`runtime.lua` 的 progression、后果、商贸和侧车就绪事件统一走公共边界；状态发布同样使用公共投影。

## 4. 自动验证

| 层级 | 结果 |
| --- | --- |
| `commerce_bridge_spec.lua` | PASS：内部回调保留在进程内，公开事件可直接 JSON 编码 |
| `companion_ledger_spec.lua` | PASS：函数字段被定位并隔离，恶意 `__pairs` 不再阻断公共状态发布 |
| 全量 Lua／公开源码验证 | PASS：78 个 Lua 文件、72 个 Lua 测试、398 个跟踪文本文件 |
| 部署核验 | PASS：Build 24575825 正式运行时 76 个文件与当前源码一致 |

## 5. 实机结果

当前会话事件序号连续为 1–25：

- `profile-activated`：1
- `progression-sidecar-ready`：1
- `merchant-registered`：8
- `merchant-shop-opened`：15

8 次登记包含 7 个 `catalog=true` 商人商会势力商人和 1 个 `catalog=false` 盗猎集团特殊商人，覆盖 7 个不同人类势力。永炎同心会在日志中完成登记；本轮 companion failure marker 为 0，公共投影降级 marker 也为 0。

## 6. 恢复

| 对象 | 结果 |
| --- | --- |
| 游戏进程 | 已正常退出，0 个残留进程 |
| 完整账号 SaveGames | 384/384，哈希差异 0 |
| Mod State | 12/12，哈希差异 0 |
| 正式安装 | 76 个记录文件与源码／部署清单一致 |

测试后的 SaveGames、State 和最终 UE4SS 日志另存于本机忽略目录，预检快照已恢复到游戏目录；没有把玩家存档或本机绝对路径加入公开仓库。

## 7. 证据边界

- 源码／自动测试：PASS。
- 正式部署：PASS。
- 实机商人登记与 JSONL 写入：PASS。
- 商店购买、出售及好感度结算：本轮未执行。
- 商人站位／漫步视觉验收：本轮未执行。
- 标题页通用 Mod 异常提示仍会显示；它来自此前状态，当前日志没有新的 companion 错误，未将其冒充为已视觉消失。
- 用户验收：未执行。

公开复核：

```powershell
python tools/verify_companion_commerce_live_evidence.py
```
