@tool
extends EditorPlugin

var dock
var tree
var search_bar
var preview_texture
var preview_label

var scan_button
var delete_button
var restore_button
var refresh_button
var me

var confirm_dialog

var unused_files: Array = []
var file_sizes := {}

var sort_ascending = true
var filter_text = ""

var trash_path = "res://.trash/"
var dependencies := {}   # file -> [dependencies]
var reverse_deps := {}   # file -> [who uses this]
var safe_delete := {}    # file -> true/false
var excluded_extensions = [".uid"]


# ---------------- SETTINGS ----------------
var protected_paths = [
	"res://addons",
	"res://.godot",
    "res://.trash"
]

var excluded_folders = [".godot", ".trash"]

var protected_extensions = [".gd", ".tscn", ".scn"]

# Scan these file types for dependencies
var dependency_scannable = ["tscn", "scn", "tres", "res", "gd"]

# All asset types to consider
var all_asset_types = ["png", "jpg", "jpeg", "svg", "webp", "ogg", "mp3", "wav", "glb", "gltf", "fbx", "obj", "tres", "tscn", "scn", "gd", "gdshader", "gdscript"]

# ---------------- INIT ----------------
func _enter_tree():
	dock = VBoxContainer.new()
	dock.name = "Asset Cleaner Pro"
	dock.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var creator_label = Label.new()
	creator_label.text = "Created by Mayur88888888 Github"
	creator_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	creator_label.add_theme_color_override("font_color", Color(0.0, 1.0, 1.0))
	dock.add_child(creator_label)
	
	
	
	scan_button = Button.new()
	scan_button.text = "Scan"
	scan_button.pressed.connect(_scan)

	delete_button = Button.new()
	delete_button.text = "Delete Selected"
	delete_button.pressed.connect(_confirm_delete_popup)

	restore_button = Button.new()
	restore_button.text = "Restore Trash"
	restore_button.pressed.connect(_restore_all)

	var sort_name_btn = Button.new()
	sort_name_btn.text = "Sort: Name"
	sort_name_btn.pressed.connect(_sort_name)

	var sort_size_btn = Button.new()
	sort_size_btn.text = "Sort: Size"
	sort_size_btn.pressed.connect(_sort_size)

	var sort_type_btn = Button.new()
	sort_type_btn.text = "Sort: Type"
	sort_type_btn.pressed.connect(_sort_type)

	refresh_button = Button.new()
	refresh_button.text = "Refresh"
	refresh_button.pressed.connect(_rebuild_tree)

	search_bar = LineEdit.new()
	search_bar.placeholder_text = "Search..."
	search_bar.text_changed.connect(_on_search_changed)

	tree = Tree.new()
	tree.columns = 3
	tree.set_column_titles_visible(true)

	tree.set_column_title(0, "File")
	tree.set_column_title(1, "Size")
	tree.set_column_title(2, "Type")

	tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tree.set_hide_root(true)

	tree.item_selected.connect(_on_item_selected)

	preview_texture = TextureRect.new()
	preview_texture.custom_minimum_size = Vector2(0, 120)

	preview_label = Label.new()
	
	# ✅ ADD PREVIEW CONTAINER
	var preview_container = VBoxContainer.new()
	preview_container.custom_minimum_size = Vector2(0, 150)
	
	var preview_header = HBoxContainer.new()
	var preview_title = Label.new()
	preview_title.text = "Preview:"
	preview_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	
	var close_preview_btn = Button.new()
	close_preview_btn.text = "✕"
	close_preview_btn.custom_minimum_size = Vector2(30, 0)
	close_preview_btn.pressed.connect(_close_preview)
	
	preview_header.add_child(preview_title)
	preview_header.add_child(close_preview_btn)
	
	preview_container.add_child(preview_header)
	preview_container.add_child(preview_texture)
	preview_container.add_child(preview_label)

	dock.add_child(scan_button)
	dock.add_child(delete_button)
	dock.add_child(restore_button)

	dock.add_child(sort_name_btn)
	dock.add_child(sort_size_btn)
	dock.add_child(sort_type_btn)
	dock.add_child(refresh_button)

	dock.add_child(search_bar)
	dock.add_child(tree)
	dock.add_child(preview_container)  # ✅ ADD CONTAINER INSTEAD OF INDIVIDUAL ITEMS

	_create_confirm_dialog()

	add_control_to_dock(EditorPlugin.DOCK_SLOT_LEFT_UL, dock)

