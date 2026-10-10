@tool
class_name BlockMap extends Node3D
## Block terrain painted from a BlockSet. Built as one mesh per chunk, skipping
## faces and edge decoration wherever another block covers them.

const CHUNK_SIZE := 16
const EMPTY := -1
const ID_MASK := 0xFFFF
const ROT_SHIFT := 16
## Horizontal sides in clockwise order seen from above. SIDES[i + 1] is "right" of SIDES[i].
const SIDES: Array[Vector3i] = [Vector3i(0, 0, 1), Vector3i(1, 0, 0), Vector3i(0, 0, -1), Vector3i(-1, 0, 0)]
## Y rotation that turns something modeled facing +Z (or the +X+Z corner) to face SIDES[i].
const SIDE_ANGLES: Array[float] = [0.0, PI * 0.5, PI, PI * 1.5]

## What a block presents on one of its six faces, for hiding touching faces.
## A face is hidden when the neighbor's face is FULL or the exact same shape.
const FACE_NONE := 0
const FACE_FULL := 1
const FACE_HALF := 2
const FACE_TRI := 10 ## + rotation: a ramp's side triangle.
## A partial face only a FULL neighbor face can hide (corner-ramp triangles, wedge tops).
const FACE_PART := -2

const Shape := BlockType.Shape

@export var block_set: BlockSet:
	set(value):
		if block_set and block_set.changed.is_connected(_on_block_set_changed):
			block_set.changed.disconnect(_on_block_set_changed)
		block_set = value
		if block_set:
			block_set.changed.connect(_on_block_set_changed)
		notify_property_list_changed()
		_on_block_set_changed()
## Skip faces touching another block. Turn off to compare the cost.
@export var hide_covered_faces := true:
	set(value): hide_covered_faces = value; rebuild_all()
@export var decorations := true:
	set(value): decorations = value; rebuild_all()
## Turns the whole grid around Y in 22.5 degree steps: 0 = the normal grid, 2 = 45 degrees
## (tiles facing between the cardinal directions), 1 / 3 = the 16-direction in-betweens. Put a
## second BlockMap inside the first with this set to lay tiles diagonally across it; painting
## follows the turned grid. `grid_offset` shifts it by fractions of a tile to line it up.
@export_range(0, 15) var yaw_steps := 0:
	set(value):
		yaw_steps = value
		rotation.y = deg_to_rad(22.5 * value)
@export var grid_offset := Vector3.ZERO:
	set(value):
		grid_offset = value
		position = value
## Builds a static collision body per chunk at runtime (not in the editor).
@export var generate_collision := true:
	set(value): generate_collision = value; rebuild_all()

@export_group("Editing")
@export var paint_block := 0
## Which side painted blocks face: 0 +Z, 1 +X, 2 -Z, 3 -X. Ramps rise toward it.
@export_range(0, 3) var paint_rotation := 0
## Layer used when painting into empty space.
@export var edit_layer := 0
@export_tool_button("Rebuild", "Reload") var rebuild_button := rebuild_all

## Cells as (x, y, z, value) quads. value = block id | rotation << 16.
@export_storage var cell_data: PackedInt32Array:
	get: return _encode()
	set(value): _decode(value)

## Totals for the last build: blocks, chunks, faces, faces_hidden, deco_quads, sprites, triangles.
var stats := {}

var _cells: Dictionary[Vector3i, int] = {}
var _chunk_cells: Dictionary[Vector3i, Dictionary] = {}
var _chunks: Dictionary[Vector3i, MeshInstance3D] = {}
var _dirty: Dictionary[Vector3i, bool] = {}
var _flush_queued := false
var _cursor: MeshInstance3D
## One off-tree TileMapLayer per Y level, used only to run Godot's terrain matching.
var _terrain_layers: Dictionary[int, TileMapLayer] = {}
var _terrains_dirty := true


class _Surface:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var custom0 := PackedFloat32Array()
	## Collision-only triangles (e.g. the real top under a top decal).
	var collision := PackedVector3Array()
	var quads := 0

	func arrays() -> Array:
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_NORMAL] = normals
		a[Mesh.ARRAY_TEX_UV] = uvs
		if not uv2s.is_empty():
			a[Mesh.ARRAY_TEX_UV2] = uv2s
		if not custom0.is_empty():
			a[Mesh.ARRAY_CUSTOM0] = custom0
		return a

	func format() -> int:
		return Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT if not custom0.is_empty() else 0


func _ready() -> void:
	rebuild_all()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		_free_terrain_layers()


func _on_block_set_changed() -> void:
	_terrains_dirty = true
	rebuild_all()


func _validate_property(property: Dictionary) -> void:
	if property.name == "paint_block" and block_set:
		var names := PackedStringArray()
		for block in block_set.blocks:
			names.append(block.name if block else "<empty>")
		property.hint = PROPERTY_HINT_ENUM
		property.hint_string = ",".join(names)


#region Cells

## Block id at `pos`, or EMPTY.
func get_cell(pos: Vector3i) -> int:
	var value: int = _cells.get(pos, EMPTY)
	return EMPTY if value == EMPTY else value & ID_MASK


func get_cell_rotation(pos: Vector3i) -> int:
	return (_cells.get(pos, 0) >> ROT_SHIFT) & 3


