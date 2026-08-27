# PalFactionTerritory0 — Mod 0

状态：**Build 24575825 当前源码已部署并通过安装审计；小型聚落帕鲁攻城已完成
4/4 原生生成、战斗、死亡、胜负、信物和回收；商人商会已完成七柜台生产驻场、
2/7 代表性真实购买、需求／非需求出售、复制去重、单窗口 20 点和敌对修复 60 点。
集中测试快捷键保持关闭；势力进度侧车已通过两次完整重启、损坏主文件备份恢复和跨世界隔离实机验收。**

Mod 0 现在同时承载势力地图、地名颜色、敌区传送限制、雷恩商人、世界平衡、小型聚落原生入侵，以及不含剧情内容的势力进度机制底座。

## 已实现

- 读取由版本化合同生成的 12 个稳定势力和 22 个地图区域注册表。
- 校验 `pwft.territory_partition.v1` 冻结基线、合同哈希和 24 个本体瞭望塔 ID。
- 实现 `Original / Territory` 地图模式策略、红绿蓝关系色、未解锁区域保留本体迷雾、M-I 昼夜关系覆盖和敌对公共传送决策。
- 只读监听 `UPalUIWorldMap::CreateWorldMapData` 与 `UPalLocationPoint::InvokeFastTravel`。
- 地图加载 10 秒后扫描 `APalLevelObjectUnlockableFastTravelPoint`，记录 `FastTravelPointID -> SoftUnlockMapMaskTexture -> regionId` 证据。
- 提供开发命令：`pwft.status`、`pwft.map`、`pwft.relation`、`pwft.region`。
- 提供版本化势力进度核心：7 个人类势力可分别加入和晋升，5 个帕鲁势力只能从敌对转为友好。
- 提供用户确认的人类势力关系查询、加入后的敌对外交覆盖、加入资格阻断和显式外交修复接口；人类势力数值好感支持受信事件增减、签名幂等、自动降级和权限回收，帕鲁势力仍禁止负向变更。权威后果路由可承接精确绑定的成员/平民伤害、任务失败/违约和战争后果。
- 提供固定市场自动外交修复：每个敌对来源需要 60 点、每个商业窗口最多 20 点，只接受成功且非负的固定市场交易，按来源逐个解除。
- 提供成员、核心成员、领队、领主四级身份，领队开始具备玩家护卫资格。
- 提供任务、防守与限额商业好感度接口，以及帕鲁和解、结局三条件。
- 提供有限帕鲁信物服务、Build 24467282 失效关闭袭击结算器，以及只接受粉丝内容包本地化键的离线论道树运行时。
- 提供内嵌 Agent 文件桥和外部操作入口：操作台自动启动本地 Ollama，当前论道中的自由文本经严格请求/回复白名单自动轮询进入既有对话面板；模型只能生成文本和建议白名单选择，`F3` 玩家确认前不能改变任何确定性状态。
- 提供七势力商业合同、原生购买成功桥接、需求品出售确认接口和商业重复结算保护。
- 提供独立 `faction_economy` 只读轻后端：商人商会为中立渠道，七个人类势力按整岛矿物资源量供应加工成品并采购短缺物资；同一商品的多个本地矿物输入使用最短板产能，已有商人出售的普通辅助输入只计入成本。
- 本机 1.0.1 已确认 9 种加工品的正式配方、内部物品 ID 和原生基础价格；9 种商品均可输出供货/采购方向，当前没有 `unresolved` 商品。
- 首版离线平衡档案 `pwft.economy.balance.supply_band_v1` 已能输出售价、库存、采购价和采购额度，并校验价格单调性、成本底线及 `1–99` 数量限制；该档案没有运行时商店修改权限。
- 四张原生 ItemShop DataTable 已离线追加 `7` 个商品组与 `7` 个抽选组，形成 `26` 条出售商品、`37` 条采购需求和 `63` 条完整市场信号；编译 UAsset、四次反向导出和含 `8` 个条目的未部署 PAK 均已通过专项验证。
- 新增 `faction_economy_shop_catalog` 只读服务；当前可执行基线的七个柜台都复用已实机验证的普通商人 `v04`，但分别绑定唯一 `PFT_Economy_*` 商品行，与独立的雷恩帕鲁商人特例分离。
- 新增 `faction_economy_merchant_runtime`：七名 ItemShop 商会员工消费 7 个唯一 `PFT_Economy_*` 行，登记代表势力并支持完整回收和失败逆序回滚；七柜台生产自动驻场、交互、网络商店绑定、连续开店及跨世界安全清理已实机通过，`Ctrl+F9` 集中测试生成保持关闭。
- 出售需求品以 `faction_economy` 供需信号为权威，`faction_commerce` 旧静态清单仅作兼容回退。
- 提供固定七势力市场和带护卫来访商队的配置化运行计划；正式七柜台驻场已启用，来访商队原生生成仍默认关闭。
- 七势力商人生命周期已覆盖雷恩现有商人登记、固定市场停用、商队事件防重复、关系转敌后的商人/护卫回收和商业桥清理。
- 提供原生商人/护卫蓝图生成适配器与七势力护卫提供器工厂；生产商会调用商人生成路线，护卫提供器仍按资格与显式流程使用。
- 出售流程可自动读取 `PalItemSlot` 的物品 ID/数量和 UI 接受结果；服务器成功信号确认前仍不结算。
- 提供势力 UI 数据模型和玩家可见适配器：仅在玩家主动按 `F5` 后创建专用 `WBP_PFT_FactionStatus`，显示 12 势力关系、好感、身份、商业外交修复、护卫和解锁门槛；再次按 `F5` 关闭。
- 提供保卫战临时友好/结算服务和领队护卫服务。
- 降到领队以下会通过统一变更回调撤回现役玩家护卫；内容包可用任务模板 `1.1` 声明人类势力、最低身份和最低好感门槛，失去权限时只暂停并保留任务进度，恢复资格后继续。
- 提供安全的 Mod 自有 JSON 旁路持久化设施；可靠世界／玩家身份确认后启用，身份
  未就绪时失败关闭，不写 Palworld 世界存档。
