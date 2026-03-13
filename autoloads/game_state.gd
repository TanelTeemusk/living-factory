extends Node

## Global game state — Living Factory biological sim

# === CELL TYPES ===
enum CellType { NONE, BASE, EXTRACTOR, ENERGY, GROWTH }

# === TILE TYPES ===
enum TileType { LOCKED, EMPTY, SUGAR_FIELD, MINERAL_FIELD }

# === RESOURCES ===
var sugar: float = 50.0
var minerals: float = 30.0
var energy: float = 20.0  # ATP

# === METABOLIC STATE ===
var energy_production: float = 0.0   # Per tick
var energy_demand: float = 0.0       # Per tick
var organism_health: float = 1.0     # 0.0 - 1.0
var tick_interval: float = 1.0       # Seconds between resource ticks

# === CELL COSTS ===
var cell_costs: Dictionary = {
	CellType.EXTRACTOR: {"energy": 5.0, "minerals": 10.0},
	CellType.ENERGY: {"energy": 3.0, "minerals": 15.0},
	CellType.GROWTH: {"energy": 10.0, "minerals": 20.0},
}

# === CELL PROPERTIES ===
var cell_names: Dictionary = {
	CellType.BASE: "Base",
	CellType.EXTRACTOR: "Extractor",
	CellType.ENERGY: "Energy Cell",
	CellType.GROWTH: "Growth Node",
}

var cell_colors: Dictionary = {
	CellType.BASE: Color(0.9, 0.85, 0.3),       # Gold
	CellType.EXTRACTOR: Color(0.3, 0.75, 0.4),   # Green
	CellType.ENERGY: Color(0.3, 0.5, 1.0),        # Blue
	CellType.GROWTH: Color(0.8, 0.3, 0.7),        # Purple
}

# Cell energy demand per tick
var cell_energy_demand: Dictionary = {
	CellType.BASE: 0.0,
	CellType.EXTRACTOR: 1.0,
	CellType.ENERGY: 0.5,
	CellType.GROWTH: 2.0,
}

# === GRID STATE ===
# Hex tile types: Dictionary[Vector2i, TileType]
var tile_map: Dictionary = {}
# Placed cells: Dictionary[Vector2i, CellType]
var placed_cells: Dictionary = {}
# Nerve connections: Array of [Vector2i, Vector2i] pairs
var nerve_connections: Array = []
# Base cell position
var base_position: Vector2i = Vector2i(0, 0)

# === UI STATE ===
var selected_cell: CellType = CellType.NONE
var demolish_mode: bool = false

# === SIGNALS ===
signal cell_placed(hex_pos: Vector2i, cell_type: CellType)
signal cell_removed(hex_pos: Vector2i)
signal selection_changed(cell_type: CellType)
signal demolish_toggled(active: bool)
signal resources_updated()
signal health_changed(new_health: float)
signal tiles_unlocked(positions: Array)
signal nerves_updated()

# === HEX GRID CONSTANTS ===
# Pointy-top hex
const HEX_SIZE: float = 32.0  # Outer radius

# Axial direction vectors for pointy-top hex (6 neighbors)
const HEX_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]

func _ready() -> void:
	_init_map()

func _init_map() -> void:
	# Create initial map: small unlocked area around origin with some resource fields
	# Unlock a radius-3 area around the base
	for q in range(-3, 4):
		for r in range(-3, 4):
			var s = -q - r
			if absi(q) + absi(r) + absi(s) <= 6:  # Hex distance <= 3
				var pos = Vector2i(q, r)
				# Scatter some resource fields
				var dist = hex_distance(pos, Vector2i.ZERO)
				if dist == 0:
					tile_map[pos] = TileType.EMPTY  # Base goes here
				elif dist >= 2:
					# Pseudo-random resource placement based on coords
					var hash_val = (q * 7 + r * 13) % 5
					if hash_val == 0:
						tile_map[pos] = TileType.SUGAR_FIELD
					elif hash_val == 1:
						tile_map[pos] = TileType.MINERAL_FIELD
					else:
						tile_map[pos] = TileType.EMPTY
				else:
					tile_map[pos] = TileType.EMPTY

	# Add locked tiles at radius 4 (visible but not yet usable)
	for q in range(-5, 6):
		for r in range(-5, 6):
			var s = -q - r
			var pos = Vector2i(q, r)
			if not tile_map.has(pos) and absi(q) + absi(r) + absi(s) <= 10:
				tile_map[pos] = TileType.LOCKED

	# Place the base cell
	placed_cells[Vector2i.ZERO] = CellType.BASE
	base_position = Vector2i.ZERO

