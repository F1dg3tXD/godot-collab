@tool
## 2D cursor that represents a collaborator editing in the editor's 2D view.
##
## Unlike the 3D [CollabUserMarker] this node is parented to the 2D editor
## viewport, so its scale follows the shared cursor sprite sheet. Callers set a
## canvas-space position with [method place] and an animation name with
## [method set_cursor_animation].
class_name CollabCursor2D
extends Node2D

## Display name shown next to the cursor.
@export var username: String = "": set = set_username
## Cursor colour (applied to the sprite and the label).
@export var marker_color: Color = Color(1, 0, 0, 1.0): set = set_marker_color
## Whether the floating username label is shown.
@export var label_visible: bool = true: set = set_label_visible

@onready var animated_sprite_2d: AnimatedSprite2D = %AnimatedSprite2D
@onready var _name_label: Label = %UserNameDisplay


func _ready() -> void:
	if animated_sprite_2d != null:
		animated_sprite_2d.centered = false
		animated_sprite_2d.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_apply_username()
	_apply_color()


## Places the cursor at a canvas-space position (the same space as the edited
## 2D scene, so the editor's canvas transform maps it onto the screen).
func place(canvas_pos: Vector2) -> void:
	position = canvas_pos


## Plays the named cursor animation. Unknown names are ignored so a peer can
## never request an animation that does not exist in the sprite sheet.
func set_cursor_animation(anim: String) -> void:
	var sprite: AnimatedSprite2D = _resolve_sprite()
	if sprite == null or sprite.sprite_frames == null:
		return
	var key: StringName = StringName(anim)
	if not sprite.sprite_frames.has_animation(key):
		return
	if sprite.animation != key:
		sprite.animation = key
	if not sprite.is_playing():
		sprite.play()


## Current cursor animation name (empty when unavailable).
func cursor_animation() -> StringName:
	var sprite: AnimatedSprite2D = _resolve_sprite()
	return sprite.animation if sprite != null else &""


func set_username(value: String) -> void:
	username = value
	if is_node_ready():
		_apply_username()


func set_marker_color(value: Color) -> void:
	marker_color = value
	if is_node_ready():
		_apply_color()


func set_label_visible(value: bool) -> void:
	label_visible = value
	if is_node_ready() and _name_label != null:
		_name_label.visible = value


func _resolve_sprite() -> AnimatedSprite2D:
	if animated_sprite_2d != null:
		return animated_sprite_2d
	return get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D


func _apply_username() -> void:
	if _name_label != null:
		_name_label.text = username


func _apply_color() -> void:
	var tint: Color = Color(marker_color.r, marker_color.g, marker_color.b, 1.0)
	if animated_sprite_2d != null and not animated_sprite_2d.modulate.is_equal_approx(tint):
		animated_sprite_2d.modulate = tint
	if _name_label != null and _name_label.label_settings != null:
		var current: LabelSettings = _name_label.label_settings
		if not current.font_color.is_equal_approx(tint):
			var settings: LabelSettings = current.duplicate() as LabelSettings
			settings.font_color = tint
			_name_label.label_settings = settings
