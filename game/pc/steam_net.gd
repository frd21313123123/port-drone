extends Node
## PC port (autoload "SteamNet"): Steam for multiplayer through GodotSteam, app 480 (Spacewar —
## Valve's free test app, so no own Steam page is needed). Lobbies find the rooms, Steam friends
## invite each other (overlay or the friends list), SteamLinkPeer carries the game itself.
## DF_STEAM_MOCK=<id> runs on a local stand-in (tests only).

signal changed  # ready / lobby state / list
signal lobby_entered(lobby_id: int, host_sid: int)  # joined somebody's lobby: connect to its host
signal lobby_failed(why: String)
signal invite_accepted(lobby_id: int)  # «Join game» / an invite from Steam

const APP_ID: int = 480
const KEY_GAME: String = "df_game"
const VAL_GAME: String = "DroneFlames"
const LOBBY_PUBLIC: int = 2
const LOBBY_FRIENDS: int = 1
const CMP_EQUAL: int = 0
const DIST_WORLDWIDE: int = 3
const RESULT_OK: int = 1

const MockScript = preload("res://pc/steam_mock.gd")
const PeerScript = preload("res://pc/steam_peer.gd")

var api: Object = null
var ok: bool = false
var why: String = ""
var my_sid: int = 0
var persona: String = ""
var lobby_id: int = 0
var lobby_host: int = 0
var lobbies: Array = []  # [{"id", "name", "n", "max", "v", "host"}]
var listing: bool = false
var list_t: int = 0
var pending_invite: int = 0
var peer: PeerScript = null  # the live link (sessions are accepted for it)
var _creating: bool = false
var _joining: int = 0
var _mock: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var args: PackedStringArray = OS.get_cmdline_args()
	for i in args.size():
		if args[i] == "+connect_lobby" and i + 1 < args.size():
			pending_invite = int(args[i + 1])
	_init_api()


func _init_api() -> void:
	var mock_id: String = OS.get_environment("DF_STEAM_MOCK")
	if mock_id != "":
		api = MockScript.new()
		_mock = true
	elif Engine.has_singleton("Steam"):
		api = Engine.get_singleton("Steam")
	else:
		why = "NO_PLUGIN"
		print("[Steam] GodotSteam is not loaded: Steam multiplayer is off")
		return
	var r: Variant = api.call("steamInitEx", APP_ID, true)
	var st: int = int((r as Dictionary).get("status", 1)) if r is Dictionary else 1
	if st != 0:
		why = String((r as Dictionary).get("verbal", "")) if r is Dictionary else ""
		if why == "":
			why = "STEAM_NOT_RUNNING"
		print("[Steam] init failed (%d): %s" % [st, why])
		return
	ok = true
	my_sid = int(api.call("getSteamID"))
	persona = String(api.call("getPersonaName"))
	if api.has_method("initRelayNetworkAccess"):
		api.call("initRelayNetworkAccess")
	api.connect("lobby_created", _on_lobby_created)
	api.connect("lobby_joined", _on_lobby_joined)
	api.connect("lobby_match_list", _on_lobby_match_list)
	api.connect("join_requested", _on_join_requested)
	api.connect("network_messages_session_request", _on_session_request)
	api.connect("network_messages_session_failed", _on_session_failed)
	print("[Steam] ready as %s (%d), app %d" % [persona, my_sid, APP_ID])
	changed.emit()


func _process(_d: float) -> void:
	if ok and _mock:
		api.call("run_callbacks")


static func inst() -> Node:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("SteamNet") if tree != null else null


# ---------------------------------------------------------------- links

func make_host_peer() -> PeerScript:
	if not ok:
		return null
	var p: PeerScript = PeerScript.new()
	p.create_host(api, my_sid)
	peer = p
	return p


func make_client_peer(host_sid: int) -> PeerScript:
	if not ok or host_sid == 0:
		return null
	var p: PeerScript = PeerScript.new()
	if p.create_client(api, my_sid, host_sid) != OK:
		return null
	peer = p
	return p


func _on_session_request(remote: int) -> void:
	if peer != null and peer.wants_session(remote):
		api.call("acceptSessionWithUser", remote)
	else:
		print("[Steam] session request from %d ignored" % remote)