func _exit_tree():
	remove_control_from_docks(dock)

# ============= PREVIEW FUNCTIONS =============
var preview_timer: Timer = null

func _on_item_selected():
	var item = tree.get_selected()
	if not item:
		return

	var path = item.get_tooltip_text(0)
	preview_label.text = path

	if path.ends_with(".png") or path.ends_with(".jpg") or path.ends_with(".jpeg"):
		var tex = load(path)
		if tex:
			preview_texture.texture = tex
	else:
		preview_texture.texture = null
	
	# ✅ AUTO-CLOSE PREVIEW AFTER 2 SECONDS
	_start_preview_timer()

func _start_preview_timer():
	if preview_timer:
		preview_timer.queue_free()
	
	preview_timer = Timer.new()
	preview_timer.wait_time = 2.0
	preview_timer.one_shot = true
	preview_timer.timeout.connect(_close_preview)
	add_child(preview_timer)
	preview_timer.start()

func _close_preview():
	preview_texture.texture = null
	preview_label.text = ""
	if preview_timer:
		preview_timer.queue_free()
		preview_timer = null

# ---------------- SCAN ----------------
func _scan():
	preview_label.text = "Scanning..."
	await _scan_async()

func _scan_async():
	print("SCAN STARTED")
	unused_files.clear()
	file_sizes.clear()
	var all = _get_all_files("res://")
	preview_label.text = "Analyzing usage..."
	await get_tree().process_frame
	var used = _get_used_files()
	
	# ✅ BUILD DEPENDENCY GRAPH FIRST
	_build_dependency_graph()
	
	# ✅ DEBUG: LOG DEPENDENCY GRAPH
	print("=== DEPENDENCY GRAPH DEBUG ===")
	for file in dependencies:
		if dependencies[file].size() > 0:
			print("File: ", file)
			print("  Dependencies: ", dependencies[file])
	
	print("=== REVERSE DEPS DEBUG ===")
	for file in reverse_deps:
		if reverse_deps[file].size() > 0:
			print("File: ", file)
			print("  Used by: ", reverse_deps[file])
	
	var count = 0
	var total = all.size()
	for f in all:
		if _is_protected(f):
			continue
			
		if not used.has(f) and not f.ends_with(".import"):
			var size = _get_file_size(f)
			unused_files.append(f)
			file_sizes[f] = size
		count += 1
		if count % 50 == 0:
			preview_label.text = "Scanning %d / %d" % [count, total]
			await get_tree().process_frame
	for f in unused_files:
		print(f, " -> ", safe_delete.get(f, "UNKNOWN"))
		preview_label.text = "Scan Complete: %d unused files" % unused_files.size()
		_rebuild_tree()


	# ✅ NOW compute safe delete (after dependency graph is built)
	_compute_safe_delete(used)
	preview_label.text = "Scan Complete: %d unused files" % unused_files.size()
	_rebuild_tree()

func _compute_safe_delete(used):
	safe_delete.clear()
	for f in unused_files:
		var has_reverse = reverse_deps.has(f) and reverse_deps[f].size() > 0
		print("CHECK:", f)
		print("  used:", used.has(f))
		print("  reverse deps:", reverse_deps.get(f, []).size())
		if not used.has(f) and not has_reverse:
			safe_delete[f] = true
			print("  ✅ SAFE TO DELETE")
		else:
			safe_delete[f] = false
			print("  ❌ HAS DEPENDENCIES")

# ---------------- SORT ----------------
func _sort_name():
	sort_ascending = !sort_ascending
	unused_files.sort()
	if not sort_ascending:
		unused_files.reverse()
	_rebuild_tree()

func _sort_size():
	sort_ascending = !sort_ascending
	unused_files.sort_custom(Callable(self, "_sort_by_size"))
	_rebuild_tree()

func _sort_type():
	sort_ascending = !sort_ascending
	unused_files.sort_custom(Callable(self, "_sort_by_type"))
	_rebuild_tree()

func _sort_by_size(a, b):
	return file_sizes[a] > file_sizes[b] if sort_ascending else file_sizes[a] < file_sizes[b]

func _sort_by_type(a, b):
	return a.get_extension() < b.get_extension() if sort_ascending else a.get_extension() > b.get_extension()

