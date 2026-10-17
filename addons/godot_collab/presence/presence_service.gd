@tool
## Presence service: captures the local cursor (3D viewport or 2D view),
## throttles/sends it, stores remote cursors and paints the 2D cursors onto the
## editor's 2D viewport overlay. 3D remote cursors and avatars are visualised by
## [CollabMarkerManager].
class_name CollabPresenceService
extends Node

signal status(text: String)

const CURSOR_FRAMES_PATH: String = "res://addons/godot_collab/assets/cursor_sprites.tres"

## Mouse buttons that turn the cursor into the "grab" animation.
const GRAB_MASK: int = (
	MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT | MOUSE_BUTTON_MASK_MIDDLE
)

var cursor_state: CollabCursorState

var _coordinator: CollabSessionCoordinator
var _settings: CollabSettings
var _logs: CollabLog
var _last_send_ms: int = 0
var _visible: bool = true
var _show_labels: bool = true
var _cursor_2d_scale: float = 1.0
var _local_scene_id: String = ""
var _local_has_cursor: bool = false
var _local_world: Vector3 = Vector3.ZERO
var _font: Font = null

# Local 3D capture.
var _camera: Camera3D = null
var _mouse_pos: Vector2 = Vector2.ZERO
var _viewport_size: Vector2 = Vector2.ONE

# Local 2D capture.
var _canvas_pos: Vector2 = Vector2.ZERO
var _viewport_2d_pos: Vector2 = Vector2(0.5, 0.5)

# Shared.
var _view_mode: String = CollabConstants.CURSOR_VIEW_3D
var _last_motion_ms: int = 0
var _button_mask: int = 0

var _drag_data_provider: Callable = Callable()
var _cursor_frames: SpriteFrames = null


func _init() -> void:
	cursor_state = CollabCursorState.new()


func setup(coordinator: CollabSessionCoordinator, settings: CollabSettings, logs: CollabLog) -> void:
	_coordinator = coordinator
	_settings = settings
	_logs = logs
	_apply_settings()
	coordinator.cursor_received.connect(_on_remote_cursor)
	coordinator.session_stopped.connect(_on_session_stopped)
	if _font == null:
		_font = ThemeDB.fallback_font


func _apply_settings() -> void:
	if _settings == null:
		return
	_show_labels = _settings.get_bool(CollabSettings.KEY_CURSOR_LABEL_KEY, true)
	var size: float = _settings.get_float(CollabSettings.KEY_CURSOR_SIZE_KEY, 8.0)
	_cursor_2d_scale = clampf(size / 8.0, 0.25, 8.0)
	cursor_state.set_marker_depth(_settings.get_float(CollabSettings.KEY_CURSOR_DEPTH_KEY, 12.0))


func set_local_scene_id(scene_id: String) -> void:
	_local_scene_id = scene_id


func set_visible(visible: bool) -> void:
	_visible = visible


func set_show_labels(show: bool) -> void:
	_show_labels = show


func set_marker_size(size: float) -> void:
	_cursor_2d_scale = clampf(size / 8.0, 0.25, 8.0)


func set_marker_depth(depth: float) -> void:
	cursor_state.set_marker_depth(depth)


func set_drag_data_provider(provider: Callable) -> void:
	_drag_data_provider = provider


func local_world_position() -> Vector3:
	return _local_world


# --- local capture --------------------------------------------------------

## Called by the plugin from _forward_3d_gui_input on mouse motion. Only records
## the sample; the throttled send happens in [method tick_local] so the remote
## cursor keeps updating (and relaxing to idle) even while the mouse is still.
func sample_local_cursor(camera: Camera3D, mouse_pos: Vector2, viewport_size: Vector2, scene_id: String, button_mask: int = 0) -> void:
	if camera == null:
		return
	_camera = camera
	_mouse_pos = mouse_pos
	_viewport_size = viewport_size
	_local_scene_id = scene_id
	_button_mask = button_mask
	_view_mode = CollabConstants.CURSOR_VIEW_3D
	_last_motion_ms = Time.get_ticks_msec()
	_local_has_cursor = true


## Called by the plugin from _forward_canvas_gui_input on mouse motion.
func sample_local_cursor_2d(canvas_pos: Vector2, viewport_pos: Vector2, scene_id: String, button_mask: int = 0) -> void:
	_canvas_pos = canvas_pos
	_viewport_2d_pos = viewport_pos
	_local_scene_id = scene_id
	_button_mask = button_mask
	_view_mode = CollabConstants.CURSOR_VIEW_2D
	_last_motion_ms = Time.get_ticks_msec()
	_local_has_cursor = true


## Refreshes the held-button state from a mouse button press/release event so the
## cursor animation reflects a click even while the mouse is not moving.
func note_local_button(button_mask: int) -> void:
	_button_mask = button_mask
	_last_motion_ms = Time.get_ticks_msec()


