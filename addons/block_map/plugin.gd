@tool
extends EditorPlugin
## Paint BlockMaps in the 3D viewport.
##   LMB (drag)        place blocks; a drag stays on the layer you started on
##   Shift+LMB (drag)  erase
##   Ctrl+LMB (drag)   swap the block type of existing blocks
##   [ / ]             previous / next block type
##   R                 rotate (which side blocks face; ramps rise toward it)
##   PgUp / PgDn       raise / lower the layer used when painting into empty space

enum Mode { NONE, PAINT, ERASE, REPLACE }

var map: BlockMap
var mode := Mode.NONE
## Cell -> packed value before the stroke touched it.
var stroke: Dictionary[Vector3i, int] = {}
var stroke_layer := 0


func _handles(object: Object) -> bool:
	return object is BlockMap


func _edit(object: Object) -> void:
	if map and map != object:
		map.hide_cursor()
	map = object as BlockMap
	mode = Mode.NONE
	stroke.clear()


func _make_visible(visible: bool) -> void:
	if not visible and map:
		map.hide_cursor()


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if map == null or map.block_set == null or not map.is_inside_tree():
		return AFTER_GUI_INPUT_PASS

	if event is InputEventKey and event.pressed and not event.echo:
		var count := map.block_set.blocks.size()
		match event.keycode:
			KEY_BRACKETLEFT when count > 0:
				map.paint_block = posmod(map.paint_block - 1, count)
			KEY_BRACKETRIGHT when count > 0:
				map.paint_block = posmod(map.paint_block + 1, count)
			KEY_R:
				map.paint_rotation = (map.paint_rotation + 1) % 4
			KEY_PAGEUP:
				map.edit_layer += 1
			KEY_PAGEDOWN:
				map.edit_layer -= 1
			_:
				return AFTER_GUI_INPUT_PASS
		map.notify_property_list_changed()
		update_overlays()
		return AFTER_GUI_INPUT_STOP

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if event.alt_pressed:
				return AFTER_GUI_INPUT_PASS
			mode = Mode.ERASE if event.shift_pressed else Mode.REPLACE if event.ctrl_pressed else Mode.PAINT
			stroke.clear()
			_stroke_at(camera, event.position, true)
		else:
			_end_stroke()
		return AFTER_GUI_INPUT_STOP

	if event is InputEventMouseMotion:
		if mode != Mode.NONE:
			_stroke_at(camera, event.position, false)
			return AFTER_GUI_INPUT_STOP
		_update_cursor(camera, event.position, event.shift_pressed, event.ctrl_pressed)

	return AFTER_GUI_INPUT_PASS


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if map == null or map.block_set == null:
		return
	var block := map.block_set.get_block(map.paint_block)
	var text := "Block: %s   Facing: %s   Layer: %d   [ ] block  R rotate  PgUp/PgDn layer  Shift erase  Ctrl swap" % [
		block.name if block else "-", ["+Z", "+X", "-Z", "-X"][map.paint_rotation & 3], map.edit_layer]
	var font := ThemeDB.fallback_font
	var pos := Vector2(12, overlay.size.y - 14)
	overlay.draw_string_outline(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4, Color.BLACK)
	overlay.draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color.WHITE)


func _ray(camera: Camera3D, screen_pos: Vector2) -> Array:
	var inv := map.global_transform.affine_inverse()
	return [inv * camera.project_ray_origin(screen_pos), inv.basis * camera.project_ray_normal(screen_pos)]


func _plane_cell(ray: Array, plane_y: float, layer: int) -> Variant:
	var from: Vector3 = ray[0]
	var dir: Vector3 = ray[1]
	if absf(dir.y) < 0.000001:
		return null
	var t := (plane_y - from.y) / dir.y
	if t < 0.0:
		return null
	var p := from + dir * t
	return Vector3i(floori(p.x), layer, floori(p.z))


## Cell a fresh paint click would fill: against the face under the mouse, else the edit layer.
func _paint_target(ray: Array) -> Variant:
	var hit := map.raycast(ray[0], ray[1])
	if not hit.is_empty() and hit.normal != Vector3i.ZERO:
		return hit.cell + hit.normal
	return _plane_cell(ray, map.edit_layer, map.edit_layer)


func _update_cursor(camera: Camera3D, screen_pos: Vector2, erase: bool, swap: bool) -> void:
	var ray := _ray(camera, screen_pos)
	var target: Variant
	var color := Color(0.3, 1.0, 0.4)
	if erase or swap:
		var hit := map.raycast(ray[0], ray[1])
		target = hit.get("cell")
		color = Color(1.0, 0.3, 0.3) if erase else Color(1.0, 0.8, 0.2)
	else:
		target = _paint_target(ray)
	if target == null:
		map.hide_cursor()
	else:
		map.show_cursor(target, color)


func _stroke_at(camera: Camera3D, screen_pos: Vector2, first: bool) -> void:
	var ray := _ray(camera, screen_pos)
	var target: Variant = null
	match mode:
		Mode.PAINT:
			if first:
				target = _paint_target(ray)
				if target != null:
					stroke_layer = target.y
			else:
				target = _plane_cell(ray, stroke_layer, stroke_layer)
			if target != null:
				_stroke_set(target, _paint_value())
		Mode.ERASE:
			if first:
				var hit := map.raycast(ray[0], ray[1])
				target = hit.get("cell")
				if target != null:
					stroke_layer = target.y
			else:
				target = _plane_cell(ray, stroke_layer + 1, stroke_layer)
			if target != null:
				_stroke_set(target, BlockMap.EMPTY)
		Mode.REPLACE:
			var hit := map.raycast(ray[0], ray[1])
			if not hit.is_empty():
				target = hit.cell
				_stroke_set(target, _paint_value())
	if target != null:
		map.show_cursor(target, Color.WHITE)


func _paint_value() -> int:
	return map.paint_block | (map.paint_rotation << BlockMap.ROT_SHIFT)


func _stroke_set(pos: Vector3i, value: int) -> void:
	var old := map.get_cell_value(pos)
	if mode == Mode.REPLACE and old == BlockMap.EMPTY:
		return
	if old == value:
		return
	if not stroke.has(pos):
		stroke[pos] = old
	map.set_cell_value(pos, value)


func _end_stroke() -> void:
	if mode != Mode.NONE and not stroke.is_empty():
		var ur := get_undo_redo()
		ur.create_action("Paint Blocks", UndoRedo.MERGE_DISABLE, map)
		for pos in stroke:
			ur.add_do_method(map, "set_cell_value", pos, map.get_cell_value(pos))
			ur.add_undo_method(map, "set_cell_value", pos, stroke[pos])
		ur.commit_action(false)
	mode = Mode.NONE
	stroke.clear()
