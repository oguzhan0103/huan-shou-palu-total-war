"""Anchor the faction-status Widget class in ModActor for runtime discovery.

The component stays invisible and does not add the Widget to the viewport.
Its only purpose is to keep a hard class reference in the cooked ModActor.
"""

import unreal


MOD_ACTOR_PATH = "/Game/Mods/PalFactionTerritory0/ModActor"
WIDGET_PATH = (
    "/Game/Mods/PalFactionTerritory0/UI/FactionStatus/"
    "WBP_PFT_FactionStatus"
)
ANCHOR_NAME = "PFT_FactionStatusWidgetAnchor"
PREFIX = "[PWFT_WIDGET_ANCHOR]"


def log(message):
    unreal.log("{} {}".format(PREFIX, message))


def fail(message):
    unreal.log_error("{} {}".format(PREFIX, message))
    raise RuntimeError(message)


def object_name(obj):
    if obj is None:
        return ""
    try:
        return str(obj.get_name())
    except Exception:
        return str(obj)


mod_actor = unreal.load_asset(MOD_ACTOR_PATH)
if mod_actor is None:
    fail("missing ModActor: {}".format(MOD_ACTOR_PATH))

widget_class = unreal.EditorAssetLibrary.load_blueprint_class(WIDGET_PATH)
if widget_class is None:
    fail("missing Widget generated class: {}".format(WIDGET_PATH))

subsystem = unreal.get_engine_subsystem(unreal.SubobjectDataSubsystem)
library = unreal.SubobjectDataBlueprintFunctionLibrary
handles = subsystem.k2_gather_subobject_data_for_blueprint(mod_actor)
if not handles:
    fail("ModActor exposes no subobject handles")

anchor_handle = None
anchor_component = None
scene_root_handle = None

for handle in handles:
    data = library.get_data(handle)
    obj = library.get_object(data)
    name = object_name(obj)
    if isinstance(obj, unreal.SceneComponent) and scene_root_handle is None:
        scene_root_handle = handle
    if ANCHOR_NAME in name:
        anchor_handle = handle
        anchor_component = obj
        break

created = False
if anchor_component is None:
    parent_handle = scene_root_handle or handles[0]
    params = unreal.AddNewSubobjectParams(
        parent_handle=parent_handle,
        new_class=unreal.WidgetComponent,
        blueprint_context=mod_actor,
        skip_mark_blueprint_modified=False,
    )
    anchor_handle, fail_reason = subsystem.add_new_subobject(params=params)
    try:
        library.get_data(anchor_handle)
    except Exception as error:
        fail(
            "add_new_subobject failed: {}; {}".format(
                fail_reason,
                error,
            )
        )
    subsystem.rename_subobject(
        handle=anchor_handle,
        new_name=unreal.Text(ANCHOR_NAME),
    )
    data = library.get_data(anchor_handle)
    anchor_component = library.get_object(data)
    created = True

if not isinstance(anchor_component, unreal.WidgetComponent):
    fail(
        "anchor has unexpected class: {}".format(
            anchor_component.get_class() if anchor_component else None
        )
    )

anchor_component.set_editor_property("widget_class", widget_class)
anchor_component.set_editor_property("visible", False)
anchor_component.set_editor_property("hidden_in_game", True)

for enum_name in ("WidgetTickMode", "TickMode"):
    enum_type = getattr(unreal, enum_name, None)
    if enum_type is not None and hasattr(enum_type, "DISABLED"):
        anchor_component.set_editor_property("tick_mode", enum_type.DISABLED)
        break
else:
    log("tick_mode enum unavailable; visibility guards remain active")

unreal.BlueprintEditorLibrary.compile_blueprint(mod_actor)
if not unreal.EditorAssetLibrary.save_loaded_asset(mod_actor, only_if_is_dirty=False):
    fail("failed to save ModActor")

verified_handles = subsystem.k2_gather_subobject_data_for_blueprint(mod_actor)
verified_by_name = {}
for handle in verified_handles:
    data = library.get_data(handle)
    obj = library.get_object(data)
    name = object_name(obj)
    if ANCHOR_NAME in name:
        verified_by_name[name] = obj

if len(verified_by_name) != 1:
    fail(
        "expected one unique anchor after save, found {} ({})".format(
            len(verified_by_name),
            ",".join(sorted(verified_by_name)),
        )
    )

verified_anchor = next(iter(verified_by_name.values()))
if verified_anchor.get_editor_property("widget_class") != widget_class:
    fail("saved anchor Widget class does not match")
if verified_anchor.get_editor_property("visible"):
    fail("saved anchor must be invisible")
if not verified_anchor.get_editor_property("hidden_in_game"):
    fail("saved anchor must be hidden in game")

log(
    "PASS action={} component={} widgetClass={} visible={} hiddenInGame={} "
    "tickMode={}".format(
        "created" if created else "updated",
        object_name(verified_anchor),
        verified_anchor.get_editor_property("widget_class"),
        verified_anchor.get_editor_property("visible"),
        verified_anchor.get_editor_property("hidden_in_game"),
        verified_anchor.get_editor_property("tick_mode"),
    )
)
