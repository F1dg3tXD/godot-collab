@tool
## Stores the latest cursor sample for every remote participant and produces
## interpolated world positions for drawing.
##
## A 3D "cursor" is represented as a world-space ray (origin + direction) taken
## from the remote user's editor camera. We place a configurable marker at a
## fixed distance along that ray. This is deliberately *not* surface picking:
## no claim is made that the marker sits on geometry. A 2D "cursor" instead
## carries a canvas-space position so it can be drawn on the 2D editor overlay
## under the local pan/zoom. Every sample also carries the remote mouse
## animation name (see [constant CollabConstants.CURSOR_ANIM_IDLE] and friends).
class_name CollabCursorState
extends RefCounted

class Sample:
	var view: String = CollabConstants.CURSOR_VIEW_3D
	var camera_transform: Transform3D = Transform3D.IDENTITY
	var ray_origin: Vector3 = Vector3.ZERO
	var ray_direction: Vector3 = Vector3.FORWARD
	var viewport_pos: Vector2 = Vector2(0.5, 0.5)
	var canvas_pos: Vector2 = Vector2.ZERO
	var scene_id: String = ""
	var anim: String = CollabConstants.CURSOR_ANIM_IDLE
	var recv_ms: int = 0
	var prev_world: Vector3 = Vector3.ZERO
	var target_world: Vector3 = Vector3.ZERO
	var segment_start_ms: int = 0
	var has_world: bool = false

var _samples: Dictionary = {} # peer_id -> Sample
var marker_depth: float = 12.0


func set_marker_depth(depth: float) -> void:
	marker_depth = depth


## Records a 3D sample from a remote peer's camera ray.
func update(peer_id: int, camera_transform: Transform3D, ray_origin: Vector3, ray_direction: Vector3, viewport_pos: Vector2, scene_id: String, anim: String = CollabConstants.CURSOR_ANIM_IDLE) -> void:
	var sample: Sample = _samples.get(peer_id, null)
	var now: int = Time.get_ticks_msec()
	var world: Vector3 = ray_origin + ray_direction.normalized() * marker_depth
	if sample == null:
		sample = Sample.new()
		sample.prev_world = world
		sample.target_world = world
		sample.segment_start_ms = now
		sample.has_world = true
		_samples[peer_id] = sample
	else:
		# Start interpolating from wherever we currently are.
		sample.prev_world = current_world(sample, now)
		sample.target_world = world
		sample.segment_start_ms = now
	sample.view = CollabConstants.CURSOR_VIEW_3D
	sample.camera_transform = camera_transform
	sample.ray_origin = ray_origin
	sample.ray_direction = ray_direction
	sample.viewport_pos = viewport_pos
	sample.scene_id = scene_id
	sample.anim = anim
	sample.recv_ms = now


## Records a 2D sample from a remote peer's 2D editor view.
func update_2d(peer_id: int, canvas_pos: Vector2, viewport_pos: Vector2, scene_id: String, anim: String = CollabConstants.CURSOR_ANIM_IDLE) -> void:
	var sample: Sample = _samples.get(peer_id, null)
	var now: int = Time.get_ticks_msec()
	if sample == null:
		sample = Sample.new()
		_samples[peer_id] = sample
	sample.view = CollabConstants.CURSOR_VIEW_2D
	sample.canvas_pos = canvas_pos
	sample.viewport_pos = viewport_pos
	sample.scene_id = scene_id
	sample.anim = anim
	sample.recv_ms = now


func remove(peer_id: int) -> void:
	_samples.erase(peer_id)


func clear() -> void:
	_samples.clear()


func has(peer_id: int) -> bool:
	return _samples.has(peer_id)


func peer_ids() -> Array[int]:
	var out: Array[int] = []
	for key in _samples.keys():
		out.append(key)
	return out


func is_stale(peer_id: int, now: int) -> bool:
	var sample: Sample = _samples.get(peer_id, null)
	if sample == null:
		return true
	return (now - sample.recv_ms) > int(CollabConstants.CURSOR_STALE_SECONDS * 1000.0)


## Whether the peer's latest sample is a 3D or 2D cursor
## ([constant CollabConstants.CURSOR_VIEW_3D] / `CURSOR_VIEW_2D`).
func view(peer_id: int) -> String:
	var sample: Sample = _samples.get(peer_id, null)
	return sample.view if sample != null else CollabConstants.CURSOR_VIEW_3D


func anim(peer_id: int) -> String:
	var sample: Sample = _samples.get(peer_id, null)
	return sample.anim if sample != null else CollabConstants.CURSOR_ANIM_IDLE


## Current interpolated world position for a peer, or [constant Vector3.ZERO].
func world_position(peer_id: int, now: int = -1) -> Vector3:
	var sample: Sample = _samples.get(peer_id, null)
	if sample == null:
		return Vector3.ZERO
	return current_world(sample, now if now >= 0 else Time.get_ticks_msec())


func camera_transform(peer_id: int) -> Transform3D:
	var sample: Sample = _samples.get(peer_id, null)
	return sample.camera_transform if sample != null else Transform3D.IDENTITY


func viewport_pos(peer_id: int) -> Vector2:
	var sample: Sample = _samples.get(peer_id, null)
	return sample.viewport_pos if sample != null else Vector2(0.5, 0.5)


func canvas_pos(peer_id: int) -> Vector2:
	var sample: Sample = _samples.get(peer_id, null)
	return sample.canvas_pos if sample != null else Vector2.ZERO


func scene_id(peer_id: int) -> String:
	var sample: Sample = _samples.get(peer_id, null)
	return sample.scene_id if sample != null else ""


static func current_world(sample: Sample, now: int) -> Vector3:
	if not sample.has_world:
		return sample.target_world
	var elapsed: float = float(now - sample.segment_start_ms) / 1000.0
	var t: float = clampf(elapsed / maxf(0.001, CollabConstants.CURSOR_INTERP_SECONDS), 0.0, 1.0)
	if t >= 1.0:
		return sample.target_world
	return sample.prev_world.lerp(sample.target_world, t)
