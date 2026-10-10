extends SceneTree
## Smoke test for the demo scene:
## godot --headless --path . --script tests/test_demo.gd

const SCENE := "res://demo/demo.tscn"
const SHAPES := ["CUBE", "SLAB", "RAMP", "RAMP_OUTER", "RAMP_INNER", "WEDGE", "CROSS", "BILLBOARD", "PANEL", "FLOOR"]

var failed := false


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	if not ResourceLoader.exists(SCENE):
		_check("scene exists (%s)" % SCENE, false)
		quit(1)
		return
	var scene: PackedScene = load(SCENE)
	var demo := scene.instantiate()
	root.add_child(demo)
	await process_frame
	await process_frame

	var maps: Array[BlockMap] = []
	for node in demo.find_children("*", "BlockMap", true, false):
		maps.append(node)
	if demo is BlockMap:
		maps.append(demo)
	_check("found BlockMap nodes (%d)" % maps.size(), not maps.is_empty())

	var triangles := 0
	var shapes := 0
	var turned_cells := -1
	var path_cells := 0
	var used := {}
	for map in maps:
		for chunk in map.get_children(true):
			if chunk is MeshInstance3D and chunk.mesh:
				for s in chunk.mesh.get_surface_count():
					triangles += chunk.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX].size() / 3
				for body in chunk.get_children():
					for col in body.get_children():
						if col is CollisionShape3D and col.shape:
							shapes += 1
		var cells := map.get_used_cells()
		if map.yaw_steps != 0:
			turned_cells = maxi(turned_cells, cells.size())
		if map.block_set == null:
			continue
		for pos in cells:
			var id := map.get_cell(pos)
			if id < 0 or id >= map.block_set.blocks.size() or map.block_set.blocks[id] == null:
				continue
			var type: BlockType = map.block_set.blocks[id]
			used[type.shape] = true
			# The autotiled dirt path (grass has a terrain too, so match the Path block).
			if type.name == "Path" and type.terrain >= 0 and map.block_set.tile_set:
				path_cells += 1
	_check("generated mesh geometry (%d triangles)" % triangles, triangles > 0)
	_check("collision shapes exist (%d)" % shapes, shapes > 0)
	for shape_name in SHAPES:
		_check("used cells include a %s block" % shape_name, used.has(BlockType.Shape[shape_name]))
	_check("a BlockMap with yaw_steps != 0 has used cells (%d)" % maxi(turned_cells, 0), turned_cells > 0)
	_check("used cells include autotiled Path blocks (%d)" % path_cells, path_cells > 0)

	root.remove_child(demo)
	demo.free()
	quit(1 if failed else 0)


func _check(label: String, ok: bool) -> void:
	print("%s: %s" % ["PASS" if ok else "FAIL", label])
	if not ok:
		failed = true
