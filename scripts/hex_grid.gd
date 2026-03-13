extends Node2D
## Main visual renderer for the hex-grid biological sim.
## Handles drawing hex tiles with 3D depth, placed cells, nerve connections, and input.

# Hex geometry constants
const HEX_SIZE: float = 32.0  # Outer radius, pointy-top
const HEX_HEIGHT_OFFSET: float = 8.0  # 3D depth for tile top face
const CELL_HEIGHT_OFFSET: float = 0.0  # Cells sit flush on the tile surface
const CELL_SIZE_RATIO: float = 0.72  # Cells nested inside tile border

# Tile colors by type (looked up dynamically since enum isn't available at const time)
var TILE_COLORS: Dictionary = {}

const TILE_OUTLINE_COLOR: Color = Color(1.0, 1.0, 1.0, 0.15)
const BACKGROUND_COLOR: Color = Color(0.04, 0.04, 0.06)
const STAR_COUNT: int = 80

# Rendering properties
const NERVE_LINE_WIDTH: float = 2.0
const NERVE_LINE_ALPHA: float = 0.7
const GHOST_CELL_ALPHA: float = 0.4
const HOVER_OVERLAY_ALPHA: float = 0.5

# UI bounds (don't consume input if in bottom 120px)
const UI_SAFE_MARGIN: float = 120.0

# Star background — spread across world space, not viewport
var stars: Array[Vector2] = []
var star_alphas: Array[float] = []

# Energy cell pulsing
var pulse_time: float = 0.0
const PULSE_SPEED: float = 3.0

func _ready() -> void:
	# Init tile colors (can't use enum in const Dictionary)
	TILE_COLORS = {
		GameState.TileType.LOCKED: Color(0.12, 0.12, 0.18),
		GameState.TileType.EMPTY: Color(0.1, 0.2, 0.15),
		GameState.TileType.SUGAR_FIELD: Color(0.25, 0.35, 0.12),
		GameState.TileType.MINERAL_FIELD: Color(0.15, 0.18, 0.3),
	}

	# Generate static star field in world space
	var rng := RandomNumberGenerator.new()
	rng.seed = 42
	for i in range(STAR_COUNT):
		var pos := Vector2(
			rng.randf_range(-1800, 1800),
			rng.randf_range(-1800, 1800)
		)
		stars.append(pos)
		star_alphas.append(rng.randf_range(0.15, 0.5))

	# Connect to GameState signals with lambdas to discard args
	GameState.cell_placed.connect(func(_a, _b): queue_redraw())
	GameState.cell_removed.connect(func(_a): queue_redraw())
	GameState.tiles_unlocked.connect(func(_a): queue_redraw())
	GameState.nerves_updated.connect(func(): queue_redraw())
	GameState.packets_updated.connect(func(): queue_redraw())

func _process(delta: float) -> void:
	pulse_time += delta
	queue_redraw()

func _draw() -> void:
	_draw_background()
	_draw_hex_tiles()
	_draw_nerve_connections()
	_draw_placed_cells()
	_draw_packets()
	_draw_hover()

# === BACKGROUND ===
func _draw_background() -> void:
	# Large dark rect in world space
	draw_rect(Rect2(-2000, -2000, 4000, 4000), BACKGROUND_COLOR)
	# Stars
	for i in range(stars.size()):
		draw_circle(stars[i], 1.0, Color(1.0, 1.0, 1.0, star_alphas[i]))