## Called every frame by the plugin. Sends the local cursor on a fixed cadence
## while a session is active, so remote peers always have a fresh position and
## the correct animation (idle/hover/grab/file-drag).
func tick_local() -> void:
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	if not _local_has_cursor:
		return
	var now: int = Time.get_ticks_msec()
	var interval_ms: int = int(1000.0 / CollabConstants.CURSOR_SEND_HZ)
	if now - _last_send_ms < interval_ms:
		return
	if _view_mode == CollabConstants.CURSOR_VIEW_2D:
		_last_send_ms = now
		_send_2d(now)
	elif _send_3d(now):
		_last_send_ms = now


func _send_3d(now: int) -> bool:
	if _camera == null or not is_instance_valid(_camera):
		return false
	var origin: Vector3 = _camera.project_ray_origin(_mouse_pos)
	var direction: Vector3 = _camera.project_ray_normal(_mouse_pos)
	var normalized: Vector2 = Vector2(
		clampf(_mouse_pos.x / maxf(1.0, _viewport_size.x), 0.0, 1.0),
		clampf(_mouse_pos.y / maxf(1.0, _viewport_size.y), 0.0, 1.0)
	)
	_local_world = origin + direction.normalized() * cursor_state.marker_depth
	_coordinator.send_cursor({
		"view": CollabConstants.CURSOR_VIEW_3D,
		"camera_transform": _camera.global_transform,
		"ray_origin": origin,
		"ray_direction": direction,
		"viewport_pos": normalized,
		"scene_id": _local_scene_id,
		"anim": _current_anim(now),
		"time_ms": now,
	})
	return true


func _send_2d(now: int) -> void:
	_coordinator.send_cursor({
		"view": CollabConstants.CURSOR_VIEW_2D,
		"canvas_pos": _canvas_pos,
		"viewport_pos": _viewport_2d_pos,
		"scene_id": _local_scene_id,
		"anim": _current_anim(now),
		"time_ms": now,
	})


## Picks the animation name for the local cursor: a file drag wins over a mouse
## button, which wins over recent motion. Anything else relaxes to idle.
func _current_anim(now: int) -> String:
	var file: String = _file_drag_animation(_drag_data())
	if not file.is_empty():
		return file
	if _button_mask & GRAB_MASK != 0:
		return CollabConstants.CURSOR_ANIM_GRAB
	var hold_ms: int = int(CollabConstants.CURSOR_HOVER_HOLD_SECONDS * 1000.0)
	if now - _last_motion_ms <= hold_ms:
		return CollabConstants.CURSOR_ANIM_HOVER
	return CollabConstants.CURSOR_ANIM_IDLE


func _drag_data() -> Variant:
	if not _drag_data_provider.is_valid():
		return null
	return _drag_data_provider.call()


## Classifies an active editor drag-and-drop payload into a file-cursor
## animation. The editor's drag data is an undocumented dictionary; we probe the
## common keys for resources and file paths and stay silent when nothing
## recognisable is present.
func _file_drag_animation(data: Variant) -> String:
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	var dict: Dictionary = data
	var kinds: Dictionary = {}
	var single: Variant = dict.get("resource", null)
	if single is Resource:
		kinds[_classify_resource(single)] = true
	var resources: Variant = dict.get("resources", null)
	if typeof(resources) == TYPE_ARRAY:
		for item in resources:
			if item is Resource:
				kinds[_classify_resource(item)] = true
	var files: Variant = dict.get("files", null)
	if typeof(files) == TYPE_PACKED_STRING_ARRAY:
		for path in files:
			kinds[_classify_path(str(path))] = true
	if kinds.has("script"):
		return CollabConstants.CURSOR_ANIM_FILE_SCRIPT
	if kinds.has("material"):
		return CollabConstants.CURSOR_ANIM_FILE_MATERIAL
	if kinds.has("object"):
		return CollabConstants.CURSOR_ANIM_FILE_OBJECT
	return ""


func _classify_resource(resource: Resource) -> String:
	if resource is Script:
		return "script"
	if resource is Material or resource is Texture2D:
		return "material"
	return "object"


func _classify_path(path: String) -> String:
	match path.get_extension().to_lower():
		"gd", "gdshader", "gdshaderinc", "shader", "cs":
			return "script"
		"material", "png", "jpg", "jpeg", "webp", "bmp", "tga", "svg", "hdr", "exr", "dds", "ktx":
			return "material"
		_:
			return "object"


