extends Node
## PC port: the start scene (res://pc/boot.tscn, set in override.cfg). Checks GitHub Releases BEFORE the game is even loaded,
## then switches to the game scene.
##  - a newer release  -> a blocking window «this version is outdated» -> download DroneFlames.exe,
##    swap it for the running one (Windows lets a running exe be renamed), start the new one;
##  - the native libraries (WebRTC, GodotSteam, steam_api64.dll) are not inside the exe: if they are
##    missing or older than the release's DroneFlames-libs-rN.zip, they are downloaded next to it.
## No network / GitHub not answering = the game just starts. Settings: res://pc/version.cfg
## (the build fills in `version` and `repo`). Tests: DF_UPDATE_API / DF_UPDATE_ASSET (debug builds only).

const GAME_SCENE: String = "res://game/main.tscn"
const CFG_PATH: String = "res://pc/version.cfg"
const API_FMT: String = "https://api.github.com/repos/%s/releases/latest"
const EXE_ASSET: String = "DroneFlames.exe"
const LIB_FILES: PackedStringArray = ["libwebrtc_native.windows.template_release.x86_64.dll",
	"libgodotsteam.windows.template_release.x86_64.dll", "steam_api64.dll"]
const CHECK_TIMEOUT_S: float = 12.0
const GOLD: Color = Color("e8b33a")
const TEXT: Color = Color("e9e4cf")

const TXT: Dictionary = {
	"ru": {"check": "Проверка обновлений...", "old": "ЭТА ВЕРСИЯ УСТАРЕЛА", "msg": "Установлена версия %s, на GitHub вышла %s.\nДля игры (и особенно для сетевой) нужно обновиться.",
		"upd": "ОБНОВИТЬ", "quit": "ВЫЙТИ", "dl": "Загрузка %s: %d%%", "apply": "Установка...", "restart": "Запуск новой версии...",
		"fail": "Не удалось обновиться:\n%s", "page": "СТРАНИЦА ЗАГРУЗКИ", "skip": "ИГРАТЬ БЕЗ ОБНОВЛЕНИЯ", "libs": "Загрузка компонентов (Steam, онлайн)...",
		"libs_done": "Компоненты установлены. Перезапуск...", "size": "Размер файла не совпал", "hash": "Контрольная сумма не совпала",
		"nowrite": "Нет доступа на запись в папку игры (переместите игру из защищённой папки)"},
	"uk": {"check": "Перевірка оновлень...", "old": "ЦЯ ВЕРСІЯ ЗАСТАРІЛА", "msg": "Встановлено версію %s, на GitHub вийшла %s.\nДля гри (особливо мережевої) потрібно оновитися.",
		"upd": "ОНОВИТИ", "quit": "ВИЙТИ", "dl": "Завантаження %s: %d%%", "apply": "Встановлення...", "restart": "Запуск нової версії...",
		"fail": "Не вдалося оновитися:\n%s", "page": "СТОРІНКА ЗАВАНТАЖЕННЯ", "skip": "ГРАТИ БЕЗ ОНОВЛЕННЯ", "libs": "Завантаження компонентів (Steam, онлайн)...",
		"libs_done": "Компоненти встановлено. Перезапуск...", "size": "Розмір файлу не збігся", "hash": "Контрольна сума не збіглася",
		"nowrite": "Немає доступу на запис у теку гри (перемістіть гру із захищеної теки)"},
	"en": {"check": "Checking for updates...", "old": "THIS VERSION IS OUTDATED", "msg": "Installed: %s. A newer version is out on GitHub: %s.\nYou need to update to play (online play especially).",
		"upd": "UPDATE", "quit": "QUIT", "dl": "Downloading %s: %d%%", "apply": "Installing...", "restart": "Starting the new version...",
		"fail": "Update failed:\n%s", "page": "DOWNLOAD PAGE", "skip": "PLAY WITHOUT UPDATING", "libs": "Downloading components (Steam, online)...",
		"libs_done": "Components installed. Restarting...", "size": "File size mismatch", "hash": "Checksum mismatch",
		"nowrite": "Cannot write to the game folder (move the game out of a protected folder)"},
}

var version: String = "0.0.0"
var repo: String = ""
var libs_rev: int = 0
var lang: String = "en"
var _layer: CanvasLayer = null
var _title: Label = null
var _msg: Label = null
var _bar: ProgressBar = null
var _row: HBoxContainer = null
var _http: HTTPRequest = null
var _total: int = 0
var _page_url: String = ""
var _dl_label: String = ""
var _exe: String = ""  # the exe path as started (after the swap the OS reports the renamed .old file)