# === HEX TILES ===
func _draw_hex_tiles() -> void:
	for tile_pos in GameState.tile_map:
		var tile_type: int = GameState.tile_map[tile_pos]
		var center := GameState.hex_to_pixel(tile_pos)
		var color: Color = TILE_COLORS.get(tile_type, Color.GRAY)
		var vertices := _get_hex_vertices(center, HEX_SIZE)

		# Bottom vertices (offset down for 3D depth)
		var bottom_verts: Array[Vector2] = []
		for v in vertices:
			bottom_verts.append(v + Vector2(0, HEX_HEIGHT_OFFSET))

		# Top face
		draw_colored_polygon(PackedVector2Array(vertices), color)

		# Side faces (bottom 3 edges: indices 2-3, 3-4, 4-5 for pointy-top)
		var side_color := color.darkened(0.4)
		for edge_idx: int in [2, 3, 4]:
			var next_idx: int = (edge_idx + 1) % 6
			draw_colored_polygon(PackedVector2Array([
				vertices[edge_idx], vertices[next_idx],
				bottom_verts[next_idx], bottom_verts[edge_idx]
			]), side_color)

		# Outline on top face
		for i: int in range(6):
			draw_line(vertices[i], vertices[(i + 1) % 6], TILE_OUTLINE_COLOR, 1.0)

		# Tile type label (only on non-locked, non-occupied tiles)
		if tile_type != GameState.TileType.LOCKED and not GameState.placed_cells.has(tile_pos):
			var tile_label := _get_tile_label(tile_type)
			if tile_label != "":
				var font := ThemeDB.fallback_font
				if font:
					var fsize := 9
					var tsize := font.get_string_size(tile_label, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize)
					var tpos := center + Vector2(-tsize.x / 2.0, tsize.y / 4.0)
					var label_color := Color(1, 1, 1, 0.4)
					draw_string(font, tpos, tile_label, HORIZONTAL_ALIGNMENT_CENTER, -1, fsize, label_color)

# === PLACED CELLS ===
func _draw_placed_cells() -> void:
	for cell_pos in GameState.placed_cells:
		var cell_type: int = GameState.placed_cells[cell_pos]
		if cell_type == GameState.CellType.NONE:
			continue

		if cell_type == GameState.CellType.GROWTH:
			_draw_growth_node(cell_pos)
			continue

		var center := GameState.hex_to_pixel(cell_pos)
		var raised_center := center - Vector2(0, CELL_HEIGHT_OFFSET)
		var cell_size := HEX_SIZE * CELL_SIZE_RATIO
		var color: Color = GameState.cell_colors.get(cell_type, Color.WHITE)

		# Extractor color by underlying resource type
		if cell_type == GameState.CellType.EXTRACTOR:
			var tile_type: int = GameState.tile_map.get(cell_pos, GameState.TileType.EMPTY)
			if tile_type == GameState.TileType.SUGAR_FIELD:
				color = Color(0.88, 0.95, 1.0)   # Pale blue-white (sugar)
			elif tile_type == GameState.TileType.MINERAL_FIELD:
				color = Color(0.25, 0.45, 0.95)  # Deep blue (mineral)

		var vertices := _get_hex_vertices(raised_center, cell_size)
		var bottom_verts: Array[Vector2] = []
		for v in vertices:
			bottom_verts.append(v + Vector2(0, HEX_HEIGHT_OFFSET))

		# Top face
		draw_colored_polygon(PackedVector2Array(vertices), color)

		# Side faces
		var side_color := color.darkened(0.3)
		for edge_idx: int in [2, 3, 4]:
			var next_idx: int = (edge_idx + 1) % 6
			draw_colored_polygon(PackedVector2Array([
				vertices[edge_idx], vertices[next_idx],
				bottom_verts[next_idx], bottom_verts[edge_idx]
			]), side_color)

		# Outline
		for i: int in range(6):
			draw_line(vertices[i], vertices[(i + 1) % 6], Color(1, 1, 1, 0.6), 1.0)

		# Label (first letter of cell name)
		var cell_name: String = GameState.cell_names.get(cell_type, "?")
		var label := cell_name.substr(0, 1).to_upper()
		var font := ThemeDB.fallback_font
		if font:
			var font_size := 14
			var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
			var text_pos := raised_center + Vector2(-text_size.x / 2.0, text_size.y / 4.0)
			draw_string(font, text_pos, label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, Color.WHITE)

# === GROWTH NODE (road junction — nerves draw the lines, nothing extra needed) ===
func _draw_growth_node(_cell_pos: Vector2i) -> void:
	pass  # Growth nodes are purely visual through nerve connections