func set_cell(pos: Vector3i, id: int, rotation := 0) -> void:
	set_cell_value(pos, EMPTY if id == EMPTY else (id & ID_MASK) | ((rotation & 3) << ROT_SHIFT))


## Packed id + rotation, as stored. Handy for undo.
func get_cell_value(pos: Vector3i) -> int:
	return _cells.get(pos, EMPTY)


func set_cell_value(pos: Vector3i, value: int) -> void:
	if get_cell_value(pos) == value:
		return
	var old_type := _type_at(pos)
	var key := chunk_of(pos)
	if value == EMPTY:
		_cells.erase(pos)
		if _chunk_cells.has(key):
			_chunk_cells[key].erase(pos)
			if _chunk_cells[key].is_empty():
				_chunk_cells.erase(key)
	else:
		_cells[pos] = value
		if not _chunk_cells.has(key):
			_chunk_cells[key] = {}
		_chunk_cells[key][pos] = true
	if not _terrains_dirty:
		_update_terrain(pos, old_type, _type_at(pos))
	# Faces and edge decoration depend on all 26 neighbors.
	for x in range(-1, 2):
		for y in range(-1, 2):
			for z in range(-1, 2):
				_dirty[chunk_of(pos + Vector3i(x, y, z))] = true
	_queue_flush()


func get_used_cells() -> Array[Vector3i]:
	return _cells.keys()


func clear() -> void:
	_cells.clear()
	_chunk_cells.clear()
	rebuild_all()


static func chunk_of(pos: Vector3i) -> Vector3i:
	return Vector3i(floori(pos.x / float(CHUNK_SIZE)), floori(pos.y / float(CHUNK_SIZE)), floori(pos.z / float(CHUNK_SIZE)))


func _encode() -> PackedInt32Array:
	var data := PackedInt32Array()
	data.resize(_cells.size() * 4)
	var i := 0
	for pos in _cells:
		data[i] = pos.x
		data[i + 1] = pos.y
		data[i + 2] = pos.z
		data[i + 3] = _cells[pos]
		i += 4
	return data


func _decode(data: PackedInt32Array) -> void:
	_cells.clear()
	_chunk_cells.clear()
	for i in range(0, data.size() - 3, 4):
		var pos := Vector3i(data[i], data[i + 1], data[i + 2])
		_cells[pos] = data[i + 3]
		var key := chunk_of(pos)
		if not _chunk_cells.has(key):
			_chunk_cells[key] = {}
		_chunk_cells[key][pos] = true
	_terrains_dirty = true
	rebuild_all()

#endregion

#region Autotile

## Top tile for the block at `pos`: Godot's terrain pick if the block autotiles, else its `top`.
func get_top_tile(pos: Vector3i) -> Vector2i:
	var type := _type_at(pos)
	if type == null:
		return Vector2i(-1, -1)
	if type.has_terrain() and _terrain_layers.has(pos.y):
		var coords := _terrain_layers[pos.y].get_cell_atlas_coords(Vector2i(pos.x, pos.z))
		if coords.x >= 0:
			return coords
	return type.top


func _autotiles(type: BlockType) -> bool:
	return type != null and type.has_terrain() and block_set.tile_set != null \
		and type.terrain_set < block_set.tile_set.get_terrain_sets_count()


func _terrain_layer(y: int) -> TileMapLayer:
	if not _terrain_layers.has(y):
		var layer := TileMapLayer.new()
		layer.tile_set = block_set.tile_set
		_terrain_layers[y] = layer
	return _terrain_layers[y]


func _free_terrain_layers() -> void:
	for y in _terrain_layers:
		_terrain_layers[y].free()
	_terrain_layers.clear()


## Paints every autotile block, one layer and terrain at a time in a fixed order,
## exactly like painting the same cells on a 2D TileMapLayer.
func _rebuild_terrains() -> void:
	_terrains_dirty = false
	_free_terrain_layers()
	if block_set == null or block_set.tile_set == null:
		return
	var groups := {}
	for pos in _cells:
		var type := _type_at(pos)
		if not _autotiles(type):
			continue
		var key := Vector3i(pos.y, type.terrain_set, type.terrain)
		if not groups.has(key):
			var cells: Array[Vector2i] = []
			groups[key] = cells
		groups[key].append(Vector2i(pos.x, pos.z))
	var keys := groups.keys()
	keys.sort()
	for key: Vector3i in keys:
		var cells: Array[Vector2i] = groups[key]
		cells.sort()
		_terrain_layer(key.x).set_cells_terrain_connect(cells, key.y, key.z, block_set.ignore_empty_terrains)


## Same call the 2D editor makes when painting or erasing one terrain cell.
func _update_terrain(pos: Vector3i, old_type: BlockType, new_type: BlockType) -> void:
	if block_set == null or block_set.tile_set == null:
		return
	var had := _autotiles(old_type)
	var has := _autotiles(new_type)
	if not had and not has:
		return
	if had and has and old_type.terrain_set == new_type.terrain_set and old_type.terrain == new_type.terrain:
		return
	var cell: Array[Vector2i] = [Vector2i(pos.x, pos.z)]
	if has:
		_terrain_layer(pos.y).set_cells_terrain_connect(cell, new_type.terrain_set, new_type.terrain, block_set.ignore_empty_terrains)
	else:
		_terrain_layer(pos.y).set_cells_terrain_connect(cell, old_type.terrain_set, -1, block_set.ignore_empty_terrains)