func _ready() -> void:
	_exe = OS.get_executable_path()
	if not _enabled():
		_start_game.call_deferred()
		return
	_load_cfg()
	if repo == "":
		_start_game.call_deferred()
		return
	_cleanup_old()
	_build_ui()
	_say("check")
	_run.call_deferred()


func _enabled() -> bool:
	if DisplayServer.get_name() == "headless" or OS.has_feature("editor") or OS.get_environment("DF_NO_UPDATE") != "":
		return false
	return OS.get_name() == "Windows" or (OS.is_debug_build() and OS.get_environment("DF_UPDATE_API") != "")


func _load_cfg() -> void:
	var c: ConfigFile = ConfigFile.new()
	if c.load(CFG_PATH) == OK:
		version = String(c.get_value("pc", "version", version))
		repo = String(c.get_value("pc", "repo", ""))
		libs_rev = int(c.get_value("pc", "libs_rev", 0))
	var l: String = OS.get_locale_language()
	lang = l if TXT.has(l) else "en"


func t(k: String) -> String:
	return String((TXT[lang] as Dictionary).get(k, k))


static func nums(v: String) -> Array:
	var out: Array = []
	var re: RegEx = RegEx.create_from_string("\\d+")
	for m: RegExMatch in re.search_all(v):
		out.append(int(m.get_string()))
	return out


## true when `a` is newer than `b` (0.32.1 > 0.32.0.1 > 0.32.0)
static func newer(a: String, b: String) -> bool:
	var x: Array = nums(a)
	var y: Array = nums(b)
	for i in maxi(x.size(), y.size()):
		var xi: int = int(x[i]) if i < x.size() else 0
		var yi: int = int(y[i]) if i < y.size() else 0
		if xi != yi:
			return xi > yi
	return false


func _exe_dir() -> String:
	return _exe.get_base_dir()


func _cleanup_old() -> void:
	var d: DirAccess = DirAccess.open(_exe_dir())
	if d == null:
		return
	for f: String in d.get_files():
		if f.ends_with(".old") or f.ends_with(".new") or f.ends_with(".tmp"):
			d.remove(f)


# ---------------------------------------------------------------- the flow

func _run() -> void:
	await get_tree().process_frame  # the first frames of a cold start can be long: the timeout must not run through them
	await get_tree().process_frame
	var api: String = OS.get_environment("DF_UPDATE_API") if OS.is_debug_build() and OS.get_environment("DF_UPDATE_API") != "" else API_FMT % repo
	var rel: Dictionary = await _get_json(api)
	if rel.is_empty():
		print("[Update] no answer from GitHub: starting")
		_finish()
		return
	var tag: String = String(rel.get("tag_name", ""))
	_page_url = String(rel.get("html_url", "https://github.com/%s/releases" % repo))
	var assets: Array = rel.get("assets", [])
	var exe_name: String = OS.get_environment("DF_UPDATE_ASSET") if OS.is_debug_build() and OS.get_environment("DF_UPDATE_ASSET") != "" else EXE_ASSET
	var exe_asset: Dictionary = _find_asset(assets, exe_name)
	if newer(tag, version) and not exe_asset.is_empty():
		print("[Update] %s -> %s" % [version, tag])
		_offer(tag.trim_prefix("v"), exe_asset, String(rel.get("body", "")))
		return
	if await _libs(assets):
		return
	_finish()


func _find_asset(assets: Array, nm: String) -> Dictionary:
	for a: Variant in assets:
		if a is Dictionary and String((a as Dictionary).get("name", "")) == nm:
			return a
	return {}


## Debug builds only (tests behind a proxy): HTTPS_PROXY and DF_UPDATE_CA (a PEM file with the proxy's CA).
func _net(h: HTTPRequest) -> void:
	if not OS.is_debug_build():
		return
	var px: String = OS.get_environment("HTTPS_PROXY")
	if px != "":
		var hp: PackedStringArray = px.trim_prefix("http://").trim_suffix("/").split(":")
		if hp.size() == 2:
			h.set_https_proxy(hp[0], int(hp[1]))
			h.set_http_proxy(hp[0], int(hp[1]))
	var ca: String = OS.get_environment("DF_UPDATE_CA")
	if ca != "":
		var cert: X509Certificate = X509Certificate.new()
		if cert.load(ca) == OK:
			h.set_tls_options(TLSOptions.client(cert))


func _get_json(url: String) -> Dictionary:
	var h: HTTPRequest = HTTPRequest.new()
	h.timeout = CHECK_TIMEOUT_S
	_net(h)
	add_child(h)
	if h.request(url, ["User-Agent: DroneFlames-PC", "Accept: application/vnd.github+json"]) != OK:
		h.queue_free()
		return {}
	var r: Array = await h.request_completed
	h.queue_free()
	if int(r[0]) != HTTPRequest.RESULT_SUCCESS or int(r[1]) != 200:
		print("[Update] check failed: result=%d http=%d" % [int(r[0]), int(r[1])])
		return {}
	var j: Variant = JSON.parse_string((r[3] as PackedByteArray).get_string_from_utf8())
	return j if j is Dictionary else {}


