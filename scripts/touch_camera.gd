extends Camera2D

const ZOOM_MIN = 0.3
const ZOOM_MAX = 3.0
const ZOOM_SMOOTHING = 10.0
const PAN_LIMIT = 2000.0
const UI_EXCLUSION_HEIGHT = 120

var touches: Dictionary = {}
var target_zoom: float = 1.0
var is_panning: bool = false
var middle_button_pressed: bool = false
var last_drag_position: Vector2 = Vector2.ZERO

func _ready() -> void:
	global_position = Vector2.ZERO
	zoom = Vector2.ONE
	target_zoom = 1.0

func _input(event: InputEvent) -> void:
	var viewport_size = get_viewport_rect().size
	var ui_boundary = viewport_size.y - UI_EXCLUSION_HEIGHT

	# Single touch or drag
	if event is InputEventScreenTouch:
		var touch_event = event as InputEventScreenTouch
		var touch_index = touch_event.index

		# Ignore touches in UI area
		if touch_event.position.y > ui_boundary:
			return

		if touch_event.pressed:
			touches[touch_index] = touch_event.position
			is_panning = true
		else:
			touches.erase(touch_index)
			if touches.is_empty():
				is_panning = false

	# Touch drag (pan with single finger)
	elif event is InputEventScreenDrag:
		var drag_event = event as InputEventScreenDrag

		# Only pan if single touch
		if drag_event.index == 0 and touches.size() == 1:
			if drag_event.position.y <= ui_boundary:
				var delta_pan = drag_event.relative * -1.0 / zoom
				global_position += delta_pan
				clamp_position()
				get_tree().root.set_input_as_handled()

	# Mouse wheel zoom (desktop testing)
	elif event is InputEventMouseButton:
		var mouse_event = event as InputEventMouseButton

		if mouse_event.button_index == MOUSE_BUTTON_WHEEL_UP:
			target_zoom = clamp(target_zoom * 1.1, ZOOM_MIN, ZOOM_MAX)
			get_tree().root.set_input_as_handled()
		elif mouse_event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			target_zoom = clamp(target_zoom / 1.1, ZOOM_MIN, ZOOM_MAX)
			get_tree().root.set_input_as_handled()
		elif mouse_event.button_index == MOUSE_BUTTON_MIDDLE:
			if mouse_event.pressed:
				middle_button_pressed = true
				last_drag_position = mouse_event.position
			else:
				middle_button_pressed = false

	# Mouse middle-click drag (desktop pan testing)
	elif event is InputEventMouseMotion and middle_button_pressed:
		var motion_event = event as InputEventMouseMotion
		var delta_pan = (motion_event.position - last_drag_position) * -1.0 / zoom
		global_position += delta_pan
		clamp_position()
		last_drag_position = motion_event.position
		get_tree().root.set_input_as_handled()

func _process(delta: float) -> void:
	# Handle pinch zoom
	if touches.size() == 2:
		var touch_positions = touches.values()
		var distance = touch_positions[0].distance_to(touch_positions[1])

		# Simple heuristic: use previous distance to compute zoom change
		# Store previous distance in touches or use a separate variable
		if not touches.has("_prev_distance"):
			touches["_prev_distance"] = distance
		else:
			var prev_distance = touches["_prev_distance"]
			if prev_distance > 0:
				var zoom_factor = distance / prev_distance
				target_zoom = clamp(target_zoom * zoom_factor, ZOOM_MIN, ZOOM_MAX)
			touches["_prev_distance"] = distance
	else:
		touches.erase("_prev_distance")

	# Smooth zoom interpolation
	var target_vec := Vector2(target_zoom, target_zoom)
	zoom = zoom.lerp(target_vec, ZOOM_SMOOTHING * delta)

func clamp_position() -> void:
	global_position.x = clamp(global_position.x, -PAN_LIMIT, PAN_LIMIT)
	global_position.y = clamp(global_position.y, -PAN_LIMIT, PAN_LIMIT)
