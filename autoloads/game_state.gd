extends Node

## Global game state — Living Factory biological sim

# === ENUMS ===
enum CellType { NONE, BASE, EXTRACTOR, ENERGY, GROWTH }
enum TileType { LOCKED, EMPTY, SUGAR_FIELD, MINERAL_FIELD }
enum ResourceType { SUGAR, MINERAL, ENERGY }

# === CELL PROPERTIES ===
var cell_names: Dictionary = {
	CellType.BASE:      "Base",
	CellType.EXTRACTOR: "Extractor",
	CellType.ENERGY:    "Energy Cell",
	CellType.GROWTH:    "Growth Node",
}

var cell_colors: Dictionary = {
	CellType.BASE:      Color(0.9, 0.85, 0.3),
	CellType.EXTRACTOR: Color(0.3, 0.75, 0.4),
	CellType.ENERGY:    Color(0.3, 0.5,  1.0),
	CellType.GROWTH:    Color(0.8, 0.3,  0.7),
}

# Which resources each cell type accepts into its buffer
var cell_accepts: Dictionary = {
	CellType.BASE:      [ResourceType.SUGAR, ResourceType.MINERAL, ResourceType.ENERGY],
	CellType.EXTRACTOR: [],
	CellType.ENERGY:    [ResourceType.SUGAR],
	CellType.GROWTH:    [ResourceType.ENERGY, ResourceType.MINERAL],
}

# Which resources each cell type produces per tick
var cell_produces: Dictionary = {
	CellType.BASE:      [],
	CellType.EXTRACTOR: [],   # Determined at tick time by tile type
	CellType.ENERGY:    [ResourceType.ENERGY],
	CellType.GROWTH:    [],
}

# Buffer capacity per resource slot (per cell)
const BUFFER_CAPACITY: float = 20.0
# Amount produced per extractor per tick
const EXTRACT_AMOUNT: float = 3.0
# Amount energy cell converts per tick (sugar in → energy out)
const ENERGY_CONVERT_AMOUNT: float = 4.0
# Packet size — how much resource per packet
const PACKET_SIZE: float = 1.0
# Packet travel time in seconds
const PACKET_TRAVEL_TIME: float = 0.8

# Resource display colors
var resource_colors: Dictionary = {
	ResourceType.SUGAR:   Color(0.95, 0.85, 0.2),   # Yellow
	ResourceType.MINERAL: Color(0.4,  0.6,  1.0),    # Blue
	ResourceType.ENERGY:  Color(0.2,  1.0,  0.6),    # Cyan-green
}

# === GLOBAL RESOURCE TOTALS (tracked for HUD) ===
var total_sugar: float = 0.0
var total_minerals: float = 0.0
var total_energy: float = 0.0
var organism_health: float = 1.0

# === GRID STATE ===
var tile_map: Dictionary = {}
var placed_cells: Dictionary = {}      # Vector2i -> CellType
var nerve_connections: Array = []      # Array of [Vector2i, Vector2i]
var base_position: Vector2i = Vector2i.ZERO

# Cell buffers: Dictionary[Vector2i, Dictionary[ResourceType, float]]
var cell_buffers: Dictionary = {}

# === PACKETS ===
# Each packet: { from: Vector2i, to: Vector2i, resource: ResourceType, amount: float, progress: float }
var packets: Array = []

# === UI STATE ===
var selected_cell: CellType = CellType.NONE
var demolish_mode: bool = false

# === HEX CONSTANTS ===
const HEX_SIZE: float = 32.0
const HEX_DIRECTIONS: Array[Vector2i] = [
	Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 1),
	Vector2i(-1, 0), Vector2i(0, -1), Vector2i(1, -1),
]

# === SIGNALS ===
signal cell_placed(hex_pos: Vector2i, cell_type: CellType)
signal cell_removed(hex_pos: Vector2i)
signal selection_changed(cell_type: CellType)
signal demolish_toggled(active: bool)
signal resources_updated()
signal health_changed(new_health: float)
signal tiles_unlocked(positions: Array)
signal nerves_updated()
signal packets_updated()

# ============================================================
func _ready() -> void:
	_init_map()

