@tool
## Server-side live project mirror used by the relay.
##
## The relay is normally a dumb forwarder, but when a project name is supplied by
## the session host it also maintains a host-authoritative copy of the live
## project under the configured projects directory (`live_<project_name>`). The
## mirror:
##
## - pulls the host's project through the ordinary transfer protocol once the
##   host registers, hashing each file so only divergent/new files travel;
## - ingests the host's live [constant CollabProtocol.MessageType.FILE_APPLY] and
##   [constant CollabProtocol.MessageType.FILE_REMOVE] messages so later edits are
##   persisted;
## - replays the persisted files to clients that join the room afterwards so they
##   start from the current server state.
##
## All writes go through [CollabPathGuard] and are excluded by
## [CollabProjectManifest], so a mirror can never escape its directory and never
## stores generated caches or version-control metadata. Nothing stored here is
## ever executed.
class_name CollabProjectMirror
extends RefCounted

const MAX_FILE_BYTES: int = 2 * 1024 * 1024
const MAX_MIRROR_FILES: int = 20000

## Pulls the manifest and file contents of the host project.
var _send_fn: Callable = Callable()
var _root: String = ""
var _transfer_id: int = 0
var _pending_files: Dictionary = {} ## path -> {size, sha256}
var _rx_path: String = ""
var _rx_buffer: PackedByteArray = PackedByteArray()
var _rx_size: int = 0
var _rx_sha: String = ""
var _synced: bool = false
var _scenes: Array = []


## Creates the mirror for [param root] (already resolved to an absolute path
## inside the approved projects directory).
func setup(root: String) -> void:
	_root = root
	DirAccess.make_dir_recursive_absolute(_root)


func root() -> String:
	return _root


func is_ready() -> bool:
	return _synced


func is_empty() -> bool:
	return _walk().is_empty()


## Begins the initial pull. [param send_fn] is called with application bytes the
## mirror wants delivered to the session host.
func begin_host_sync(send_fn: Callable) -> void:
	_send_fn = send_fn
	_transfer_id = randi()
	_pending_files.clear()
	_synced = false
	_send(CollabProtocol.MessageType.TRANSFER_REQUEST, {
		"transfer_id": _transfer_id,
		"path": "*manifest*",
	})


## Ingests a wrapped application packet that the host sent to the mirror.
func ingest(app_bytes: PackedByteArray) -> void:
	var decoded: Dictionary = CollabProtocol.decode(app_bytes)
	if not decoded.get("ok", false):
		return
	var type: int = int(decoded["type"])
	var payload: Dictionary = decoded["payload"]
	match type:
		CollabProtocol.MessageType.TRANSFER_MANIFEST:
			_on_manifest(payload)
		CollabProtocol.MessageType.TRANSFER_CHUNK:
			_on_chunk(payload)
		CollabProtocol.MessageType.TRANSFER_FILE_DONE:
			_on_file_done(payload)
		CollabProtocol.MessageType.TRANSFER_COMPLETE:
			_synced = true
		CollabProtocol.MessageType.FILE_APPLY:
			_on_file_apply(payload)
		CollabProtocol.MessageType.FILE_REMOVE:
			_on_file_remove(payload)
		CollabProtocol.MessageType.SCENE_LIST:
			var scenes: Variant = payload.get("scenes", [])
			_scenes = scenes if typeof(scenes) == TYPE_ARRAY else []
		_:
			pass


## Frames that replay the mirror's current state to a joining client. The frames
## carry the host application id as origin, matching the live host. Large files
## cannot be replayed through FILE_APPLY and are skipped (clients can still pull
## them through the full project-download path).
func snapshot_frames(dest_app_id: int) -> Array:
	var out: Array = []
	if _root.is_empty():
		return out
	for rel in _walk():
		var absolute: String = CollabPathGuard.resolve_within(_root, rel)
		if absolute.is_empty():
			continue
		var bytes: PackedByteArray = FileAccess.get_file_as_bytes(absolute)
		if bytes.size() > MAX_FILE_BYTES:
			continue
		var app_bytes: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.FILE_APPLY, {
			"path": rel,
			"data": bytes,
			"scene": rel.get_extension().to_lower() in ["tscn", "scn", "escn"],
		})
		if app_bytes.is_empty():
			continue
		out.append(CollabRelayProtocol.encode_data(CollabRelayProtocol.HOST_APP_ID, dest_app_id, app_bytes))
	var scenes: Array = _scan_scenes()
	var scene_bytes: PackedByteArray = CollabProtocol.encode(CollabProtocol.MessageType.SCENE_LIST, {
		"scenes": scenes,
		"revision": 0,
	})
	if not scene_bytes.is_empty():
		out.append(CollabRelayProtocol.encode_data(CollabRelayProtocol.HOST_APP_ID, dest_app_id, scene_bytes))
	return out


# ---------------------------------------------------------------------------
# Transfer pull
# ---------------------------------------------------------------------------

func _on_manifest(payload: Dictionary) -> void:
	if not payload.has("files") or typeof(payload["files"]) != TYPE_ARRAY:
		return
	var host_files: Dictionary = {}
	for entry in payload["files"]:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var rel: String = CollabPathGuard.normalize_relative(str((entry as Dictionary).get("path", "")))
		if rel.is_empty() or CollabProjectManifest.is_excluded_relative(rel):
			continue
		host_files[rel] = {
			"size": int((entry as Dictionary).get("size", 0)),
			"sha256": str((entry as Dictionary).get("sha256", "")),
		}
	# Host is the master: mirror files the host no longer has are removed.
	for rel in _walk():
		if not host_files.has(rel):
			_remove_file(rel)
	# Request files that are missing or divergent.
	for rel in host_files.keys():
		var info: Dictionary = host_files[rel]
		var digest: String = _hash_local(rel)
		if not digest.is_empty() and digest == str(info["sha256"]):
			continue
		_pending_files[rel] = info
		_send(CollabProtocol.MessageType.TRANSFER_REQUEST, {
			"transfer_id": _transfer_id,
			"path": rel,
		})
	_synced = true


