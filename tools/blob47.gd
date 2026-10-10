extends RefCounted
## The 47-tile "blob" autotile layout: one tile per neighbor mask, where a corner only
## counts when both sides next to it are connected. Bits: 0 N, 1 NE, 2 E, 3 SE, 4 S, 5 SW, 6 W, 7 NW.

const N := 1
const NE := 2
const E := 4
const SE := 8
const S := 16
const SW := 32
const W := 64
const NW := 128

## Godot neighbor for each bit, in bit order.
const NEIGHBORS: Array[int] = [
	TileSet.CELL_NEIGHBOR_TOP_SIDE, TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER,
	TileSet.CELL_NEIGHBOR_RIGHT_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER,
	TileSet.CELL_NEIGHBOR_LEFT_SIDE, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
]


static func masks() -> Array[int]:
	var out: Array[int] = []
	for m in 256:
		if (m & NE and not (m & N and m & E)) or (m & SE and not (m & S and m & E)) \
				or (m & SW and not (m & S and m & W)) or (m & NW and not (m & N and m & W)):
			continue
		out.append(m)
	return out