func _init_map() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()

	const UNLOCKED_RADIUS: int = 6
	const LOCKED_RADIUS: int = 12
	const CLEAR_RADIUS: int = 2
	const SUGAR_CHANCE: float = 0.18
	const MINERAL_CHANCE: float = 0.14

	for q in range(-LOCKED_RADIUS, LOCKED_RADIUS + 1):
		for r in range(-LOCKED_RADIUS, LOCKED_RADIUS + 1):
			var pos := Vector2i(q, r)
			var dist := hex_distance(pos, Vector2i.ZERO)
			if dist > LOCKED_RADIUS:
				continue
			if dist == 0:
				tile_map[pos] = TileType.EMPTY
			elif dist <= UNLOCKED_RADIUS:
				if dist <= CLEAR_RADIUS:
					tile_map[pos] = TileType.EMPTY
				else:
					var roll := rng.randf()
					if roll < SUGAR_CHANCE:
						tile_map[pos] = TileType.SUGAR_FIELD
					elif roll < SUGAR_CHANCE + MINERAL_CHANCE:
						tile_map[pos] = TileType.MINERAL_FIELD
					else:
						tile_map[pos] = TileType.EMPTY
			else:
				tile_map[pos] = TileType.LOCKED

	_place_base(Vector2i.ZERO)

func _place_base(pos: Vector2i) -> void:
	placed_cells[pos] = CellType.BASE
	base_position = pos
	_init_cell_buffer(pos)

# ============================================================
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

# ============================================================
# === PLACEMENT ===
func can_place_cell(hex_pos: Vector2i, type: CellType) -> bool:
	if not tile_map.has(hex_pos):
		return false
	if tile_map[hex_pos] == TileType.LOCKED:
		return false
	if placed_cells.has(hex_pos):
		return false
	if type == CellType.EXTRACTOR:
		var tt: int = tile_map[hex_pos]
		if tt != TileType.SUGAR_FIELD and tt != TileType.MINERAL_FIELD:
			return false
	# Must be adjacent to at least one existing cell
	for dir in HEX_DIRECTIONS:
		if placed_cells.has(hex_pos + dir):
			return true
	return false

func place_cell(hex_pos: Vector2i, type: CellType) -> bool:
	if not can_place_cell(hex_pos, type):
		return false
	placed_cells[hex_pos] = type
	_init_cell_buffer(hex_pos)
	_rebuild_nerves()
	cell_placed.emit(hex_pos, type)
	resources_updated.emit()
	if type == CellType.GROWTH:
		_unlock_around(hex_pos)
	return true

func remove_cell(hex_pos: Vector2i) -> bool:
	if not placed_cells.has(hex_pos):
		return false
	if placed_cells[hex_pos] == CellType.BASE:
		return false
	placed_cells.erase(hex_pos)
	cell_buffers.erase(hex_pos)
	# Remove packets going to/from this cell
	packets = packets.filter(func(p): return p.from != hex_pos and p.to != hex_pos)
	_rebuild_nerves()
	cell_removed.emit(hex_pos)
	return true

func _init_cell_buffer(hex_pos: Vector2i) -> void:
	var buf: Dictionary = {}
	for rt in ResourceType.values():
		buf[rt] = 0.0
	cell_buffers[hex_pos] = buf

