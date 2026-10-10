extends SceneTree
## Renders the demo scene to docs/screenshot.png. Needs a window (not --headless):
## godot --path . --resolution 1280x720 --script tools/screenshot.gd

const OUT := "res://docs/screenshot.png"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var demo: Node = load("res://demo/demo.tscn").instantiate()
	demo.get_node("UI").visible = false
	root.add_child(demo)
	# Let chunks build, shadows settle and the waterfall pick a frame.
	for i in 30:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	img.save_png(ProjectSettings.globalize_path(OUT))
	print("wrote %s %dx%d" % [OUT, img.get_width(), img.get_height()])
	quit()
