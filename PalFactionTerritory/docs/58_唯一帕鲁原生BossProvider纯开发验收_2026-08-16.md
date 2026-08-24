# 唯一帕鲁原生 Boss Provider 纯开发验收

日期：2026-08-16

状态：**合同、源码、运行时接入和自动测试完成。2026-08-22 已补齐 Build 24575825 当前 PAK 的前五只原生 Boss 资产目录，但场景内 spawner UObject、地点、实际实例、完整数值和权威回调仍未绑定；本轮未部署、未启动游戏，未形成新增实机或用户接受证据。**

## 1. 本轮完成边界

- 新增 `contracts/unique_pal_boss_provider.v1.json`，把 Boss 白名单、绑定证据、石板级数值、原生表现投递和权威回调分开定义。
- 新增 `unique_pal_boss_provider_bus.lua`，只接受受信内容模块注册的 Provider；Provider 必须保证 delivery ID 幂等和 world generation 回调隔离。
- 非唯一帕鲁 Boss 一律返回抑制策略；唯一帕鲁也必须同时处于有效开放阶段并拥有当前 world generation 的已核验绑定，才会获得生成授权。
- 显式区分两条路线：复用已有原生 Boss，或使用经核验的兼容替换槽位。两者都必须提供当前 Build、species ID、spawner key、预期 Actor class 和地点；替换路线额外要求确切 slot ID。
- `raid-slab` 平衡档由内容配置提供等级、生命、伤害、减伤、异常抗性和捕获难度倍率；Core 不猜默认数字，并强制 `captureAllowed = true`。
- 原生投递覆盖 `announce / spawn / open / close / cooldown`。失败投递可重试，已经过期的预告/生成/开放投递会取消，不会在迟到时重新生成 Boss。
- 原生结果覆盖 `spawn / defeat / capture / timeout`。每个回调都核对 provider、authority、binding、唯一帕鲁、开放 event、species、spawner、Actor binding/class 和 world generation，并使用稳定 callback ID 做同签名重放与异签名冲突拒绝。
- 世界卸载、sidecar 恢复或换根后清空 handler 和 native binding，并提升 generation；旧 UObject 回调无法继续写入。

## 2. “击败”语义

交接要求 P1 必须有权威击败回调，但此前状态机只写明“捕获或超时”。为避免擅自把击败等同于归属转移，本轮采用最小且可逆的失败关闭语义：

- 权威击败会关闭本轮开放，要求原生清理和冷却表现；
- 唯一帕鲁继续保持 `wild/unclaimed`；
- 不自动归玩家，不自动分给 NPC，不触发势力毁灭；
- 下一轮必须重新排期。

只有权威捕获回调能把归属转给玩家；只有已开放实例的权威超时回调能进入既有确定性 NPC 分配。若项目负责人后续给出不同的击败规则，应先升合同版本和补迁移/回归测试，不能在 Provider 中暗改。

## 3. 与现有状态机的接线

- `unique_pal_campaign.lua` API 升至 `1.1.0`，新增击败权威和不转移归属的关闭路径；sidecar 子状态 schema 仍为 `1.0.0`，旧快照无需迁移。
- 核心 operation signature 在通知监听器前写入，防止监听器即时保存 sidecar 后，重启又重放已经提交的状态变化。
- 捕获和超时事件现在携带当轮 spawn/Actor binding，用于精确关闭同一实例，不扫描或销毁无关对象。
- `runtime.lua` 创建并导出 `_G.PWFT_UNIQUE_PAL_BOSS_PROVIDER_BUS_V1`，把总线交给受信 `activate(context)` 内容模块，并在世界卸载时统一解绑。
- Companion 状态和启动日志新增 Provider 数量、handler、binding、待投递和 generation；它们是诊断信息，不是实机成功证明。

## 4. 自动测试覆盖

专项测试覆盖：

- 非白名单 Boss 抑制、关闭窗口抑制和有效窗口授权；
- 未核验 spawner、Actor 或 slot 的绑定拒绝；
- 已有原生 Boss 与替换槽位两条显式路线；
- 完整 `raid-slab` 数值和可捕获门闩；
- 预告首次失败后的幂等重试，以及预告、生成、开放、关闭、冷却五类投递；
- 旧 generation、错误 identity、迟到 event 和 Actor 实例拒绝；
- 生成、击败、捕获、超时正向回调；同 ID 同签名重放与异签名冲突；
- 击败后仍为 wild、捕获后归玩家、超时后确定性归 NPC；
- sidecar 恢复后 Provider 定义与投递/回调账本保留，handler 和 binding 不保留；世界卸载再次 generation fencing。

专项命令：

```powershell
..\node_modules\.bin\fengari.cmd mod0/tests/unique_pal_campaign_spec.lua
..\node_modules\.bin\fengari.cmd mod0/tests/unique_pal_boss_provider_bus_spec.lua
```

完整门禁：

```powershell
node ..\tools\verify-public.mjs
python .\tools\verify_mod0.py
powershell -ExecutionPolicy Bypass -File .\scripts\verify-mod0.ps1
git diff --check
```

本轮结果：专项测试均 `PASS`；`verify_mod0.py` 通过；`verify-mod0.ps1` 退出码为 `0`；公共源码验证汇总为 `69 Lua files / 62 Lua tests / 341 tracked text files scanned`；`git diff --check` 无空白错误，仅提示 Windows 工作区既有的 LF→CRLF 转换警告。

## 5. 尚未完成的证据层

| 层级 | 状态 |
| --- | --- |
| 设计/合同 | 完成 |
| 源码 | 完成 |
| 自动测试 | 完成 |
| 当前 PAK 资产目录 | 完成：前五只 species、Boss 参数行、Boss Actor 与 8 个候选 spawner 已哈希；不需要替换槽位 |
| 场景内正式绑定 | 未完成：没有绑定 spawner UObject、地点、实例、完整 raid-slab 数值与原生回调 |
| 游戏目录部署 | 未执行 |
| Build 24575825 实机 | 未执行 |
| 用户接受 | 未执行 |

P2 世界效果、战争与赎回的通用 Provider 源码随后已完成，见 `docs/59_唯一帕鲁世界效果战争与赎回Provider纯开发验收_2026-08-16.md`。Build 24575825 的资产目录增量见 `docs/62_唯一帕鲁P1P2本地绑定证据盘点_2026-08-22.md`。仍需内容或实机证据的项目包括：前五只候选 spawner 的场景对象、地点、实际 Actor 实例、石板级确切数值、开放时长和权威回调。空涡龙 species ID、新地图唯一帕鲁及任何不可逆毁灭仍不得推断。

只有用户在对话中明确授权后，才能部署并启动实机验证；至少要逐条观察预告、单实例生成、数值应用、可捕获、击败不转移、捕获转移、超时回收/分配、重复回调、返回标题和重进世界。离线 PASS 不能替代这些画面、日志和用户接受证据。