func _on_session_failed(_reason: int, remote: int, _state: int, msg: String) -> void:
	print("[Steam] session with %d failed: %s" % [remote, msg])
	if peer != null:
		peer.session_failed(remote)


# ---------------------------------------------------------------- lobbies

func create_lobby(max_members: int) -> void:
	if not ok:
		lobby_failed.emit("STEAM")
		return
	leave_lobby()
	_creating = true
	lobby_host = my_sid
	api.call("createLobby", LOBBY_PUBLIC, max_members)


func _on_lobby_created(result: int, id: int) -> void:
	_creating = false
	if result != RESULT_OK:
		print("[Steam] lobby not created: %d" % result)
		lobby_host = 0
		lobby_failed.emit("CREATE")
		return
	lobby_id = id
	lobby_host = my_sid
	api.call("setLobbyData", id, KEY_GAME, VAL_GAME)
	api.call("setLobbyData", id, "name", persona)
	api.call("setLobbyData", id, "v", NetConfig.version())
	api.call("setLobbyData", id, "host", str(my_sid))
	api.call("setLobbyJoinable", id, true)
	print("[Steam] lobby %d open" % id)
	changed.emit()


func refresh_lobbies() -> void:
	if not ok or listing:
		return
	listing = true
	api.call("addRequestLobbyListStringFilter", KEY_GAME, VAL_GAME, CMP_EQUAL)
	api.call("addRequestLobbyListDistanceFilter", DIST_WORLDWIDE)
	api.call("requestLobbyList")
	changed.emit()


func _on_lobby_match_list(ids: Array) -> void:
	listing = false
	list_t = Time.get_ticks_msec()
	lobbies = []
	for v: Variant in ids:
		var id: int = int(v)
		if id == lobby_id:
			continue
		var host: int = int(String(api.call("getLobbyData", id, "host")))
		if host == 0 or host == my_sid:
			continue
		lobbies.append({"id": id, "name": String(api.call("getLobbyData", id, "name")), "v": String(api.call("getLobbyData", id, "v")),
			"n": int(api.call("getNumLobbyMembers", id)), "max": int(api.call("getLobbyMemberLimit", id)), "host": host})
	changed.emit()


func join_lobby(id: int) -> void:
	if not ok or id == 0:
		lobby_failed.emit("STEAM")
		return
	leave_lobby()
	_joining = id
	api.call("joinLobby", id)


func _on_lobby_joined(id: int, _perm: int, _locked: bool, response: int) -> void:
	if _creating or (id == lobby_id and lobby_host == my_sid):
		return  # Steam enters its creator into the new lobby as well
	if id != _joining:
		return
	_joining = 0
	if response != RESULT_OK:
		lobby_failed.emit("JOIN_%d" % response)
		return
	var host: int = int(String(api.call("getLobbyData", id, "host")))
	if host == 0:
		host = int(api.call("getLobbyOwner", id))
	if host == 0 or host == my_sid:
		api.call("leaveLobby", id)
		lobby_failed.emit("GONE")
		return
	if String(api.call("getLobbyData", id, "v")) != NetConfig.version():
		api.call("leaveLobby", id)
		lobby_failed.emit("VERSION")
		return
	lobby_id = id
	lobby_host = host
	changed.emit()
	lobby_entered.emit(id, host)


func leave_lobby() -> void:
	if ok and lobby_id != 0:
		api.call("leaveLobby", lobby_id)
	lobby_id = 0
	lobby_host = 0
	_joining = 0


func set_joinable(on: bool) -> void:
	if ok and lobby_id != 0 and lobby_host == my_sid:
		api.call("setLobbyJoinable", lobby_id, on)


func set_count(n: int) -> void:
	if ok and lobby_id != 0 and lobby_host == my_sid:
		api.call("setLobbyData", lobby_id, "n", str(n))


func invite_friends() -> bool:
	if not ok or lobby_id == 0:
		return false
	api.call("activateGameOverlayInviteDialog", lobby_id)
	return true


func _on_join_requested(id: int, _friend: int) -> void:
	print("[Steam] join requested: lobby %d" % id)
	pending_invite = id
	invite_accepted.emit(id)


func take_invite() -> int:
	var id: int = pending_invite
	pending_invite = 0
	return id
