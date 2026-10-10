extends SceneTree
## Builds the demo atlas: godot --headless --path . --script tools/make_atlas.gd
## Block faces, plants and the tree come from Kenney's CC0 Voxel Pack (demo/kenney/),
## box-downscaled from 128px to 16px. The flower, the waterfall frames and the
## 47-tile path are generated here.
## Layout (16px tiles), 16x8 tiles = 256x128 px:
##   row 0: grass top, grass side, dirt, grass fringe, flower
##   row 1: stone top, stone side, sand, grass tuft, bush
##   cols 5-7, rows 0-3: 3x4 tree
##   cols 0-3, rows 4-7: waterfall, 4 animation frames of 1x4
##   cols 8-15, rows 0-5: dirt path, 47-tile blob autotile (order from blob47.gd)

const T := 16
const KENNEY := "res://demo/kenney/"
const Blob47 := preload("res://tools/blob47.gd")
var rng := RandomNumberGenerator.new()
var img: Image


func _init() -> void:
	rng.seed = 7
	img = Image.create_empty(T * 16, T * 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))

	var grass_top := _kenney("grass_top")
	var grass_side := _kenney("dirt_grass")
	_put(Vector2i(0, 0), grass_top)
	_put(Vector2i(1, 0), grass_side)
	_put(Vector2i(2, 0), _kenney("dirt"))
	_put(Vector2i(0, 1), _kenney("stone"))
	_put(Vector2i(1, 1), _kenney("brick_grey"))
	_put(Vector2i(2, 1), _kenney("sand"))
	_put(Vector2i(3, 1), _kenney("grass4", true))
	_put(Vector2i(4, 1), _kenney("grass2", true))
	_fringe(Vector2i(3, 0), grass_side)
	_flower(Vector2i(4, 0), grass_top.get_pixel(8, 8))
	_tree(Vector2i(5, 0), _kenney("leaves"), _kenney("trunk_side"))
	_waterfall()
	var masks := Blob47.masks()
	for i in masks.size():
		_path_tile(Vector2i(8 + i % 8, i / 8), masks[i], grass_top)
	img.save_png("res://demo/blocks.png")
	print("wrote res://demo/blocks.png %dx%d" % [img.get_width(), img.get_height()])
	quit()


## Loads a Kenney PNG and box-downscales it to one T x T tile. Alpha is snapped
## to 0 or 1 so cutout sprites keep hard edges. With `fit`, a sprite is first
## cropped to a square around its opaque pixels (resting on the bottom edge) so it
## fills the tile.
func _kenney(file: String, fit := false) -> Image:
	var src := Image.load_from_file(ProjectSettings.globalize_path(KENNEY + file + ".png"))
	src.convert(Image.FORMAT_RGBA8)
	if fit:
		var used := src.get_used_rect()
		var side := maxi(used.size.x, used.size.y)
		var square := Image.create_empty(side, side, false, Image.FORMAT_RGBA8)
		square.blit_rect(src, used, Vector2i((side - used.size.x) / 2, side - used.size.y))
		square.resize(T * 8, T * 8, Image.INTERPOLATE_NEAREST)
		src = square
	var k := src.get_width() / T
	var out := Image.create_empty(T, T, false, Image.FORMAT_RGBA8)
	for ty in T:
		for tx in T:
			var sum := Color(0, 0, 0, 0)
			for y in k:
				for x in k:
					var c := src.get_pixel(tx * k + x, ty * k + y)
					sum += Color(c.r * c.a, c.g * c.a, c.b * c.a, c.a)
			if sum.a < k * k * 0.5:
				continue
			out.set_pixel(tx, ty, Color(sum.r / sum.a, sum.g / sum.a, sum.b / sum.a, 1.0))
	return out


func _put(tile: Vector2i, tile_img: Image) -> void:
	img.blit_rect(tile_img, Rect2i(0, 0, T, T), tile * T)


func _px(tile: Vector2i, x: int, y: int, color: Color) -> void:
	img.set_pixel(tile.x * T + x, tile.y * T + y, color)


func _vary(color: Color, amount: float) -> Color:
	var k := rng.randf_range(-amount, amount)
	return Color(clampf(color.r + k, 0, 1), clampf(color.g + k, 0, 1), clampf(color.b + k, 0, 1))


## Fringe: the grass band of the grass side tile, transparent below, so it can
## hang over the side of a block.
func _fringe(tile: Vector2i, grass_side: Image) -> void:
	for x in T:
		for y in T / 2:
			var c := grass_side.get_pixel(x, y)
			if c.g > c.r and c.g > c.b:
				_px(tile, x, y, c)