func _on_remote_cursor(peer_id: int, payload: Dictionary) -> void:
	if _coordinator == null or peer_id == _coordinator.local_peer_id():
		return
	var view: String = str(payload.get("view", CollabConstants.CURSOR_VIEW_3D))
	var scene: String = str(payload.get("scene_id", ""))
	var anim: String = str(payload.get("anim", CollabConstants.CURSOR_ANIM_IDLE))
	var viewport_pos: Vector2 = _vector2(payload.get("viewport_pos", null), Vector2(0.5, 0.5))
	if view == CollabConstants.CURSOR_VIEW_2D:
		var canvas: Vector2 = _vector2(payload.get("canvas_pos", null), Vector2.ZERO)
		cursor_state.update_2d(peer_id, canvas, viewport_pos, scene, anim)
		return
	var origin: Variant = payload.get("ray_origin", null)
	var direction: Variant = payload.get("ray_direction", null)
	if typeof(origin) != TYPE_VECTOR3 or typeof(direction) != TYPE_VECTOR3:
		return
	var camera_transform: Transform3D = Transform3D.IDENTITY
	var ct: Variant = payload.get("camera_transform", null)
	if typeof(ct) == TYPE_TRANSFORM3D:
		camera_transform = ct
	cursor_state.update(peer_id, camera_transform, origin, direction, viewport_pos, scene, anim)


func _vector2(value: Variant, fallback: Vector2) -> Vector2:
	return value if typeof(value) == TYPE_VECTOR2 else fallback


func _on_session_stopped(_reason: String) -> void:
	cursor_state.clear()
	_local_has_cursor = false
	_camera = null


# --- drawing --------------------------------------------------------------

## Paints remote 2D cursors onto the 2D viewport overlay. [param overlay] is the
## control provided by EditorPlugin._forward_canvas_draw_over_viewport.
func draw_overlay_2d(overlay: Control) -> void:
	if not _visible or _coordinator == null or not _coordinator.session_manager.is_active():
		return
	var viewport_2d: SubViewport = _editor_viewport_2d()
	if viewport_2d == null or overlay == null:
		return
	var canvas_transform: Transform2D = viewport_2d.get_canvas_transform()
	var now: int = Time.get_ticks_msec()
	for participant in _coordinator.registry.all():
		var peer_id: int = participant.peer_id
		if peer_id == _coordinator.local_peer_id():
			continue
		if not cursor_state.has(peer_id) or cursor_state.is_stale(peer_id, now):
			continue
		if cursor_state.view(peer_id) != CollabConstants.CURSOR_VIEW_2D:
			continue
		var remote_scene: String = cursor_state.scene_id(peer_id)
		if not remote_scene.is_empty() and not _local_scene_id.is_empty() and remote_scene != _local_scene_id:
			continue
		var screen: Vector2 = canvas_transform * cursor_state.canvas_pos(peer_id)
		if screen.x < 0.0 or screen.y < 0.0 or screen.x > overlay.size.x or screen.y > overlay.size.y:
			continue
		_draw_cursor_2d(overlay, screen, cursor_state.anim(peer_id), participant.color(), participant.display_name(), now)


func _draw_cursor_2d(overlay: Control, screen: Vector2, anim: String, color: Color, label: String, now: int) -> void:
	var tint: Color = Color(color.r, color.g, color.b, 1.0)
	var texture: Texture2D = _cursor_texture(anim, now)
	if texture != null:
		var size: Vector2 = texture.get_size() * _cursor_2d_scale
		overlay.draw_texture_rect(texture, Rect2(screen, size), false, tint)
	else:
		# Fallback crosshair if the sprite sheet is unavailable.
		overlay.draw_line(screen + Vector2(-6.0, 0.0), screen + Vector2(6.0, 0.0), tint, 1.0)
		overlay.draw_line(screen + Vector2(0.0, -6.0), screen + Vector2(0.0, 6.0), tint, 1.0)
	if _show_labels and _font != null:
		overlay.draw_string(_font, screen + Vector2(8.0, 24.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, tint)


func _cursor_texture(anim: String, now: int) -> Texture2D:
	if _cursor_frames == null:
		_cursor_frames = load(CURSOR_FRAMES_PATH) as SpriteFrames
	if _cursor_frames == null:
		return null
	var name: String = anim
	if not _cursor_frames.has_animation(StringName(name)):
		name = CollabConstants.CURSOR_ANIM_IDLE
	if not _cursor_frames.has_animation(StringName(name)):
		return null
	var key: StringName = StringName(name)
	var count: int = _cursor_frames.get_frame_count(key)
	if count <= 0:
		return null
	var frame: int = 0
	var speed: float = _cursor_frames.get_animation_speed(key)
	if count > 1 and speed > 0.0:
		frame = int(floor((float(now) / 1000.0) * speed)) % count
	return _cursor_frames.get_frame_texture(key, frame)


func _editor_viewport_2d() -> SubViewport:
	var editor_interface: EditorInterface = _get_editor_interface()
	if editor_interface == null:
		return null
	return editor_interface.get_editor_viewport_2d() as SubViewport


var _editor_interface_provider: Callable = Callable()


func set_editor_interface_provider(provider: Callable) -> void:
	_editor_interface_provider = provider


func _get_editor_interface() -> EditorInterface:
	if _editor_interface_provider.is_valid():
		return _editor_interface_provider.call()
	return null