- 提供服务器权威多人会话底座：`K2_PostLogin/K2_OnLogout` 绑定精确控制器 UID，主机与每名远端玩家使用独立势力、A9 奖励和帕鲁和解侧车服务；重连复用同一玩家档案，换图先保存再清引用。`PWFT_MULTIPLAYER_PLAYER_SERVICES_V1` 可向当前／后加入玩家统一注册奖励频道与帕鲁内容并按 UID 结算；`PWFT_MULTIPLAYER_READ_MODEL_V1` 只发布严格匹配玩家和世界代际的只读 UI 快照。非权威客户端只读观察，未知控制器事件失败关闭，远端伤害、奖励或袭击战果不会误写主机档案。原生快照传输、真实第二客户端和无头独服仍需实机验收。
- 提供 `PalCharacterParameterComponent:OnDamage` 的精确目标伤害探针：只处理已登记 Defender、匹配组件 Owner、直接本地玩家和正 `ActualDamage`；同目标 5 秒去抖。当前证据来自旧 Build 24370881，Build 24575825 正式扣分保持关闭。
- 提供版本化公共接口，供后续粉丝任务、剧情、UI 和生成适配器调用：
  `_G.PWFT_FACTION_API_V1`、`_G.PWFT_FACTION_CONSEQUENCE_API_V1`、
  `_G.PWFT_FACTION_CONSEQUENCE_NATIVE_BINDING_V1`、
  `_G.PWFT_MULTIPLAYER_AUTHORITY_V1`、
  `_G.PWFT_MULTIPLAYER_NATIVE_BINDING_V1`、
  `_G.PWFT_COMMERCE_API_V1`、
  `_G.PWFT_ECONOMY_API_V1`、`_G.PWFT_ECONOMY_SHOP_API_V1`、
  `_G.PWFT_JOIN_API_V1`、
  `_G.PWFT_COMMERCE_BRIDGE_V1`、`_G.PWFT_DEFENSE_API_V1`、
  `_G.PWFT_GUARD_API_V1`、`_G.PWFT_MERCHANT_RUNTIME_V1`、
  `_G.PWFT_FACTION_UI_MODEL_V1`、`_G.PWFT_FACTION_UI_V1`；启用原生生成后还会导出
  `_G.PWFT_NATIVE_CHARACTER_ADAPTER_V1`。帕鲁机制另导出
  `_G.PWFT_PAL_RECONCILIATION_API_V1`、
  `_G.PWFT_PAL_RAID_RESULT_ADAPTER_V1` 与
  `_G.PWFT_PAL_DISCOURSE_API_V1`、`_G.PWFT_AGENT_DIALOGUE_BRIDGE_V1` 与
  `_G.PWFT_AGENT_DIALOGUE_OPERATOR_V1`；唯一帕鲁原生 Boss 接线另导出
  `_G.PWFT_UNIQUE_PAL_CAMPAIGN_V1` 与
  `_G.PWFT_UNIQUE_PAL_BOSS_PROVIDER_BUS_V1`、
  `_G.PWFT_UNIQUE_PAL_WORLD_EFFECT_BUS_V1`；商会柜台另导出
  `_G.PWFT_ECONOMY_MERCHANT_RUNTIME_V1`。
- 提供 `pwft.progress`、`pwft.factions`、`pwft.commerce` 和 `pwft.economy` 离线/开发诊断命令。

## 安全边界

- `enableMapOverlayMutation = true`
- `enableFastTravelEnforcement = true` only overrides Palworld's public
  `IsEnableFastTravel` query for mapped hostile territories; it never writes
  unlock flags, moves the player, or changes save data.