# === NERVE CONNECTIONS ===
func _draw_nerve_connections() -> void:
	const NERVE_COLOR := Color(0.45, 0.55, 0.5, 0.6)

	for connection in GameState.nerve_connections:
		var from_pos: Vector2i = connection[0]
		var to_pos: Vector2i = connection[1]
		var from_pixel := GameState.hex_to_pixel(from_pos)
		var to_pixel   := GameState.hex_to_pixel(to_pos)
		draw_line(from_pixel, to_pixel, NERVE_COLOR, NERVE_LINE_WIDTH)

# === PACKETS ===
func _draw_packets() -> void:
	for packet in GameState.packets:
		var from_pixel := GameState.hex_to_pixel(packet.from)
		var to_pixel   := GameState.hex_to_pixel(packet.to)
		var pos := from_pixel.lerp(to_pixel, packet.progress)
		var color: Color = packet.get("debug_color", GameState.resource_colors.get(packet.resource, Color.WHITE))

		# Outer glow
		var glow := color
		glow.a = 0.3
		draw_circle(pos, 6.0, glow)
		# Core dot
		draw_circle(pos, 3.5, color)

func _edge_key(a: Vector2i, b: Vector2i) -> String:
	# Canonical key regardless of direction
	if a.x < b.x or (a.x == b.x and a.y < b.y):
		return "%d,%d>%d,%d" % [a.x, a.y, b.x, b.y]
	return "%d,%d>%d,%d" % [b.x, b.y, a.x, a.y]

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

# === INPUT ===
func _unhandled_input(event: InputEvent) -> void:
	# Mouse click
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			# Check UI safe zone
			var viewport_size := get_viewport_rect().size
			if mb.position.y > viewport_size.y - UI_SAFE_MARGIN:
				return
			# Convert screen position to world coords via canvas transform
			var world_pos := get_canvas_transform().affine_inverse() * mb.position
			var hex_pos := GameState.pixel_to_hex(world_pos)
			_handle_hex_click(hex_pos)
			get_viewport().set_input_as_handled()
		return

	# Touch input
	if event is InputEventScreenTouch:
		var st := event as InputEventScreenTouch
		if st.pressed and st.index == 0:
			var viewport_size := get_viewport_rect().size
			if st.position.y > viewport_size.y - UI_SAFE_MARGIN:
				return
			var world_pos := get_canvas_transform().affine_inverse() * st.position
			var hex_pos := GameState.pixel_to_hex(world_pos)
			_handle_hex_click(hex_pos)
			get_viewport().set_input_as_handled()

func _handle_hex_click(hex_pos: Vector2i) -> void:
	if not GameState.tile_map.has(hex_pos):
		return
	if GameState.demolish_mode:
		if GameState.placed_cells.has(hex_pos):
			GameState.remove_cell(hex_pos)
	elif GameState.selected_cell != GameState.CellType.NONE:
		GameState.place_cell(hex_pos, GameState.selected_cell)

# === HEX GEOMETRY ===
func _get_hex_vertices(center: Vector2, size: float) -> Array[Vector2]:
	var verts: Array[Vector2] = []
	for i in range(6):
		var angle := (i * 60.0 + 30.0) * PI / 180.0
		verts.append(center + Vector2(size * cos(angle), size * sin(angle)))
	return verts

func _get_tile_label(tile_type: int) -> String:
	match tile_type:
		GameState.TileType.EMPTY:
			return ""
		GameState.TileType.SUGAR_FIELD:
			return "Sugar"
		GameState.TileType.MINERAL_FIELD:
			return "Mineral"
		GameState.TileType.LOCKED:
			return ""
	return ""

func _efficiency_color(efficiency: float) -> Color:
	if efficiency >= 0.5:
		var t := (efficiency - 0.5) * 2.0
		return Color.YELLOW.lerp(Color.GREEN, t)
	else:
		var t := efficiency * 2.0
		return Color.RED.lerp(Color.YELLOW, t)