func _on_chunk(payload: Dictionary) -> void:
	var rel: String = CollabPathGuard.normalize_relative(str(payload.get("path", "")))
	if rel.is_empty():
		return
	var offset: int = int(payload.get("offset", 0))
	var data: Variant = payload.get("data", PackedByteArray())
	if typeof(data) != TYPE_PACKED_BYTE_ARRAY:
		return
	if rel != _rx_path or offset != _rx_buffer.size():
		_rx_path = rel
		_rx_buffer = PackedByteArray()
		if offset != 0:
			_rx_buffer.resize(offset)
	_rx_buffer.append_array(data)


func _on_file_done(payload: Dictionary) -> void:
	var rel: String = CollabPathGuard.normalize_relative(str(payload.get("path", "")))
	if rel.is_empty() or rel != _rx_path:
		_rx_buffer = PackedByteArray()
		_rx_path = ""
		return
	var sha: String = str(payload.get("sha256", ""))
	var expected: Dictionary = _pending_files.get(rel, {})
	var want_sha: String = sha if not sha.is_empty() else str(expected.get("sha256", ""))
	if not want_sha.is_empty() and _sha256_bytes(_rx_buffer) != want_sha:
		_pending_files.erase(rel)
		_rx_buffer = PackedByteArray()
		_rx_path = ""
		return
	_write_file(rel, _rx_buffer)
	_pending_files.erase(rel)
	_rx_buffer = PackedByteArray()
	_rx_path = ""


func _on_file_apply(payload: Dictionary) -> void:
	var rel: String = CollabPathGuard.normalize_relative(str(payload.get("path", "")))
	if rel.is_empty() or CollabProjectManifest.is_excluded_relative(rel):
		return
	var data: Variant = payload.get("data", PackedByteArray())
	if typeof(data) != TYPE_PACKED_BYTE_ARRAY:
		return
	var bytes: PackedByteArray = data
	if bytes.size() > MAX_FILE_BYTES:
		return
	_write_file(rel, bytes)
	if _scenes.is_empty():
		_scenes = _scan_scenes()


func _on_file_remove(payload: Dictionary) -> void:
	var rel: String = CollabPathGuard.normalize_relative(str(payload.get("path", "")))
	if rel.is_empty():
		return
	_remove_file(rel)


# ---------------------------------------------------------------------------
# Disk helpers
# ---------------------------------------------------------------------------

func _write_file(rel: String, bytes: PackedByteArray) -> void:
	var absolute: String = CollabPathGuard.resolve_within(_root, rel)
	if absolute.is_empty() or not CollabPathGuard.no_symlink_escape(_root, rel):
		return
	var parent: String = absolute.get_base_dir()
	if not DirAccess.dir_exists_absolute(parent):
		DirAccess.make_dir_recursive_absolute(parent)
	var file: FileAccess = FileAccess.open(absolute, FileAccess.WRITE)
	if file == null:
		return
	file.store_buffer(bytes)
	file.close()


func _remove_file(rel: String) -> void:
	var absolute: String = CollabPathGuard.resolve_within(_root, rel)
	if absolute.is_empty():
		return
	if FileAccess.file_exists(absolute):
		DirAccess.remove_absolute(absolute)


func _hash_local(rel: String) -> String:
	var absolute: String = CollabPathGuard.resolve_within(_root, rel)
	if absolute.is_empty() or not FileAccess.file_exists(absolute):
		return ""
	return CollabIdentity.sha256_file(absolute)


func _sha256_bytes(bytes: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(bytes)
	return ctx.finish().hex_encode()


func _walk() -> Array:
	var out: Array = []
	if _root.is_empty() or not DirAccess.dir_exists_absolute(_root):
		return out
	var queue: Array[String] = [""]
	while not queue.is_empty():
		var rel_dir: String = queue.pop_back()
		var absolute: String = _root if rel_dir.is_empty() else _root.path_join(rel_dir)
		var dir := DirAccess.open(absolute)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name: String = dir.get_next()
		while name != "":
			if name != "." and name != "..":
				var rel: String = name if rel_dir.is_empty() else rel_dir.path_join(name)
				if dir.current_is_dir():
					if not _dir_excluded(name):
						queue.append(rel)
				else:
					if not CollabPathGuard.is_symlink(absolute.path_join(name)):
						out.append(rel)
						if out.size() >= MAX_MIRROR_FILES:
							dir.list_dir_end()
							return out
			name = dir.get_next()
		dir.list_dir_end()
	out.sort()
	return out


func _dir_excluded(name: String) -> bool:
	return CollabProjectManifest.EXCLUDED_DIRS.has(name)


func _scan_scenes() -> Array:
	var scenes: Array = []
	for rel in _walk():
		if rel.get_extension().to_lower() in ["tscn", "scn", "escn"]:
			scenes.append(rel if rel.begins_with("res://") else "res://" + rel)
	scenes.sort()
	return scenes


func _send(type: CollabProtocol.MessageType, payload: Dictionary) -> void:
	if not _send_fn.is_valid():
		return
	var bytes: PackedByteArray = CollabProtocol.encode(type, payload)
	if bytes.is_empty():
		return
	_send_fn.call(bytes)