#endregion

#region Raycast

## Grid raycast in this node's local space. Returns {cell, normal} or {} on a miss.
func raycast(from: Vector3, dir: Vector3, max_dist := 500.0) -> Dictionary:
	dir = dir.normalized()
	var cell := Vector3i(from.floor())
	var step := Vector3i(int(signf(dir.x)), int(signf(dir.y)), int(signf(dir.z)))
	var t_max := Vector3.INF
	var t_delta := Vector3.INF
	for axis in 3:
		if dir[axis] != 0.0:
			t_delta[axis] = absf(1.0 / dir[axis])
			var edge := cell[axis] + (1 if dir[axis] > 0.0 else 0)
			t_max[axis] = (edge - from[axis]) / dir[axis]
	var normal := Vector3i.ZERO
	var t := 0.0
	while t <= max_dist:
		if _cells.has(cell):
			return {"cell": cell, "normal": normal}
		var axis := t_max.min_axis_index()
		cell[axis] += step[axis]
		t = t_max[axis]
		t_max[axis] += t_delta[axis]
		normal = Vector3i.ZERO
		normal[axis] = -step[axis]
	return {}

#endregion

#region Building

func rebuild_all() -> void:
	for key in _chunks:
		_dirty[key] = true
	for key in _chunk_cells:
		_dirty[key] = true
	_queue_flush()


func _queue_flush() -> void:
	if _flush_queued:
		return
	_flush_queued = true
	_flush.call_deferred()


func _flush() -> void:
	_flush_queued = false
	if not is_inside_tree():
		return
	if _terrains_dirty:
		_rebuild_terrains()
	for key in _dirty:
		_build_chunk(key)
	_dirty.clear()
	var totals := {"blocks": _cells.size(), "chunks": _chunks.size(), "faces": 0, "faces_hidden": 0, "deco_quads": 0, "sprites": 0, "triangles": 0}
	for key in _chunks:
		var chunk_stats: Dictionary = _chunks[key].get_meta("stats")
		for stat in chunk_stats:
			totals[stat] += chunk_stats[stat]
	stats = totals


func _build_chunk(key: Vector3i) -> void:
	var inst: MeshInstance3D = _chunks.get(key)
	var members: Dictionary = _chunk_cells.get(key, {})
	if members.is_empty() or block_set == null:
		if inst:
			inst.queue_free()
			_chunks.erase(key)
		return

	var solid := _Surface.new()
	var deco := _Surface.new()
	var sprites := _Surface.new()
	var billboards := _Surface.new()
	var hidden := 0
	var sprite_reach := 0.0
	for pos in members:
		var type := _type_at(pos)
		if type == null:
			continue
		var rot := get_cell_rotation(pos)
		match type.shape:
			Shape.CUBE:
				hidden += _emit_cube(pos, rot, type, solid, deco, sprites)
			Shape.SLAB:
				hidden += _emit_slab(pos, type, solid, sprites)
			Shape.RAMP:
				hidden += _emit_ramp(pos, rot, type, solid)
			Shape.WEDGE, Shape.RAMP_OUTER, Shape.RAMP_INNER:
				hidden += _emit_diagonal(pos, rot, type, solid)
			Shape.CROSS:
				_emit_cross(pos, type, sprites)
			Shape.PANEL:
				_emit_panel(pos, rot, type, sprites)
			Shape.FLOOR:
				_emit_floor(pos, type, sprites)
			Shape.BILLBOARD:
				_emit_billboard(pos, type, billboards)
				sprite_reach = maxf(sprite_reach, maxf(type.sprite_size.x * 0.5, type.sprite_size.y))

	var mesh := ArrayMesh.new()
	if solid.quads > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, solid.arrays())
		mesh.surface_set_material(mesh.get_surface_count() - 1, block_set.get_solid_material())
	if deco.verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, deco.arrays())
		mesh.surface_set_material(mesh.get_surface_count() - 1, block_set.get_deco_material())
	if sprites.verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, sprites.arrays(), [], {}, sprites.format())
		mesh.surface_set_material(mesh.get_surface_count() - 1, block_set.get_sprite_material())
	if billboards.verts.size() > 0:
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, billboards.arrays(), [], {}, billboards.format())
		mesh.surface_set_material(mesh.get_surface_count() - 1, block_set.get_billboard_material())
		# Sprite vertices sit on their anchors until the shader spreads them out.
		mesh.custom_aabb = mesh.get_aabb().grow(sprite_reach + 0.5)

	if inst == null:
		inst = MeshInstance3D.new()
		inst.name = "Chunk_%d_%d_%d" % [key.x, key.y, key.z]
		add_child(inst, false, INTERNAL_MODE_BACK)
		_chunks[key] = inst
	inst.mesh = mesh
	inst.set_meta("stats", {
		"faces": solid.quads,
		"faces_hidden": hidden,
		"deco_quads": deco.quads,
		"sprites": sprites.quads + billboards.quads,
		"triangles": (solid.verts.size() + deco.verts.size() + sprites.verts.size() + billboards.verts.size()) / 3,
	})

	for child in inst.get_children():
		child.queue_free()
	if generate_collision and not Engine.is_editor_hint() and (solid.quads > 0 or not solid.collision.is_empty()):
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(solid.verts + solid.collision)
		var col := CollisionShape3D.new()
		col.shape = shape
		var body := StaticBody3D.new()
		body.add_child(col)
		inst.add_child(body)