## Flower: stem + petals.
func _flower(tile: Vector2i, grass: Color) -> void:
	for y in range(7, 16):
		_px(tile, 8, y, grass.darkened(0.3))
	for leaf in [Vector2i(7, 12), Vector2i(6, 11), Vector2i(9, 10), Vector2i(10, 9)]:
		_px(tile, leaf.x, leaf.y, grass.darkened(0.2))
	for d in [Vector2i(0, -2), Vector2i(0, 2), Vector2i(-2, 0), Vector2i(2, 0), Vector2i(-1, -1), Vector2i(1, -1), Vector2i(-1, 1), Vector2i(1, 1)]:
		_px(tile, 8 + d.x, 5 + d.y, Color(0.95, 0.45, 0.6))
	_px(tile, 8, 5, Color(1.0, 0.85, 0.3))


## Tree (3x4 tiles): a trunk cut from the Kenney bark texture in the bottom-middle
## tile, and a canopy of shaded discs filled with the Kenney leaves texture.
func _tree(tile: Vector2i, leaves: Image, bark: Image) -> void:
	var origin := tile * T
	for y in range(30, 64):
		for x in range(20, 28):
			var c := bark.get_pixel(x - 16, y % T)
			img.set_pixelv(origin + Vector2i(x, y), c.darkened(0.2 if x == 20 or x == 27 else 0.0))
	for c in [Vector2(24, 18), Vector2(14, 26), Vector2(34, 26), Vector2(24, 30), Vector2(18, 12), Vector2(30, 12)]:
		_canopy(origin, c, 11.0, leaves)


## Shaded disc of leaves, lighter toward the top-left.
func _canopy(origin: Vector2i, center: Vector2, radius: float, leaves: Image) -> void:
	for y in range(int(center.y - radius), int(center.y + radius) + 1):
		for x in range(int(center.x - radius), int(center.x + radius) + 1):
			var d := Vector2(x, y).distance_to(center)
			if d > radius - rng.randf_range(0.0, 1.2):
				continue
			var shade := (Vector2(x, y) - center).dot(Vector2(0.6, 0.8)) / radius
			var c := leaves.get_pixel(posmod(x, T), posmod(y, T))
			img.set_pixelv(origin + Vector2i(x, y), c.lightened(0.12).darkened(0.2 * (shade + 1.0)))


## Streaks slide down 4px per frame, so 4 frames loop over one 16px period.
func _waterfall() -> void:
	var water := Color(0.30, 0.55, 0.88)
	var offsets := []
	for x in T:
		offsets.append(rng.randi_range(0, 15))
	for frame in 4:
		var origin := Vector2i(frame * T, 4 * T)
		for y in T * 4:
			for x in T:
				if (x == 0 or x == T - 1) and rng.randf() < 0.5:
					continue
				var color := water.darkened(0.12 if x < 2 or x > T - 3 else 0.0)
				if posmod(y - frame * 4 + offsets[x], 16) < 3:
					color = Color(0.72, 0.86, 1.0)
				img.set_pixelv(origin + Vector2i(x, y), color)


## Dirt path tile for one blob mask: grass creeps in along unconnected sides and
## into corners whose diagonal is missing. The grass pixels are copied from the
## grass top tile so path cells blend into neighbouring grass blocks.
func _path_tile(tile: Vector2i, mask: int, grass: Image) -> void:
	var path := Color(0.70, 0.52, 0.34)
	for y in T:
		for x in T:
			var edge := 99
			if not mask & Blob47.N: edge = mini(edge, y)
			if not mask & Blob47.S: edge = mini(edge, T - 1 - y)
			if not mask & Blob47.W: edge = mini(edge, x)
			if not mask & Blob47.E: edge = mini(edge, T - 1 - x)
			for corner in [[Blob47.NE, T - 1 - x, y], [Blob47.SE, T - 1 - x, T - 1 - y], [Blob47.SW, x, T - 1 - y], [Blob47.NW, x, y]]:
				var sides_ok: bool = (corner[0] == Blob47.NE and mask & Blob47.N and mask & Blob47.E) \
					or (corner[0] == Blob47.SE and mask & Blob47.S and mask & Blob47.E) \
					or (corner[0] == Blob47.SW and mask & Blob47.S and mask & Blob47.W) \
					or (corner[0] == Blob47.NW and mask & Blob47.N and mask & Blob47.W)
				if sides_ok and not mask & corner[0]:
					edge = mini(edge, maxi(corner[1], corner[2]))
			var ragged := rng.randi_range(1, 2)
			var color := _vary(path, 0.05)
			if edge < ragged:
				color = grass.get_pixel(x, y)
			elif edge == ragged:
				color = path.darkened(0.25)
			_px(tile, x, y, color)