func _finish() -> void:
	_start_game()


func _start_game() -> void:
	get_tree().change_scene_to_file(GAME_SCENE)


## the blocking «outdated» window
func _offer(new_ver: String, asset: Dictionary, notes: String) -> void:
	_title.text = t("old")
	_msg.text = t("msg") % [version, new_ver] + ("\n\n" + notes.strip_edges().left(420) if notes.strip_edges() != "" else "")
	_buttons([[t("upd"), true, func() -> void: _do_update(new_ver, asset)], [t("quit"), false, func() -> void: get_tree().quit()]])


func _do_update(new_ver: String, asset: Dictionary) -> void:
	_buttons([])
	var dir: String = _exe_dir()
	var exe: String = _exe
	var tmp: String = exe + ".new"
	var probe: FileAccess = FileAccess.open(dir.path_join("write.test.tmp"), FileAccess.WRITE)
	if probe == null:
		_fail(t("nowrite"))
		return
	probe.close()
	DirAccess.remove_absolute(dir.path_join("write.test.tmp"))
	var err: String = await _download(String(asset.get("browser_download_url", "")), tmp, int(asset.get("size", 0)), new_ver)
	if err == "":
		var dg: String = String(asset.get("digest", ""))
		if dg.begins_with("sha256:") and FileAccess.get_sha256(tmp).to_lower() != dg.trim_prefix("sha256:").to_lower():
			err = t("hash")
	if err != "":
		DirAccess.remove_absolute(tmp)
		_fail(err)
		return
	_say("apply")
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(tmp, 493)  # 0755 (only the tests run this on Linux)
	var old: String = exe + ".old"
	DirAccess.remove_absolute(old)
	if DirAccess.rename_absolute(exe, old) != OK:
		_fail(t("nowrite"))
		return
	if DirAccess.rename_absolute(tmp, exe) != OK:
		DirAccess.rename_absolute(old, exe)  # put the old one back
		_fail(t("nowrite"))
		return
	_say("restart")
	await get_tree().create_timer(0.6).timeout
	_relaunch()


func _relaunch() -> void:
	OS.create_process(_exe, OS.get_cmdline_args())
	get_tree().quit()


## -> "" when saved, else the reason
func _download(url: String, path: String, size: int, label: String) -> String:
	if url == "":
		return "no url"
	_http = HTTPRequest.new()
	_http.download_file = path
	_http.timeout = 0.0
	_http.max_redirects = 10
	_net(_http)
	add_child(_http)
	_total = size
	_dl_label = label
	_bar.visible = true
	_bar.value = 0
	if _http.request(url, ["User-Agent: DroneFlames-PC"]) != OK:
		_http.queue_free()
		_http = null
		return "request"
	_msg.text = t("dl") % [label, 0]
	var r: Array = await _http.request_completed
	_http.queue_free()
	_http = null
	_bar.visible = false
	if int(r[0]) != HTTPRequest.RESULT_SUCCESS or int(r[1]) != 200:
		return "HTTP %d / %d" % [int(r[1]), int(r[0])]
	var got: int = FileAccess.get_size(path) if FileAccess.file_exists(path) else 0
	if size > 0 and got != size:
		return t("size")
	return ""


func _process(_d: float) -> void:
	if _http != null and _total > 0 and _bar != null and _bar.visible:
		var pc: float = clampf(float(_http.get_downloaded_bytes()) / float(_total), 0.0, 1.0)
		_bar.value = pc * 100.0
		_msg.text = t("dl") % [_dl_label, int(pc * 100.0)]


func _fail(why: String) -> void:
	print("[Update] failed: ", why)
	_bar.visible = false
	_title.text = t("old")
	_msg.text = t("fail") % why
	_buttons([[t("page"), true, func() -> void: OS.shell_open(_page_url)], [t("skip"), false, func() -> void: _finish()], [t("quit"), false, func() -> void: get_tree().quit()]])


# ---------------------------------------------------------------- native libraries (Windows)

