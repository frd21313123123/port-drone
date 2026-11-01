extends SceneTree
func _walk(root: String, rel: String, out: Array) -> void:
	var d := DirAccess.open(root.path_join(rel))
	d.include_hidden = true
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var r := n if rel == "" else rel.path_join(n)
		if d.current_is_dir():
			_walk(root, r, out)
		else:
			out.append(r)
		n = d.get_next()
func _init() -> void:
	var args := OS.get_cmdline_user_args()
	var src: String = args[0]
	var dst: String = args[1]
	var files: Array = []
	_walk(src, "", files)
	var p := PCKPacker.new()
	p.pck_start(dst)
	for f in files:
		p.add_file("res://" + f, src.path_join(f))
	p.flush(false)
	print("packed ", files.size(), " files")
	quit()
