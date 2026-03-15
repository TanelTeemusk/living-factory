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
const STAR_COUNT: int = 200

# Rendering properties
const NERVE_LINE_WIDTH: float = 2.0
const NERVE_LINE_ALPHA: float = 0.7
const GHOST_CELL_ALPHA: float = 0.4
const HOVER_OVERLAY_ALPHA: float = 0.5

# UI bounds (don't consume input if in bottom panel area)
const UI_SAFE_MARGIN: float = 170.0

# Star background — spread across world space, not viewport
var stars: Array[Vector2] = []
var star_alphas: Array[float] = []


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
			rng.randf_range(-3600, 3600),
			rng.randf_range(-3600, 3600)
		)
		stars.append(pos)
		star_alphas.append(rng.randf_range(0.15, 0.5))

	GameState.cell_placed.connect(func(_a, _b): queue_redraw())
	GameState.cell_removed.connect(func(_a): queue_redraw())
	GameState.tiles_unlocked.connect(func(_a): queue_redraw())
	GameState.nerves_updated.connect(func(): queue_redraw())
	GameState.extractor_rotated.connect(func(_h): queue_redraw())
	GameState.growth_rotated.connect(func(_h): queue_redraw())

func _draw() -> void:
	_draw_background()
	_draw_hex_tiles()
	_draw_nerve_connections()
	_draw_placed_cells()

func _visible_world_rect() -> Rect2:
	var vp := get_viewport_rect()
	var xf := get_canvas_transform().affine_inverse()
	var tl := xf * vp.position
	var br := xf * (vp.position + vp.size)
	var margin := GameState.HEX_SIZE * 2.0
	return Rect2(tl - Vector2(margin, margin), br - tl + Vector2(margin * 2.0, margin * 2.0))

# === BACKGROUND ===
func _draw_background() -> void:
	var wr := _visible_world_rect()
	draw_rect(wr, BACKGROUND_COLOR)
	# Stars — only draw ones inside the visible rect
	for i in range(stars.size()):
		if wr.has_point(stars[i]):
			draw_circle(stars[i], 1.0, Color(1.0, 1.0, 1.0, star_alphas[i]))

# === HEX TILES ===
func _draw_hex_tiles() -> void:
	var wr := _visible_world_rect()
	for tile_pos in GameState.tile_map:
		var center := GameState.hex_to_pixel(tile_pos)
		if not wr.has_point(center):
			continue
		var tile_type: int = GameState.tile_map[tile_pos]
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
	var wr := _visible_world_rect()
	for cell_pos in GameState.placed_cells:
		var cell_type: int = GameState.placed_cells[cell_pos]
		if cell_type == GameState.CellType.NONE:
			continue
		var center := GameState.hex_to_pixel(cell_pos)
		if not wr.has_point(center):
			continue

		if cell_type == GameState.CellType.GROWTH:
			_draw_growth_node(cell_pos)
			continue

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

		# Outlet arrow for extractors — always visible, even when pointing at non-road.
		# Priority: player override > BFS parent. Dim color when pointing at a non-road.
		if cell_type == GameState.CellType.EXTRACTOR:
			var outlet_pos: Vector2i
			var active: bool  # true = connected to a road/base
			if GameState.extractor_outlet.has(cell_pos):
				outlet_pos = GameState.extractor_outlet[cell_pos]
				active = GameState.nerve_parent.has(cell_pos)  # post-BFS assigned = valid road
			elif GameState.nerve_parent.has(cell_pos):
				outlet_pos = GameState.nerve_parent[cell_pos]
				active = true
			else:
				outlet_pos = cell_pos  # no direction known yet, skip
			if outlet_pos != cell_pos:
				var outlet_pixel := GameState.hex_to_pixel(outlet_pos)
				var arrow_dir  := (outlet_pixel - raised_center).normalized()
				var arrow_start := raised_center + arrow_dir * (HEX_SIZE * 0.25)
				var arrow_tip   := raised_center + arrow_dir * (HEX_SIZE * 0.72)
				var arrow_color := Color(1.0, 0.9, 0.3, 0.9) if active else Color(0.7, 0.5, 0.2, 0.55)
				var perp := Vector2(-arrow_dir.y, arrow_dir.x)
				var head_size := 5.0
				draw_line(arrow_start, arrow_tip, arrow_color, 2.0)
				draw_line(arrow_tip, arrow_tip - arrow_dir * head_size + perp * head_size * 0.6, arrow_color, 2.0)
				draw_line(arrow_tip, arrow_tip - arrow_dir * head_size - perp * head_size * 0.6, arrow_color, 2.0)