func _libs(assets: Array) -> bool:
	if OS.get_name() != "Windows":
		return false
	var want: int = 0
	var asset: Dictionary = {}
	var re: RegEx = RegEx.create_from_string("^DroneFlames-libs-r(\\d+)\\.zip$")
	for a: Variant in assets:
		var m: RegExMatch = re.search(String((a as Dictionary).get("name", ""))) if a is Dictionary else null
		if m != null and int(m.get_string(1)) > want:
			want = int(m.get_string(1))
			asset = a
	if asset.is_empty():
		return false
	var dir: String = _exe_dir()
	var have: int = 0
	var rf: FileAccess = FileAccess.open(dir.path_join("libs.rev"), FileAccess.READ)
	if rf != null:
		have = int(rf.get_as_text().strip_edges())
	var missing: bool = false
	for f: String in LIB_FILES:
		if not FileAccess.file_exists(dir.path_join(f)):
			missing = true
	if not missing and have >= want:
		return false
	var guard: String = "user://libs_try.txt"  # one try per minute: a failing write must not restart forever
	if FileAccess.file_exists(guard) and Time.get_unix_time_from_system() - float(FileAccess.get_file_as_string(guard)) < 60.0:
		return false
	var gf: FileAccess = FileAccess.open(guard, FileAccess.WRITE)
	if gf != null:
		gf.store_string(str(Time.get_unix_time_from_system()))
		gf.close()
	_title.text = ""
	_say("libs")
	var zip: String = dir.path_join("libs.zip.tmp")
	var err: String = await _download(String(asset.get("browser_download_url", "")), zip, int(asset.get("size", 0)), "libs")
	if err != "":
		print("[Update] libs download failed: ", err)
		return false
	var z: ZIPReader = ZIPReader.new()
	if z.open(zip) != OK:
		return false
	for f: String in z.get_files():
		var base: String = f.get_file()
		if not LIB_FILES.has(base):
			continue
		var target: String = dir.path_join(base)
		if FileAccess.file_exists(target):
			DirAccess.remove_absolute(target + ".old")
			DirAccess.rename_absolute(target, target + ".old")  # a loaded dll can be renamed, not overwritten
		var out: FileAccess = FileAccess.open(target, FileAccess.WRITE)
		if out == null:
			z.close()
			return false
		out.store_buffer(z.read_file(f))
		out.close()
	z.close()
	DirAccess.remove_absolute(zip)
	var wf: FileAccess = FileAccess.open(dir.path_join("libs.rev"), FileAccess.WRITE)
	if wf != null:
		wf.store_string(str(want))
		wf.close()
	_say("libs_done")
	await get_tree().create_timer(0.8).timeout
	_relaunch()
	return true


# ---------------------------------------------------------------- the window

func _say(k: String) -> void:
	_msg.text = t(k)


func _buttons(items: Array) -> void:
	for c: Node in _row.get_children():
		c.queue_free()
	for it: Array in items:
		var b: Button = Button.new()
		b.text = String(it[0])
		b.custom_minimum_size = Vector2(190, 46)
		b.focus_mode = Control.FOCUS_ALL
		b.add_theme_font_size_override("font_size", 16)
		b.add_theme_color_override("font_color", TEXT)
		var col: Color = Color("3e8e2f") if bool(it[1]) else Color("5a5a44")
		for st: String in ["normal", "hover", "pressed", "focus"]:
			var sb: StyleBoxFlat = StyleBoxFlat.new()
			sb.bg_color = col.lightened(0.15) if st == "hover" else col
			sb.set_border_width_all(2)
			sb.border_color = Color("1b1d12")
			sb.set_corner_radius_all(4)
			b.add_theme_stylebox_override(st, sb)
		b.pressed.connect(it[2] as Callable)
		_row.add_child(b)
		if bool(it[1]):
			b.grab_focus.call_deferred()


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 200
	add_child(_layer)
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.03, 1.0)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(bg)
	var cc: CenterContainer = CenterContainer.new()
	cc.set_anchors_preset(Control.PRESET_FULL_RECT)
	cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(cc)
	var pc: PanelContainer = PanelContainer.new()
	var sb: StyleBoxFlat = StyleBoxFlat.new()
	sb.bg_color = Color("3b4228")
	sb.set_border_width_all(3)
	sb.border_color = Color("1b1d12")
	sb.set_content_margin_all(26)
	pc.add_theme_stylebox_override("panel", sb)
	cc.add_child(pc)
	var vb: VBoxContainer = VBoxContainer.new()
	vb.add_theme_constant_override("separation", 14)
	vb.custom_minimum_size = Vector2(520, 0)
	pc.add_child(vb)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 28)
	_title.add_theme_color_override("font_color", GOLD)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(_title)
	_msg = Label.new()
	_msg.add_theme_font_size_override("font_size", 17)
	_msg.add_theme_color_override("font_color", TEXT)
	_msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_msg.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_msg.custom_minimum_size = Vector2(520, 0)
	vb.add_child(_msg)
	_bar = ProgressBar.new()
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 14)
	_bar.visible = false
	vb.add_child(_bar)
	_row = HBoxContainer.new()
	_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_row.add_theme_constant_override("separation", 12)
	vb.add_child(_row)
