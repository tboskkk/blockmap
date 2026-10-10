extends SceneTree
## Builds demo/blocks.tres and demo/demo.tscn from demo/blocks.png:
## godot --headless --path . --script tools/make_demo.gd

enum { GRASS, DIRT, STONE, SAND, GRASS_SLAB, GRASS_RAMP, STONE_SLAB, FLOWER, TUFT, BUSH, TREE, PATH, WATERFALL,
	GRASS_RAMP_OUTER, GRASS_RAMP_INNER, STONE_WEDGE, GRASS_WEDGE, SAND_PATCH }

const Blob47 := preload("res://tools/blob47.gd")


func _init() -> void:
	var block_set := BlockSet.new()
	block_set.atlas = load("res://demo/blocks.png")
	block_set.blocks = [
		_block("Grass", Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), true),
		_block("Dirt", Vector2i(2, 0), Vector2i(2, 0), Vector2i(2, 0), false),
		_block("Stone", Vector2i(0, 1), Vector2i(1, 1), Vector2i(0, 1), false),
		_block("Sand", Vector2i(2, 1), Vector2i(2, 1), Vector2i(2, 1), false),
	]
	block_set.blocks[GRASS].side_covered = Vector2i(2, 0)
	block_set.blocks[GRASS].fringe = Vector2i(3, 0)
	for entry in [["Grass Slab", BlockType.Shape.SLAB, GRASS], ["Grass Ramp", BlockType.Shape.RAMP, GRASS],
			["Stone Slab", BlockType.Shape.SLAB, STONE]]:
		block_set.blocks.append(_shaped(block_set, entry))
	block_set.blocks.append(_sprite("Flower", BlockType.Shape.CROSS, Vector2i(4, 0), Vector2i.ONE))
	block_set.blocks.append(_sprite("Grass Tuft", BlockType.Shape.CROSS, Vector2i(3, 1), Vector2i.ONE))
	block_set.blocks.append(_sprite("Bush", BlockType.Shape.BILLBOARD, Vector2i(4, 1), Vector2i.ONE))
	block_set.blocks[BUSH].billboard_mode = BlockType.BillboardMode.FACE_CAMERA
	block_set.blocks.append(_sprite("Tree", BlockType.Shape.BILLBOARD, Vector2i(5, 0), Vector2i(3, 4)))
	# Autotiled dirt path; grass sits a decal-height above it so paths read as a dip.
	var path := _block("Path", Vector2i(8, 0), Vector2i(2, 0), Vector2i(2, 0), false)
	path.terrain_set = 0
	path.terrain = 1
	block_set.blocks.append(path)
	block_set.blocks[GRASS].terrain_set = 0
	block_set.blocks[GRASS].terrain = 0
	block_set.blocks[GRASS].top_decal = 0.125
	var waterfall := _sprite("Waterfall", BlockType.Shape.PANEL, Vector2i(0, 4), Vector2i(1, 4))
	waterfall.anim_frames = 4
	waterfall.anim_fps = 8.0
	block_set.blocks.append(waterfall)
	for entry in [["Grass Ramp Corner", BlockType.Shape.RAMP_OUTER, GRASS], ["Grass Ramp Inner Corner", BlockType.Shape.RAMP_INNER, GRASS],
			["Stone Wedge", BlockType.Shape.WEDGE, STONE], ["Grass Wedge", BlockType.Shape.WEDGE, GRASS]]:
		block_set.blocks.append(_shaped(block_set, entry))
	block_set.blocks.append(_sprite("Sand Patch", BlockType.Shape.FLOOR, Vector2i(2, 1), Vector2i.ONE))
	block_set.tile_set = _make_tile_set(block_set.atlas)
	ResourceSaver.save(block_set, "res://demo/blocks.tres")
	block_set = load("res://demo/blocks.tres")

	var scene_root := Node3D.new()
	scene_root.name = "Demo"
	scene_root.set_script(load("res://demo/demo.gd"))

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = Sky.new()
	var sky := ProceduralSkyMaterial.new()
	# No ground: sky all the way down for the floating-island look.
	sky.ground_horizon_color = sky.sky_horizon_color
	sky.ground_bottom_color = sky.sky_top_color
	env.sky.sky_material = sky
	# Flat ambient (sky ambient picks up the sun disc). Values are tuned for the Mobile
	# renderer; demo.gd swaps in Compatibility's own when running on that.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.62, 0.72, 0.9)
	env.ambient_light_energy = 0.3
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.background_energy_multiplier = 1.4
	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	_add(scene_root, world_env)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	_add(scene_root, sun)

	var map := BlockMap.new()
	map.name = "BlockMap"
	map.block_set = block_set
	_add(scene_root, map)
	_build_island(map)

	# A second grid turned 45 degrees inside the first: a diagonal stone causeway
	# from the ruin toward the mound.
	var diagonal := BlockMap.new()
	diagonal.name = "DiagonalGrid"
	diagonal.block_set = block_set
	diagonal.yaw_steps = 2
	diagonal.grid_offset = Vector3(-4.0, 7.0, 4.0)
	map.add_child(diagonal)
	diagonal.owner = scene_root
	for i in 6:
		diagonal.set_cell(Vector3i(0, 0, -i), STONE_SLAB)
		diagonal.set_cell(Vector3i(1, 0, -i), STONE_SLAB)

	var cam := Camera3D.new()
	cam.name = "Camera3D"
	_add(scene_root, cam)

	var ui := CanvasLayer.new()
	ui.name = "UI"
	_add(scene_root, ui)
	var info := Label.new()
	info.name = "Info"
	info.position = Vector2(12, 8)
	info.add_theme_constant_override("outline_size", 6)
	info.add_theme_color_override("font_outline_color", Color.BLACK)
	ui.add_child(info)
	info.owner = scene_root

	var scene := PackedScene.new()
	var err := scene.pack(scene_root)
	assert(err == OK)
	ResourceSaver.save(scene, "res://demo/demo.tscn")
	print("wrote demo scene with %d blocks" % map.get_used_cells().size())
	scene_root.free()
	quit()


