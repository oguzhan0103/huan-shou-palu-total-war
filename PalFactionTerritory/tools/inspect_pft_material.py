import unreal


MATERIAL_PATH = "/Game/Mods/PalFactionTerritory0/UI/Materials/M_PFT_NativeMapLayerProbe"


def inspect_input(expression, name):
    try:
        value = expression.get_editor_property(name)
        unreal.log("[PFT_MATERIAL_INSPECT] {}.{}={}".format(expression.get_class().get_name(), name, value))
    except Exception as exc:
        unreal.log("[PFT_MATERIAL_INSPECT] {}.{} unavailable={}".format(expression.get_class().get_name(), name, exc))


material = unreal.load_asset(MATERIAL_PATH)
if material is None:
    raise RuntimeError("material missing: {}".format(MATERIAL_PATH))

for expression in material.get_editor_property("expressions"):
    class_name = expression.get_class().get_name()
    if class_name in {
        "MaterialExpressionSaturate",
        "MaterialExpressionDivide",
        "MaterialExpressionMax",
        "MaterialExpressionMultiply",
    }:
        unreal.log("[PFT_MATERIAL_INSPECT] expression={} object={}".format(class_name, expression.get_name()))
        for input_name in ("input", "a", "b"):
            inspect_input(expression, input_name)

unreal.log("[PFT_MATERIAL_INSPECT] complete")
