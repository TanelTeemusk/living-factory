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
const MIN_ITEM_GAP: float = 0.25      # minimum progress gap — allows ~4 items per segment

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

# Extractor outlet overrides: Vector2i -> Vector2i (neighbor chosen by player rotation)
# If an entry exists here it overrides BFS-assigned nerve_parent for that extractor.
var extractor_outlet: Dictionary = {}

# Road (GROWTH) outlet overrides: Vector2i -> Vector2i
var growth_outlet: Dictionary = {}

signal extractor_rotated(hex_pos: Vector2i)
signal growth_rotated(hex_pos: Vector2i)

# === PACKETS ===
# { from: Vector2i, to: Vector2i, resource: int, progress: float }
# progress: 0.0=at from, 1.0=at to
# Items live on belt segments. At progress=1.0 they wait to enter next segment.
var packets: Array = []

func _make_packet(from: Vector2i, to: Vector2i, resource: int) -> Dictionary:
	return {
		"from": from,
		"to": to,
		"resource": resource,
		"progress": 0.0,
	}

# === UI STATE ===
var selected_cell: CellType = CellType.NONE  # kept for ghost rendering compat
var demolish_mode: bool = false               # kept for ghost rendering compat
var selected_hex: Vector2i = Vector2i(-999, -999)  # currently tapped hex (sentinel = none)
const NO_HEX: Vector2i = Vector2i(-999, -999)

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
signal hex_selection_changed(hex_pos: Vector2i)  # fired when tapped hex changes
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
	const LOCKED_RADIUS: int = 36
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

# Tap-to-select hex (Polytopia style)
func select_hex(hex_pos: Vector2i) -> void:
	if selected_hex == hex_pos:
		deselect_hex()
		return
	selected_hex = hex_pos
	# Clear any old build-mode state so ghost doesn't show
	selected_cell = CellType.NONE
	demolish_mode = false
	hex_selection_changed.emit(hex_pos)

func deselect_hex() -> void:
	selected_hex = NO_HEX
	selected_cell = CellType.NONE
	demolish_mode = false
	hex_selection_changed.emit(NO_HEX)

# Rotate an extractor's outlet one step clockwise through all 6 directions.
# The pointed-at neighbor doesn't have to be a road — if it isn't, the extractor
# simply idles until a road is built there. Always succeeds for any placed extractor.
func rotate_extractor(hex_pos: Vector2i) -> bool:
	if placed_cells.get(hex_pos, CellType.NONE) != CellType.EXTRACTOR:
		return false

	# All 6 neighbors as candidates (in fixed clockwise order = HEX_DIRECTIONS order)
	var candidates: Array[Vector2i] = []
	for dir in HEX_DIRECTIONS:
		candidates.append(hex_pos + dir)

	# Find current pointed direction (outlet override, or BFS parent, or default to index 0)
	var current: Vector2i = extractor_outlet.get(hex_pos, nerve_parent.get(hex_pos, Vector2i(-9999, -9999)))
	var idx := candidates.find(current)
	var next_idx := (idx + 1) % candidates.size()
	extractor_outlet[hex_pos] = candidates[next_idx]

	# Flush in-flight packets from this extractor (stale route)
	packets = packets.filter(func(p): return p.from != hex_pos)

	# Rebuild nerve so nerve_parent[hex_pos] reflects new outlet
	nerve_parent.erase(hex_pos)
	_rebuild_nerves()
	extractor_rotated.emit(hex_pos)
	return true

# Rotate a road's outlet one step through adjacent GROWTH/BASE neighbors.
# Cycles only through valid relay neighbors (not extractors, not empty).
# Cycle detection in _rebuild_nerves prevents routing loops.
func rotate_growth(hex_pos: Vector2i) -> bool:
	if placed_cells.get(hex_pos, CellType.NONE) != CellType.GROWTH:
		return false

	# Valid outlet candidates: adjacent GROWTH or BASE nodes only
	var candidates: Array[Vector2i] = []
	for dir in HEX_DIRECTIONS:
		var nb := hex_pos + dir
		var nb_type: int = placed_cells.get(nb, CellType.NONE)
		if nb_type == CellType.GROWTH or nb_type == CellType.BASE:
			candidates.append(nb)

	if candidates.size() < 2:
		return false  # nothing to rotate to

	var current: Vector2i = growth_outlet.get(hex_pos, nerve_parent.get(hex_pos, Vector2i(-9999, -9999)))
	var idx := candidates.find(current)
	var next_idx := (idx + 1) % candidates.size()
	growth_outlet[hex_pos] = candidates[next_idx]

	# Flush packets on this segment (stale route)
	packets = packets.filter(func(p): return p.from != hex_pos)

	nerve_parent.erase(hex_pos)
	_rebuild_nerves()
	growth_rotated.emit(hex_pos)
	return true