func _type_at(pos: Vector3i) -> BlockType:
	if not _cells.has(pos):
		return null
	return block_set.get_block(_cells[pos] & ID_MASK)


func _solid(pos: Vector3i) -> bool:
	var type := _type_at(pos)
	return type != null and type.is_solid()


## What the block at `pos` presents on its face pointing `dir`.
func _face_code(pos: Vector3i, dir: Vector3i) -> int:
	var type := _type_at(pos)
	if type == null:
		return FACE_NONE
	var rot := get_cell_rotation(pos)
	match type.shape:
		Shape.CUBE:
			return FACE_FULL
		Shape.SLAB:
			if dir == Vector3i.DOWN:
				return FACE_FULL
			return FACE_HALF if dir.y == 0 else FACE_NONE
		Shape.RAMP:
			if dir == Vector3i.DOWN or dir == SIDES[rot]:
				return FACE_FULL
			if dir.y == 0 and dir != -SIDES[rot]:
				return FACE_TRI + rot
		Shape.WEDGE, Shape.RAMP_INNER:
			if dir == Vector3i.DOWN and type.shape == Shape.RAMP_INNER:
				return FACE_FULL
			if dir == SIDES[rot] or dir == SIDES[(rot + 1) % 4]:
				return FACE_FULL
		Shape.RAMP_OUTER:
			if dir == Vector3i.DOWN:
				return FACE_FULL
	return FACE_NONE


func _hidden(pos: Vector3i, dir: Vector3i, my_code: int) -> bool:
	if not hide_covered_faces:
		return false
	var other := _face_code(pos + dir, -dir)
	return other == FACE_FULL or (other != FACE_NONE and other == my_code)


func _covered_top(pos: Vector3i) -> bool:
	return _face_code(pos + Vector3i.UP, Vector3i.DOWN) == FACE_FULL


func _has_lip(pos: Vector3i) -> bool:
	var type := _type_at(pos)
	return type != null and type.shape == Shape.CUBE and type.decorated and type.edge_part == null and not _covered_top(pos)


## Returns how many faces were hidden.
func _emit_cube(pos: Vector3i, rot: int, type: BlockType, solid: _Surface, deco: _Surface, sprites: _Surface) -> int:
	var center := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	var covered_top := _covered_top(pos)
	var hidden := 0
	var decal := 0.0 if covered_top else type.top_decal

	if _hidden(pos, Vector3i.UP, FACE_FULL):
		hidden += 1
	elif decal > 0.0:
		# Raised visible top; the real top stays for collision only.
		_collision_face(solid, center, Vector3.UP, Vector3.RIGHT, Vector3.BACK)
		_face(deco, center + Vector3.UP * decal, Vector3.UP, Vector3.RIGHT, Vector3.BACK, get_top_tile(pos))
		_emit_decal_walls(pos, type, decal, deco)
	else:
		_top_face(pos, type, center, solid, sprites)
	if _hidden(pos, Vector3i.DOWN, FACE_FULL):
		hidden += 1
	else:
		_face(solid, center, Vector3.DOWN, Vector3.RIGHT, Vector3.BACK, type.bottom)
	for i in 4:
		var s := SIDES[i]
		if _hidden(pos, s, FACE_FULL):
			hidden += 1
			continue
		var tile := type.front if i == rot and type.front.x >= 0 else type.get_side(covered_top)
		_face(solid, center, Vector3(s), Vector3(SIDES[(i + 1) % 4]), Vector3.DOWN, tile)

	if not decorations or not type.decorated or covered_top:
		return hidden
	for i in 4:
		var s := SIDES[i]
		if _solid(pos + s):
			continue
		var t := SIDES[(i + 1) % 4]
		var outer_corner := not _solid(pos + t) and not _solid(pos + s + t)
		if type.edge_part:
			_append_mesh(deco, type.edge_part, Transform3D(Basis(Vector3.UP, SIDE_ANGLES[i]), center))
			if outer_corner and type.corner_part:
				_append_mesh(deco, type.corner_part, Transform3D(Basis(Vector3.UP, SIDE_ANGLES[i]), center))
		else:
			_emit_lip(deco, pos, i, type)
	return hidden


## Bottom half block. Sides use the top half of the side tile so grass bands still show.
func _emit_slab(pos: Vector3i, type: BlockType, solid: _Surface, sprites: _Surface) -> int:
	var c := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	var hidden := 0
	_top_face(pos, type, c + Vector3.DOWN * 0.5, solid, sprites)
	if _hidden(pos, Vector3i.DOWN, FACE_FULL):
		hidden += 1
	else:
		_face(solid, c, Vector3.DOWN, Vector3.RIGHT, Vector3.BACK, type.bottom)
	var side := type.get_side(_covered_top(pos))
	for i in 4:
		var s := SIDES[i]
		if _hidden(pos, s, FACE_HALF):
			hidden += 1
			continue
		var sv := Vector3(s)
		var right := Vector3(SIDES[(i + 1) % 4])
		var mid := c + sv * 0.5
		_quad(solid, [mid - right * 0.5, mid + right * 0.5, mid + right * 0.5 + Vector3.DOWN * 0.5, mid - right * 0.5 + Vector3.DOWN * 0.5],
			[Vector2(0, 0), Vector2(1, 0), Vector2(1, 0.5), Vector2(0, 0.5)], sv, side)
	return hidden


