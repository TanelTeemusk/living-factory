extends Node

## Global game state — Living Factory biological sim

# === ENUMS ===
enum CellType { NONE, BASE, EXTRACTOR, GROWTH }
enum TileType { LOCKED, EMPTY, SUGAR_FIELD, MINERAL_FIELD }
enum ResourceType { SUGAR, MINERAL }

# === CELL PROPERTIES ===
var cell_names: Dictionary = {
	CellType.BASE:      "Base",
	CellType.EXTRACTOR: "Extractor",
	CellType.GROWTH:    "Growth Node",
}

var cell_colors: Dictionary = {
	CellType.BASE:      Color(0.9,  0.85, 0.3),
	CellType.EXTRACTOR: Color(0.3,  0.75, 0.4),
	CellType.GROWTH:    Color(0.8,  0.3,  0.7),
}

# Resource display colors
var resource_colors: Dictionary = {
	ResourceType.SUGAR:   Color(0.9,  0.95, 1.0),
	ResourceType.MINERAL: Color(0.3,  0.5,  1.0),
}

# === CONSTANTS ===
const EXTRACT_INTERVAL: float = 1.5   # seconds between extractor producing one item
const PACKET_TRAVEL_TIME: float = 0.8 # seconds to cross one segment
const MIN_ITEM_GAP: float = 0.5       # minimum progress gap — limits belt to ~2 items max

# === GLOBAL RESOURCE TOTALS ===
var total_sugar: float = 0.0
var total_minerals: float = 0.0
var organism_health: float = 1.0

# === GRID STATE ===
var tile_map: Dictionary = {}
var placed_cells: Dictionary = {}
var nerve_connections: Array = []
var nerve_parent: Dictionary = {}
var base_position: Vector2i = Vector2i.ZERO

# Extractor production timers: Vector2i -> float (time until next item)
var extractor_timers: Dictionary = {}

# === PACKETS ===
# { from: Vector2i, to: Vector2i, resource: int, progress: float }
# progress: 0.0=at from, 1.0=at to
# Items live on belt segments. At progress=1.0 they wait to enter next segment.
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
	for dir in HEX_DIRECTIONS:
		if placed_cells.has(hex_pos + dir):
			return true
	return false

func place_cell(hex_pos: Vector2i, type: CellType) -> bool:
	if not can_place_cell(hex_pos, type):
		return false
	placed_cells[hex_pos] = type
	if type == CellType.EXTRACTOR:
		extractor_timers[hex_pos] = EXTRACT_INTERVAL
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
	extractor_timers.erase(hex_pos)
	nerve_parent.erase(hex_pos)
	packets = packets.filter(func(p): return p.from != hex_pos and p.to != hex_pos)
	_rebuild_nerves()
	cell_removed.emit(hex_pos)
	return true

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
# === NERVE NETWORK — roads never change once built ===
func _rebuild_nerves() -> void:
	# BFS from base. Parent is assigned at discovery time — the cell that
	# first reaches a neighbor becomes its parent. This guarantees:
	# - Parent is always exactly one hop closer to base
	# - Direction is always away from base (outward) toward leaves
	# - No second-pass ambiguity or tiebreaking needed
	# - Extractors are never used as parents (dead-ends)
	#
	# Roads never change: we skip cells that already have a nerve_parent.

	var visited: Dictionary = {}
	var queue: Array[Vector2i] = [base_position]
	visited[base_position] = true

	while queue.size() > 0:
		var current: Vector2i = queue.pop_front()
		for dir in HEX_DIRECTIONS:
			var nb: Vector2i = current + dir
			if not placed_cells.has(nb):
				continue
			if visited.has(nb):
				continue
			visited[nb] = true

			# Extractors are dead-ends — they get a parent (their one outlet)
			# but they can never BE a parent for anyone else.
			# So: assign nb's parent = current, but don't expand from extractors.
			if not nerve_parent.has(nb):
				# Only assign if current is not an extractor
				# (extractor can't be a relay/parent)
				if placed_cells.get(current, CellType.NONE) != CellType.EXTRACTOR:
					nerve_parent[nb] = current

			# Don't BFS through extractors — they're leaves
			if placed_cells.get(nb, CellType.NONE) != CellType.EXTRACTOR:
				queue.append(nb)

	# Rebuild rendering list from nerve_parent
	nerve_connections.clear()
	for cell_pos in nerve_parent:
		if placed_cells.has(cell_pos):
			nerve_connections.append([cell_pos, nerve_parent[cell_pos]])

	# Drop packets on edges that no longer exist
	packets = packets.filter(func(p): return \
		placed_cells.has(p.from) and placed_cells.has(p.to) and \
		nerve_parent.has(p.from) and nerve_parent[p.from] == p.to)

	nerves_updated.emit()

# ============================================================
# === BELT HELPERS ===

