"""Read-only probe for the dedicated faction-status Widget layout.

Print the generated widget hierarchy, slot layout, Z-order, visibility and
text-style properties that can explain a background control covering the
summary text at runtime.
"""

import unreal


WIDGET_PATH = (
    "/Game/Mods/PalFactionTerritory0/UI/FactionStatus/"
    "WBP_PFT_FactionStatus"
)


def value(obj, name):
    try:
        return obj.get_editor_property(name)
    except Exception as exc:
        return f"<unavailable:{exc}>"


def describe(widget):
    slot = value(widget, "slot")
    details = {
        "name": widget.get_name(),
        "class": widget.get_class().get_name(),
        "visibility": str(value(widget, "visibility")),
        "slotClass": (
            slot.get_class().get_name()
            if isinstance(slot, unreal.Object)
            else str(slot)
        ),
    }
    if isinstance(slot, unreal.Object):
        for name in (
            "layout_data",
            "z_order",
            "horizontal_alignment",
            "vertical_alignment",
            "padding",
        ):
            details[name] = str(value(slot, name))
    for name in (
        "text",
        "color_and_opacity",
        "font",
        "default_text_style_override",
        "default_text_style",
        "auto_wrap_text",
    ):
        result = value(widget, name)
        if not str(result).startswith("<unavailable:"):
            details[name] = str(result)
    unreal.log(
        "[PFT_WIDGET_LAYOUT] "
        + " ".join(f"{key}={item}" for key, item in details.items())
    )


def main():
    blueprint = unreal.load_asset(WIDGET_PATH)
    if blueprint is None:
        raise RuntimeError(f"missing widget blueprint: {WIDGET_PATH}")
    generated_class = unreal.EditorAssetLibrary.load_blueprint_class(
        WIDGET_PATH
    )
    if generated_class is None:
        raise RuntimeError(f"missing generated class: {WIDGET_PATH}")
    cdo = unreal.get_default_object(generated_class)
    unreal.log(
        "[PFT_WIDGET_LAYOUT] "
        f"blueprint={blueprint.get_full_name()} "
        f"class={generated_class.get_full_name()} "
        f"cdo={cdo.get_full_name()}"
    )
    for name in (
        "CanvasPanel_1",
        "BTN_FactionSummary",
        "TXT_FactionSummary",
    ):
        widget = value(cdo, name)
        if not isinstance(widget, unreal.Object):
            unreal.log(
                f"[PFT_WIDGET_LAYOUT] name={name} object={widget}"
            )
            continue
        describe(widget)
    unreal.log("[PFT_WIDGET_LAYOUT] PASS")


main()
