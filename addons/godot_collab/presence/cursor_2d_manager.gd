@tool
## Spawns and updates a live [CollabCursor2D] for every remote participant whose
## latest sample is a 2D cursor. Cursors are parented to the editor's 2D viewport
## so they share the edited scene's canvas transform while never being part of the
## scene (they are not serialised, never show in the Scene dock and never mark the
## scene dirty). Peers editing in the 3D view are drawn by [CollabMarkerManager].
##
## The live-cursor scene ([code]assets/cursor_2d.tscn[/code]) and this approach
## are adapted from GodotTogether (https://github.com/Wolfyxon/GodotTogether),
## which places participant avatars directly in the editor's 2D viewport and
## polls its mouse position instead of relying on canvas input forwarding.
class_name CollabCursor2DManager
extends Node

const CURSOR_SCENE_PATH: String = "res://addons/godot_collab/assets/cursor_2d.tscn"
const CONTAINER_NAME: String = "CollabCursor2D"
const CURSOR_Z_INDEX: int = 4096

var _coordinator: CollabSessionCoordinator
var _settings: CollabSettings
var _logs: CollabLog
var _cursor_state: CollabCursorState
var _viewport_provider: Callable = Callable()
var _cursor_scene: PackedScene
var _container: Node2D
var _cursors: Dictionary = {}

var _enabled: bool = true
var _show_labels: bool = true
var _cursor_scale: float = 1.0
var _local_scene_id: String = ""


func setup(coordinator: CollabSessionCoordinator, settings: CollabSettings, logs: CollabLog, cursor_state: CollabCursorState) -> void:
	_coordinator = coordinator
	_settings = settings
	_logs = logs
	_cursor_state = cursor_state
	_cursor_scene = load(CURSOR_SCENE_PATH) as PackedScene
	_apply_settings()
	if _coordinator != null:
		_coordinator.session_stopped.connect(_on_session_stopped)
		_coordinator.registry.changed.connect(_reap)


func set_viewport_provider(provider: Callable) -> void:
	_viewport_provider = provider


func set_local_scene_id(scene_id: String) -> void:
	_local_scene_id = scene_id


func _apply_settings() -> void:
	if _settings == null:
		return
	_enabled = _settings.get_bool(CollabSettings.KEY_CURSOR_2D_MARKERS, true)
	_show_labels = _settings.get_bool(CollabSettings.KEY_CURSOR_LABEL_KEY, true)
	var size: float = _settings.get_float(CollabSettings.KEY_CURSOR_SIZE_KEY, 8.0)
	_cursor_scale = clampf(size / 8.0, 0.25, 8.0)


## Called every frame by the plugin while a session is active.
func poll() -> void:
	if not _enabled:
		_clear()
		return
	if _coordinator == null or not _coordinator.session_manager.is_active():
		return
	if not _ensure_container():
		return
	var now: int = Time.get_ticks_msec()
	var seen: Dictionary = {}
	for participant in _coordinator.registry.all():
		var peer_id: int = participant.peer_id
		if peer_id == _coordinator.local_peer_id():
			continue
		if not _cursor_state.has(peer_id) or _cursor_state.is_stale(peer_id, now):
			continue
		if _cursor_state.view(peer_id) != CollabConstants.CURSOR_VIEW_2D:
			continue
		var remote_scene: String = _cursor_state.scene_id(peer_id)
		if not remote_scene.is_empty() and not _local_scene_id.is_empty() and remote_scene != _local_scene_id:
			continue
		seen[peer_id] = true
		var cursor: CollabCursor2D = _cursor_for(peer_id)
		if cursor == null:
			continue
		cursor.place(_cursor_state.canvas_pos(peer_id))
		cursor.set_cursor_animation(_cursor_state.anim(peer_id))
		var wanted_scale: Vector2 = Vector2.ONE * _cursor_scale
		if not cursor.scale.is_equal_approx(wanted_scale):
			cursor.scale = wanted_scale
		var display: String = participant.display_name()
		if cursor.username != display:
			cursor.username = display
		var tint: Color = participant.color()
		if not cursor.marker_color.is_equal_approx(tint):
			cursor.marker_color = tint
		if cursor.label_visible != _show_labels:
			cursor.label_visible = _show_labels
	for peer_id in _cursors.keys():
		if not seen.has(peer_id):
			_remove_cursor(peer_id)


