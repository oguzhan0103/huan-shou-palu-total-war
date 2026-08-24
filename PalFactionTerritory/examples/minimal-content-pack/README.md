# PWFT 最小内容包作者 SDK

这是一个无官方剧情、无游戏资产、默认不加载的机制示例。Lua 文件只返回数据表；它们不会自行执行结算、写入 Palworld 存档或修改游戏世界。所有玩家可见内容都以 localization key 表示，演示字符串仅用于验证接线，内容作者必须替换。

## 文件用途

- `manifest.lua`：内容包身份、版本、依赖、冲突、能力和本地化键声明。
- `localization_keys.lua`：唯一的 key 目录，不包含任何显示文本。
- `localization_catalogs.lua`：`zh-CN` / `en-US` 演示字符串；实际内容包在这里填写正文。
- `quest_template.lua`：一个包含推进、选择和完成阶段的通用任务模板。
- `strategic_world.lua`：一只唯一帕鲁和一座城邦的占位定义。
- `unique_pal_campaign.lua`：唯一 Boss 白名单、开放窗口、毁灭目标、NPC 候选势力和高额赎金的纯数据示例；原生 Boss 槽位未验证前保持 `pending`。
- `ending_routes.lua`：保留、移交、移除三个纯规则路线槽。
- `content_actions.lua`：任务/选择结果可触发的白名单机制动作；夺取唯一帕鲁、毁城和提交结局等不可逆动作必须声明玩家确认。
- `leader_guards.lua`：NPC 领主/重要角色及护卫编组骨架；只声明稳定 ID、精确角色类、场景和上限。Core 已为七个人类势力提供 `<factionId>.default-guard` 原生护卫原型；内容作者也可通过 `PWFT_NPC_LEADER_GUARD_NATIVE_PRODUCTION_V1:register_archetype(...)` 注册额外原型。真实领主 Actor 出现后必须用同一 API 精确绑定，生产 Provider 才会按编组生成、跟随、进入战斗并整组回收。
- `reward_policies.lua`：难度倍率、里程碑保底、频道单位数和单次上限；只计算奖励意图，不直接写背包。
- `pal_discourse.lua`：一个通用帕鲁代表和一棵可完成或放弃的有向无环论道树。
- `bundle.lua`：可被 Core 原子校验和注册的 `pwft.content-bundle.v1` 整包。
- `content_module.lua`：游戏内加载入口，导出 `bundle`，并在受信 `activate(context)` 中把示例奖励频道绑定到 Build 24575825 的原生物品 Provider。
- `pack.lua`：兼容测试和工具链的一览入口。

## 作者必须替换的字段

1. 将 `example.minimal`、`example.minimal.foundation` 和版本号替换为作者自己的稳定命名空间、包 ID 与 SemVer。所有任务、城邦、唯一帕鲁、路线、代表、节点、选择、flag 和 result tag 都必须留在该命名空间内。
2. 在 `localization_keys.lua` 中建立完整 key 目录，在 `localization_catalogs.lua` 中为这些 key 提供文本。不要把剧情、标题、描述或对话直接写入任务或机制表。
3. 将 `speciesId`、人类/帕鲁 `factionId`、城邦归属、信物额度和好感度上限替换为目标内容。引用的核心 ID 必须存在于当前 PWFT registry。
4. 按需要改写任务阶段图、三条路线的 `conditions`/`effects`、`content_actions.lua`、`leader_guards.lua`、`unique_pal_campaign.lua` 和论道树节点。任务的每个阶段必须可达且存在完成路径；论道树必须无环、全部可达、所有路径终止。没有实机证据时不得把 Boss `bindingStatus` 从 `pending` 改成 `bound`。
5. 修改已发布定义时必须提升 `contentVersion` 并提供迁移；不得在相同版本下静默改动内容。
6. 把 `content_module.lua` 中示例 `nativeItemId = "StainlessSteel"` 换成内容包实际奖励，并把 `maximumUnitsPerDelivery` 设为不低于 policy 可能产生的最高单位数。Core 会先把 operation/channel 写入 Mod 侧车，再按精确 `OwnerPlayerUId` 选择库存；主机使用 `AddItem_ServerInternal`，客户端使用 `RequestAddItem_ToServer`，只有 `CountItemNum` 精确增加预期数量才完成。进程中断或读回歧义会进入 `reconciliation-required`，绝不自动再发一份。金币、模型输出和直接 SaveGames 修改均不是支持的奖励频道。

## 游戏内安装与加载

1. 将整个 `minimal-content-pack` 文件夹复制到 `PalFactionTerritory0/Scripts/`。
2. 在 `pwft/config.lua` 的 `contentModules.modules` 数组中加入：

```lua
contentModules = {
    enabled = true,
    modules = {
        "minimal-content-pack.content_module",
    },
    fallbackLocale = "zh-CN",
}
```

3. 启动后检查 UE4SS 日志：该包必须出现 `CONTENT_MODULE ... registered=true activated=true`，汇总必须为 `CONTENT_MODULE_LOADER_READY ... failed=0`。

