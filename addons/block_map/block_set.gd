@tool
class_name BlockSet extends Resource
## A tilesheet atlas plus the block types painted from it.

const UV_EPS := 0.002
const SpriteShader := preload("sprite.gdshader")
const BillboardShader := preload("billboard.gdshader")

@export var atlas: Texture2D:
	set(value):
		atlas = value
		_solid_material = null
		_deco_material = null
		_billboard_material = null
		_sprite_material = null
		emit_changed()
@export var tile_size := Vector2i(16, 16):
	set(value): tile_size = value; emit_changed()
@export var blocks: Array[BlockType] = []:
	set(value):
		for block in blocks:
			if block and block.changed.is_connected(emit_changed):
				block.changed.disconnect(emit_changed)
		blocks = value
		for block in blocks:
			if block and not block.changed.is_connected(emit_changed):
				block.changed.connect(emit_changed)
		emit_changed()

@export_group("Autotile")
## Godot TileSet holding the terrains. Paint and set up terrains in Godot's normal
## TileSet editor; its atlas source should use the same image as `atlas`.
@export var tile_set: TileSet:
	set(value): tile_set = value; emit_changed()
## Passed straight to TileMapLayer.set_cells_terrain_connect. Keep it the same as your
## 2D maps to get identical results. When true, terrain tiles won't place next to empty
## cells unless the tileset has tiles for empty neighbors.
@export var ignore_empty_terrains := false:
	set(value): ignore_empty_terrains = value; emit_changed()

@export_group("Edge Decoration")
## How far the decorated lip overhangs past the block edge.
@export_range(0.0, 0.5, 0.01) var lip := 0.125:
	set(value): lip = value; emit_changed()
## How far the fringe hangs below the top edge.
@export_range(0.0, 1.0, 0.01) var fringe_depth := 0.3125:
	set(value): fringe_depth = value; emit_changed()

var _solid_material: StandardMaterial3D
var _deco_material: StandardMaterial3D
var _billboard_material: ShaderMaterial
var _sprite_material: ShaderMaterial


func get_block(id: int) -> BlockType:
	if id < 0 or id >= blocks.size():
		return null
	return blocks[id]


## UV inside a region of `size` tiles starting at `tile`; `local` is 0..1 across the region.
func tile_uv(tile: Vector2i, local: Vector2, size := Vector2i.ONE) -> Vector2:
	var atlas_size := Vector2(atlas.get_size()) if atlas else Vector2(tile_size)
	var eps := Vector2(UV_EPS, UV_EPS) / Vector2(size)
	local = local.clamp(eps, Vector2.ONE - eps)
	return (Vector2(tile) + local * Vector2(size)) * Vector2(tile_size) / atlas_size


func get_solid_material() -> StandardMaterial3D:
	if _solid_material == null:
		_solid_material = _make_material(false)
	return _solid_material


func get_deco_material() -> StandardMaterial3D:
	if _deco_material == null:
		_deco_material = _make_material(true)
	return _deco_material


func get_billboard_material() -> ShaderMaterial:
	if _billboard_material == null:
		_billboard_material = _make_shader_material(BillboardShader)
	return _billboard_material


func get_sprite_material() -> ShaderMaterial:
	if _sprite_material == null:
		_sprite_material = _make_shader_material(SpriteShader)
	return _sprite_material


## UV distance from one animation frame to the next for a sprite `size` tiles wide.
func frame_stride(size: Vector2i) -> float:
	var width := float(atlas.get_width()) if atlas else float(tile_size.x)
	return size.x * tile_size.x / width


func _make_shader_material(shader: Shader) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("atlas", atlas)
	return mat


func _make_material(cutout: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = atlas
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.roughness = 1.0
	if cutout:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat
