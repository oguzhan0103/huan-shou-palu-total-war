# PWFT 最小内容包作者 SDK

这是一个无剧情、无游戏资产、默认不加载的机制示例。Lua 文件只返回数据表；它们不会自行执行结算、写入存档或修改游戏世界。所有玩家可见内容都以 localization key 表示，实际文本由内容作者在自己的本地化层中提供。

## 文件用途

- `manifest.lua`：内容包身份、版本、依赖、冲突、能力和本地化键声明。
- `localization_keys.lua`：唯一的 key 目录，不包含任何显示文本。
- `quest_template.lua`：一个包含推进、选择和完成阶段的通用任务模板。
- `strategic_world.lua`：一只唯一帕鲁和一座城邦的占位定义。
- `ending_routes.lua`：保留、移交、移除三个纯规则路线槽。
- `pal_discourse.lua`：一个通用帕鲁代表和一棵可完成或放弃的有向无环论道树。
- `pack.lua`：供加载器一次取得上述所有数据表的聚合入口。

## 作者必须替换的字段

1. 将 `example.minimal`、`example.minimal.foundation` 和版本号替换为作者自己的稳定命名空间、包 ID 与 SemVer。所有任务、城邦、唯一帕鲁、路线、代表、节点、选择、flag 和 result tag 都必须留在该命名空间内。
2. 在 `localization_keys.lua` 中建立完整 key 目录，并在作者自己的本地化文件中为这些 key 提供文本。不要把剧情、标题、描述或对话直接写入机制表。
3. 将 `speciesId`、人类/帕鲁 `factionId`、城邦归属、信物额度和好感度上限替换为目标内容。引用的核心 ID 必须存在于当前 PWFT registry。
4. 按需要改写任务阶段图、三条路线的 `conditions`/`effects` 和论道树节点。任务的每个阶段必须可达且存在完成路径；论道树必须无环、全部可达、所有路径终止。
5. 修改已发布定义时必须提升 `contentVersion` 并提供迁移；不得在相同版本下静默改动内容。

## 注册顺序

加载器应先 `require("minimal-content-pack.pack")`，然后按下列顺序调用：

1. `ContentPackRegistry:register(pack.manifest)`；失败时停止，不能注册后续定义。
2. `QuestRuntime:register_template(pack.questTemplate)`。
3. 使用 `{ contentPackRegistry = registry }` 创建 `StrategicWorld`，再调用 `register_pack(pack.strategicWorld)`。
4. 在战略定义注册后创建 `EndingRuntime`，同样传入内容包 registry，再调用 `register_pack(pack.endingRoutes)`。
5. 创建 `PalReconciliation` 与 `PalDiscourseRuntime` 后调用 `register_pack(pack.palDiscourse)`；原生对话呈现仍须独立实机验收。

示例不会被 `runtime.lua` 自动加载。正式内容加载器必须先完整验证一批 manifest，再提交注册，避免半包状态。

## 确定性 Core 结算

作者内容只能给出 key、稳定 ID、条件和结构化结果。UI 或剧情层选择某个分支后，`QuestRuntime` 记录 branch ID 与结构化 result；受信任 Core 将白名单 result 映射到 `StrategicWorld` 的显式操作，再由 `EndingRuntime:evaluate` 检查路线条件，并最终调用 `commit`。每一步必须使用持久、唯一的 event/operation ID，重复事件只能重放同一结果，冲突事件必须失败关闭。

模型、对话文本、manifest 和内容包定义都无权直接改写世界或结局状态。端到端行为见 `mod0/tests/content_pack_author_sdk_e2e_spec.lua`。
