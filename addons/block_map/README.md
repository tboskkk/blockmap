# BlockMap

3D block maps textured from a normal 2D tilesheet. Each block's faces use atlas tiles, faces touching another block are never built, and decorated blocks grow a lip + hanging fringe only on their exposed top edges.

## Setup
1. Make a **BlockSet** resource: set `atlas` (your tilesheet) and `tile_size`, then add **BlockType**s.
2. For each BlockType, pick a `shape` and set atlas coords for `top`, `side`, `bottom`. Optional extras:
   - `side_covered`: the side tile used when something sits on top (e.g. plain dirt under grass)
   - `decorated` + `fringe`: turns on the edge lip; `fringe` is a tile whose top slice hangs off the edge
   - `edge_part` / `corner_part`: your own modeled decoration meshes instead of the procedural lip.
     Model `edge_part` for the +Z edge of a block centered on the origin (-0.5..0.5) and UV it to the same atlas.
     Model `corner_part` for the +X+Z corner. Both get rotated to every exposed edge.
   - `front` (cubes): tile for the side the block is rotated to face (doors, signs, windows)
3. Add a **BlockMap** node and assign the BlockSet.

## Shapes
| Shape | What it is |
|---|---|
| CUBE | Full block. The only shape that gets edge decoration. |
| SLAB | Bottom half block. Its sides use the top half of the side tile, so grass bands still show. |
| RAMP | Slope rising toward the block's facing. Its side triangles follow the slope. |
| RAMP_OUTER | Corner slope rising to one top corner, between the facing side and the next one clockwise. It turns the corner where two ramps meet. |
| RAMP_INNER | Inside-corner slope: high along the facing side and the next one clockwise, sloping down to the opposite corner. |
| WEDGE | Block cut diagonally in plan: full walls on the facing side and the next one clockwise, and a diagonal wall across. For 45° walls and island edges. |
| CROSS | Two crossed quads, like Minecraft plants. Uses `sprite` / `sprite_size`. |
| BILLBOARD | Sprite that turns toward the camera. `UPRIGHT` turns around Y only (trees). `FACE_CAMERA` faces the camera fully and reads as flat 2D in ortho/top-down. |
| PANEL | Flat sprite against the side the block faces, hanging down from the cell top. For waterfalls, vines, and signs. Paint it in the empty cell next to a wall and rotate it to face the wall. |
| FLOOR | Flat sprite lying on the cell floor, `sprite_size` tiles along +X / +Z. For rugs, puddles, and overlay layers. |

Sprites (CROSS / BILLBOARD / PANEL) can animate: set `anim_frames` and `anim_fps`, and lay the frames out left to right in the atlas, each `sprite_size` wide. The animation runs in the shader, so it costs nothing on the CPU. On a CUBE or SLAB, `anim_frames` animates the top tile instead (frames one tile apart).

Sprites (CROSS / BILLBOARD) take a region of `sprite_size` tiles starting at `sprite`. The center of the bottom-middle tile sits on the cell center, so a 3x4 tree painted on top of a grass block has its trunk on the grass. Sprites don't hide faces, block decoration, or get collision. Billboards cast shadows but don't receive them.

## Turned grids (diagonal layouts)
To lay tiles diagonally across a map, add a second BlockMap as a child of the first and set `yaw_steps`. It turns in 22.5° steps: 2 gives 45° (the 8-direction in-betweens), and 1 or 3 give the 16-direction ones. `grid_offset` shifts it by fractions of a tile to line it up. Painting follows the turned grid, and collision works. The demo's `DiagonalGrid` is a 45° stone causeway.

The two grids don't know about each other. Faces aren't hidden where they touch, edge decoration ignores the other grid, and autotiling is per grid. Where a turned tile's top sits level with a base tile's top in the same spot, the two surfaces flicker (z-fighting), so put turned tiles on top of the ground (slabs work well) or nudge `grid_offset.y`.

## Autotile
Autotile uses Godot's own terrain matching, so it gives the same results as a 2D TileMapLayer.
1. Make a normal Godot **TileSet** with terrains, in Godot's TileSet editor. Its atlas should use the same image as the BlockSet `atlas`.
2. Assign it to the BlockSet's `tile_set`.
3. Set `terrain_set` / `terrain` on each BlockType that should autotile.

Top faces then pick their tile from same-terrain blocks on the same layer. Any terrain mode works (corners + sides / 47 blob, sides only, corners only). Internally, each Y level runs an off-screen TileMapLayer with the same `set_cells_terrain_connect` calls the 2D editor makes. `tests/test_autotile.gd` checks this tile for tile against a real TileMapLayer.

`ignore_empty_terrains` on the BlockSet is passed straight through. With it on, Godot won't place terrain tiles next to empty cells unless the tileset has tiles for empty neighbors, so it defaults to off.

## Top decal
`top_decal` on a cube raises its visible top without moving its collision. Characters sink into it slightly, and lower neighbors (like a path block without a decal) sit in a dip, with the decal's short side walls casting real shadows onto the path edges. Edge decoration moves up with it.

Touching faces are hidden by shape: a full face hides anything, half faces hide matching half faces, and ramp sides hide matching ramp sides.

## Painting (select the BlockMap, 3D viewport)
| Input | Action |
|---|---|
| LMB / drag | place blocks (a drag stays on the layer it started on) |
| Shift + LMB / drag | erase |
| Ctrl + LMB / drag | swap the block type of existing blocks |
| `[` / `]` | previous / next block |
| R | rotate (which side blocks face; ramps rise toward it) |
| PgUp / PgDn | layer used when painting into empty space |

Undo/redo works per stroke. While a BlockMap is selected it takes left-clicks in the viewport, so select other nodes from the scene tree.

## Notes
- The map is built as one mesh per 16×16×16 chunk, so Godot can skip off-screen chunks and an edit only rebuilds nearby chunks.
- Collision is generated per chunk at runtime (`generate_collision`).
- `stats` reports blocks, chunks, faces drawn and hidden, decoration quads, and triangles.
- `tools/make_atlas.gd` and `tools/make_demo.gd` regenerate the placeholder atlas and demo scene.