# ============================================================
# === GROWTH / EXPANSION ===
func _unlock_around(hex_pos: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var unlocked: Array = []

	for q in range(-2, 3):
		for r in range(-2, 3):
			var offset := Vector2i(q, r)
			if hex_distance(offset, Vector2i.ZERO) > 2:
				continue
			var neighbor := hex_pos + offset
			if neighbor == hex_pos:
				continue
			if tile_map.has(neighbor) and tile_map[neighbor] == TileType.LOCKED:
				var roll := rng.randf()
				if roll < 0.18:
					tile_map[neighbor] = TileType.SUGAR_FIELD
				elif roll < 0.32:
					tile_map[neighbor] = TileType.MINERAL_FIELD
				else:
					tile_map[neighbor] = TileType.EMPTY
				unlocked.append(neighbor)
			elif not tile_map.has(neighbor):
				tile_map[neighbor] = TileType.LOCKED
				for dir2 in HEX_DIRECTIONS:
					var far := neighbor + dir2
					if not tile_map.has(far):
						tile_map[far] = TileType.LOCKED

	if unlocked.size() > 0:
		tiles_unlocked.emit(unlocked)

# ============================================================
# === NERVE NETWORK ===
func _rebuild_nerves() -> void:
	nerve_connections.clear()
	var distances: Dictionary = {}
	var queue: Array[Vector2i] = [base_position]
	distances[base_position] = 0

	while queue.size() > 0:
		var current: Vector2i = queue.pop_front()
		for dir in HEX_DIRECTIONS:
			var nb: Vector2i = current + dir
			if placed_cells.has(nb) and not distances.has(nb):
				distances[nb] = distances[current] + 1
				queue.append(nb)

	for cell_pos in placed_cells:
		if cell_pos == base_position:
			continue
		if not distances.has(cell_pos):
			continue
		var best: Vector2i = cell_pos
		var best_dist: int = 9999
		for dir in HEX_DIRECTIONS:
			var nb: Vector2i = cell_pos + dir
			if distances.has(nb) and distances[nb] < best_dist:
				best_dist = distances[nb]
				best = nb
		if best != cell_pos:
			nerve_connections.append([cell_pos, best])

	nerves_updated.emit()

func get_nerve_efficiency(hex_pos: Vector2i) -> float:
	var dist := _get_network_distance(hex_pos)
	if dist < 0:
		return 0.0
	return clampf(1.0 - dist * 0.08, 0.2, 1.0)

func _get_network_distance(hex_pos: Vector2i) -> int:
	if hex_pos == base_position:
		return 0
	var visited: Dictionary = {}
	var queue: Array = [[base_position, 0]]
	visited[base_position] = true
	while queue.size() > 0:
		var item: Array = queue.pop_front()
		var current: Vector2i = item[0]
		var dist: int = item[1]
		for dir in HEX_DIRECTIONS:
			var nb: Vector2i = current + dir
			if nb == hex_pos:
				return dist + 1
			if placed_cells.has(nb) and not visited.has(nb):
				visited[nb] = true
				queue.append([nb, dist + 1])
	return -1

# Returns the set of nerve neighbors for a cell (cells connected by a nerve edge)
func get_nerve_neighbors(hex_pos: Vector2i) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for conn in nerve_connections:
		if conn[0] == hex_pos:
			result.append(conn[1])
		elif conn[1] == hex_pos:
			result.append(conn[0])
	return result

# ============================================================
# === RESOURCE TICK (1s) ===
func process_tick() -> void:
	# 1. Extractors produce into their own buffer
	for cell_pos in placed_cells:
		var type: int = placed_cells[cell_pos]
		match type:
			CellType.EXTRACTOR:
				var tile_type: int = tile_map.get(cell_pos, TileType.EMPTY)
				var rt: int = -1
				if tile_type == TileType.SUGAR_FIELD:
					rt = ResourceType.SUGAR
				elif tile_type == TileType.MINERAL_FIELD:
					rt = ResourceType.MINERAL
				if rt >= 0:
					var buf: Dictionary = cell_buffers[cell_pos]
					buf[rt] = minf(buf[rt] + EXTRACT_AMOUNT, BUFFER_CAPACITY)

			CellType.ENERGY:
				# Convert sugar from buffer → energy
				var buf: Dictionary = cell_buffers[cell_pos]
				var sugar_in: float = minf(buf[ResourceType.SUGAR], ENERGY_CONVERT_AMOUNT)
				if sugar_in > 0.0:
					buf[ResourceType.SUGAR] -= sugar_in
					buf[ResourceType.ENERGY] = minf(
						buf[ResourceType.ENERGY] + sugar_in * 2.0,
						BUFFER_CAPACITY
					)

	# 2. Route packets outward from each cell
	_route_packets()

	# 3. Deliver arrived packets (progress >= 1.0)
	_deliver_packets()

	# 4. Update global totals for HUD
	_update_totals()

	organism_health = 1.0  # TODO: re-enable drain later
	resources_updated.emit()
	health_changed.emit(organism_health)

func _route_packets() -> void:
	# For each cell, check if it has surplus resources to send out
	for cell_pos in placed_cells:
		var buf: Dictionary = cell_buffers[cell_pos]
		for rt in ResourceType.values():
			var amount: float = buf.get(rt, 0.0)
			if amount < PACKET_SIZE:
				continue

			# Find best neighbor to send to via nerve
			var target := _find_best_target(cell_pos, rt)
			if target == cell_pos:
				continue  # No valid target found

			# Spawn packet
			buf[rt] -= PACKET_SIZE
			packets.append({
				"from": cell_pos,
				"to": target,
				"resource": rt,
				"amount": PACKET_SIZE,
				"progress": 0.0,
			})

	packets_updated.emit()

func _find_best_target(from: Vector2i, rt: int) -> Vector2i:
	var neighbors := get_nerve_neighbors(from)
	var best: Vector2i = from
	var best_need: float = -1.0

	for nb in neighbors:
		if not placed_cells.has(nb):
			continue
		var nb_type: int = placed_cells[nb]
		var accepted: Array = cell_accepts.get(nb_type, [])

		# Does this cell accept this resource?
		if not rt in accepted:
			# Try to relay through it toward a cell that does
			continue

		var nb_buf: Dictionary = cell_buffers[nb]
		var current_level: float = nb_buf.get(rt, 0.0)
		var need: float = BUFFER_CAPACITY - current_level

		if need > best_need:
			best_need = need
			best = nb

	return best

func _deliver_packets() -> void:
	var remaining: Array = []
	for packet in packets:
		if packet.progress >= 1.0:
			# Deliver to destination buffer
			var dest: Vector2i = packet.to
			if cell_buffers.has(dest):
				var buf: Dictionary = cell_buffers[dest]
				var rt: int = packet.resource
				buf[rt] = minf(buf.get(rt, 0.0) + packet.amount, BUFFER_CAPACITY)
		else:
			remaining.append(packet)
	packets = remaining

# ============================================================
# === VISUAL TICK (called at ~10fps from ticker) ===
func advance_packets(delta: float) -> void:
	var speed: float = 1.0 / PACKET_TRAVEL_TIME
	for packet in packets:
		packet.progress = minf(packet.progress + delta * speed, 1.0)
	packets_updated.emit()

# ============================================================
# === HUD TOTALS ===
func _update_totals() -> void:
	total_sugar = 0.0
	total_minerals = 0.0
	total_energy = 0.0
	for cell_pos in cell_buffers:
		var buf: Dictionary = cell_buffers[cell_pos]
		total_sugar    += buf.get(ResourceType.SUGAR,   0.0)
		total_minerals += buf.get(ResourceType.MINERAL, 0.0)
		total_energy   += buf.get(ResourceType.ENERGY,  0.0)

# ============================================================
# === HEX MATH ===
static func hex_distance(a: Vector2i, b: Vector2i) -> int:
	var dq: int = a.x - b.x
	var dr: int = a.y - b.y
	var ds: int = (-a.x - a.y) - (-b.x - b.y)
	return (absi(dq) + absi(dr) + absi(ds)) / 2

static func hex_to_pixel(hex: Vector2i) -> Vector2:
	var x: float = HEX_SIZE * (sqrt(3.0) * hex.x + sqrt(3.0) / 2.0 * hex.y)
	var y: float = HEX_SIZE * (3.0 / 2.0 * hex.y)
	return Vector2(x, y)

static func pixel_to_hex(pixel: Vector2) -> Vector2i:
	var q: float = (sqrt(3.0) / 3.0 * pixel.x - 1.0 / 3.0 * pixel.y) / HEX_SIZE
	var r: float = (2.0 / 3.0 * pixel.y) / HEX_SIZE
	return _axial_round(q, r)

static func _axial_round(q: float, r: float) -> Vector2i:
	var s: float = -q - r
	var rq: float = roundf(q)
	var rr: float = roundf(r)
	var rs: float = roundf(s)
	var dq: float = absf(rq - q)
	var dr: float = absf(rr - r)
	var ds: float = absf(rs - s)
	if dq > dr and dq > ds:
		rq = -rr - rs
	elif dr > ds:
		rr = -rq - rs
	return Vector2i(int(rq), int(rr))
