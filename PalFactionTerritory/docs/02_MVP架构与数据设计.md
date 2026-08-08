# MVP 架构与数据设计

## 1. 最小结构

```text
本体状态与资源
  ├─ 瞭望塔解锁状态
  ├─ 原地图 / 原迷雾 / 原区域遮罩
  ├─ 势力与人物文本
  └─ 公共传送点
          │
          ▼
Runtime Adapter（待实现，尽量薄）
  ├─ 读取当前塔区和解锁状态
  ├─ 接入地图打开/关闭与传送请求
  └─ 把关系变更转给 UI
          │
          ▼
Territory Core（已实现、无 UE 依赖）
  ├─ 稳定 ID 与数据校验
  ├─ 原始地图 / 势力版图模式
  ├─ 关系 → 颜色
  ├─ 敌对公共传送策略
  └─ 入境事件判定
```

第一版保持一个核心、一个运行时适配层和一组数据契约，不拆成地图、外交、传送、提示四个独立 Mod。

## 2. 稳定 ID

### 势力 ID

格式：`pwft.faction.<stable_slug>`。

示例：`pwft.faction.rayne_syndicate`。它是整合包内部稳定主键，不替换本体 Team/Group ID；运行时绑定单独记录并允许随游戏更新迁移。

### 领地 ID

格式：`pwft.territory.watchtower_<native_number>`，世界树保留原本后缀。

领地永久绑定本体 `WatchTower_*` ID。名称、塔主、遮罩或势力后来修订时，领地 ID 不变。

### 关系状态

只允许三态：

- `Hostile`：红色；公共传送禁用。
- `Friendly`：绿色；公共传送可用。
- `Neutral`：蓝色；公共传送可用。

未解锁不是第四种外交状态，而是地图可见性状态；继续由本体迷雾表达。

## 3. 数据契约

### `contracts/factions.v1.json`

只记录已在本体文本中确认的势力名称、原文键和可验证的运行时绑定。没有证据的 native binding 为 `null`。

### `contracts/tower_territories.v1.json`

包含 24 个瞭望塔 ID。字段包括：

- 本体塔 ID 与本体显示文本键。
- 本体中英名称。
- 所有势力、控制者／塔主。
- 本体遮罩资源路径。
- 绑定状态和证据引用。

当前只有 `WatchTower_1` 的所有者具备直接原文支撑：雷恩盗猎团以该塔为据点并掌控周边区域。其 `T_MapMask_a` 仍标为候选，需 `.usmap` 或 LiveView 确认。其他 23 个区域不凭地名猜所有者。

### 关系状态

运行时最小记录：

```json
{
  "factionId": "pwft.faction.rayne_syndicate",
  "state": "Hostile",
  "revision": 1
}
```

同一势力取 revision 最大的记录。后续模块只调用关系接口，不直接操作地图颜色。

## 4. 对外最小接口

未来运行时适配层只需要暴露：

- `GetRelation(factionId)`
- `SetRelation(factionId, state, reason)`
- `GetTerritoryByTower(nativeTowerId)`
- `GetTerritoryAtLocation(worldLocation)`
- `CanUsePublicFastTravel(destination)`
- `OnRelationChanged`
- `OnTerritoryEntered`

第一版不提供领土转移、扩张、城市耐久、商队或战争接口。

## 5. 地图行为

### 原始地图

- 默认模式。
- 不生成势力遮罩，不改原始图层可见性，不改迷雾。
- Mod 关闭或卸载后自然回到本体行为。

### 势力版图

- 对已解锁且完成绑定的区域，创建临时 UI Image。
- Image 引用本体 `M_WorldMapMaskPaint_FixedTexture`。
- `MaskTexture` 直接引用本体区域遮罩。
- `SelectionColor` 使用关系色。
- 未解锁区和未完成遮罩绑定的区域不绘制，原迷雾保持可见。

### 切换

复用本体地图切换控件的样式与输入语义，只增加一个必要标签“势力版图”；原地图名称继续使用本体 `WORLDMAP_NAME_MainMap_TextData`。不另做菜单或大面板。

## 6. 传送行为

判定目标是“公共传送”，不影响剧情强制传送、死亡重生、地牢出口或 Mod 未来自有传送。

必须覆盖两个入口：

1. 地图上选择巨鹫之像／传送点。
2. 场景内与公共传送对象交互。

目标领地未解锁时沿用本体限制；目标领地为敌对时返回 `hostile_territory`；其余关系允许。权威侧必须重复判定，避免客户端绕过。

## 7. 入境事件

### 入境地名展示（方案已定）

以本体 `PalPlayerCharacter.OnChangeRegionArea(RegionNameID)` 为唯一主触发。本体正是通过这条事件驱动 `WBP_PlayerUI:OnChangedRegion` 与 `WBP_IngamePlaceName` 显示地点卡片，因此不再为玩家实际进入领地额外叠加一张“危险提示”UI。

Mod 在该事件中仅做一次轻量查表：

`RegionNameID -> territoryId -> 领地所属势力 -> 该玩家当前关系 -> 地点卡片展示模型`

其中 `RegionNameID -> territoryId` 是独立交叉表，而不是修改本体地点表：一个势力领地可对应多个本体地名区；政治聚落等例外也在交叉表中覆盖地理归属。尚未完成实机核验的地点 ID 保持原版地点显示。

地图遮罩色、传送目标判定和地点卡片不是三张各自维护的表：它们都以同一条领地记录为事实源（原生遮罩、已核验的 `RegionNameID`、所属势力），再调用同一个关系展示模型取得敌对红、友好绿、中立蓝。

展示层复用原版 `WBP_IngamePlaceName` 的单张地点卡片，在同一次 UI 分发中改写其最终展示文本、颜色及必要的视觉样式；关系颜色固定为敌对红、友好绿、中立蓝。这样玩家只会看到一次地点播报，但能立即理解此处的势力关系。实际 Hook 时仍需验证本体动画不会在首帧覆盖颜色；如会覆盖，只在同一地点事件后补一次延迟重设，不使用轮询。

地图传送目标的危险提示属于另一条“传送前确认”路径，可继续独立存在；它不参与实体入境时的地点播报。

不会借用犯罪系统，也不会改变 `Wanted`、`CrimeIds`、犯罪 HUD 或自卫队生成逻辑。坐标/区域遮罩只作为没有可用 `RegionNameID` 的特殊区域的后备方案，不作为常规检测机制。