# === GROWTH NODE ===
func _draw_growth_node(cell_pos: Vector2i) -> void:
	# Always draw an outlet arrow — same priority as extractor:
	# 1. player override (growth_outlet), 2. BFS parent (nerve_parent), 3. best default toward base
	var outlet_pos: Vector2i
	var active: bool  # true = connected and actually routing
	if GameState.growth_outlet.has(cell_pos):
		outlet_pos = GameState.growth_outlet[cell_pos]
		active = GameState.nerve_parent.has(cell_pos)
	elif GameState.nerve_parent.has(cell_pos):
		outlet_pos = GameState.nerve_parent[cell_pos]
		active = true
	else:
		outlet_pos = GameState._best_default_outlet(cell_pos)
		active = false

	var center := GameState.hex_to_pixel(cell_pos)
	var outlet_pixel := GameState.hex_to_pixel(outlet_pos)
	var arrow_dir  := (outlet_pixel - center).normalized()
	var arrow_start := center + arrow_dir * (HEX_SIZE * 0.15)
	var arrow_tip   := center + arrow_dir * (HEX_SIZE * 0.62)
	# Bright teal when active, dim muted teal when disconnected/idle
	var arrow_color := Color(0.55, 0.85, 0.7, 0.85) if active else Color(0.35, 0.55, 0.5, 0.45)
	var perp := Vector2(-arrow_dir.y, arrow_dir.x)
	var head_size := 5.0
	draw_line(arrow_start, arrow_tip, arrow_color, 2.0)
	draw_line(arrow_tip, arrow_tip - arrow_dir * head_size + perp * head_size * 0.6, arrow_color, 2.0)
	draw_line(arrow_tip, arrow_tip - arrow_dir * head_size - perp * head_size * 0.6, arrow_color, 2.0)

# === NERVE CONNECTIONS ===
func _draw_nerve_connections() -> void:
	const NERVE_COLOR  := Color(0.45, 0.55, 0.5, 0.6)
	const ARROW_COLOR  := Color(0.55, 0.75, 0.65, 0.75)
	const ARROW_SIZE   := 5.0   # half-length of each arrowhead wing
	const ARROW_OFFSET := 0.62  # how far along the segment (0=from, 1=to) to place the arrow

	for connection in GameState.nerve_connections:
		var from_pos: Vector2i = connection[0]
		var to_pos:   Vector2i = connection[1]
		var from_pixel := GameState.hex_to_pixel(from_pos)
		var to_pixel   := GameState.hex_to_pixel(to_pos)
		draw_line(from_pixel, to_pixel, NERVE_COLOR, NERVE_LINE_WIDTH)

		# Skip arrow on extractor→road segments (extractor already has its own outlet arrow)
		var from_type: int = GameState.placed_cells.get(from_pos, GameState.CellType.NONE)
		if from_type == GameState.CellType.EXTRACTOR:
			continue

		# Tiny mid-segment arrowhead pointing from→to (toward base)
		var dir := (to_pixel - from_pixel).normalized()
		var perp := Vector2(-dir.y, dir.x)
		var tip := from_pixel.lerp(to_pixel, ARROW_OFFSET)
		var base_l := tip - dir * ARROW_SIZE + perp * ARROW_SIZE * 0.55
		var base_r := tip - dir * ARROW_SIZE - perp * ARROW_SIZE * 0.55
		draw_line(tip, base_l, ARROW_COLOR, 1.5)
		draw_line(tip, base_r, ARROW_COLOR, 1.5)

# === INPUT ===
func _unhandled_input(event: InputEvent) -> void:
	# Mouse click
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			var viewport_size := get_viewport_rect().size
			# Block taps inside open bottom sheet
			var panel_open := GameState.selected_hex != GameState.NO_HEX
			var safe := UI_SAFE_MARGIN if panel_open else 4.0
			if mb.position.y > viewport_size.y - safe:
				return
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
			var panel_open := GameState.selected_hex != GameState.NO_HEX
			var safe := UI_SAFE_MARGIN if panel_open else 4.0
			if st.position.y > viewport_size.y - safe:
				return
			var world_pos := get_canvas_transform().affine_inverse() * st.position
			var hex_pos := GameState.pixel_to_hex(world_pos)
			_handle_hex_click(hex_pos)
			get_viewport().set_input_as_handled()

func _handle_hex_click(hex_pos: Vector2i) -> void:
	if not GameState.tile_map.has(hex_pos):
		# Tapped outside — deselect
		GameState.deselect_hex()
		return
	GameState.select_hex(hex_pos)

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
