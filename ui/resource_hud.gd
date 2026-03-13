extends HBoxContainer

var sugar_label: Label
var minerals_label: Label
var energy_label: Label
var health_label: Label

func _ready() -> void:
	anchor_right = 1.0
	offset_bottom = 50

	# Create dark semi-transparent background
	var panel_stylebox = StyleBoxFlat.new()
	panel_stylebox.bg_color = Color(0.1, 0.1, 0.15, 0.8)
	panel_stylebox.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", panel_stylebox)

	# Add some padding
	add_theme_constant_override("separation", 24)

	# Create labels
	sugar_label = _create_label("Sugar", Color(0.9, 0.85, 0.3))
	minerals_label = _create_label("Minerals", Color(0.5, 0.6, 0.8))
	energy_label = _create_label("Energy", Color(0.3, 0.7, 1.0))
	health_label = _create_label("Health", Color(0.3, 0.9, 0.4))

	# Add to container
	add_child(sugar_label)
	add_child(minerals_label)
	add_child(energy_label)
	add_child(health_label)

	# Connect to signals
	GameState.resources_updated.connect(_on_resources_updated)
	GameState.health_changed.connect(_on_health_changed)

	# Initial update
	_on_resources_updated()
	_on_health_changed()

func _create_label(name: String, color: Color) -> Label:
	var label = Label.new()
	label.text = name
	label.add_theme_color_override("font_color", color)
	var font = ThemeDB.fallback_font
	label.add_theme_font_override("font", font)
	label.add_theme_font_size_override("font_size", 20)
	return label

func _on_resources_updated() -> void:
	sugar_label.text = "🍬 %.1f" % GameState.sugar
	minerals_label.text = "💎 %.0f" % GameState.minerals
	energy_label.text = "⚡ %.1f" % GameState.energy

func _on_health_changed(_new_health: float = 0.0) -> void:
	var health_percent := GameState.organism_health * 100.0
	var health_color := Color(0.3, 0.9, 0.4) if GameState.organism_health > 0.5 else Color(0.9, 0.3, 0.3)
	health_label.add_theme_color_override("font_color", health_color)
	health_label.text = "❤️ %.0f%%" % health_percent
