extends PanelContainer
## Polytopia-style hex-info bottom sheet.
## Hidden until the player taps a hex; slides up with tile info + context actions.

# ── Layout ──────────────────────────────────────────────────────────────────
const PANEL_HEIGHT: float = 160.0
const SLIDE_SPEED:  float = 800.0   # px / sec

var _target_y: float = 0.0   # 0 = fully visible, PANEL_HEIGHT = hidden
var _current_y: float = 0.0  # offset from the bottom anchor

# ── Child refs (built in _ready) ────────────────────────────────────────────
var _title_label:    Label
var _subtitle_label: Label
var _button_row:     HBoxContainer

func _ready() -> void:
	# ── Panel style ──────────────────────────────────────────────────────────
	custom_minimum_size = Vector2(0, PANEL_HEIGHT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.13, 0.96)
	sb.set_corner_radius_all(0)
	sb.corner_radius_top_left  = 16
	sb.corner_radius_top_right = 16
	add_theme_stylebox_override("panel", sb)

	# ── Anchor: bottom full-width ────────────────────────────────────────────
	set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	offset_top    = -PANEL_HEIGHT
	offset_bottom = 0.0
	offset_left   = 0.0
	offset_right  = 0.0

	# ── Inner layout ─────────────────────────────────────────────────────────
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   20)
	margin.add_theme_constant_override("margin_right",  20)
	margin.add_theme_constant_override("margin_top",    16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(vbox)
	add_child(margin)

	_title_label = Label.new()
	_title_label.add_theme_font_size_override("font_size", 18)
	_title_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95))
	vbox.add_child(_title_label)

	_subtitle_label = Label.new()
	_subtitle_label.add_theme_font_size_override("font_size", 13)
	_subtitle_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	_subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	vbox.add_child(_subtitle_label)

	_button_row = HBoxContainer.new()
	_button_row.add_theme_constant_override("separation", 10)
	vbox.add_child(_button_row)

	# ── Start hidden (slid off bottom) ───────────────────────────────────────
	_current_y = PANEL_HEIGHT
	_target_y  = PANEL_HEIGHT
	_apply_offset()

	# ── Signals ──────────────────────────────────────────────────────────────
	GameState.hex_selection_changed.connect(_on_hex_selection_changed)
	GameState.cell_placed.connect(func(_a, _b): _refresh())
	GameState.cell_removed.connect(func(_a): _refresh())

func _process(delta: float) -> void:
	if absf(_current_y - _target_y) > 0.5:
		_current_y = move_toward(_current_y, _target_y, SLIDE_SPEED * delta)
		_apply_offset()

func _apply_offset() -> void:
	offset_top    = -PANEL_HEIGHT + _current_y
	offset_bottom = _current_y

# ── Hex selection ────────────────────────────────────────────────────────────
func _on_hex_selection_changed(hex_pos: Vector2i) -> void:
	if hex_pos == GameState.NO_HEX:
		_target_y = PANEL_HEIGHT   # slide out
		return
	_rebuild_panel(hex_pos)
	_target_y = 0.0               # slide in

func _refresh() -> void:
	if GameState.selected_hex != GameState.NO_HEX:
		_rebuild_panel(GameState.selected_hex)

# ── Panel content ─────────────────────────────────────────────────────────────
func _rebuild_panel(hex_pos: Vector2i) -> void:
	# Clear old buttons
	for child in _button_row.get_children():
		child.queue_free()

	var tile_type:  int = GameState.tile_map.get(hex_pos, -1)
	var cell_type:  int = GameState.placed_cells.get(hex_pos, GameState.CellType.NONE)
	var is_locked:  bool = tile_type == GameState.TileType.LOCKED

	# ── Title / subtitle ─────────────────────────────────────────────────────
	_title_label.text    = _tile_name(tile_type, cell_type)
	_subtitle_label.text = _tile_description(tile_type, cell_type, is_locked)

	# ── Action buttons ───────────────────────────────────────────────────────
	if is_locked:
		return  # no actions on locked tiles

	var has_cell: bool = cell_type != GameState.CellType.NONE

	if not has_cell:
		# What can be placed here?
		var can_extractor: bool = GameState.can_place_cell(hex_pos, GameState.CellType.EXTRACTOR)
		var can_growth:    bool = GameState.can_place_cell(hex_pos, GameState.CellType.GROWTH)

		if can_extractor:
			_add_button("Build Extractor", Color(0.25, 0.55, 0.35), func():
				GameState.place_cell(hex_pos, GameState.CellType.EXTRACTOR)
			)
		if can_growth:
			_add_button("Build Road", Color(0.4, 0.25, 0.55), func():
				GameState.place_cell(hex_pos, GameState.CellType.GROWTH)
			)
		if not can_extractor and not can_growth:
			_subtitle_label.text += "\nCan't build here — place adjacent to existing cells."
	else:
		# There's a cell — offer demolish (not on base)
		if cell_type != GameState.CellType.BASE:
			_add_button("Demolish", Color(0.55, 0.15, 0.15), func():
				GameState.remove_cell(hex_pos)
				GameState.deselect_hex()
			)

func _add_button(label: String, bg: Color, callback: Callable) -> void:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(120, 44)

	var sb_normal := StyleBoxFlat.new()
	sb_normal.bg_color = bg
	sb_normal.set_corner_radius_all(8)
	btn.add_theme_stylebox_override("normal", sb_normal)

	var sb_hover := StyleBoxFlat.new()
	sb_hover.bg_color = bg.lightened(0.15)
	sb_hover.set_corner_radius_all(8)
	btn.add_theme_stylebox_override("hover", sb_hover)

	var sb_pressed := StyleBoxFlat.new()
	sb_pressed.bg_color = bg.darkened(0.15)
	sb_pressed.set_corner_radius_all(8)
	btn.add_theme_stylebox_override("pressed", sb_pressed)

	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_font_size_override("font_size", 14)
	btn.pressed.connect(callback)
	_button_row.add_child(btn)

# ── Display helpers ───────────────────────────────────────────────────────────
func _tile_name(tile_type: int, cell_type: int) -> String:
	if cell_type != GameState.CellType.NONE:
		return GameState.cell_names.get(cell_type, "Unknown")
	match tile_type:
		GameState.TileType.EMPTY:        return "Empty Hex"
		GameState.TileType.SUGAR_FIELD:  return "Sugar Field"
		GameState.TileType.MINERAL_FIELD: return "Mineral Field"
		GameState.TileType.LOCKED:       return "Locked Territory"
	return "Unknown"

func _tile_description(tile_type: int, cell_type: int, is_locked: bool) -> String:
	if is_locked:
		return "Expand your network to unlock this area."
	match cell_type:
		GameState.CellType.BASE:
			return "Your central hub. Resources are delivered here."
		GameState.CellType.EXTRACTOR:
			if tile_type == GameState.TileType.SUGAR_FIELD:
				return "Harvesting sugar from this field."
			elif tile_type == GameState.TileType.MINERAL_FIELD:
				return "Harvesting minerals from this field."
			return "Extracting resources."
		GameState.CellType.GROWTH:
			return "Road junction — routes items toward the base."
	# Empty tile
	match tile_type:
		GameState.TileType.SUGAR_FIELD:
			return "Rich in sugar. Build an Extractor to harvest it."
		GameState.TileType.MINERAL_FIELD:
			return "Mineral deposit. Build an Extractor to harvest it."
	return "An open hex. Build a Road to expand your network."
