# PalFactionTerritory0 — Mod 0

状态：**Build 24467282 当前源码已部署并通过安装审计；小型聚落帕鲁攻城已完成两轮 4/4 原生生成、战斗激活和回收实机验收；商人商会已完成七柜台、七个势力商品行绑定及原生 ItemShop 连续开店实机验收。正式测试生成与商业结算开关默认关闭。**

Mod 0 现在同时承载势力地图、地名颜色、敌区传送限制、雷恩商人、世界平衡、小型聚落原生入侵，以及不含剧情内容的势力进度机制底座。

## 已实现

- 读取由版本化合同生成的 12 个稳定势力和 22 个地图区域注册表。
- 校验 `pwft.territory_partition.v1` 冻结基线、合同哈希和 24 个本体瞭望塔 ID。
- 实现 `Original / Territory` 地图模式策略、红绿蓝关系色、未解锁区域保留本体迷雾、M-I 昼夜关系覆盖和敌对公共传送决策。
- 只读监听 `UPalUIWorldMap::CreateWorldMapData` 与 `UPalLocationPoint::InvokeFastTravel`。
- 地图加载 10 秒后扫描 `APalLevelObjectUnlockableFastTravelPoint`，记录 `FastTravelPointID -> SoftUnlockMapMaskTexture -> regionId` 证据。
- 提供开发命令：`pwft.status`、`pwft.map`、`pwft.relation`、`pwft.region`。
- 提供版本化势力进度核心：7 个人类势力可分别加入和晋升，5 个帕鲁势力只能从敌对转为友好。
- 提供用户确认的人类势力关系查询、加入后的敌对外交覆盖、加入资格阻断和显式外交修复接口；不会降低数值好感度。
- 提供固定市场自动外交修复：每个敌对来源需要 60 点、每个商业窗口最多 20 点，只接受成功且非负的固定市场交易，按来源逐个解除。
- 提供成员、核心成员、领队、领主四级身份，领队开始具备玩家护卫资格。
- 提供任务、防守与限额商业好感度接口，以及帕鲁和解、结局三条件。
- 提供有限帕鲁信物服务、Build 24467282 失效关闭袭击结算器，以及只接受粉丝内容包本地化键的离线论道树运行时。
- 提供七势力商业合同、原生购买成功桥接、需求品出售确认接口和商业重复结算保护。
- 提供独立 `faction_economy` 只读轻后端：商人商会为中立渠道，七个人类势力按整岛矿物资源量供应加工成品并采购短缺物资；同一商品的多个本地矿物输入使用最短板产能，已有商人出售的普通辅助输入只计入成本。
- 本机 1.0.1 已确认 9 种加工品的正式配方、内部物品 ID 和原生基础价格；9 种商品均可输出供货/采购方向，当前没有 `unresolved` 商品。
- 首版离线平衡档案 `pwft.economy.balance.supply_band_v1` 已能输出售价、库存、采购价和采购额度，并校验价格单调性、成本底线及 `1–99` 数量限制；该档案没有运行时商店修改权限。
- 四张原生 ItemShop DataTable 已离线追加 `7` 个商品组与 `7` 个抽选组，形成 `26` 条出售商品、`37` 条采购需求和 `63` 条完整市场信号；编译 UAsset、四次反向导出和含 `8` 个条目的未部署 PAK 均已通过专项验证。
- 新增 `faction_economy_shop_catalog` 只读服务；七个柜台使用普通商人 `v04–v10`，雷恩柜台明确使用 `v10 / CaravanShop5`，与雷恩帕鲁商人特例分离。
- 新增 `faction_economy_merchant_runtime`：七名 ItemShop 商会员工消费 7 个唯一 `PFT_Economy_*` 行，登记代表势力并支持完整回收和失败逆序回滚；七柜台生成、交互、网络商店绑定、连续开店及 7/7 回收已实机通过，正式配置默认关闭集中测试生成。
- 出售需求品以 `faction_economy` 供需信号为权威，`faction_commerce` 旧静态清单仅作兼容回退。
- 提供固定七势力市场和带护卫来访商队的配置化运行计划；原生生成默认关闭。
- 七势力商人生命周期已覆盖雷恩现有商人登记、固定市场停用、商队事件防重复、关系转敌后的商人/护卫回收和商业桥清理。
- 提供默认关闭的原生商人/护卫蓝图生成适配器与七势力护卫提供器工厂。
- 出售流程可自动读取 `PalItemSlot` 的物品 ID/数量和 UI 接受结果；服务器成功信号确认前仍不结算。
- 提供势力 UI 数据模型和玩家可见适配器：仅在玩家主动按 `F5` 后创建专用 `WBP_PFT_FactionStatus`，显示 12 势力关系、好感、身份、商业外交修复、护卫和解锁门槛；再次按 `F5` 关闭。
- 提供保卫战临时友好/结算服务和领队护卫服务。
- 提供安全的 MOD 自有 JSON 旁路持久化设施；可靠身份键确认前默认关闭。
- 提供版本化公共接口，供后续粉丝任务、剧情、UI 和生成适配器调用：
  `_G.PWFT_FACTION_API_V1`、`_G.PWFT_COMMERCE_API_V1`、
  `_G.PWFT_ECONOMY_API_V1`、`_G.PWFT_ECONOMY_SHOP_API_V1`、
  `_G.PWFT_JOIN_API_V1`、
  `_G.PWFT_COMMERCE_BRIDGE_V1`、`_G.PWFT_DEFENSE_API_V1`、
  `_G.PWFT_GUARD_API_V1`、`_G.PWFT_MERCHANT_RUNTIME_V1`、
  `_G.PWFT_FACTION_UI_MODEL_V1`、`_G.PWFT_FACTION_UI_V1`；启用原生生成后还会导出
  `_G.PWFT_NATIVE_CHARACTER_ADAPTER_V1`。帕鲁机制另导出
  `_G.PWFT_PAL_RECONCILIATION_API_V1`、
  `_G.PWFT_PAL_RAID_RESULT_ADAPTER_V1` 与
  `_G.PWFT_PAL_DISCOURSE_API_V1`；商会柜台另导出
  `_G.PWFT_ECONOMY_MERCHANT_RUNTIME_V1`。