- `enableSaveWrites = false`
- 势力进度侧车已启用，但只在可靠世界/玩家身份键就绪后开放写入；身份未就绪时失败关闭。Build 24575825 已完成两次完整重启、主文件损坏后 `active:backup` 自愈和两个世界 profile 隔离实机验收。
- 势力进度 sidecar 载荷从 `1.0` 自动迁移到 `1.1`，保留未知扩展状态；任意控制台、客户端和 Ollama 文本均不能直接施加好感变更，旧 `pwft.progress grant` 已失败关闭。
- 原生伤害适配器不扫描世界，只接受精确 UObject 全路径与类身份一致的已登记目标。Build 24575825 已于 2026-08-25 完成真实服务器 NPC 伤害回调、玩家控制器 Pawn 归因和同一 Actor 多 Lua 包装器实机确认；当前 `probeEnabled=true`、`settlementEnabled=true`，其他构建仍按签名失败关闭。
- `nativeEconomyMerchantSpawnEnabled = true`；`FTPoint90` 泰拉瑞亚密域小岛已锁定为中立“商人商会”并从势力着色/敌对传送限制中剥离。七柜台商品资产、原生商店绑定、交互、生成、正式根坐标和朝向均已实机验收。正式运行时会在玩家接近商会时生成七柜台，离开较远后统一回收；`Ctrl+F9` 集中测试开关仍默认关闭。
- 原生 ItemShop 可以表达商品、售价与库存，但不能覆盖玩家出售价格；需求品奖励只在
  服务器出售请求与真实背包复制确认后结算，不伪造采购金币补差。
- 购买只在原生返回 `Successed` 后结算；出售数量没有在真实背包中下降时仍然失败关闭。
- 势力 UI 已具备无地图依赖的专用 UMG 资产和显式 `F5` 开关；显示、输入、刷新、
  关闭和分辨率已经实机通过。
- 正式加入已具备注册入口、外交预览、明确确认、过期邀请拦截和统一公共 API；原生交互界面归入后续玩家 UI 阶段。
- 帕鲁袭击结算只接受四成员全灭、玩家方胜利、确定性头领和本地玩家／所属帕鲁
  击杀归属；计时器清理、缺席和模糊归因不得结算。
- 离线论道树只保存结构和本地化键，不包含基座剧情；原生帕鲁代表交互与对话 UI 已实机通过。Ollama 自由文本链已完成源码、真实 provider、HTTP 和部署验证；基座默认不启用示例剧情包，因此“内容包代表 Actor 上显示一条模型回复”仍属于内容依赖的实机验收，而不是基座凭空生成 NPC 的职责。
- 不覆盖 `WBP_Map_Body`，不修改原 PAK，不触碰玩家存档。
- 犯罪提示 UI 仍不接入；当前证据不足以证明它能脱离犯罪状态安全展示。

## 下一道门槛

1. 商人商会 1.0 与势力进度侧车 B0 已完成；队形、朝向、自由漫步和采购金币补差不作为当前门槛。
2. 下一项不依赖剧情的集中实机是 B1 世界 80 级；必须分阶段启用并验证玩家以外目标、切图、刷新、Boss、商人和友军无误改。
3. 好感下降、身份降级、权限回收、三类权威后果 provider 与原生伤害 probe-only 适配器已完成纯开发和自动测试；下一道对应门槛是核验 Build 24575825 当前 Hook 与真实伤害来源，保持无扣分探针先验收，再经用户授权打开并验证旧 sidecar 迁移、护卫撤回、任务暂停/恢复、NPC/商人/UI 刷新实机闭环。
4. 唯一性帕鲁状态机、P1 Boss Provider 和 P2 世界效果／战争／赎回 Provider 已完成纯源码和自动测试；真实 species、Boss Actor、spawner、替换槽位、城市锚点、商会柜台、袭击、支付、Pal 交付与平衡数值仍须内容证据和实机授权。
5. 不以离线 PASS 代替实机结论；正式剧情、代表和精确 Actor 继续由内容包提供。

## 当前源码与历史部署

- 当前宿主 build：Steam `24575825`；数据合同来源 build：`24181527`。
- 玩家安装相对位置：`Pal/Binaries/Win64/ue4ss/Mods/PalFactionTerritory0`；完整步骤
  见仓库根目录 `INSTALL.md`。
- UE4SS：Palworld 专用 zDev 包；`MemberVariableLayout.ini` 已存在。
- 控制台：文本控制台关闭，GUI 开发控制台开启，便于首次观察且不启用额外通用作弊 Mod。
- 当前部署经本地安装审计确认：76 个记录文件与部署清单及当前源码哈希一致；原始日志与部署快照保留在私有验收区，不进入公开仓库。
- 商会生产驻场与恢复证据：`docs/48_商人商会生产驻场生命周期验收_2026-08-12.md`。

## PMK / UMG 当前状态

UE 5.1.1 与 VS 2022/MSVC 14.38 工具链已验证。专用
`WBP_PFT_FactionStatus` 从空白 `UUserWidget` 建立；层级只包含根画布、摘要容器和
文本控件，依赖扫描不包含旧地图 Widget。运行时复用已 Cook Widget 树，不采用曾
导致崩溃的 Lua 动态 UMG 构造。Cooked 资产不进入 source-only GitHub Release。