## Slope rising toward SIDES[rot]. Built facing +Z, then rotated.
func _emit_ramp(pos: Vector3i, rot: int, type: BlockType, solid: _Surface) -> int:
	var c := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	var b := Basis(Vector3.UP, SIDE_ANGLES[rot])
	var hidden := 0
	var side := type.get_side(_covered_top(pos))

	# Slope, mapped like a top face so it lines up with neighboring tops.
	var lo_l := Vector3(-0.5, -0.5, -0.5)
	var lo_r := Vector3(0.5, -0.5, -0.5)
	var hi_r := Vector3(0.5, 0.5, 0.5)
	var hi_l := Vector3(-0.5, 0.5, 0.5)
	_quad(solid, [c + b * lo_l, c + b * lo_r, c + b * hi_r, c + b * hi_l],
		[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], b * Vector3(0, 1, -1).normalized(), get_top_tile(pos))

	if _hidden(pos, Vector3i.DOWN, FACE_FULL):
		hidden += 1
	else:
		_face(solid, c, Vector3.DOWN, Vector3.RIGHT, Vector3.BACK, type.bottom)

	var back := SIDES[rot]
	if _hidden(pos, back, FACE_FULL):
		hidden += 1
	else:
		_face(solid, c, Vector3(back), Vector3(SIDES[(rot + 1) % 4]), Vector3.DOWN, side)

	# Side triangles. v follows the slope so the tile's top band runs along it.
	for x in [-0.5, 0.5]:
		var dir := Vector3i((b * Vector3(signf(x), 0, 0)).round())
		if _hidden(pos, dir, FACE_TRI + rot):
			hidden += 1
			continue
		var p := [Vector3(x, -0.5, -0.5), Vector3(x, -0.5, 0.5), Vector3(x, 0.5, 0.5)]
		var uvs := []
		for v: Vector3 in p:
			var u := 0.5 - v.z if x > 0.0 else v.z + 0.5
			uvs.append(Vector2(u, v.z - v.y))
		_tri(solid, [c + b * p[0], c + b * p[1], c + b * p[2]], uvs, Vector3(dir), side)
	return hidden


## WEDGE / RAMP_OUTER / RAMP_INNER, built from corner points. With s = SIDES[rot] and
## t = SIDES[rot + 1], corner A = s + t is the "high" corner, B = s - t, C = -s - t (low /
## opposite), D = -s + t. Tops and slopes use the top tile mapped flat on X/Z, so they line up
## with neighboring tops; walls use the side tile.
func _emit_diagonal(pos: Vector3i, rot: int, type: BlockType, solid: _Surface) -> int:
	var c := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	var s := Vector3(SIDES[rot]) * 0.5
	var t := Vector3(SIDES[(rot + 1) % 4]) * 0.5
	var lo := Vector3.DOWN * 0.5
	var hi := Vector3.UP * 0.5
	var a := s + t
	var b := s - t
	var cc := -s - t
	var d := -s + t
	var top := get_top_tile(pos)
	var side := type.get_side(_covered_top(pos))
	var hidden := 0
	var above_full := _face_code(pos + Vector3i.UP, Vector3i.DOWN) == FACE_FULL and hide_covered_faces

	match type.shape:
		Shape.WEDGE:
			# Prism over triangle A-B-D: two full walls, one diagonal wall, triangle top/bottom.
			hidden += _wall(solid, pos, c, SIDES[rot], [a + lo, b + lo, b + hi, a + hi], side)
			hidden += _wall(solid, pos, c, SIDES[(rot + 1) % 4], [d + lo, a + lo, a + hi, d + hi], side)
			_poly(solid, c, [b + lo, d + lo, d + hi, b + hi], (-s - t).normalized(), side, false)
			if above_full:
				hidden += 1
			else:
				_poly(solid, c, [a + hi, b + hi, d + hi], Vector3.UP, top, true)
			if _hidden(pos, Vector3i.DOWN, FACE_PART):
				hidden += 1
			else:
				_poly(solid, c, [a + lo, d + lo, b + lo], Vector3.DOWN, top, true)
		Shape.RAMP_OUTER:
			# Pyramid with its apex over A.
			var apex := a + hi
			hidden += _wall(solid, pos, c, SIDES[rot], [b + lo, a + lo, apex], side)
			hidden += _wall(solid, pos, c, SIDES[(rot + 1) % 4], [a + lo, d + lo, apex], side)
			_poly(solid, c, [apex, b + lo, cc + lo], _up_normal(apex, b + lo, cc + lo), top, true)
			_poly(solid, c, [apex, cc + lo, d + lo], _up_normal(apex, cc + lo, d + lo), top, true)
			hidden += _bottom(solid, pos, c, top)
		Shape.RAMP_INNER:
			# Cube with the corner over C sloped away: flat triangle A-B-D on top, slope B-C-D.
			hidden += _wall(solid, pos, c, SIDES[rot], [a + lo, b + lo, b + hi, a + hi], side)
			hidden += _wall(solid, pos, c, SIDES[(rot + 1) % 4], [d + lo, a + lo, a + hi, d + hi], side)
			hidden += _wall(solid, pos, c, -SIDES[(rot + 1) % 4], [b + lo, cc + lo, b + hi], side)
			hidden += _wall(solid, pos, c, -SIDES[rot], [cc + lo, d + lo, d + hi], side)
			if above_full:
				hidden += 1
			else:
				_poly(solid, c, [a + hi, b + hi, d + hi], Vector3.UP, top, true)
			_poly(solid, c, [b + hi, cc + lo, d + hi], _up_normal(b + hi, cc + lo, d + hi), top, true)
			hidden += _bottom(solid, pos, c, top)
	return hidden


