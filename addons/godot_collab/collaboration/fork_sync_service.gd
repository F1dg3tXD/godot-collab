## Exchanges project manifests between peers and runs the three-way merge planner.
## This first version reports conflicts and decisions; it does not yet transfer or
## write file contents (those land in a later slice).
class_name CollabForkSyncService
extends RefCounted

signal status_changed(text: String)
signal conflict_found(path: String, reason: String)

var coordinator: CollabSessionCoordinator = null
var project_root: Callable = Callable()


func setup(coord: CollabSessionCoordinator, root: Callable) -> void:
	coordinator = coord
	project_root = root
	if coordinator != null:
		coordinator.fork_sync_message.connect(_on_message)


func teardown() -> void:
	if coordinator != null:
		coordinator.fork_sync_message.disconnect(_on_message)
	coordinator = null


func _root_path() -> String:
	if not project_root.is_valid():
		return ""
	return str(project_root.call())


func build_manifest() -> Dictionary:
	var out: Dictionary = {}
	var root: String = _root_path()
	if root.is_empty():
		return out
	_walk(root, "", out)
	return out


func _walk(absolute: String, rel_prefix: String, out: Dictionary) -> void:
	var dir: DirAccess = DirAccess.open(absolute)
	if dir == null:
		return
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while name != "":
		if name == "." or name == "..":
			name = dir.get_next()
			continue
		var rel: String = (rel_prefix + "/" + name) if not rel_prefix.is_empty() else name
		var abs: String = absolute.path_join(name)
		if dir.current_is_dir():
			if name != ".git" and name != ".godot" and name != ".import":
				_walk(abs, rel, out)
		elif not name.ends_with(".import"):
			var h: String = _sha256(abs)
			if not h.is_empty():
				out[rel] = h
		name = dir.get_next()
	dir.list_dir_end()


func _sha256(path: String) -> String:
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var chunk: PackedByteArray = file.get_buffer(65536)
	while chunk.size() > 0:
		ctx.update(chunk)
		chunk = file.get_buffer(65536)
	file.close()
	var digest: PackedByteArray = ctx.finish()
	return digest.hex_encode()


func request_sync() -> void:
	if coordinator == null or coordinator.session_manager == null:
		return
	var files: Array = []
	for path in build_manifest().keys():
		files.append({"path": path, "sha256": build_manifest()[path]})
	var payload: Dictionary = {"files": files}
	coordinator.session_manager.send_to_server(CollabProtocol.MessageType.FORK_SYNC_MANIFEST, payload)


func _on_message(from_peer: int, type: int, payload: Dictionary) -> void:
	if type == CollabProtocol.MessageType.FORK_SYNC_MANIFEST:
		_handle_incoming_manifest(from_peer, payload)
	elif type == CollabProtocol.MessageType.FORK_SYNC_RESULT:
		_handle_result(payload)


func _handle_incoming_manifest(from_peer: int, payload: Dictionary) -> void:
	if coordinator == null or not coordinator.is_host():
		return
	var client_manifest: Dictionary = {}
	for entry in payload.get("files", []):
		if typeof(entry) == TYPE_DICTIONARY:
			client_manifest[str(entry.get("path", ""))] = str(entry.get("sha256", ""))
	var host_manifest: Dictionary = build_manifest()
	var decisions: Array = CollabMergePlanner.plan({}, host_manifest, client_manifest)
	var conflicts: Array = CollabMergePlanner.conflicts(decisions)
	for c in conflicts:
		conflict_found.emit(str(c.get("path", "")), str(c.get("reason", "")))
	status_changed.emit("Fork sync: %d conflict(s)." % conflicts.size())
	var out_files: Array = []
	for d in decisions:
		out_files.append(d)
	coordinator.session_manager.broadcast(CollabProtocol.MessageType.FORK_SYNC_RESULT, {"decisions": out_files}, true)


func _handle_result(payload: Dictionary) -> void:
	var conflicts: Array = []
	for d in payload.get("decisions", []):
		if typeof(d) == TYPE_DICTIONARY and str(d.get("action", "")) == "conflict":
			conflicts.append(d)
			conflict_found.emit(str(d.get("path", "")), str(d.get("reason", "")))
	status_changed.emit("Fork sync: %d conflict(s)." % conflicts.size())