# Lowest progress of any item on this directed edge (-1.0 if belt empty).
# This is the item closest to the entry point (progress=0) — the "back of the queue".
# A new item can only enter if this back item has moved far enough away from 0.
func _belt_back(from_pos: Vector2i, to_pos: Vector2i) -> float:
	var back: float = 2.0  # sentinel: higher than any real progress
	for p in packets:
		if p.from == from_pos and p.to == to_pos:
			if p.progress < back:
				back = p.progress
	if back > 1.0:
		return -1.0  # empty
	return back

# Can a new item enter this belt?
# Yes if belt is empty, or the rearmost item has moved at least MIN_ITEM_GAP from entry.
func _belt_accepts_entry(from_pos: Vector2i, to_pos: Vector2i) -> bool:
	var back: float = _belt_back(from_pos, to_pos)
	if back < 0.0:
		return true  # empty belt
	return back >= MIN_ITEM_GAP

# ============================================================
# === MAIN UPDATE — called every frame from resource_ticker ===
func advance_packets(delta: float) -> void:
	var speed: float = 1.0 / PACKET_TRAVEL_TIME

	# --- Step 1: Extractor production ---
	# Extractors tick their timer and push one item onto their outgoing belt when ready.
	for cell_pos in extractor_timers.keys():
		if not placed_cells.has(cell_pos):
			continue
		if not nerve_parent.has(cell_pos):
			continue
		var parent: Vector2i = nerve_parent[cell_pos]
		# Only count down if the belt can accept a new item
		if not _belt_accepts_entry(cell_pos, parent):
			continue  # belt full — stall extraction (back-pressure)
		extractor_timers[cell_pos] -= delta
		if extractor_timers[cell_pos] <= 0.0:
			extractor_timers[cell_pos] = EXTRACT_INTERVAL
			var tile_type: int = tile_map.get(cell_pos, TileType.EMPTY)
			var rt: int = -1
			if tile_type == TileType.SUGAR_FIELD:
				rt = ResourceType.SUGAR
			elif tile_type == TileType.MINERAL_FIELD:
				rt = ResourceType.MINERAL
			if rt >= 0:
				packets.append({
					"from":     cell_pos,
					"to":       parent,
					"resource": rt,
					"progress": 0.0,
				})

	# --- Step 2: Move items along their belts ---
	# Sort front-to-back so leaders advance first, making room for followers.
	packets.sort_custom(func(a, b): return a.progress > b.progress)

	var remaining: Array = []

	var all_packets: Array = packets.duplicate()  # snapshot before we modify

	for packet in packets:
		var from_pos: Vector2i = packet.from
		var to_pos: Vector2i   = packet.to

		# Find the closest item ahead on the same belt (search full snapshot)
		var ahead_progress: float = 1.1  # beyond max so default = no blocker
		for other in all_packets:
			if other == packet:
				continue
			if other.from == from_pos and other.to == to_pos:
				if other.progress > packet.progress and other.progress < ahead_progress:
					ahead_progress = other.progress

		# Can advance up to (ahead - MIN_ITEM_GAP). If no blocker, can go to 1.0.
		var cap: float
		if ahead_progress > 1.0:
			cap = 1.0  # nothing ahead, move freely
		else:
			cap = maxf(ahead_progress - MIN_ITEM_GAP, packet.progress)  # don't move backward

		var new_progress: float = minf(packet.progress + delta * speed, cap)
		packet.progress = new_progress

		if new_progress < 1.0:
			remaining.append(packet)
			continue

		# --- Step 3: Item reached end of segment ---
		var dest_type: int = placed_cells.get(to_pos, CellType.NONE)

		if dest_type == CellType.BASE:
			# Arrived at base — consume
			total_sugar    += 1.0 if packet.resource == ResourceType.SUGAR   else 0.0
			total_minerals += 1.0 if packet.resource == ResourceType.MINERAL else 0.0
			resources_updated.emit()
			# drop packet

		elif dest_type == CellType.EXTRACTOR:
			# Extractors never receive items — hold packet at end of segment forever
			# (this shouldn't happen if _rebuild_nerves is correct, but safety net)
			packet.progress = 1.0
			remaining.append(packet)

		elif dest_type == CellType.GROWTH and nerve_parent.has(to_pos):
			# Growth node = pure relay. Pass through to next belt immediately.
			var next_hop: Vector2i = nerve_parent[to_pos]
			if _belt_accepts_entry(to_pos, next_hop):
				remaining.append({
					"from":     to_pos,
					"to":       next_hop,
					"resource": packet.resource,
					"progress": 0.0,
				})
			else:
				# Next belt full — wait at end of current segment
				packet.progress = 1.0
				remaining.append(packet)

		else:
			# Unknown/disconnected — drop
			pass

	packets = remaining
	packets_updated.emit()

# ============================================================
# === LEGACY TICK — called by resource_ticker every 1s ===
# Only updates HUD totals now; production is frame-driven above.
func process_tick() -> void:
	organism_health = 1.0
	health_changed.emit(organism_health)

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