## Normal of a sloped triangle, facing up.
func _up_normal(p0: Vector3, p1: Vector3, p2: Vector3) -> Vector3:
	var n := (p1 - p0).cross(p2 - p0).normalized()
	return n if n.y >= 0.0 else -n


## An axis-aligned wall (quad or triangle) on side `dir`, skipped when a full face covers it.
func _wall(surf: _Surface, pos: Vector3i, c: Vector3, dir: Vector3i, pts: Array, tile: Vector2i) -> int:
	if _hidden(pos, dir, FACE_PART if pts.size() == 3 else FACE_FULL):
		return 1
	_poly(surf, c, pts, Vector3(dir), tile, false)
	return 0


func _bottom(surf: _Surface, pos: Vector3i, c: Vector3, tile: Vector2i) -> int:
	if _hidden(pos, Vector3i.DOWN, FACE_FULL):
		return 1
	_face(surf, c, Vector3.DOWN, Vector3.RIGHT, Vector3.BACK, tile)
	return 0


## Triangle or quad from cell-local points (cell center `c`). `flat` maps the tile on X/Z
## (tops, slopes); otherwise across the face horizontally with V going down.
func _poly(surf: _Surface, c: Vector3, pts: Array, normal: Vector3, tile: Vector2i, flat: bool) -> void:
	var across := Vector3(-normal.z, 0, normal.x).normalized()
	var extent := 0.0
	for p: Vector3 in pts:
		extent = maxf(extent, absf(p.dot(across)))
	extent = maxf(extent, 0.5)
	var world := []
	var uvs := []
	for p: Vector3 in pts:
		world.append(c + p)
		uvs.append(Vector2(p.x + 0.5, p.z + 0.5) if flat else Vector2(p.dot(across) / (2.0 * extent) + 0.5, 0.5 - p.y))
	if pts.size() == 3:
		_tri(surf, world, uvs, normal, tile)
	else:
		_quad(surf, world, uvs, normal, tile)


## Two crossed quads, like Minecraft plants. Normals point up so they light like the ground.
func _emit_cross(pos: Vector3i, type: BlockType, surf: _Surface) -> void:
	var size := type.sprite_size
	var base := Vector3(pos) + Vector3(0.5, 0.0, 0.5)
	var half := size.x * 0.5
	var height := Vector3.UP * size.y
	for diag in [Vector3(half, 0, half), Vector3(half, 0, -half)]:
		_quad(surf, [base - diag + height, base + diag + height, base + diag, base - diag],
			[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], Vector3.UP, type.sprite, size)
		_tag_sprite(surf, type, 0.0)


## Top face of a block whose center is `center`. Animated tops go through the sprite
## shader; their collision stays with the solid surface.
func _top_face(pos: Vector3i, type: BlockType, center: Vector3, solid: _Surface, sprites: _Surface) -> void:
	if type.anim_frames > 1:
		_face(sprites, center, Vector3.UP, Vector3.RIGHT, Vector3.BACK, get_top_tile(pos))
		_tag_sprite(sprites, type, 0.0)
		_collision_face(solid, center, Vector3.UP, Vector3.RIGHT, Vector3.BACK)
	else:
		_face(solid, center, Vector3.UP, Vector3.RIGHT, Vector3.BACK, get_top_tile(pos))


## Flat sprite lying just above the cell floor, `sprite_size` tiles along +X / +Z.
func _emit_floor(pos: Vector3i, type: BlockType, surf: _Surface) -> void:
	var o := Vector3(pos) + Vector3.UP * 0.01
	var w := float(type.sprite_size.x)
	var d := float(type.sprite_size.y)
	_quad(surf, [o, o + Vector3(w, 0, 0), o + Vector3(w, 0, d), o + Vector3(0, 0, d)],
		[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], Vector3.UP, type.sprite, type.sprite_size)
	_tag_sprite(surf, type, 0.0)


## Flat sprite against side SIDES[rot], hanging down from the cell top.
func _emit_panel(pos: Vector3i, rot: int, type: BlockType, surf: _Surface) -> void:
	var s := Vector3(SIDES[rot])
	# Right-hand side for someone in the cell looking at the wall.
	var right := Vector3(SIDES[(rot + 3) % 4])
	var top := Vector3(pos) + Vector3(0.5, 1.0, 0.5) + s * 0.49
	var half := type.sprite_size.x * 0.5
	var drop := Vector3.DOWN * type.sprite_size.y
	_quad(surf, [top - right * half, top + right * half, top + right * half + drop, top - right * half + drop],
		[Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], -s, type.sprite, type.sprite_size)
	_tag_sprite(surf, type, 0.0)