# ---------------- SEARCH ----------------
func _on_search_changed(text):
	filter_text = text.to_lower()
	_rebuild_tree()

# ---------------- TREE BUILD ----------------
func _rebuild_tree():
	tree.clear()
	var root = tree.create_item()

	for f in unused_files:
		if filter_text != "" and not f.to_lower().contains(filter_text):
			continue

		var item = tree.create_item(root)

		item.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
		item.set_editable(0, true)

		item.set_text(0, f.get_file())  # cleaner display
		item.set_tooltip_text(0, f)

		item.set_checked(0, false)

		item.set_text(1, _format_size(file_sizes[f]))
		item.set_text(2, f.get_extension())
		
		if safe_delete.has(f) and safe_delete[f]:
			item.set_custom_color(0, Color(0.4, 1.0, 0.4))  # green
			item.set_custom_color(1, Color(0.4, 1.0, 0.4))
			item.set_custom_color(2, Color(0.4, 1.0, 0.4))
		else:
			item.set_custom_color(0, Color(1.0, 0.8, 0.4))  # yellow/orange for files with dependencies
			item.set_custom_color(1, Color(1.0, 0.8, 0.4))
			item.set_custom_color(2, Color(1.0, 0.8, 0.4))

# ---------------- DELETE ----------------
func _confirm_delete_popup():
	confirm_dialog.popup_centered()

func _delete_selected():
	var root = tree.get_root()
	if not root:
		return

	var child = root.get_first_child()

	while child:
		if child.is_checked(0):
			var file = child.get_tooltip_text(0)

			if not _is_protected(file):
				DirAccess.make_dir_recursive_absolute(trash_path)
				DirAccess.rename_absolute(file, trash_path + file.get_file())

		child = child.get_next()

	_scan()
	EditorInterface.get_resource_filesystem().scan()

# ---------------- RESTORE ----------------
func _restore_all():
	var files = _get_all_files(trash_path)

	for f in files:
		var original = "res://" + f.get_file()
		DirAccess.rename_absolute(f, original)

	EditorInterface.get_resource_filesystem().scan()
	print("Restored all files")

# ---------------- PREVIEW ----------------

# ---------------- DIALOG ----------------
func _create_confirm_dialog():
	confirm_dialog = ConfirmationDialog.new()
	confirm_dialog.dialog_text = "Delete selected files?"
	confirm_dialog.confirmed.connect(_delete_selected)
	dock.add_child(confirm_dialog)

# ---------------- HELPERS ----------------
func _is_protected(path):
	for p in protected_paths:
		if path.begins_with(p):
			return true

	for e in protected_extensions:
		if path.ends_with(e):
			return true

	return false

func _get_file_size(path):
	if FileAccess.file_exists(path):
		var f = FileAccess.open(path, FileAccess.READ)
		if f:
			return f.get_length()
	return 0

func _format_size(bytes):
	return "%.2f KB" % (bytes / 1024.0)

# ============= ENHANCED DEPENDENCY GRAPH =============

func _build_dependency_graph():
	dependencies.clear()
	reverse_deps.clear()
	var all_files = _get_all_files("res://")
	
	# Initialize all files in reverse_deps
	for f in all_files:
		reverse_deps[f] = []
	
	# Scan all resource types
	var resources = _get_files_by_ext(["tscn", "scn", "tres", "res"])
	for r in resources:
		_scan_resource_deps(r)
	
	# Scan scripts
	var scripts = _get_files_by_ext(["gd"])
	for s in scripts:
		_scan_script_deps(s)
	
	# Scan shaders
	var shaders = _get_files_by_ext(["gdshader"])
	for sh in shaders:
		_scan_shader_deps(sh)
	
	# Scan scenes for embedded resources
	for scene in resources:
		if scene.ends_with(".tscn") or scene.ends_with(".scn"):
			_scan_scene_deps(scene)
	
	print("Dependency graph built. Total files: ", all_files.size())
	print("Reverse deps count: ", reverse_deps.size())






func _scan_scene_deps(scene_path: String):
	var scene = load(scene_path)
	if not scene:
		return
	
	var deps = []
	_collect_scene_deps(scene, deps, {})
	dependencies[scene_path] = deps
	
	for d in deps:
		if not reverse_deps.has(d):
			reverse_deps[d] = []
		if not reverse_deps[d].has(scene_path):
			reverse_deps[d].append(scene_path)