# Returns the best default outlet neighbor for a freshly placed extractor.
# Priority: adjacent GROWTH > adjacent BASE > neighbor closest in direction of base.
# Returns hex_pos itself if nothing sensible found (caller should skip setting outlet).
func _best_default_outlet(hex_pos: Vector2i) -> Vector2i:
	# 1. Adjacent road/base
	for dir in HEX_DIRECTIONS:
		var nb := hex_pos + dir
		var t: int = placed_cells.get(nb, CellType.NONE)
		if t == CellType.GROWTH or t == CellType.BASE:
			return nb
	# 2. No adjacent road — pick the neighbor whose pixel position is closest to base
	var base_pixel := hex_to_pixel(base_position)
	var hex_pixel  := hex_to_pixel(hex_pos)
	var best_nb    := hex_pos
	var best_dot   := -INF
	for dir in HEX_DIRECTIONS:
		var nb := hex_pos + dir
		var nb_pixel := hex_to_pixel(nb)
		# Dot product of (nb - hex) with (base - hex): positive = toward base
		var toward_base := (base_pixel - hex_pixel).normalized()
		var nb_dir      := (nb_pixel  - hex_pixel).normalized()
		var d := toward_base.dot(nb_dir)
		if d > best_dot:
			best_dot = d
			best_nb  = nb
	return best_nb

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
		return true  # any unlocked resource tile, no adjacency required
	if type == CellType.GROWTH:
		return true  # any unlocked empty tile, no adjacency required
	# Other cell types still require adjacency
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
		# Pre-point outlet toward nearest road/base neighbor, or toward base if none adjacent
		var best_nb := _best_default_outlet(hex_pos)
		if best_nb != hex_pos:
			extractor_outlet[hex_pos] = best_nb
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
	extractor_outlet.erase(hex_pos)
	growth_outlet.erase(hex_pos)
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
			if not nerve_parent.has(nb):
				if placed_cells.get(current, CellType.NONE) != CellType.EXTRACTOR:
					nerve_parent[nb] = current  # BFS default

			# Don't BFS through extractors — they're leaves
			if placed_cells.get(nb, CellType.NONE) != CellType.EXTRACTOR:
				queue.append(nb)

	# Post-BFS: apply growth (road) outlet overrides first, then extractor overrides.
	# Growth overrides must be applied before extractors so extractor validity check is accurate.

	# -- Growth overrides --
	for g_pos in growth_outlet:
		if placed_cells.get(g_pos, CellType.NONE) != CellType.GROWTH:
			continue
		var target: Vector2i = growth_outlet[g_pos]
		var target_type: int = placed_cells.get(target, CellType.NONE)
		if target_type == CellType.GROWTH or target_type == CellType.BASE:
			nerve_parent[g_pos] = target
		else:
			nerve_parent.erase(g_pos)  # points at non-road — road becomes a dead end

	# Cycle-break: walk nerve_parent chains; if any road loops back to itself, erase its parent
	for start in nerve_parent.keys():
		if placed_cells.get(start, CellType.NONE) != CellType.GROWTH:
			continue
		var visited_walk: Dictionary = {}
		var cur: Vector2i = start
		while nerve_parent.has(cur):
			if visited_walk.has(cur):
				nerve_parent.erase(start)  # break the cycle at the rotated node
				break
			visited_walk[cur] = true
			cur = nerve_parent[cur]

	# -- Extractor overrides --
	for ext_pos in extractor_outlet:
		if placed_cells.get(ext_pos, CellType.NONE) != CellType.EXTRACTOR:
			continue
		var target: Vector2i = extractor_outlet[ext_pos]
		var target_type: int = placed_cells.get(target, CellType.NONE)
		if target_type == CellType.GROWTH or target_type == CellType.BASE:
			nerve_parent[ext_pos] = target
		else:
			nerve_parent.erase(ext_pos)  # points at non-road — extractor idles

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
# Pass pending_packets to also check items queued this frame but not yet in self.packets.
func _belt_accepts_entry(from_pos: Vector2i, to_pos: Vector2i, pending: Array = []) -> bool:
	var back: float = _belt_back(from_pos, to_pos)
	# Also check items queued this frame (in pending but not yet in packets)
	for p in pending:
		if p.from == from_pos and p.to == to_pos:
			if back < 0.0 or p.progress < back:
				back = p.progress
	if back < 0.0:
		return true  # empty belt
	return back >= MIN_ITEM_GAP