## Animation + billboard mode for the quad just added (see sprite.gdshaderinc).
func _tag_sprite(surf: _Surface, type: BlockType, mode: float) -> void:
	var stride := block_set.frame_stride(type.sprite_size)
	for i in 6:
		surf.custom0.append_array([float(type.anim_frames), type.anim_fps, stride, mode])


## Camera-facing sprite. All four vertices sit on the cell center (the bottom-middle
## tile's center); UV2 carries each corner's offset for the billboard shader.
func _emit_billboard(pos: Vector3i, type: BlockType, surf: _Surface) -> void:
	var anchor := Vector3(pos) + Vector3(0.5, 0.5, 0.5)
	var size := type.sprite_size
	var half := size.x * 0.5
	var offsets := [Vector2(-half, size.y - 0.5), Vector2(half, size.y - 0.5), Vector2(half, -0.5), Vector2(-half, -0.5)]
	var locals := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	for i in [0, 1, 2, 0, 2, 3]:
		surf.verts.append(anchor)
		surf.normals.append(Vector3.UP)
		surf.uvs.append(block_set.tile_uv(type.sprite, locals[i], size))
		surf.uv2s.append(offsets[i])
	surf.quads += 1
	_tag_sprite(surf, type, 1.0 if type.billboard_mode == BlockType.BillboardMode.UPRIGHT else 2.0)


## Short walls around a top decal, down to whatever the neighbor covers.
func _emit_decal_walls(pos: Vector3i, type: BlockType, decal: float, deco: _Surface) -> void:
	var c := Vector3(pos) + Vector3(0.5, 1.0, 0.5)
	var side := type.get_side(false)
	for i in 4:
		var s := SIDES[i]
		var lo := maxf(1.0, _cover_height(pos, s)) - 1.0
		if lo >= decal - 0.0001:
			continue
		var sv := Vector3(s)
		var right := Vector3(SIDES[(i + 1) % 4])
		var mid := c + sv * 0.5
		var depth := decal - lo
		_quad(deco, [mid - right * 0.5 + Vector3.UP * decal, mid + right * 0.5 + Vector3.UP * decal,
			mid + right * 0.5 + Vector3.UP * lo, mid - right * 0.5 + Vector3.UP * lo],
			[Vector2(0, 0), Vector2(1, 0), Vector2(1, depth), Vector2(0, depth)], sv, side)


## How high (relative to pos.y) the neighbor on side `s` covers our side.
func _cover_height(pos: Vector3i, s: Vector3i) -> float:
	var q := pos + s
	if _solid(q + Vector3i.UP):
		return 2.0
	match _face_code(q, -s):
		FACE_FULL:
			var t := _type_at(q)
			return 1.0 + (t.top_decal if t.shape == Shape.CUBE else 0.0)
		FACE_HALF:
			return 0.5
	return 0.0


## Procedural edge decoration for side SIDES[i]: a flat lip overhanging the edge
## plus a fringe hanging off its outer rim. Trimmed where a neighbor's lip would
## overlap (inner corners), extended around outer corners.
func _emit_lip(deco: _Surface, pos: Vector3i, i: int, type: BlockType) -> void:
	var s := SIDES[i]
	var t_hi := SIDES[(i + 1) % 4]
	var t_lo := SIDES[(i + 3) % 4]
	var lip := block_set.lip
	var origin := Vector3(pos) + Vector3(0.5, 1.0 + type.top_decal, 0.5)
	var sv := Vector3(s)
	var right := Vector3(t_hi)
	var top_tile := get_top_tile(pos)

	var trim_lo := _has_lip(pos + s + t_lo)
	var trim_hi := _has_lip(pos + s + t_hi)
	var outer_lo := not _solid(pos + t_lo) and not _solid(pos + s + t_lo)
	var outer_hi := not _solid(pos + t_hi) and not _solid(pos + s + t_hi)

	# Where two lips meet at an inner corner, the X-facing lip owns the overlap.
	var strip_trims := s.x == 0
	var a := -0.5 + (lip if trim_lo and strip_trims else 0.0)
	var b := 0.5 - (lip if trim_hi and strip_trims else 0.0)
	_lip_rect(deco, origin, sv, right, a, b, top_tile)
	if outer_hi:
		_lip_rect(deco, origin, sv, right, 0.5, 0.5 + lip, top_tile)

	var fa := -0.5 + (lip if trim_lo else 0.0) - (lip if outer_lo else 0.0)
	var fb := 0.5 - (lip if trim_hi else 0.0) + (lip if outer_hi else 0.0)
	# Split at cell boundaries so fringe UVs stay inside one atlas tile.
	for seg in [Vector2(fa, -0.5), Vector2(-0.5, 0.5), Vector2(0.5, fb)]:
		var lo := maxf(seg.x, fa)
		var hi := minf(seg.y, fb)
		if hi - lo > 0.0001:
			_fringe(deco, origin, sv, right, lo, hi, type.fringe)


## Lip quad on the top plane spanning [ra, rb] along `right`, overhanging by lip along s.
func _lip_rect(surf: _Surface, origin: Vector3, s: Vector3, right: Vector3, ra: float, rb: float, tile: Vector2i) -> void:
	var lip := block_set.lip
	var p := [
		origin + right * ra + s * 0.5,
		origin + right * rb + s * 0.5,
		origin + right * rb + s * (0.5 + lip),
		origin + right * ra + s * (0.5 + lip),
	]
	var base: Vector3 = ((p[0] + p[2]) * 0.5).floor()
	var uvs := []
	for v in p:
		var local: Vector3 = v - base
		uvs.append(Vector2(local.x, local.z))
	_quad(surf, p, uvs, Vector3.UP, tile)