func _collect_scene_deps(res, list: Array, visited: Dictionary):
	if not res or visited.has(res):
		return
	
	visited[res] = true
	
	# Add resource path if it exists
	if res.resource_path != "":
		if not list.has(res.resource_path):
			list.append(res.resource_path)
	
	# Recursively scan all properties
	for prop in res.get_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		
		var val = res.get(prop.name)
		
		if val is Resource:
			_collect_scene_deps(val, list, visited)
		elif val is Array:
			for item in val:
				if item is Resource:
					_collect_scene_deps(item, list, visited)
		elif val is Dictionary:
			for key in val:
				var item = val[key]
				if item is Resource:
					_collect_scene_deps(item, list, visited)


# ============= RESOURCE DEPENDENCY SCANNING =============
func _scan_resource_deps(resource_path: String):
	var res = load(resource_path)
	if not res:
		return
	
	var deps = []
	_collect_resource_deps(res, deps, {})
	dependencies[resource_path] = deps
	
	for d in deps:
		if not reverse_deps.has(d):
			reverse_deps[d] = []
		if not reverse_deps[d].has(resource_path):
			reverse_deps[d].append(resource_path)

func _collect_resource_deps(res, list: Array, visited: Dictionary):
	if not res or visited.has(res):
		return
	
	visited[res] = true
	
	# Add resource path if it exists
	if res.resource_path != "" and res.resource_path != "":
		if not list.has(res.resource_path):
			list.append(res.resource_path)
	
	# Recursively scan all properties
	for prop in res.get_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		
		var val = res.get(prop.name)
		
		# Handle Resource types
		if val is Resource:
			_collect_resource_deps(val, list, visited)
		
		# Handle arrays of resources
		elif val is Array:
			for item in val:
				if item is Resource:
					_collect_resource_deps(item, list, visited)
		
		# Handle dictionaries with resource values
		elif val is Dictionary:
			for key in val:
				var item = val[key]
				if item is Resource:
					_collect_resource_deps(item, list, visited)

# ============= SCRIPT DEPENDENCY SCANNING =============
func _scan_script_deps(script_path: String):
	var text = FileAccess.get_file_as_string(script_path)
	if text == "":
		return
	
	var deps = []
	
	# Pattern 1: preload("res://...")
	var preload_regex = RegEx.new()
	if preload_regex.compile("preload\\([\"']([^\"']+)[\"']\\)") == OK:
		var preload_matches = preload_regex.search_all(text)
		for m in preload_matches:
			var path = m.get_string(1)
			if path.begins_with("res://") and FileAccess.file_exists(path) and not deps.has(path):
				deps.append(path)
				print("  Found preload: ", path)
	
	# Pattern 2: load("res://...")
	var load_regex = RegEx.new()
	if load_regex.compile("load\\([\"']([^\"']+)[\"']\\)") == OK:
		var load_matches = load_regex.search_all(text)
		for m in load_matches:
			var path = m.get_string(1)
			if path.begins_with("res://") and FileAccess.file_exists(path) and not deps.has(path):
				deps.append(path)
				print("  Found load: ", path)
	
	# Pattern 3: Direct res:// references
	var res_regex = RegEx.new()
	if res_regex.compile("res://[a-zA-Z0-9_./\\-]+") == OK:
		var res_matches = res_regex.search_all(text)
		for m in res_matches:
			var path = m.get_string()
			if path.begins_with("res://") and FileAccess.file_exists(path) and not deps.has(path):
				deps.append(path)
				print("  Found res:// reference: ", path)
	
	dependencies[script_path] = deps
	
	for d in deps:
		if not reverse_deps.has(d):
			reverse_deps[d] = []
		if not reverse_deps[d].has(script_path):
			reverse_deps[d].append(script_path)


