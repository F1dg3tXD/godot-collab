#!/usr/bin/env -S godot --headless --script
## Headless entry point for the Godot Collab relay server.
##
## The relay lets editors behind NAT, CGNAT or restrictive firewalls
## collaborate: the host and every client make an outbound ENet/UDP connection
## to this process, which forwards opaque packets between them. Nothing inbound
## needs to be reachable on the participants' machines.
##
## Run it from a project that has the Godot Collab add-on installed (so
## [CollabRelayServer] and its dependencies are available), for example:
##
##     godot --headless --path /srv/collab-host --script tools/relay_server/relay_server.gd \
##         -- --port 45900 --max-clients 128
##
## Or simply, from inside this repository:
##
##     godot --headless --script tools/relay_server/relay_server.gd
##
## Then set Editor Settings -> `godot_collab/network/use_relay` to true and
## point `godot_collab/network/relay_address` at this machine.
##
## The relay is transport-only for live traffic, but it optionally keeps a
## host-authoritative *project mirror* on disk (`--projects-dir`, default
## `tools/relay_server/projects`): when a host registers it pulls the host's live
## project (hash-diffed through the normal transfer protocol), persists later
## file changes, and replays the stored state to clients that join afterwards.
## Pass `--projects-dir ""` to disable mirroring and keep the relay purely
## in-memory.
##
## Set `GODOT_COLLAB_RELAY_PASSWORD` to require a password on every session:
## hosts and clients must enter the same password in the add-on before they can
## register a room. Without the variable (or with an empty value) the relay
## accepts anyone, as before. The value is never printed or stored.
extends SceneTree

var _server: CollabRelayServer = null
var _logs: CollabLog = null


func _init() -> void:
	var args: Dictionary = _parse_args(OS.get_cmdline_user_args())
	_logs = CollabLog.new()
	_logs.set_level(CollabLog.Level.INFO)
	if args.has("help"):
		_usage()
		quit(0)
		return
	var port: int = int(args.get("port", CollabConstants.DEFAULT_RELAY_PORT))
	var max_clients: int = int(args.get("max-clients", CollabRelayServer.DEFAULT_MAX_CLIENTS))
	var bind_address: String = str(args.get("bind", "*"))
	var projects_dir: String = str(args.get("projects-dir", _default_projects_dir()))
	var password: String = OS.get_environment("GODOT_COLLAB_RELAY_PASSWORD")

	_server = CollabRelayServer.new(_logs)
	var err: Error = _server.start(port, max_clients, bind_address, projects_dir, password)
	if err != OK:
		printerr("Relay failed to start on UDP %d: %s" % [port, error_string(err)])
		quit(1)
		return
	if projects_dir.is_empty():
		_logs.info("Relay mirroring disabled.")
	else:
		_logs.info("Relay mirroring live projects into %s." % ProjectSettings.globalize_path(projects_dir))
	_logs.info("Godot Collab relay running. Press Ctrl+C to stop.")


func _process(_delta: float) -> bool:
	if _server != null:
		_server.poll()
	return false


func _finalize() -> void:
	if _server != null:
		_server.stop()


func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out: Dictionary = {}
	var i: int = 0
	while i < argv.size():
		var arg: String = argv[i]
		if arg == "--port" and i + 1 < argv.size():
			out["port"] = argv[i + 1].to_int()
			i += 2
			continue
		if arg == "--max-clients" and i + 1 < argv.size():
			out["max-clients"] = argv[i + 1].to_int()
			i += 2
			continue
		if arg == "--bind" and i + 1 < argv.size():
			out["bind"] = argv[i + 1]
			i += 2
			continue
		if arg == "--projects-dir" and i + 1 < argv.size():
			out["projects-dir"] = argv[i + 1]
			i += 2
			continue
		if arg == "--help" or arg == "-h":
			out["help"] = true
		i += 1
	return out


func _usage() -> void:
	print("Usage: godot --headless --script tools/relay_server/relay_server.gd -- [options]")
	print("  --port <n>         UDP port to listen on (default %d)" % CollabConstants.DEFAULT_RELAY_PORT)
	print("  --max-clients <n>  Maximum simultaneous ENet clients (default %d)" % CollabRelayServer.DEFAULT_MAX_CLIENTS)
	print("  --bind <address>   Bind address (default * = all interfaces)")
	print("  --projects-dir <d> Directory for host project mirrors (default %s)" % _default_projects_dir())
	print("                     Pass \"\" to disable mirroring.")
	print("  --help             Show this help")
	print("")
	print("Environment:")
	print("  GODOT_COLLAB_RELAY_PASSWORD  Require hosts/clients to supply this password.")


func _default_projects_dir() -> String:
	return ProjectSettings.globalize_path("res://").path_join("tools/relay_server/projects")