func _fringe(surf: _Surface, origin: Vector3, s: Vector3, right: Vector3, ra: float, rb: float, tile: Vector2i) -> void:
	var out := s * (0.5 + block_set.lip)
	var depth := block_set.fringe_depth
	var p := [
		origin + out + right * ra,
		origin + out + right * rb,
		origin + out + right * rb + Vector3.DOWN * depth,
		origin + out + right * ra + Vector3.DOWN * depth,
	]
	var base := floorf((ra + rb) * 0.5 + 0.5)
	var ua := ra + 0.5 - base
	var ub := rb + 0.5 - base
	_quad(surf, p, [Vector2(ua, 0.0), Vector2(ub, 0.0), Vector2(ub, depth), Vector2(ua, depth)], s, tile)


## Unit face of the block at `center`, facing `normal`. `right`/`down` orient the tile.
func _face(surf: _Surface, center: Vector3, normal: Vector3, right: Vector3, down: Vector3, tile: Vector2i) -> void:
	var c := center + normal * 0.5
	var p := [
		c - right * 0.5 - down * 0.5,
		c + right * 0.5 - down * 0.5,
		c + right * 0.5 + down * 0.5,
		c - right * 0.5 + down * 0.5,
	]
	_quad(surf, p, [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)], normal, tile)


func _collision_face(surf: _Surface, center: Vector3, normal: Vector3, right: Vector3, down: Vector3) -> void:
	var c := center + normal * 0.5
	var p := [c - right * 0.5 - down * 0.5, c + right * 0.5 - down * 0.5, c + right * 0.5 + down * 0.5, c - right * 0.5 + down * 0.5]
	var order := [0, 1, 2, 0, 2, 3]
	if (p[1] - p[0]).cross(p[2] - p[0]).dot(normal) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for i in order:
		surf.collision.append(p[i])


func _quad(surf: _Surface, p: Array, local_uvs: Array, normal: Vector3, tile: Vector2i, size := Vector2i.ONE) -> void:
	var order := [0, 1, 2, 0, 2, 3]
	# Godot treats clockwise triangles as front-facing.
	if (p[1] - p[0]).cross(p[2] - p[0]).dot(normal) > 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for i in order:
		surf.verts.append(p[i])
		surf.normals.append(normal)
		surf.uvs.append(block_set.tile_uv(tile, local_uvs[i], size))
	surf.quads += 1


func _tri(surf: _Surface, p: Array, local_uvs: Array, normal: Vector3, tile: Vector2i) -> void:
	var order := [0, 1, 2]
	if (p[1] - p[0]).cross(p[2] - p[0]).dot(normal) > 0.0:
		order = [0, 2, 1]
	for i in order:
		surf.verts.append(p[i])
		surf.normals.append(normal)
		surf.uvs.append(block_set.tile_uv(tile, local_uvs[i]))
	surf.quads += 1


func _append_mesh(surf: _Surface, mesh: Mesh, xform: Transform3D) -> void:
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals = arrays[Mesh.ARRAY_NORMAL]
		var uvs = arrays[Mesh.ARRAY_TEX_UV]
		var indices = arrays[Mesh.ARRAY_INDEX]
		var count: int = indices.size() if indices != null else verts.size()
		for n in count:
			var v: int = indices[n] if indices != null else n
			surf.verts.append(xform * verts[v])
			surf.normals.append(xform.basis * normals[v] if normals != null else Vector3.UP)
			surf.uvs.append(uvs[v] if uvs != null else Vector2.ZERO)
		surf.quads += count / 6

#endregion

#region Editor cursor

func show_cursor(cell: Vector3i, color: Color) -> void:
	if _cursor == null:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.vertex_color_use_as_albedo = true
		mat.no_depth_test = true
		_cursor = MeshInstance3D.new()
		_cursor.mesh = ImmediateMesh.new()
		_cursor.material_override = mat
		add_child(_cursor, false, INTERNAL_MODE_BACK)
	var im := _cursor.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_set_color(color)
	var lo := Vector3(cell) - Vector3.ONE * 0.02
	var hi := Vector3(cell) + Vector3.ONE * 1.02
	for a in 3:
		var b := (a + 1) % 3
		var c := (a + 2) % 3
		for corner in [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]:
			var from := lo
			from[b] = hi[b] if corner.x else lo[b]
			from[c] = hi[c] if corner.y else lo[c]
			var to := from
			to[a] = hi[a]
			im.surface_add_vertex(from)
			im.surface_add_vertex(to)
	# Tick on the facing side so rotation is visible while painting.
	var mid := (lo + hi) * 0.5
	var facing := Vector3(SIDES[paint_rotation & 3])
	im.surface_add_vertex(Vector3(mid.x, lo.y, mid.z))
	im.surface_add_vertex(Vector3(mid.x, lo.y, mid.z) + facing * 0.52)
	im.surface_end()
	_cursor.visible = true


func hide_cursor() -> void:
	if _cursor:
		_cursor.visible = false

#endregion
