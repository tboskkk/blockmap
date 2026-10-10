@tool
class_name BlockType extends Resource
## One paintable block. Faces pull tiles from the BlockSet atlas by atlas coords.

enum Shape {
	CUBE, ## Full block.
	SLAB, ## Bottom half block.
	RAMP, ## Slope rising toward the block's facing.
	CROSS, ## Two crossed quads, like Minecraft plants. Uses `sprite`.
	BILLBOARD, ## Sprite that turns to face the camera. Uses `sprite`.
	PANEL, ## Flat sprite against the side the block faces, hanging down from the cell top (waterfalls, vines, signs).
	FLOOR, ## Flat sprite lying on the cell floor (rugs, puddles, overlay layers). Uses `sprite`.
	WEDGE, ## Block cut diagonally in plan: full on the facing side and the side clockwise of it.
	RAMP_OUTER, ## Corner slope rising to one top corner (between the facing side and the next one clockwise).
	RAMP_INNER, ## Inside-corner slope: high on the facing side and the next one clockwise, low at the opposite corner.
}
enum BillboardMode {
	UPRIGHT, ## Turns around Y only; stays standing (trees, NPC-style props).
	FACE_CAMERA, ## Fully faces the camera; reads as flat 2D in ortho/top-down.
}

@export var name := "Block":
	set(value): name = value; emit_changed()
@export var shape := Shape.CUBE:
	set(value): shape = value; emit_changed()

@export_group("Tiles")
@export var top := Vector2i(0, 0):
	set(value): top = value; emit_changed()
@export var side := Vector2i(0, 0):
	set(value): side = value; emit_changed()
## Side tile used when another block sits on top. (-1, -1) reuses `side`.
@export var side_covered := Vector2i(-1, -1):
	set(value): side_covered = value; emit_changed()
@export var bottom := Vector2i(0, 0):
	set(value): bottom = value; emit_changed()
## Cube only: tile for the side the block is rotated to face. (-1, -1) reuses `side`.
@export var front := Vector2i(-1, -1):
	set(value): front = value; emit_changed()

@export_group("Autotile")
## Terrain set in the BlockSet's `tile_set`. Top tiles are then picked by Godot's own
## terrain matching against same-terrain blocks on the same layer. -1 = no autotile.
@export var terrain_set := -1:
	set(value): terrain_set = value; emit_changed()
@export var terrain := -1:
	set(value): terrain = value; emit_changed()

@export_group("Top Decal")
## Cube only: raises the visible top by this much without moving collision, so
## characters sink into it and lower neighbors (paths) sit in a shadowed dip.
@export_range(0.0, 0.5, 0.0625) var top_decal := 0.0:
	set(value): top_decal = value; emit_changed()

@export_group("Sprite")
## CROSS / BILLBOARD / PANEL: top-left atlas tile of the sprite (first frame).
@export var sprite := Vector2i(0, 0):
	set(value): sprite = value; emit_changed()
## Sprite size in tiles. CROSS / BILLBOARD: the center of the bottom-middle tile sits
## on the cell center. PANEL: hangs down from the cell top.
@export var sprite_size := Vector2i(1, 1):
	set(value): sprite_size = value; emit_changed()
@export var billboard_mode := BillboardMode.UPRIGHT:
	set(value): billboard_mode = value; emit_changed()
## Animation frames, laid out left to right in the atlas, each `sprite_size` wide.
## On a CUBE / SLAB this animates the top tile instead (frames one tile apart).
@export_range(1, 64) var anim_frames := 1:
	set(value): anim_frames = value; emit_changed()
@export var anim_fps := 8.0:
	set(value): anim_fps = value; emit_changed()

@export_group("Edge Decoration")
## Cube only: adds an overhanging lip + hanging fringe on every exposed top edge.
@export var decorated := false:
	set(value): decorated = value; emit_changed()
## Tile drawn on the hanging fringe. Only its top `fringe_depth` slice is used.
@export var fringe := Vector2i(0, 0):
	set(value): fringe = value; emit_changed()
## Optional authored mesh for one exposed top edge, replacing the procedural lip.
## Model it for the +Z edge of a block centered on the origin (-0.5..0.5), UV'd to the atlas.
@export var edge_part: Mesh:
	set(value): edge_part = value; emit_changed()
## Optional authored mesh for an outer corner, modeled for the +X+Z corner.
@export var corner_part: Mesh:
	set(value): corner_part = value; emit_changed()


func has_terrain() -> bool:
	return terrain_set >= 0 and terrain >= 0


func get_side(covered: bool) -> Vector2i:
	if covered and side_covered.x >= 0:
		return side_covered
	return side


## Shapes that are terrain: they hide faces, carry collision and stop edge decoration.
func is_solid() -> bool:
	return shape in [Shape.CUBE, Shape.SLAB, Shape.RAMP, Shape.WEDGE, Shape.RAMP_OUTER, Shape.RAMP_INNER]