# === SELECTION ===
func select_cell(type: CellType) -> void:
	demolish_mode = false
	selected_cell = type
	selection_changed.emit(type)
	demolish_toggled.emit(false)

func toggle_demolish() -> void:
	selected_cell = CellType.NONE
	demolish_mode = !demolish_mode
	selection_changed.emit(CellType.NONE)
	demolish_toggled.emit(demolish_mode)

func clear_selection() -> void:
	selected_cell = CellType.NONE
	demolish_mode = false
	selection_changed.emit(CellType.NONE)
	demolish_toggled.emit(false)

# === PLACEMENT ===
func can_place_cell(hex_pos: Vector2i, type: CellType) -> bool:
	# Must be on an unlocked, non-locked tile
	if not tile_map.has(hex_pos):
		return false
	if tile_map[hex_pos] == TileType.LOCKED:
		return false
	# Can't place on occupied tile
	if placed_cells.has(hex_pos):
		return false
	# Extractor must be on a resource field
	if type == CellType.EXTRACTOR:
		if tile_map[hex_pos] != TileType.SUGAR_FIELD and tile_map[hex_pos] != TileType.MINERAL_FIELD:
			return false
	# TODO: Re-enable cost checks later
	# if cell_costs.has(type):
	#	var cost = cell_costs[type]
	#	if energy < cost.get("energy", 0):
	#		return false
	#	if minerals < cost.get("minerals", 0):
	#		return false
	# Must be adjacent to at least one existing cell (connected to organism)
	var has_neighbor = false
	for dir in HEX_DIRECTIONS:
		var neighbor = hex_pos + dir
		if placed_cells.has(neighbor):
			has_neighbor = true
			break
	if not has_neighbor:
		return false
	return true

func place_cell(hex_pos: Vector2i, type: CellType) -> bool:
	if not can_place_cell(hex_pos, type):
		return false
	# TODO: Re-enable cost deductions later
	# if cell_costs.has(type):
	#	var cost = cell_costs[type]
	#	energy -= cost.get("energy", 0)
	#	minerals -= cost.get("minerals", 0)
	placed_cells[hex_pos] = type
	_rebuild_nerves()
	cell_placed.emit(hex_pos, type)
	resources_updated.emit()
	# If growth node, unlock adjacent locked tiles
	if type == CellType.GROWTH:
		_unlock_around(hex_pos)
	return true

func remove_cell(hex_pos: Vector2i) -> bool:
	if not placed_cells.has(hex_pos):
		return false
	if placed_cells[hex_pos] == CellType.BASE:
		return false  # Can't remove the base
	placed_cells.erase(hex_pos)
	_rebuild_nerves()
	cell_removed.emit(hex_pos)
	return true

# === GROWTH / EXPANSION ===
func _unlock_around(hex_pos: Vector2i) -> void:
	var unlocked: Array = []
	for dir in HEX_DIRECTIONS:
		var neighbor = hex_pos + dir
		if tile_map.has(neighbor) and tile_map[neighbor] == TileType.LOCKED:
			# Assign resource type randomly
			var hash_val = (neighbor.x * 7 + neighbor.y * 13 + 3) % 6
			if hash_val == 0:
				tile_map[neighbor] = TileType.SUGAR_FIELD
			elif hash_val == 1:
				tile_map[neighbor] = TileType.MINERAL_FIELD
			else:
				tile_map[neighbor] = TileType.EMPTY
			unlocked.append(neighbor)
		elif not tile_map.has(neighbor):
			# Add new locked tiles beyond
			for dir2 in HEX_DIRECTIONS:
				var far = neighbor + dir2
				if not tile_map.has(far):
					tile_map[far] = TileType.LOCKED
	if unlocked.size() > 0:
		tiles_unlocked.emit(unlocked)

# === NERVE NETWORK ===
func _rebuild_nerves() -> void:
	nerve_connections.clear()
	# Simple: each cell connects to nearest neighbor that is closer to base
	# BFS from base to assign distances
	var distances: Dictionary = {}
	var queue: Array[Vector2i] = [base_position]
	distances[base_position] = 0

	while queue.size() > 0:
		var current = queue.pop_front()
		for dir in HEX_DIRECTIONS:
			var neighbor = current + dir
			if placed_cells.has(neighbor) and not distances.has(neighbor):
				distances[neighbor] = distances[current] + 1
				queue.append(neighbor)

	# For each cell (except base), connect to neighbor with lowest distance
	for cell_pos in placed_cells:
		if cell_pos == base_position:
			continue
		if not distances.has(cell_pos):
			continue  # Disconnected cell
		var best_neighbor: Vector2i = cell_pos
		var best_dist: int = 9999
		for dir in HEX_DIRECTIONS:
			var neighbor = cell_pos + dir
			if distances.has(neighbor) and distances[neighbor] < best_dist:
				best_dist = distances[neighbor]
				best_neighbor = neighbor
		if best_neighbor != cell_pos:
			nerve_connections.append([cell_pos, best_neighbor])

	nerves_updated.emit()