- 提供 `pwft.progress`、`pwft.factions`、`pwft.commerce` 和 `pwft.economy` 离线/开发诊断命令。

## 安全边界

- `enableMapOverlayMutation = true`
- `enableFastTravelEnforcement = true` only overrides Palworld's public
  `IsEnableFastTravel` query for mapped hostile territories; it never writes
  unlock flags, moves the player, or changes save data.
- `enableSaveWrites = false`
- 势力进度已有版本化快照和主文件/临时文件/备份回退设施；在拿到可靠的世界/玩家身份键前保持 `enabled = false`。
- `nativeEconomyMerchantSpawnEnabled = false`；`FTPoint90` 泰拉瑞亚密域小岛已锁定为中立“商人商会”并从势力着色/敌对传送限制中剥离。七柜台商品资产、原生商店绑定、交互和生成已实机验收；正式开关继续默认关闭，等待内容包给出最终平整地面根坐标与朝向。
- 原生 ItemShop 可以表达商品、覆盖售价与库存，但不能过滤势力需求品或覆盖玩家出售价格；因此采购补差和商业好感度必须等待真实服务器出售成功信号，目前只读报价且不会写钱或好感度。
- 购买只在原生返回 `Successed` 后结算；出售可自动提取物品槽，但没有服务器成功信号时仍不结算。
- 势力 UI 已具备无地图依赖的专用 UMG 资产和显式 `F5` 开关，但仍标记为 `dedicated-faction-panel-ready-live-acceptance-pending`；未实机确认前不宣称显示、输入和分辨率验收通过。
- 正式加入已具备注册入口、外交预览、明确确认、过期邀请拦截和统一公共 API；原生交互界面归入后续玩家 UI 阶段。
- 帕鲁袭击结算只接受权威原生结束、胜负、最终波次确定性头领和本地击杀归属；原生绑定保持关闭，计时器清理不得结算。
- 离线论道树只保存结构和本地化键，不包含基座剧情；原生帕鲁代表交互与对话 UI 保持关闭。
- 不覆盖 `WBP_Map_Body`，不修改原 PAK，不触碰玩家存档。
- 犯罪提示 UI 仍不接入；当前证据不足以证明它能脱离犯罪状态安全展示。

## 下一道门槛

1. 商人商会机制与商品组绑定已经实机通过；下一步仅是把七柜台内容落位到 `FTPoint90` 的最终平整地面根坐标，校正朝向并避开传送点和密域入口。
2. 实机验收已完成的原生出售复制确认探针后，分别验收采购补差和限额商业好感度；在此之前保持商品行启用、原生绑定、生成、刷货、补钱和好感度写入关闭。
3. 等待维护者明确命令后，才通过 Steam 进入指定的受保护测试存档。
4. 实机分别验收启动、交易、商人、UI、护卫、防守和保存/恢复，不以离线 PASS 代替实机结论。

## 当前源码与历史部署

- 当前宿主 build：Steam `24467282`；数据合同来源 build：`24181527`。
- 位置：`E:\SteamLibrary\steamapps\common\Palworld\Pal\Binaries\Win64\ue4ss\Mods\PalFactionTerritory0`。
- UE4SS：Palworld 专用 zDev 包；`MemberVariableLayout.ini` 已存在。
- 控制台：文本控制台关闭，GUI 开发控制台开启，便于首次观察且不启用额外通用作弊 Mod。
- 当前部署证据：`evidence/deployments/mod0-dev-build24467282.json`；37 个运行时文件与当前源码哈希一致。
- 最终实机与恢复证据：`docs/40_帕鲁攻城与商人商会最终实机验收_2026-08-08.md`。
- 本轮部署备份：`evidence/deployments/mod0-runtime-script-backups/20260808-200558/`。

## PMK / UMG 当前状态

UE 5.1.1 与 VS 2022/MSVC 14.38 已就绪。`E:\mod\PalworldModdingKit\Content\Mods\PalFactionTerritory0\UI\FactionStatus\WBP_PFT_FactionStatus.uasset` 已从空白 `UUserWidget` 建立、编译和保存；层级只包含根画布、摘要容器和文本控件，依赖扫描不包含 `WBP_PFT_TerritoryMap` 或任何地图纹理/切换控件。运行时复用这棵专用的已 Cook Widget 树，不采用曾导致崩溃的 Lua 动态 UMG 构造。