func _reap() -> void:
	if _cursor_state == null:
		return
	var now: int = Time.get_ticks_msec()
	for peer_id in _cursors.keys():
		if not _cursor_state.has(peer_id) or _cursor_state.is_stale(peer_id, now):
			_remove_cursor(peer_id)


func _ensure_container() -> bool:
	var viewport: SubViewport = _get_viewport()
	if viewport == null:
		return false
	if _container != null and _container.is_inside_tree() and _container.get_parent() == viewport:
		return true
	if _container != null and _container.is_inside_tree():
		_container.get_parent().remove_child(_container)
	_container = viewport.get_node_or_null(CONTAINER_NAME) as Node2D
	if _container == null:
		_container = Node2D.new()
		_container.name = CONTAINER_NAME
		_container.z_index = CURSOR_Z_INDEX
		_container.set_meta("godot_collab_internal", true)
		viewport.add_child(_container)
	return true


func _cursor_for(peer_id: int) -> CollabCursor2D:
	var existing: CollabCursor2D = _cursors.get(peer_id, null)
	if existing != null and is_instance_valid(existing):
		return existing
	if _cursor_scene == null:
		return null
	var cursor: CollabCursor2D = _cursor_scene.instantiate() as CollabCursor2D
	if cursor == null:
		return null
	cursor.name = "CollabPeer_%d" % peer_id
	cursor.z_index = CURSOR_Z_INDEX
	_container.add_child(cursor)
	_cursors[peer_id] = cursor
	return cursor


func _remove_cursor(peer_id: int) -> void:
	var cursor: Node = _cursors.get(peer_id, null)
	_cursors.erase(peer_id)
	if cursor != null and is_instance_valid(cursor):
		cursor.queue_free()


func _clear() -> void:
	for peer_id in _cursors.keys():
		_remove_cursor(peer_id)
	if _container != null and is_instance_valid(_container):
		_container.queue_free()
	_container = null


func _on_session_stopped(_reason: String) -> void:
	_clear()


func _get_viewport() -> SubViewport:
	if not _viewport_provider.is_valid():
		return null
	return _viewport_provider.call() as SubViewport


## Converts a position in the embedding [SubViewportContainer]'s local space to
## the canvas space the edited scene (and therefore [CollabCursor2D]) lives in.
## The editor stores its 2D pan/zoom in the viewport's global canvas transform,
## which [method Viewport.get_final_transform] includes (unlike
## [method Viewport.get_canvas_transform]); dividing by the container's stretch
## shrink keeps this correct if the editor ever renders the 2D view scaled down.
## Credit: GodotTogether, https://github.com/Wolfyxon/GodotTogether.
static func viewport_to_canvas(viewport: Viewport, viewport_pos: Vector2) -> Vector2:
	if viewport == null:
		return viewport_pos
	var local_pos: Vector2 = viewport_pos
	var container := viewport.get_parent() as SubViewportContainer
	if container != null and container.is_stretch_enabled() and container.get_stretch_shrink() > 1:
		local_pos /= float(container.get_stretch_shrink())
	var final_transform: Transform2D = viewport.get_final_transform()
	if final_transform.determinant() == 0.0:
		return viewport_pos
	return final_transform.affine_inverse() * local_pos


# --- test helpers ---------------------------------------------------------

func cursor_count() -> int:
	return _cursors.size()


func has_cursor(peer_id: int) -> bool:
	return _cursors.has(peer_id) and is_instance_valid(_cursors[peer_id])
