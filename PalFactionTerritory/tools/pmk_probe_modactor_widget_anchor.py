"""Read-only PMK probe for anchoring the faction-status widget class."""

import unreal


MOD_ACTOR_PATH = "/Game/Mods/PalFactionTerritory0/ModActor"
WIDGET_PATH = (
    "/Game/Mods/PalFactionTerritory0/UI/FactionStatus/"
    "WBP_PFT_FactionStatus"
)


def report_api(label, owner, tokens):
    names = sorted(
        name
        for name in dir(owner)
        if any(token in name.lower() for token in tokens)
    )
    unreal.log("[PWFT_ANCHOR_PROBE] {}={}".format(label, ",".join(names)))


mod_actor = unreal.load_asset(MOD_ACTOR_PATH)
widget = unreal.load_asset(WIDGET_PATH)
unreal.log("[PWFT_ANCHOR_PROBE] MOD_ACTOR={}".format(mod_actor))
unreal.log("[PWFT_ANCHOR_PROBE] WIDGET={}".format(widget))

if widget is not None:
    try:
        unreal.log(
            "[PWFT_ANCHOR_PROBE] WIDGET_GENERATED_CLASS={}".format(
                widget.get_editor_property("generated_class")
            )
        )
    except Exception as error:
        unreal.log(
            "[PWFT_ANCHOR_PROBE] WIDGET_GENERATED_CLASS_ERROR={}".format(
                error
            )
        )

for loader_name, loader in (
    (
        "editor_asset_library",
        lambda: unreal.EditorAssetLibrary.load_blueprint_class(WIDGET_PATH),
    ),
    (
        "load_class",
        lambda: unreal.load_class(
            None,
            "{}.{}_C".format(WIDGET_PATH, WIDGET_PATH.rsplit("/", 1)[-1]),
        ),
    ),
):
    try:
        widget_class = loader()
        unreal.log(
            "[PWFT_ANCHOR_PROBE] WIDGET_CLASS loader={} value={}".format(
                loader_name,
                widget_class,
            )
        )
    except Exception as error:
        unreal.log(
            "[PWFT_ANCHOR_PROBE] WIDGET_CLASS_ERROR loader={} error={}".format(
                loader_name,
                error,
            )
        )

try:
    transient_component = unreal.new_object(unreal.WidgetComponent)
    unreal.log(
        "[PWFT_ANCHOR_PROBE] TRANSIENT_WIDGET_COMPONENT={}".format(
            transient_component
        )
    )
    for property_name in (
        "widget_class",
        "hidden_in_game",
        "visible",
        "tick_mode",
    ):
        try:
            value = transient_component.get_editor_property(property_name)
            unreal.log(
                "[PWFT_ANCHOR_PROBE] WIDGET_COMPONENT_PROPERTY "
                "name={} value={}".format(property_name, value)
            )
        except Exception as error:
            unreal.log(
                "[PWFT_ANCHOR_PROBE] WIDGET_COMPONENT_PROPERTY_ERROR "
                "name={} error={}".format(property_name, error)
            )
except Exception as error:
    unreal.log(
        "[PWFT_ANCHOR_PROBE] TRANSIENT_WIDGET_COMPONENT_ERROR={}".format(
            error
        )
    )

subsystem_class = getattr(unreal, "SubobjectDataSubsystem", None)
params_class = getattr(unreal, "AddNewSubobjectParams", None)
library_class = getattr(
    unreal,
    "SubobjectDataBlueprintFunctionLibrary",
    None,
)
widget_component_class = getattr(unreal, "WidgetComponent", None)

unreal.log(
    "[PWFT_ANCHOR_PROBE] TYPES subsystem={} params={} library={} "
    "widgetComponent={}".format(
        subsystem_class,
        params_class,
        library_class,
        widget_component_class,
    )
)

if subsystem_class is not None:
    report_api(
        "SUBSYSTEM_API",
        subsystem_class,
        ("subobject", "gather", "rename", "attach"),
    )
if params_class is not None:
    report_api(
        "PARAMS_API",
        params_class,
        ("class", "parent", "blueprint"),
    )
if library_class is not None:
    report_api(
        "LIBRARY_API",
        library_class,
        ("data", "object", "name"),
    )
if widget_component_class is not None:
    report_api(
        "WIDGET_COMPONENT_API",
        widget_component_class,
        ("widget", "visibility", "tick", "hidden"),
    )

if mod_actor is not None and subsystem_class is not None:
    subsystem = unreal.get_engine_subsystem(subsystem_class)
    handles = subsystem.k2_gather_subobject_data_for_blueprint(mod_actor)
    unreal.log(
        "[PWFT_ANCHOR_PROBE] MOD_ACTOR_HANDLES={}".format(len(handles))
    )
    if library_class is not None:
        for index, handle in enumerate(handles):
            try:
                data = library_class.get_data(handle)
                obj = library_class.get_object(data)
                unreal.log(
                    "[PWFT_ANCHOR_PROBE] HANDLE index={} object={}".format(
                        index,
                        obj,
                    )
                )
            except Exception as error:
                unreal.log(
                    "[PWFT_ANCHOR_PROBE] HANDLE_ERROR index={} error={}".format(
                        index,
                        error,
                    )
                )