func get_nerve_efficiency(hex_pos: Vector2i) -> float:
	# Efficiency decreases with distance from base
	var dist = _get_network_distance(hex_pos)
	if dist < 0:
		return 0.0  # Disconnected
	return clampf(1.0 - dist * 0.08, 0.2, 1.0)

func _get_network_distance(hex_pos: Vector2i) -> int:
	# BFS distance through placed cells
	if hex_pos == base_position:
		return 0
	var visited: Dictionary = {}
	var queue: Array = [[base_position, 0]]
	visited[base_position] = true

	while queue.size() > 0:
		var item = queue.pop_front()
		var current: Vector2i = item[0]
		var dist: int = item[1]
		for dir in HEX_DIRECTIONS:
			var neighbor = current + dir
			if neighbor == hex_pos:
				return dist + 1
			if placed_cells.has(neighbor) and not visited.has(neighbor):
				visited[neighbor] = true
				queue.append([neighbor, dist + 1])
	return -1  # Disconnected

# === RESOURCE TICK ===
func process_tick() -> void:
	var total_demand: float = 0.0
	var total_production: float = 0.0

	for cell_pos in placed_cells:
		var type = placed_cells[cell_pos]
		var efficiency = get_nerve_efficiency(cell_pos)

		# Demand
		total_demand += cell_energy_demand.get(type, 0.0)

		match type:
			CellType.EXTRACTOR:
				var tile_type = tile_map.get(cell_pos, TileType.EMPTY)
				if tile_type == TileType.SUGAR_FIELD:
					sugar += 3.0 * efficiency
				elif tile_type == TileType.MINERAL_FIELD:
					minerals += 2.0 * efficiency
			CellType.ENERGY:
				# Convert sugar to energy
				var conversion = minf(sugar, 5.0) * efficiency
				sugar -= conversion
				energy += conversion * 2.0
				total_production += conversion * 2.0
			CellType.GROWTH:
				pass  # Growth nodes just consume energy

	# TODO: Re-enable energy demand deduction and health drain later
	# energy -= total_demand
	# energy = maxf(energy, 0.0)

	# Update metabolic state (tracking only, no drain)
	energy_production = total_production
	energy_demand = total_demand

	# TODO: Re-enable health logic later
	# Health stays at 1.0 during building phase
	organism_health = 1.0

	resources_updated.emit()
	health_changed.emit(organism_health)

# === HEX MATH ===
static func hex_distance(a: Vector2i, b: Vector2i) -> int:
	var dq = a.x - b.x
	var dr = a.y - b.y
	var ds = (-a.x - a.y) - (-b.x - b.y)
	return (absi(dq) + absi(dr) + absi(ds)) / 2

## Convert axial hex coords to pixel position (pointy-top)
static func hex_to_pixel(hex: Vector2i) -> Vector2:
	var x = HEX_SIZE * (sqrt(3.0) * hex.x + sqrt(3.0) / 2.0 * hex.y)
	var y = HEX_SIZE * (3.0 / 2.0 * hex.y)
	return Vector2(x, y)

## Convert pixel position to axial hex coords (pointy-top)
static func pixel_to_hex(pixel: Vector2) -> Vector2i:
	var q = (sqrt(3.0) / 3.0 * pixel.x - 1.0 / 3.0 * pixel.y) / HEX_SIZE
	var r = (2.0 / 3.0 * pixel.y) / HEX_SIZE
	return _axial_round(q, r)

static func _axial_round(q: float, r: float) -> Vector2i:
	var s = -q - r
	var rq = roundf(q)
	var rr = roundf(r)
	var rs = roundf(s)
	var dq = absf(rq - q)
	var dr = absf(rr - r)
	var ds = absf(rs - s)
	if dq > dr and dq > ds:
		rq = -rr - rs
	elif dr > ds:
		rr = -rq - rs
	return Vector2i(int(rq), int(rr))
