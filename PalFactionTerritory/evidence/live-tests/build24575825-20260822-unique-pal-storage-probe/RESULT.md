# 唯一帕鲁原生交付：Build 24575825 仓库只读探针

- 时间：2026-08-22 16:49:41 +08:00
- 游戏：Steam Build 24575825，标题版本 `v1.0.3.101283`
- 范围：本地单人 QA 世界，只读帕鲁仓库对象链
- 结论：**PASS（仅仓库容量和空槽回读）**

## 实机返回

```text
[UniquePalNativeDeliveryProbe] STORAGE_READBACK_OK generation=4 pages=32 emptyPage=6 emptySlot=191 capacity=true mutation=false
UNIQUE_PAL_NATIVE_DELIVERY_PROBE_RESULT attempt=1 ok=true reason=native-delivery-storage-capacity-confirmed generation=4 readOnly=true mutation=false
```

已在真实世界内成功解析并读取：

- `PalPlayerController -> PalPlayerState`
- `PalPlayerState:GetPalStorage()`
- `PalPlayerDataPalStorage:GetPageNum()`
- `PalPlayerDataPalStorage:GetPageIndexExistEmptySlot(0)`
- `PalPlayerDataPalStorage.TargetContainer`
- `PalIndividualCharacterContainer:FindEmptySlot()`
- `PalIndividualCharacterSlot:IsEmpty/GetSlotIndex/GetSlotId`

## 边界

- 本探针没有生成帕鲁，没有调用 `PalCaptureSuccess`，没有直接增删改仓库容器。
- 没有验证“捕获后精确个体 ID 回读”，因此原生捕获交付仍然保持失败关闭。
- 进入游戏世界可能触发游戏自身的正常自动保存；本结论只声明探针本身没有保存写路径。

## 原始日志身份

- 相对安装路径：`Pal/Binaries/Win64/ue4ss/UE4SS.log`
- 退出后大小：`309642` bytes
- SHA-256：`A1D5A0C6DAF47BEE4892D2155D3126898973FF56AB20C0A7BFDA1B02B0D25A11`