Core 会在同一个 Lua 环境中 `require` 配置的模块，先把 manifest、任务、战略世界、唯一 Boss 战役、结局、白名单机制动作、NPC 领主护卫、帕鲁论道和本地化全部放入临时运行时校验，再进行确定性提交。任何一域失败时，整包不注册。`activate(context)` 可取得 `uniquePalCampaign`、`uniquePalBossProviderBus`、`uniquePalWorldEffectBus`、`uniquePalNativeDeliveryProduction`、`uniquePalRansomShopBridge`、`factionNpcAttitudeBus` 与 `npcLeaderGuardOrchestrator`，但必须注册配置白名单中的原生 provider，并精确绑定当前世界 actor；世界卸载后绑定和部署全部丢弃，Core 会在下一次 `load-map-post` 自动重新调用同一个受信 `activate(context)`，所以激活函数必须可幂等重入并重新发现当前世界对象，不能缓存上一代 UObject。不同 UE4SS Mod 的 `_G` 相互隔离，因此不支持另建一个 Mod 后通过 `_G.PWFT_*` 注入内容。

唯一 Boss 接线只有在 `unique_pal_campaign.lua` 的 `bindingStatus = "bound"` 且内容模块同时提交经当前 Build 核验的 `speciesId`、spawner key、预期 Actor class、地点、原生已有 Boss 或替换槽位路线，以及完整 `raid-slab` 数值档时才会激活。Provider 必须保证 delivery ID 幂等和 world generation 回调隔离；缺少任一证据时保持 `pending`。示例故意不提供这些值，不能直接改成正式绑定。

势力毁灭和赎回的世界效果同样不会从示例自动生效。`uniquePalWorldEffectBus` 要求每个目标显式绑定当前 Build 的势力刷新器、允许清理的 Actor binding/class、城市锚点与居民／功能 NPC 刷新器、商会柜台，以及文本、保卫袭击、后台结果、支付和 Pal 交付路线。禁止扫描全部 Actor、删除地图建筑或由模型确认胜负／付款；未核验时只保留 Core 状态和待投递记录。

### P2 赎金商品与原生 Pal 交付

本体只提供机制，不替内容作者猜写赎金价格、持有势力或剧情商品。生产接线必须在同一次 `activate(context)` 中按以下顺序完成：

1. 向 `uniquePalWorldEffectBus` 注册 generation-fenced、delivery-ID 幂等的 Provider。
2. 为目标注册当前 Build 的精确 world-effect target binding；其中 `ransomPaymentKey` 与 `palDeliveryKey` 必须是本内容包的稳定路线。
3. 调用 `uniquePalNativeDeliveryProduction:register(...)`，只提交该 target binding 实际会交付的唯一帕鲁。Build 24575825 当前只批准 `pwft.unique.pinkcat/PinkCat`、`pwft.unique.anubis/Anubis`、`pwft.unique.weasel_dragon/WeaselDragon`、`pwft.unique.black_metal_dragon/BlackMetalDragon`、`pwft.unique.ronin/Ronin`；新地图暂定项不允许注册。
4. Provider 收到 `ransom-offer` 时，用 `uniquePalRansomShopBridge:accept_offer(payload, context, nativeOffer)` 绑定一个已经生成并核验的原生 ItemShop 商品。`nativeOffer` 必须给出确切的 `nativeOfferId/shopId/productId/merchantFactionId/unitPrice/ransomPaymentKey`，库存和购买数量都为 1，价格等于 `unique_pal_campaign.lua` 的 `ransomPrice`，商人势力等于当前持有者。
5. Provider 收到 `pal-delivery` 时，只调用 `uniquePalNativeDeliveryProduction:handle_delivery(payload, context)`；不要直接改金币、Pal 容器或存档。

赎金商品的原生 DataTable 行属于内容密钥：静态 `OverridePrice` 必须与该 Pal 的 `ransomPrice` 相同。购买取消、余额不足或服务器返回失败时不会转移归属；服务器成功后商业好感固定为 0，随后事务桥只创建一次个体、只提交一次捕获，并在仓库回读完全相同的 individual identity 后才完成。合同见 `contracts/unique_pal_delivery_production.v1.json`，整链自动测试见 `mod0/tests/unique_pal_ransom_native_delivery_e2e_spec.lua`。

默认 `modules = {}`，所以机制基座本身仍然不携带剧情。

## 离线校验

在仓库根目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/validate-content-pack.ps1 -PackPath examples/minimal-content-pack
```

如果使用发布 ZIP，在解压目录运行：

```powershell
powershell -ExecutionPolicy Bypass -File AuthorSDK/validate-content-pack.ps1 -PackPath AuthorSDK/minimal-content-pack
```

命令会返回可读错误并以非零退出码拒绝无效 manifest、未声明的本地化 key、非法论道树、依赖/冲突或跨领域 ID/版本不一致。

## 确定性 Core 结算

作者内容只能给出 key、稳定 ID、条件和预登记的白名单动作。UI 或剧情层选择某个分支后，`QuestRuntime` 记录 branch ID 与结构化 result；`ContentActionRuntime` 只接受已随内容包原子注册的动作，并把它们映射到势力、`StrategicWorld` 或 `EndingRuntime` 的显式操作。加入、唯一帕鲁转移、占领/毁灭/恢复城市、最后通牒与提交结局必须收到明确玩家确认；商业与防守好感、帕鲁和解均不允许由该通用入口伪造。人类势力任务失败或违约可登记 `apply_faction_consequence`，参数为 `factionId`、正数 `penalty` 及 `mission-failure`/`contract-breach` 原因码；它仍由 Core 生成负向 delta，作者文本不能直接改好感。每一步必须使用持久、唯一的 event/operation ID，重复事件只能重放同一结果，冲突事件必须失败关闭。

模型、对话文本、manifest 和内容包定义都无权直接改写世界或结局状态。端到端行为见 `mod0/tests/content_pack_author_sdk_e2e_spec.lua`。
