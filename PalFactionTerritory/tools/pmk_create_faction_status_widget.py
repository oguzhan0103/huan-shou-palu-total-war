"""Create a blank dedicated faction-status Widget Blueprint in PMK.

The asset is deliberately created from ``UUserWidget`` rather than copied from
the legacy territory-map widget.  This keeps the relationship panel free of
map textures, map controls and map Blueprint dependencies.
"""

import unreal


TARGET_PATH = (
    "/Game/Mods/PalFactionTerritory0/UI/FactionStatus/"
    "WBP_PFT_FactionStatus"
)


def recreate_blank_and_open():
    if unreal.EditorAssetLibrary.does_asset_exist(TARGET_PATH):
        if not unreal.EditorAssetLibrary.delete_asset(TARGET_PATH):
            raise RuntimeError(f"failed to delete stale asset: {TARGET_PATH}")
        unreal.log(f"PFT_FACTION_STATUS_WIDGET_STALE_REMOVED {TARGET_PATH}")

    package_path, asset_name = TARGET_PATH.rsplit("/", 1)
    factory = unreal.WidgetBlueprintFactory()
    factory.set_editor_property("parent_class", unreal.UserWidget)
    target = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
        asset_name,
        package_path,
        unreal.WidgetBlueprint,
        factory,
    )
    if target is None:
        raise RuntimeError(f"failed to create blank widget: {TARGET_PATH}")

    unreal.EditorAssetLibrary.save_loaded_asset(target)
    unreal.log(f"PFT_FACTION_STATUS_WIDGET_BLANK_CREATED {TARGET_PATH}")

    editor_subsystem = unreal.get_editor_subsystem(
        unreal.AssetEditorSubsystem
    )
    editor_subsystem.open_editor_for_assets([target])
    unreal.log("PFT_FACTION_STATUS_WIDGET_EDITOR_OPENED")


recreate_blank_and_open()
