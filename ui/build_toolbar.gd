extends PanelContainer

var buttons: Dictionary = {}
var active_cell_type: GameState.CellType = GameState.CellType.NONE

func _ready() -> void:
	# Setup panel background
	var panel_stylebox = StyleBoxFlat.new()
	panel_stylebox.bg_color = Color(0.1, 0.1, 0.15, 0.8)
	panel_stylebox.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", panel_stylebox)

	# Create HBoxContainer for buttons
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)
	add_child(hbox)

	# Create building buttons
	_create_building_button(hbox, GameState.CellType.EXTRACTOR, "Extractor")
	_create_building_button(hbox, GameState.CellType.ENERGY, "Energy")
	_create_building_button(hbox, GameState.CellType.GROWTH, "Growth")

	# Add separator
	var separator = VSeparator.new()
	hbox.add_child(separator)

	# Add demolish button (special styling)
	_create_demolish_button(hbox)

	# Add separator
	separator = VSeparator.new()
	hbox.add_child(separator)

	# Add cancel/deselect button
	_create_cancel_button(hbox)

	# Connect signals
	GameState.selection_changed.connect(_on_selection_changed)
	GameState.demolish_toggled.connect(_on_demolish_toggled)

func _create_building_button(parent: HBoxContainer, cell_type: GameState.CellType, name: String) -> void:
	var button = Button.new()
	button.text = name
	button.custom_minimum_size = Vector2(100, 40)

	# Add cost info if available
	if cell_type in GameState.cell_costs:
		var cost = GameState.cell_costs[cell_type]
		var cost_text = ""
		if "energy" in cost and cost["energy"] > 0:
			cost_text += "⚡%.0f " % cost["energy"]
		if "minerals" in cost and cost["minerals"] > 0:
			cost_text += "💎%.0f" % cost["minerals"]
		if cost_text:
			button.text = name + "\n" + cost_text

	button.pressed.connect(func() -> void:
		GameState.select_cell(cell_type)
	)

	parent.add_child(button)
	buttons[cell_type] = button
	_update_button_style(button, cell_type)

func _create_demolish_button(parent: HBoxContainer) -> void:
	var button = Button.new()
	button.text = "Demolish"
	button.custom_minimum_size = Vector2(100, 40)
	button.pressed.connect(func() -> void:
		GameState.toggle_demolish()
	)

	parent.add_child(button)
	buttons["demolish"] = button

func _create_cancel_button(parent: HBoxContainer) -> void:
	var button = Button.new()
	button.text = "Cancel"
	button.custom_minimum_size = Vector2(80, 40)
	button.pressed.connect(func() -> void:
		GameState.clear_selection()
	)

	parent.add_child(button)
	buttons["cancel"] = button

func _update_button_style(button: Button, cell_type: GameState.CellType) -> void:
	var is_active = (cell_type == active_cell_type)

	if is_active:
		var highlight_stylebox = StyleBoxFlat.new()
		highlight_stylebox.bg_color = Color(0.2, 0.2, 0.25, 1.0)
		highlight_stylebox.set_border_width_all(3)
		highlight_stylebox.border_color = Color(0.3, 0.8, 1.0)
		button.add_theme_stylebox_override("normal", highlight_stylebox)
	else:
		var normal_stylebox = StyleBoxFlat.new()
		normal_stylebox.bg_color = Color(0.15, 0.15, 0.2, 0.9)
		button.add_theme_stylebox_override("normal", normal_stylebox)

func _on_selection_changed(cell_type: GameState.CellType) -> void:
	active_cell_type = cell_type

	for type in [GameState.CellType.EXTRACTOR, GameState.CellType.ENERGY, GameState.CellType.GROWTH]:
		if type in buttons:
			_update_button_style(buttons[type], type)

func _on_demolish_toggled(enabled: bool) -> void:
	if "demolish" in buttons:
		var demolish_button = buttons["demolish"]
		if enabled:
			var highlight_stylebox = StyleBoxFlat.new()
			highlight_stylebox.bg_color = Color(0.4, 0.15, 0.15, 1.0)
			highlight_stylebox.set_border_width_all(3)
			highlight_stylebox.border_color = Color(0.9, 0.3, 0.3)
			demolish_button.add_theme_stylebox_override("normal", highlight_stylebox)
		else:
			var normal_stylebox = StyleBoxFlat.new()
			normal_stylebox.bg_color = Color(0.15, 0.15, 0.2, 0.9)
			demolish_button.add_theme_stylebox_override("normal", normal_stylebox)
