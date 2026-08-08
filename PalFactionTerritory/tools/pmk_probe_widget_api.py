"""Read-only Unreal Python API probe for the faction UI asset builder."""

import unreal


def report(owner, tokens):
    names = [
        name
        for name in dir(owner)
        if any(token in name.lower() for token in tokens)
    ]
    unreal.log(
        "[PWFT_UI_PROBE] {}={}".format(
            getattr(owner, "__name__", type(owner).__name__),
            ",".join(sorted(names)),
        )
    )


for class_name, tokens in (
    ("CanvasPanel", ("add", "child", "slot")),
    ("VerticalBox", ("add", "child", "slot")),
    ("TextBlock", ("text", "font", "color", "variable")),
    (
        "CanvasPanelSlot",
        ("anchor", "offset", "position", "size", "alignment"),
    ),
):
    owner = getattr(unreal, class_name, None)
    unreal.log(
        "[PWFT_UI_PROBE] CLASS_{}={}".format(
            class_name,
            owner,
        )
    )
    if owner is not None:
        report(owner, tokens)

widget = unreal.load_asset(
    "/Game/Mods/PalFactionTerritory0/UI/WBP_PFT_TerritoryMap"
)
unreal.log("[PWFT_UI_PROBE] EXISTING_WIDGET={}".format(widget))
if widget is not None:
    for prop in (
        "widget_tree",
        "generated_class",
        "parent_class",
    ):
        try:
            unreal.log(
                "[PWFT_UI_PROBE] PROP_{}={}".format(
                    prop,
                    widget.get_editor_property(prop),
                )
            )
        except Exception as error:
            unreal.log(
                "[PWFT_UI_PROBE] PROP_{}_ERROR={}".format(
                    prop,
                    error,
                )
            )
    try:
        widget_tree = widget.get_editor_property("widget_tree")
        unreal.log(
            "[PWFT_UI_PROBE] WIDGET_TREE_TYPE={}".format(
                type(widget_tree)
            )
        )
        report(
            widget_tree,
            ("construct", "root", "widget", "find"),
        )
        unreal.log(
            "[PWFT_UI_PROBE] ROOT_WIDGET={}".format(
                widget_tree.get_editor_property("root_widget")
            )
        )
    except Exception as error:
        unreal.log(
            "[PWFT_UI_PROBE] WIDGET_TREE_ERROR={}".format(
                error
            )
        )
