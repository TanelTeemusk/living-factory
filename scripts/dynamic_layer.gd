extends Node2D
## Dynamic rendering layer — redraws every frame.
## Handles: moving packets, selected hex pulse, hover ghost.
## Kept separate from hex_grid.gd (static world) so the world tiles
## don't redraw every frame just because a packet moved.

const HEX_SIZE: float = 32.0
const CELL_HEIGHT_OFFSET: float = 0.0
const CELL_SIZE_RATIO: float = 0.72
const PULSE_SPEED: float = 3.0
const HOVER_OVERLAY_ALPHA: float = 0.5
const GHOST_CELL_ALPHA: float = 0.4
const UI_SAFE_MARGIN: float = 170.0

var pulse_time: float = 0.0

func _process(delta: float) -> void:
	pulse_time += delta
	queue_redraw()

func _draw() -> void:
	_draw_packets()
	_draw_selected_hex()
	_draw_hover()

# === PACKETS ===
func _draw_packets() -> void:
	for packet in GameState.packets:
		var from_pixel := GameState.hex_to_pixel(packet.from)
		var to_pixel   := GameState.hex_to_pixel(packet.to)
		var pos := from_pixel.lerp(to_pixel, packet.progress)
		var color: Color = GameState.resource_colors.get(packet.resource, Color.WHITE)
		var glow := color
		glow.a = 0.3
		draw_circle(pos, 6.0, glow)
		draw_circle(pos, 3.5, color)

# === SELECTED HEX PULSE ===
func _draw_selected_hex() -> void:
	var hex := GameState.selected_hex
	if hex == GameState.NO_HEX:
		return
	if not GameState.tile_map.has(hex):
		return
	var center := GameState.hex_to_pixel(hex)
	var verts := _get_hex_vertices(center, HEX_SIZE + 3.0)
	var alpha := 0.5 + 0.25 * sin(pulse_time * PULSE_SPEED)
	for i in range(6):
		draw_line(verts[i], verts[(i + 1) % 6], Color(1.0, 0.85, 0.3, alpha), 2.5)

# === HOVER GHOST ===
func _draw_hover() -> void:
	var hovered_hex := GameState.pixel_to_hex(get_global_mouse_position())

	if GameState.demolish_mode:
		if GameState.placed_cells.has(hovered_hex) and GameState.placed_cells[hovered_hex] != GameState.CellType.BASE:
			var center := GameState.hex_to_pixel(hovered_hex)
			var raised := center - Vector2(0, CELL_HEIGHT_OFFSET)
			var verts := _get_hex_vertices(raised, HEX_SIZE * CELL_SIZE_RATIO)
			draw_colored_polygon(PackedVector2Array(verts), Color(1, 0, 0, HOVER_OVERLAY_ALPHA))
		return

	if GameState.selected_cell == GameState.CellType.NONE:
		return
	if not GameState.tile_map.has(hovered_hex):
		return
	if GameState.placed_cells.has(hovered_hex):
		return

	var center := GameState.hex_to_pixel(hovered_hex)
	var raised := center - Vector2(0, CELL_HEIGHT_OFFSET)
	var verts := _get_hex_vertices(raised, HEX_SIZE * CELL_SIZE_RATIO)

	var can_place := GameState.can_place_cell(hovered_hex, GameState.selected_cell)
	var ghost_color: Color
	if can_place:
		ghost_color = GameState.cell_colors.get(GameState.selected_cell, Color.WHITE)
		ghost_color.a = GHOST_CELL_ALPHA
	else:
		ghost_color = Color(1, 0.2, 0.2, GHOST_CELL_ALPHA)
	draw_colored_polygon(PackedVector2Array(verts), ghost_color)

# === HEX GEOMETRY (duplicated to avoid cross-script coupling) ===
func _get_hex_vertices(center: Vector2, size: float) -> Array[Vector2]:
	var verts: Array[Vector2] = []
	for i in range(6):
		var angle := (i * 60.0 + 30.0) * PI / 180.0
		verts.append(center + Vector2(size * cos(angle), size * sin(angle)))
	return verts