# ============================================================
# === MAIN UPDATE — called every frame from resource_ticker ===
func advance_packets(delta: float) -> void:
	var speed: float = 1.0 / PACKET_TRAVEL_TIME

	# remaining accumulates all packets surviving this frame.
	# Declared early so Step 1 can pass it to _belt_accepts_entry
	# to prevent two items from entering the same belt in the same frame.
	var remaining: Array = []

	# Tracks which junction (growth) nodes have already forwarded an item this frame.
	# Prevents two incoming items from crossing the same junction simultaneously.
	var junction_used: Dictionary = {}

	# --- Step 1: Extractor production ---
	# Extractors tick their timer and push one item onto their outgoing belt when ready.
	for cell_pos in extractor_timers.keys():
		if not placed_cells.has(cell_pos):
			continue
		if not nerve_parent.has(cell_pos):
			continue
		var parent: Vector2i = nerve_parent[cell_pos]
		# Only count down if the belt can accept a new item (check packets + already-queued this frame)
		if not _belt_accepts_entry(cell_pos, parent, remaining):
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
				remaining.append(_make_packet(cell_pos, parent, rt))

	# --- Step 2: Pre-claim junctions ---
	# Each junction slot can be owned by at most one packet per frame.
	# Ownership is assigned to the packet with the highest progress heading to that junction.
	# Packets are keyed by identity (their dict reference) so we can check ownership in Step 3.
	# junction_used: Vector2i -> packet dict (the owner)
	packets.sort_custom(func(a, b): return a.progress > b.progress)

	for packet in packets:
		var to_pos: Vector2i = packet.to
		if placed_cells.get(to_pos, CellType.NONE) == CellType.GROWTH:
			if not junction_used.has(to_pos):
				junction_used[to_pos] = packet  # highest-progress packet wins

	# --- Step 3: Move items along their belts ---
	# Leaders move first (already sorted desc).
	var all_packets: Array = packets.duplicate()  # snapshot before we modify

	for packet in packets:
		var from_pos: Vector2i = packet.from
		var to_pos: Vector2i   = packet.to

		# Find the closest item ahead on the same belt
		var ahead_progress: float = 1.1
		for other in all_packets:
			if other == packet:
				continue
			if other.from == from_pos and other.to == to_pos:
				if other.progress > packet.progress and other.progress < ahead_progress:
					ahead_progress = other.progress

		const ENTRY_STOP: float = 1.0 - MIN_ITEM_GAP * 0.5

		var cap: float
		if ahead_progress <= 1.0:
			# Blocked by item ahead on same belt
			cap = maxf(ahead_progress - MIN_ITEM_GAP, packet.progress)
		else:
			# Nothing ahead on this belt — check destination
			var dest_type_peek: int = placed_cells.get(to_pos, CellType.NONE)
			var next_accepts: bool = false
			if dest_type_peek == CellType.BASE:
				next_accepts = true
			elif dest_type_peek == CellType.EXTRACTOR:
				next_accepts = false
			elif dest_type_peek == CellType.GROWTH and nerve_parent.has(to_pos):
				var next_hop: Vector2i = nerve_parent[to_pos]
				var is_owner: bool = junction_used.get(to_pos) == packet
				if is_owner:
					# Owner moves freely; cap at 1.0 if next belt accepts, else ENTRY_STOP
					next_accepts = _belt_accepts_entry(to_pos, next_hop, remaining)
				else:
					# Not the owner — stop before the junction so the owner has clear passage
					next_accepts = false
			if next_accepts:
				cap = 1.0
			else:
				cap = ENTRY_STOP

		var new_progress: float = minf(packet.progress + delta * speed, cap)
		packet.progress = new_progress

		if new_progress < 1.0:
			remaining.append(packet)
			continue

		# --- Step 4: Item reached end of segment (progress == 1.0) ---
		var dest_type: int = placed_cells.get(to_pos, CellType.NONE)

		if dest_type == CellType.BASE:
			total_sugar    += 1.0 if packet.resource == ResourceType.SUGAR   else 0.0
			total_minerals += 1.0 if packet.resource == ResourceType.MINERAL else 0.0
			resources_updated.emit()
			# drop packet

		elif dest_type == CellType.EXTRACTOR:
			# Safety net — should never route here
			packet.progress = 1.0
			remaining.append(packet)

		elif dest_type == CellType.GROWTH and nerve_parent.has(to_pos):
			var next_hop: Vector2i = nerve_parent[to_pos]
			if _belt_accepts_entry(to_pos, next_hop, remaining):
				var forwarded := _make_packet(to_pos, next_hop, packet.resource)
				remaining.append(forwarded)
			else:
				# Next belt full — wait
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

const SQRT3: float = 1.7320508075688772

static func hex_to_pixel(hex: Vector2i) -> Vector2:
	var x: float = HEX_SIZE * (SQRT3 * hex.x + SQRT3 * 0.5 * hex.y)
	var y: float = HEX_SIZE * 1.5 * hex.y
	return Vector2(x, y)

static func pixel_to_hex(pixel: Vector2) -> Vector2i:
	var q: float = (SQRT3 / 3.0 * pixel.x - 1.0 / 3.0 * pixel.y) / HEX_SIZE
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