# ============= SHADER DEPENDENCY SCANNING =============
func _scan_shader_deps(shader_path: String):
	var text = FileAccess.get_file_as_string(shader_path)
	if text == "":
		return
	
	var deps = []
	
	# Pattern: #include "res://..."
	var include_regex = RegEx.new()
	include_regex.compile("#include\\s+[\"']([^\"']+)[\"']")
	var include_matches = include_regex.search_all(text)
	for m in include_matches:
		var path = m.get_string(1)
		if path.begins_with("res://") and not deps.has(path):
			deps.append(path)
	
	# Pattern: texture references
	var tex_regex = RegEx.new()
	tex_regex.compile("hint_default_white|hint_default_black|hint_normal|hint_roughness_normal|hint_roughness_g|hint_roughness_b|hint_roughness_gray|hint_anisotropy|hint_albedo|hint_orm")
	
	dependencies[shader_path] = deps
	
	for d in deps:
		if not reverse_deps.has(d):
			reverse_deps[d] = []
		if not reverse_deps[d].has(shader_path):
			reverse_deps[d].append(shader_path)

# ============= FILE SCAN ================
func _get_all_files(path):
	var files = []
	var dir = DirAccess.open(path)

	if dir:
		dir.list_dir_begin()
		var name = dir.get_next()

		while name != "":
			if excluded_folders != null and name in excluded_folders:
				name = dir.get_next()
				continue

			var full_path = path + "/" + name

			if dir.current_is_dir():
				if name != "." and name != "..":
					files += _get_all_files(full_path)
			else:
				# Ignore UID files
				if excluded_extensions != null and name.ends_with(".uid"):
					name = dir.get_next()
					continue
				
				files.append(full_path)

			name = dir.get_next()

	return files

# ============= USED FILES DETECTION =============
func _get_used_files():
	var used := {}

	# Scan all resource types
	var resources = _get_files_by_ext(["tscn", "scn", "tres", "res"])
	var scripts = _get_files_by_ext(["gd"])
	var shaders = _get_files_by_ext(["gdshader"])

	# Resource dependencies
	for r in resources:
		var res = load(r)
		if res:
			_collect_used_deps(res, used, {})

	# Script references
	for script_path in scripts:
		var text = FileAccess.get_file_as_string(script_path)
		if text == "":
			continue
		
		# preload
		var preload_regex = RegEx.new()
		if preload_regex.compile("preload\\([\"']([^\"']+)[\"']\\)") == OK:
			var preload_matches = preload_regex.search_all(text)
			for m in preload_matches:
				var path = m.get_string(1)
				if path.begins_with("res://") and FileAccess.file_exists(path):
					used[path] = true
		
		# load
		var load_regex = RegEx.new()
		if load_regex.compile("load\\([\"']([^\"']+)[\"']\\)") == OK:
			var load_matches = load_regex.search_all(text)
			for m in load_matches:
				var path = m.get_string(1)
				if path.begins_with("res://") and FileAccess.file_exists(path):
					used[path] = true
		
		# Direct res:// references
		var res_regex = RegEx.new()
		if res_regex.compile("res://[a-zA-Z0-9_./\\-]+") == OK:
			var res_matches = res_regex.search_all(text)
			for m in res_matches:
				var path = m.get_string()
				if path.begins_with("res://") and FileAccess.file_exists(path):
					used[path] = true
	
	# Shader includes
	for shader_path in shaders:
		var text = FileAccess.get_file_as_string(shader_path)
		if text == "":
			continue
		
		var include_regex = RegEx.new()
		if include_regex.compile("#include\\s+[\"']([^\"']+)[\"']") == OK:
			var include_matches = include_regex.search_all(text)
			for m in include_matches:
				var path = m.get_string(1)
				if path.begins_with("res://") and FileAccess.file_exists(path):
					used[path] = true
	
	return used

func _collect_used_deps(res, used: Dictionary, visited: Dictionary):
	if not res or visited.has(res):
		return
	
	visited[res] = true
	
	if res.resource_path != "":
		used[res.resource_path] = true
	
	for prop in res.get_property_list():
		if prop.usage & PROPERTY_USAGE_STORAGE == 0:
			continue
		
		var val = res.get(prop.name)
		
		if val is Resource:
			_collect_used_deps(val, used, visited)
		elif val is Array:
			for item in val:
				if item is Resource:
					_collect_used_deps(item, used, visited)
		elif val is Dictionary:
			for key in val:
				var item = val[key]
				if item is Resource:
					_collect_used_deps(item, used, visited)

# ============= UTILITY =============
func _get_files_by_ext(exts):
	var result = []
	var all = _get_all_files("res://")

	for f in all:
		for e in exts:
			if f.ends_with("." + e):
				result.append(f)
				break

	return result
