# 幻兽帕鲁全面战争

《幻兽帕鲁全面战争》是一个非商业、社区驱动的 Mod 项目。当前版本是 **v1.0.2 开源机制基座**：它把玩法规则、运行时代码、内容包接口和测试交给社区，但不把剧情文本或详细世界设定写死在 Core 中。

> 这不是“一键安装的完整剧情 Mod”。公开 Release 是 source-only 源码包，不含 Pocketpair 游戏资产、Cooked PAK、存档或模型。玩家可直接体验的独立 UE4SS 扩展与开发者基座在同一仓库中分别标注，离线通过不会冒充实机通过。

## 当前状态

| 内容 | 状态 | 已验证范围 |
| --- | --- | --- |
| 小型聚落帕鲁攻城 | Build `24467282` 实机通过 | 两轮均原生生成 4/4、居民优先战斗、4/4 回收 |
| 商人商会七柜台 | Build `24467282` 实机通过 | 7 个实体、7 个势力、7 个商品行；原生 ItemShop 可连续打开；7/7 回收 |
| 势力进度、商业规则、任务、护卫、结局和内容包 SDK | 离线验证通过 | 规则、API、幂等与回归测试完成；部分原生入口默认关闭 |
| 帕鲁信物与有限论道 | 离线验证通过 | 信物、任务门闩、有限次数、技术故障返还、红转蓝结算完成 |
| NPC / 帕鲁聊天 | 控制与路由底座离线完成 | 外部 AI、Core 控制器、通用呈现路由、代表精确绑定/距离门闩和技术故障返还已完成；原生 Widget 与 NPC Delegate 尚未接通 |
| `PalMultiOtomo0` 多帕鲁 | 独立扩展源码已公开 | F6 最多增加 4 只辅助帕鲁、F7 回收；当前 Build 仍应重新实机确认 |

完整、逐项且不夸大的状态说明见 [已完成内容](./幻兽帕鲁全面战争_已完成内容.md)，后续顺序见 [未完成项收敛计划](./PalFactionTerritory/docs/41_未完成项收敛计划_2026-08-10.md)。攻城与商会的实机记录见 [最终实机验收](./PalFactionTerritory/docs/40_帕鲁攻城与商人商会最终实机验收_2026-08-08.md)。

## 仓库组成

- `PalFactionTerritory/`：势力、商业、攻城、帕鲁和解、内容包 SDK、作者示例和测试。
- `PalMultiOtomo/`：独立的多帕鲁 UE4SS 扩展。
- `PalAgentDialogue/`：本地 Ollama / OpenAI-compatible NPC 对话实验运行时与 UE4SS 文件桥。

项目采用“基座 + 密钥”结构：

- **基座**负责确定性机制、状态、接口和安全边界。
- **密钥**由内容作者提供剧情、任务文本、本地化、代表、信物名称、城邦映射和结局条件。
- 大模型只能生成对话和白名单建议，不能直接修改任务、好感度、物品、经济或世界状态。

## 获取与验证

请从 [GitHub Releases](https://github.com/oguzhan0103/huan-shou-palu-total-war/releases) 下载 v1.0.2 的分包源码和 `SHA256SUMS.txt`。开发者也可以克隆仓库后运行：

```powershell
npm ci
npm test

Set-Location .\PalAgentDialogue
cargo test --all-targets
```

`PalMultiOtomo0` 的手动安装目录位于 `PalMultiOtomo/mod0/ue4ss/PalMultiOtomo0/`。`PalFactionTerritory0` 公开包不包含地图、UMG 和商店 DataTable 的 Cooked PAK，因此应视为开发者基座，而不是完整玩家安装包。

## 参与开发

内容作者从 `PalFactionTerritory/examples/minimal-content-pack/` 开始。贡献代码或内容前请阅读 [贡献指南](./CONTRIBUTING.md)、[安全策略](./SECURITY.md) 和 [第三方资产说明](./THIRD_PARTY_NOTICES.md)。

玄绒龙已从活动 Mod 和公开发布范围撤出。本仓库不包含其模型、纹理、FBX、Cook 资源或 PAK。

本项目采用 [MIT License](./LICENSE)，与 Pocketpair 无隶属、授权或官方关系。《幻兽帕鲁》名称、角色和游戏资产归其权利人所有。
