# 幻兽帕鲁全面战争

《幻兽帕鲁全面战争》是一个非商业、社区驱动的 Mod 项目。本次版本是
**v1.0.3 source-only 开源机制基座**。它把玩法
规则、运行时代码、内容包接口和测试交给社区，但不把剧情文本或详细世界设定写死
在 Core 中。

> 这不是“一键安装的完整剧情 Mod”。公开 Release 只包含第一方源码，不含
> Pocketpair 游戏资产、Cooked PAK、存档、日志、模型或本机部署产物。离线通过、
> 自动验证、实机通过和内容作者待集成在文档中分别标注。

## 当前状态

| 内容 | 状态 | 已验证范围 |
| --- | --- | --- |
| 小型聚落四成员攻城与有限信物 | 实机通过，Build `24467282` 历史证据 | 4/4 原生生成与死亡聚合、玩家所属帕鲁头领击杀归因、玩家方胜利和单枚信物结算；本体自然 incident 创建仍不稳定 |
| 商人商会七柜台 | 实机通过，Build `24575825` | `FTPoint90` 正式落位、7 个势力商品行、原生 ItemShop、生产自动驻场和返回标题安全清理 |
| 商业好感度 | 单项实机闭环通过 | 需求品 `IronIngot` 的服务器请求、库存复制确认和一次结算 `applied=2`；负向及重复分支有离线失败关闭测试 |
| 势力面板与帕鲁代表对话 | 实机通过，Build `24575825` | F5 面板、原生代表交互、Cooked 对话面板、F1/F2 与数字选项；正式角色和剧情由内容包提供 |
| 玩家人类护卫 | 实机通过，Build `24575825` | 生成、跟随、战斗让权、战后恢复、召回、死亡释放和再次部署；未把自然战死动画录像冒充为证据 |
| 本地 AI 对话 | 基座链路验证通过 | 本地 Ollama、Core 文件桥、操作台、严格回复白名单和玩家 F3 确认已验证；仍需内容作者绑定正式代表 Actor 后做具体剧情画面验收 |
| `PalMultiOtomo0` 多帕鲁 | 独立扩展源码已公开 | F6 最多增加 4 只辅助帕鲁、F7 回收；实机基线仍为 Build `24467282`，Build `24575825` 应重新确认 |
| 蓝图 A0–A9 纯开发机制 | 源码与自动测试完成 | 任务目标、保卫好感、资源/战争、战略原生总线、结局效果、NPC 态度、领主护卫和奖励政策均已接入 Core/内容包；具体 Actor、provider 与游戏画面仍按项实机 |

完整状态见 [已完成内容](./幻兽帕鲁全面战争_已完成内容.md)。当前发布收敛顺序见
[未完成项收敛计划](./PalFactionTerritory/docs/41_未完成项收敛计划_2026-08-10.md)，
最新 Build 与护卫验收见
[Build 24575825 验收](./PalFactionTerritory/docs/47_Build24575825兼容性与玩家护卫最终验收_2026-08-12.md)，
商会驻场见
[商会生产驻场验收](./PalFactionTerritory/docs/48_商人商会生产驻场生命周期验收_2026-08-12.md)，
本地模型链路见
[本地 Ollama 对话验收](./PalFactionTerritory/docs/49_本地Ollama对话链开发与验收_2026-08-12.md)。

## 仓库组成

- `PalFactionTerritory/`：势力、商业、攻城、有限信物、护卫、内容包 SDK 和测试。
- `PalMultiOtomo/`：独立的多帕鲁 UE4SS 扩展。
- `PalAgentDialogue/`：本地 Ollama / OpenAI-compatible NPC 对话 sidecar 与独立
  UE4SS 文件桥。

项目采用“基座 + 密钥”结构：

- **基座**负责确定性机制、状态、接口、失败关闭和安全边界。
- **密钥**由内容作者提供剧情、任务文本、本地化、代表、信物名称、城邦映射和
  结局叙事。
- 大模型只能生成对话和白名单建议，不能直接修改任务、好感度、物品、经济、
  势力或世界状态。

## 获取与验证

已发布附件见 [GitHub Releases](https://github.com/oguzhan0103/huan-shou-palu-total-war/releases)。
开发者克隆仓库后运行：

```powershell
npm ci
npm test

Set-Location .\PalAgentDialogue
cargo test --locked --all-targets
```

`PalMultiOtomo0` 的手动安装目录位于
`PalMultiOtomo/mod0/ue4ss/PalMultiOtomo0/`。`PalFactionTerritory0` 的公开 Core
源码包不包含地图、UMG 和商店 DataTable 的 Cooked PAK，因此面向开发者和内容
作者，不是完整玩家安装包。

Core 源码附件同时包含 `PalFactionTerritory/companion/` 外接操作台。先在
`PalAgentDialogue/` 运行 `cargo build --release`，再执行
`PalFactionTerritory/companion/start-companion.cmd`；也可以用
`PAL_AGENT_EXECUTABLE` 与 `PAL_AGENT_CHARACTER_PACK` 指向单独构建的 sidecar 和
角色包。操作台只监听本机回环地址，模型输出仍须通过 Core 白名单和玩家确认。

## 参与开发

内容作者从 `PalFactionTerritory/examples/minimal-content-pack/` 开始。贡献代码或
内容前请阅读 [贡献指南](./CONTRIBUTING.md)、[安全策略](./SECURITY.md) 和
[第三方资产说明](./THIRD_PARTY_NOTICES.md)。

玄绒龙已从活动 Mod 和公开发布范围撤出。本仓库不包含其模型、纹理、FBX、Cook
资源或 PAK。

本项目采用 [MIT License](./LICENSE)，与 Pocketpair 无隶属、授权或官方关系。
《幻兽帕鲁》名称、角色和游戏资产归其权利人所有。