func _add(scene_root: Node, node: Node) -> void:
	scene_root.add_child(node)
	node.owner = scene_root


func _block(block_name: String, top: Vector2i, side: Vector2i, bottom: Vector2i, decorated: bool) -> BlockType:
	var b := BlockType.new()
	b.name = block_name
	b.top = top
	b.side = side
	b.bottom = bottom
	b.decorated = decorated
	return b


## [name, shape, source block]: a shaped block textured like the source block.
func _shaped(block_set: BlockSet, entry: Array) -> BlockType:
	var src: BlockType = block_set.blocks[entry[2]]
	var b := _block(entry[0], src.top, src.side, src.bottom, false)
	b.shape = entry[1]
	return b


func _sprite(block_name: String, shape: BlockType.Shape, sprite: Vector2i, size: Vector2i) -> BlockType:
	var b := BlockType.new()
	b.name = block_name
	b.shape = shape
	b.sprite = sprite
	b.sprite_size = size
	return b


## Godot TileSet with a Grass terrain (one plain tile) and a Path terrain (47-tile blob),
## editable in Godot's normal TileSet editor. Saved inside blocks.tres.
func _make_tile_set(atlas: Texture2D) -> TileSet:
	var ts := TileSet.new()
	ts.add_terrain_set()
	ts.set_terrain_set_mode(0, TileSet.TERRAIN_MODE_MATCH_CORNERS_AND_SIDES)
	ts.add_terrain(0)
	ts.set_terrain_name(0, 0, "Grass")
	ts.set_terrain_color(0, 0, Color(0.4, 0.75, 0.3))
	ts.add_terrain(0)
	ts.set_terrain_name(0, 1, "Path")
	ts.set_terrain_color(0, 1, Color(0.65, 0.45, 0.3))
	var src := TileSetAtlasSource.new()
	src.texture = atlas
	src.texture_region_size = Vector2i(16, 16)
	ts.add_source(src, 0)
	src.create_tile(Vector2i(0, 0))
	var grass := src.get_tile_data(Vector2i(0, 0), 0)
	grass.terrain_set = 0
	grass.terrain = 0
	for n in Blob47.NEIGHBORS:
		grass.set_terrain_peering_bit(n, 0)
	var masks := Blob47.masks()
	for i in masks.size():
		var coords := Vector2i(8 + i % 8, i / 8)
		src.create_tile(coords)
		var td := src.get_tile_data(coords, 0)
		td.terrain_set = 0
		td.terrain = 1
		for b in 8:
			td.set_terrain_peering_bit(Blob47.NEIGHBORS[b], 1 if masks[i] & (1 << b) else 0)
	return ts


