## Pure three-way merge planner for project files.
##
## Given a base manifest and the host/client manifests (path -> sha256), it
## returns a list of decisions without touching the filesystem or the network.
## Each decision is a Dictionary:
##   { "path": String, "action": String, "reason": String }
## Actions: "keep", "take_host", "take_client", "delete", "conflict".
class_name CollabMergePlanner
extends RefCounted


static func plan(base: Dictionary, host: Dictionary, client: Dictionary) -> Array:
	var decisions: Array = []
	var paths: Array = []
	for p in base.keys():
		if not paths.has(p):
			paths.append(p)
	for p in host.keys():
		if not paths.has(p):
			paths.append(p)
	for p in client.keys():
		if not paths.has(p):
			paths.append(p)
	paths.sort()
	for path in paths:
		var in_base: bool = base.has(path)
		var in_host: bool = host.has(path)
		var in_client: bool = client.has(path)
		var base_hash: String = str(base.get(path, ""))
		var host_hash: String = str(host.get(path, ""))
		var client_hash: String = str(client.get(path, ""))
		var host_changed: bool = in_base and in_host and host_hash != base_hash
		var client_changed: bool = in_base and in_client and client_hash != base_hash
		var host_deleted: bool = in_base and not in_host
		var client_deleted: bool = in_base and not in_client
		var decision: Dictionary = {"path": path}
		if in_base:
			if host_deleted and client_deleted:
				decision["action"] = "delete"
				decision["reason"] = "deleted on both sides"
			elif host_deleted and client_changed:
				decision["action"] = "conflict"
				decision["reason"] = "host deleted, client modified"
			elif client_deleted and host_changed:
				decision["action"] = "conflict"
				decision["reason"] = "client deleted, host modified"
			elif not in_host or not in_client:
				decision["action"] = "conflict"
				decision["reason"] = "missing on one side"
			elif host_hash == client_hash:
				decision["action"] = "keep"
				decision["reason"] = "both sides agree"
			elif not host_changed and client_changed:
				decision["action"] = "take_client"
				decision["reason"] = "only client changed"
			elif host_changed and not client_changed:
				decision["action"] = "take_host"
				decision["reason"] = "only host changed"
			else:
				decision["action"] = "conflict"
				decision["reason"] = "both sides changed differently"
		else:
			if in_host and in_client:
				if host_hash == client_hash:
					decision["action"] = "keep"
					decision["reason"] = "both sides added identically"
				else:
					decision["action"] = "conflict"
					decision["reason"] = "both sides added differently"
			elif in_host:
				decision["action"] = "take_host"
				decision["reason"] = "added by host only"
			elif in_client:
				decision["action"] = "take_client"
				decision["reason"] = "added by client only"
			else:
				decision["action"] = "keep"
				decision["reason"] = "absent on all sides"
		decisions.append(decision)
	return decisions


static func conflicts(decisions: Array) -> Array:
	var out: Array = []
	for d in decisions:
		if str(d.get("action", "")) == "conflict":
			out.append(d)
	return out
