"""Create or repair the PMK packaging label for PalFactionTerritory0.

Run this from Unreal Editor's Tools > Execute Python Script.  It is deliberately
idempotent: rerunning it only repairs the same label instead of creating a
second asset.  The label is a build-time packaging marker, not runtime logic.
"""

import unreal


DESTINATION = "/Game/Mods/PalFactionTerritory0"
LABEL_NAME = "PAL_PalFactionTerritory0"
LABEL_PATH = f"{DESTINATION}/{LABEL_NAME}"
CHUNK_ID = 1001


def main():
    editor_assets = unreal.EditorAssetLibrary
    label = (
        editor_assets.load_asset(LABEL_PATH)
        if editor_assets.does_asset_exist(LABEL_PATH)
        else None
    )

    if not label:
        # UE 5.1 does not expose PrimaryAssetLabelFactory to Python.  A
        # DataAssetFactory targeting PrimaryAssetLabel is the supported
        # generic route for this editor version.
        factory = unreal.DataAssetFactory()
        factory.set_editor_property("data_asset_class", unreal.PrimaryAssetLabel)
        label = unreal.AssetToolsHelpers.get_asset_tools().create_asset(
            LABEL_NAME,
            DESTINATION,
            unreal.PrimaryAssetLabel,
            factory,
        )

    if not label:
        raise RuntimeError(f"Could not create or load {LABEL_PATH}")

    label.set_editor_property("label_assets_in_my_directory", True)
    label.set_editor_property("is_runtime_label", False)

    rules = label.get_editor_property("rules")
    rules.set_editor_property("chunk_id", CHUNK_ID)
    rules.set_editor_property("cook_rule", unreal.PrimaryAssetCookRule.ALWAYS_COOK)
    label.set_editor_property("rules", rules)

    if not editor_assets.save_loaded_asset(label, only_if_is_dirty=False):
        raise RuntimeError(f"Failed to save {LABEL_PATH}")

    unreal.log(
        "PalFactionTerritory0 label ready: "
        f"{LABEL_PATH}; directory=true; chunk={CHUNK_ID}; cook=AlwaysCook"
    )


if __name__ == "__main__":
    main()
