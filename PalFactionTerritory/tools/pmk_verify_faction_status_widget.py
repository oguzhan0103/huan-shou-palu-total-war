"""Read-only PMK verification for the dedicated faction-status Widget."""

import unreal


TARGET_PATH = (
    "/Game/Mods/PalFactionTerritory0/UI/FactionStatus/"
    "WBP_PFT_FactionStatus"
)
FORBIDDEN_REFERENCE_TOKENS = (
    "PFT_Main_Original",
    "PFT_Main_Territory",
    "PFT_Tree_Original",
    "PFT_Tree_Territory",
    "WBP_PFT_TerritoryMap",
)


def main():
    target = unreal.load_asset(TARGET_PATH)
    if target is None:
        raise RuntimeError(f"missing faction status widget: {TARGET_PATH}")

    registry = unreal.AssetRegistryHelpers.get_asset_registry()
    options = unreal.AssetRegistryDependencyOptions(
        include_soft_package_references=True,
        include_hard_package_references=True,
        include_searchable_names=True,
        include_soft_management_references=True,
        include_hard_management_references=True,
    )
    dependencies = [
        str(value)
        for value in registry.get_dependencies(
            unreal.Name(TARGET_PATH),
            options,
        )
    ]
    forbidden = [
        dependency
        for dependency in dependencies
        if any(
            token.lower() in dependency.lower()
            for token in FORBIDDEN_REFERENCE_TOKENS
        )
    ]
    if forbidden:
        raise RuntimeError(
            "legacy map references remain: {}".format(
                ", ".join(forbidden)
            )
        )

    unreal.log(
        "PFT_FACTION_STATUS_WIDGET_VERIFIED "
        f"path={TARGET_PATH} dependencies={len(dependencies)}"
    )


main()