func _build_island(map: BlockMap) -> void:
	var noise := FastNoiseLite.new()
	noise.seed = 3
	noise.frequency = 0.15
	var top := 6
	var r := 9.0
	var ir := ceili(r * 1.3)
	for x in range(-ir, ir + 1):
		for z in range(-ir, ir + 1):
			var d := Vector2(x, z).length()
			var edge := r * (1.0 + noise.get_noise_2d(x, z) * 0.35)
			if d >= edge:
				continue
			# Inverted cone underneath: deep in the middle, thin at the rim.
			var depth := 1 + int((1.0 - d / edge) * r * 0.9)
			for k in depth:
				map.set_cell(Vector3i(x, top - k, z), GRASS if k == 0 else DIRT if k < 3 else STONE)

	# Raised mound: covered grass switches to dirt sides, with ramps all round and
	# corner ramps at the corners.
	for x in range(2, 5):
		for z in range(0, 3):
			map.set_cell(Vector3i(x, 7, z), GRASS)
	for i in range(2, 5):
		map.set_cell(Vector3i(i, 7, -1), GRASS_RAMP, 0)
		map.set_cell(Vector3i(i, 7, 3), GRASS_RAMP, 2)
		map.set_cell(Vector3i(1, 7, i - 2), GRASS_RAMP, 1)
		map.set_cell(Vector3i(5, 7, i - 2), GRASS_RAMP, 3)
	map.set_cell(Vector3i(1, 7, -1), GRASS_RAMP_OUTER, 0)
	map.set_cell(Vector3i(5, 7, -1), GRASS_RAMP_OUTER, 3)
	map.set_cell(Vector3i(1, 7, 3), GRASS_RAMP_OUTER, 1)
	map.set_cell(Vector3i(5, 7, 3), GRASS_RAMP_OUTER, 2)
	# Stone ruin with an inner corner and a short pillar.
	for p in [Vector3i(-5, 7, -3), Vector3i(-4, 7, -3), Vector3i(-3, 7, -3), Vector3i(-5, 7, -2), Vector3i(-5, 7, -1), Vector3i(-5, 8, -3), Vector3i(-5, 9, -3)]:
		map.set_cell(p, STONE)
	# Slab steps up to the stone ruin, and a stone slab ledge.
	for x in range(-4, -1):
		map.set_cell(Vector3i(x, 7, -5), GRASS_SLAB)
	for z in range(-2, 1):
		map.set_cell(Vector3i(-6, 7, z), STONE_SLAB)
	# Sand beach on the east rim.
	for pos in map.get_used_cells():
		if pos.y == top and pos.x > 6 and map.get_cell(pos) == GRASS:
			map.set_cell(pos, SAND)
	# Floating stepping stones, and a two-block bar to show lips joining.
	for p in [Vector3i(11, 7, 2), Vector3i(13, 8, 3), Vector3i(-11, 5, 5), Vector3i(-12, 8, -6), Vector3i(-11, 8, -6)]:
		map.set_cell(p, GRASS)

	# Diagonal wall: a staircase of stone cubes with wedges filling the notches.
	for i in 5:
		for y in [7, 8]:
			map.set_cell(Vector3i(2 + i, y, -7 + i), STONE)
			if i < 4:
				map.set_cell(Vector3i(3 + i, y, -7 + i), STONE_WEDGE, 3)
	# One of each sloped shape in a row.
	for i in 4:
		map.set_cell(Vector3i(-5 + i * 2, 7, -6), [GRASS_RAMP, GRASS_RAMP_OUTER, GRASS_RAMP_INNER, GRASS_WEDGE][i], 0)

	# Winding dirt path across the open south side of the island.
	for x in range(-7, 8):
		var z := 5 + roundi(1.2 * sin(x * 0.55))
		for p in [Vector3i(x, top, z), Vector3i(x, top, z + 1)]:
			if map.get_cell(p) == GRASS and map.get_cell(p + Vector3i.UP) == BlockMap.EMPTY:
				map.set_cell(p, PATH)

	# Waterfall off the south rim, two panels long.
	var rim := 0
	while map.get_cell(Vector3i(-2, top, rim + 1)) != BlockMap.EMPTY:
		rim += 1
	map.set_cell(Vector3i(-2, top, rim + 1), WATERFALL, 2)
	map.set_cell(Vector3i(-2, top - 4, rim + 1), WATERFALL, 2)

	# Trees and bushes.
	for p in [Vector3i(-1, 7, 0), Vector3i(3, 8, 1), Vector3i(-7, 7, -4), Vector3i(6, 7, 5)]:
		map.set_cell(p, TREE)
	for p in [Vector3i(-2, 7, 3), Vector3i(0, 7, -3), Vector3i(-8, 7, 3)]:
		map.set_cell(p, BUSH)
	# Scatter flowers and tufts on open grass.
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for pos in map.get_used_cells():
		var above := pos + Vector3i.UP
		if map.get_cell(pos) != GRASS or map.get_cell(above) != BlockMap.EMPTY:
			continue
		var roll := rng.randf()
		if roll < 0.12:
			map.set_cell(above, TUFT)
		elif roll < 0.17:
			map.set_cell(above, FLOWER)

	# A sand patch lying on the dirt path (FLOOR overlay; grass tops sit a decal higher
	# and would cover it).
	for p in [Vector3i(0, 7, 5), Vector3i(0, 7, 6), Vector3i(1, 7, 6), Vector3i(1, 7, 7)]:
		map.set_cell(p, SAND_PATCH)
