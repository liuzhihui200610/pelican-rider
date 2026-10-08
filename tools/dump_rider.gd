extends SceneTree

func _init() -> void:
	for path in ["res://assets/ai/ai_rider.glb", "res://assets/ai/ai_pelican.glb"]:
		var ps = load(path)
		if ps == null:
			print("NO GLB: ", path)
			continue
		print("=== ", path, " ===")
		var inst = ps.instantiate()
		if inst == null:
			print("  instantiate failed")
			continue
		_print_tree(inst, 1)
	quit()

func _print_tree(n: Node, d: int) -> void:
	var pad := ""
	for i in d:
		pad += "  "
	var extra := ""
	if n is BoneAttachment3D or (n.name.to_lower().contains("bone")):
		extra = " <BONE>"
	print(pad, n.name, " [", n.get_class(), "]", extra)
	for c in n.get_children():
		_print_tree(c, d + 1)
