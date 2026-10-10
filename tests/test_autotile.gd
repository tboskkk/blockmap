extends SceneTree
## Checks BlockMap autotiling against a plain 2D TileMapLayer:
## godot --headless --path . --script tests/test_autotile.gd
## For each Godot terrain mode, paints the same cells on both (all at once, then
## 200 random paints/erases one cell at a time) and compares every tile.

const SIDE_BITS: Array[int] = [TileSet.CELL_NEIGHBOR_TOP_SIDE, TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_LEFT_SIDE]
const CORNER_BITS: Array[int] = [TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER]
const SIZE := 24
const GRASS := 0
const PATH := 1

var failures := 0


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var demo_set: TileSet = (load("res://demo/blocks.tres") as BlockSet).tile_set
	await _check("corners+sides (47 blob, demo tileset)", demo_set)
	await _check("sides only (16 tiles)", _make_16(TileSet.TERRAIN_MODE_MATCH_SIDES, SIDE_BITS))
	await _check("corners only (16 tiles)", _make_16(TileSet.TERRAIN_MODE_MATCH_CORNERS, CORNER_BITS))
	print("RESULT: ", "PASS" if failures == 0 else "FAIL (%d mismatches)" % failures)
	quit(1 if failures else 0)


func _check(label: String, tile_set: TileSet) -> void:
	var block_set := BlockSet.new()
	block_set.atlas = load("res://demo/blocks.png")
	block_set.tile_set = tile_set
	var grass := BlockType.new()
	grass.terrain_set = 0
	grass.terrain = GRASS
	var path := BlockType.new()
	path.terrain_set = 0
	path.terrain = PATH
	block_set.blocks = [grass, path]

	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var noise := FastNoiseLite.new()
	noise.seed = 99
	noise.frequency = 0.12
	var data := PackedInt32Array()
	var by_terrain := {GRASS: [] as Array[Vector2i], PATH: [] as Array[Vector2i]}
	for x in SIZE:
		for z in SIZE:
			var t := PATH if noise.get_noise_2d(x, z) > 0.15 else GRASS
			data.append_array([x, 0, z, t])
			by_terrain[t].append(Vector2i(x, z))

	var map := BlockMap.new()
	map.generate_collision = false
	map.block_set = block_set
	map.cell_data = data
	root.add_child(map)
	await process_frame
	await process_frame

	# 2D side: the calls BlockMap makes for a full rebuild (terrain order, sorted cells).
	var layer := TileMapLayer.new()
	layer.tile_set = tile_set
	for t in [GRASS, PATH]:
		var cells: Array[Vector2i] = by_terrain[t]
		cells.sort()
		layer.set_cells_terrain_connect(cells, 0, t, block_set.ignore_empty_terrains)
	var bulk := _compare(map, layer)

	# One cell at a time, like painting in the editor.
	for i in 200:
		var c := Vector2i(rng.randi_range(0, SIZE - 1), rng.randi_range(0, SIZE - 1))
		var roll := rng.randi_range(0, 2)
		var single: Array[Vector2i] = [c]
		if roll == 2:
			map.set_cell(Vector3i(c.x, 0, c.y), BlockMap.EMPTY)
			layer.set_cells_terrain_connect(single, 0, -1, block_set.ignore_empty_terrains)
		else:
			map.set_cell(Vector3i(c.x, 0, c.y), roll)
			layer.set_cells_terrain_connect(single, 0, roll, block_set.ignore_empty_terrains)
	var edits := _compare(map, layer)

	var used := {}
	for x in SIZE:
		for z in SIZE:
			used[layer.get_cell_atlas_coords(Vector2i(x, z))] = true
	print("%s: all at once %d/%d match, after 200 edits %d/%d match, %d distinct tiles used" % [
		label, bulk.x, bulk.y, edits.x, edits.y, used.size()])
	failures += (bulk.y - bulk.x) + (edits.y - edits.x)
	layer.free()
	map.free()


## Returns (matching, total) over the test area.
func _compare(map: BlockMap, layer: TileMapLayer) -> Vector2i:
	var ok := 0
	for x in SIZE:
		for z in SIZE:
			var expected := layer.get_cell_atlas_coords(Vector2i(x, z))
			var got := map.get_top_tile(Vector3i(x, 0, z)) if map.get_cell(Vector3i(x, 0, z)) != BlockMap.EMPTY else Vector2i(-1, -1)
			if expected == got:
				ok += 1
			elif failures < 5:
				print("  mismatch at ", Vector2i(x, z), ": 2D ", expected, " vs 3D ", got)
	return Vector2i(ok, SIZE * SIZE)


## Grass tile plus 16 path tiles covering every combination of the 4 given bits.
func _make_16(mode: int, bits: Array[int]) -> TileSet:
	var ts := TileSet.new()
	ts.add_terrain_set()
	ts.set_terrain_set_mode(0, mode)
	ts.add_terrain(0)
	ts.add_terrain(0)
	var src := TileSetAtlasSource.new()
	src.texture = load("res://demo/blocks.png")
	src.texture_region_size = Vector2i(16, 16)
	ts.add_source(src, 0)
	src.create_tile(Vector2i(0, 0))
	var g := src.get_tile_data(Vector2i(0, 0), 0)
	g.terrain_set = 0
	g.terrain = GRASS
	for b in bits:
		g.set_terrain_peering_bit(b, GRASS)
	for m in 16:
		var coords := Vector2i(8 + m % 8, m / 8)
		src.create_tile(coords)
		var td := src.get_tile_data(coords, 0)
		td.terrain_set = 0
		td.terrain = PATH
		for i in 4:
			td.set_terrain_peering_bit(bits[i], PATH if m & (1 << i) else GRASS)
	return ts
