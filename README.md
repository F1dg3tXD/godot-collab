# Godot Collab

Roblox Studio-style multiplayer collaboration for the **Godot 4.7.2 editor**.

Godot Collab is a real editor add-on (an `EditorPlugin`), not a game project that
imitates the editor. It adds a dock to the Godot editor, opens an isolated ENet
(UDP) session, shows remote users' 3D cursors in the editor's 3D viewport, and
lets a host own an authoritative shared scene that clients can edit through a
structured, validated operation protocol.

> Status: early but functional. The connection layer, participant presence,
> remote 3D/2D cursors, and the host-authoritative scene-edit protocol are
> implemented. See the
> [Limitations page](https://github.com/F1dg3tXD/godot-collab/wiki/Limitations)
> for exactly what is and is not supported today.

## Features

- **Top-toolbar controls** (Host, Join, **Paste & Join**, Copy Code, Request
  Snapshot, Disconnect) next to the playtest buttons, plus an editor dock with
  username, connection status, generated invitation code, session-code input,
  participant list, collaboration mode, project sync status, and error messages.
  **Paste & Join** reads an invitation code straight from the clipboard and joins
  in one click.
- Isolated ENet/UDP session (host-authoritative). The add-on never touches the
  editor's global `MultiplayerAPI` peer.
- Direct IP:port connections and short invitation codes resolved through an
  optional rendezvous service (`tools/rendezvous_server/`).
- **Dedicated relay server** (`tools/relay_server/`) so two editors can
  collaborate over the internet **without any port forwarding**: the host and
  every client make outbound connections to the relay, which forwards opaque
  packets between them. A relay invitation (`gc2.…`) embeds the relay endpoint,
  a room, the session token, and the rendezvous URL. The relay never interprets
  application payloads; by default it stores nothing, and when started with
  `--projects-dir` it keeps a host-authoritative live mirror of the host project
  (`live_<project>/`) that is replayed to clients that join later. The Docker
  image also bundles the short-code
  rendezvous service so a host can offer a short code instead. See
  [Connectivity and Relay](https://github.com/F1dg3tXD/godot-collab/wiki/Connectivity-and-Relay)
  and [Hosting a Relay](https://github.com/F1dg3tXD/godot-collab/wiki/Hosting-a-Relay).
- Optional UPnP UDP port mapping, with honest connectivity reporting
  (LAN-only vs. externally reachable vs. relay vs. unverified).
- Remote 3D cursors and usernames drawn in the editor viewport, with per-user
  colours, interpolation, rate limiting, and stale-state removal.
- Live 3D `editorNodeVis` markers for each remote participant, so collaborators
  see each other moving in the editor's 3D view in real time.
- Live **2D cursors** in the 2D editor view (`assets/cursor_2d.tscn`): the
  remote pointer is drawn at the same canvas position, follows the scene's
  pan/zoom, and plays the same idle/hover/grab animations. The viewport-polling
  approach is adapted from
  [GodotTogether](https://github.com/Wolfyxon/GodotTogether).
- Host-authoritative scene operations: node create/remove/rename/reparent,
  `Node3D` transform, and the **general Inspector-property set** (derived from
  `get_property_list()`, not a fixed whitelist), including slash sub-properties
  such as `surface_material_override/0` and `theme_override_*`, both host→client
  and client→host.
- **Resource reference sync.** Assigning a resource in the Inspector (a material,
  texture, `Environment`, …) is synced. File-backed resources travel by `res://`
  path; **embedded (path-less) resources** — e.g. a material created inline, or a
  texture dragged straight from the filesystem — are serialised and rebuilt on
  the other side. This also covers **nested node properties**: in-place edits to
  an embedded resource (changing a material's colour, a `BoxShape3D`'s size, an
  `Environment`'s mode) propagate, including sub-resources owned by a node. These
  are caught by periodically re-serialising embedded resources, because most
  Godot resource types do **not** emit `changed` for ordinary property edits.
  Executable payloads (scripts, packed scenes) are refused.
- **Multi-scene collaboration.** Every open scene is tracked independently, so
  collaborators can work in different scenes at once and the host switching tabs
  never reverts anyone's edits. Changes to a scene the host is not viewing are
  applied and persisted on the host.
- **Source-file sync.** Changed scripts, resources, `.uid` sidecars and binary
  assets (images, models, audio, fonts) are relayed to the host and to other
  peers (generated caches and, deliberately, `addons/` are excluded). Files are
  written to disk only, never executed. A scene file that is *open in the editor*
  is protected: it is driven by the operation stream, not by raw file writes.
  Only files the editor can actually load are synced; extension-less files and
  machine-local `*.import` metadata stay local, so peers never see
  broken-import markers in the Filesystem dock.
- **Project settings are synced as editor state.** The host's application
  config, autoloads, input map, physics/layer names and similar settings are
  pushed to clients over the wire; `project.godot` itself is never copied over
  a peer's copy.
- **Workspace authoring.** Collaborators can ask the host to create a new scene
  or add a project file — including by dropping a binary asset into the
  Filesystem dock; the host validates it (path/size/extension) and distributes a
  local copy to every peer. File **renames and deletions** are propagated too: a
  renamed file is delivered to its new path and the old path is removed, so
  participants do not end up with duplicate or stale files.
- **Ctrl+S just works.** In a host-workspace session, pressing Ctrl+S is promoted
  to a full *shared* save: the host persists every scene that received remote
  edits and notifies all peers. A client's Ctrl+S is forwarded to the host. This
  is on top of the explicit **Save Shared Scene** button.
- **Rejoin-safe node identity.** Node ids are host-authoritative only; a client
  that restarts onto a stale scene reconciles its ids to the host's on join, so
  its edits can never hit the wrong node.
- Explicit **Save Shared Scene** (persists remote edits, then saves the focused
  scene) and optional auto-save on the host.
- Host-owned project snapshot download (chunked, checksummed, path-safe) that
  builds a local project copy.
- **Git presence mode**: presence + cursors only, for users who already share a
  Git repository and keep their own checkouts.

## Requirements

- Godot **4.7.2** stable.
- GDScript only. No native extensions, no C#, no custom engine build, no
  third-party dependencies.
- Python 3 (standard library only) only if you want to run the optional
  rendezvous service.

## Installation

Full setup instructions are on the
[Getting Started](https://github.com/F1dg3tXD/godot-collab/wiki/Getting-Started)
page.

1. Copy `addons/godot_collab/` into your Godot project's `addons/` directory.
2. Open the project in Godot 4.7.2.
3. `Project > Project Settings > Plugins`, then enable **Godot Collab**.
4. A **Godot Collab** dock appears (left, upper-right slot).

To remove it, disable the plugin. It tears down its nodes, timers, network
peers, and UPnP mapping.

## Quick start (two editors on one machine)

See [Getting Started](https://github.com/F1dg3tXD/godot-collab/wiki/Getting-Started)
for the full walkthrough, and
[Invitation Codes](https://github.com/F1dg3tXD/godot-collab/wiki/Invitation-Codes)
for what the codes contain.

1. In editor **A**: open the dock, set a username, click **Host** in the top
   toolbar. Copy the invitation code from the dock (**Copy Code** in the toolbar).
2. In editor **B**: set a username, then click **Paste & Join** in the top
   toolbar (or paste the code into the dock's session-code field and click
   **Join**). The dock reports "Waiting for host approval" if approval is on.
3. Both docks now list two participants with host/client roles. (Host approval is
   off by default for easy LAN use; enable *Require host approval* in the dock on
   untrusted networks, and the host will then confirm each join.)
4. Move the mouse over editor **A**'s 3D viewport; a coloured cursor and username
   appear in editor **B**'s viewport (and vice-versa).
5. With a scene open on both sides, edit a `Node3D` transform (via the Inspector
   or the 3D gizmo) or any other Inspector property. The change is applied to the
   host's scene and broadcast; client edits reach the host too. Changes to source
   files (scripts, resources) are relayed as well, and project settings changes
   reach the client's editor — but never edit files under `addons/` while a
   session is live.

For internet use, relay mode is the default (see the next section). For direct
LAN hosting, uncheck **Use a relay server** and use the host's LAN IP in a direct
invitation; the rendezvous service, UPnP, and manual port forwarding are optional
refinements. See the
[Testing page](https://github.com/F1dg3tXD/godot-collab/wiki/Testing) for the
reproducible two-editor checks.

### Collaborating over the internet without port forwarding

Relay mode is the default hosting path: the host and every client connect
*outbound* to a relay server, so no port forwarding is needed (works behind
CGNAT and restrictive firewalls). Run the relay from a machine that both sides
can reach:

```
GODOT=/path/to/godot tools/relay_server/run.sh --port 45900
```

For an unattended deployment, `relayctl.sh` starts the relay, the rendezvous
service, and the project mirror together, with PID files and logs:

```
GODOT=/path/to/godot tools/relay_server/relayctl.sh start \
  --port 45900 --rendezvous-port 9080
tools/relay_server/relayctl.sh status     # or restart / stop
```

The wrapper imports the project once (to build the GDScript class cache a fresh
checkout lacks) and then starts the relay. A Docker image is also provided; it
runs the relay (UDP `45900`) **and** the short-code rendezvous (TCP `9080`) in one
container:

```
docker build -f tools/relay_server/Dockerfile -t godot-collab-relay:4.7.2 .
docker run --rm -p 45900:45900/udp -p 9080:9080/tcp godot-collab-relay:4.7.2
```

To keep the relay's optional live project mirror (`live_<project>/`) visible on
the host, bind-mount the mirror directory — without it the image's `VOLUME`
declaration creates an anonymous volume whose contents are invisible outside
the container and are lost when it is recreated:

```
docker run --rm -p 45900:45900/udp -p 9080:9080/tcp \
  -v /srv/collab/projects:/relay/tools/relay_server/projects \
  godot-collab-relay:4.7.2
```

`tools/relay_server/docker-compose.yml` does this already (host side
overridable with `COLLAB_MIRROR_DIR`).

Then, in the dock, make sure **Use a relay server** is ticked, enter the relay's
address (`host` or `host:port`), and click **Host**. Share the generated `gc2.…`
invitation code; joining clients decode the relay endpoint, room, and rendezvous
URL from it, so **pasting the long code sets the client up automatically** — after
that, six-character short codes from the same server work with no manual setup.
The relay only forwards bytes — it is not an application server, and it stores
nothing on disk by default (the optional project mirror is described above).

### Requiring a relay password

Relays reachable from the internet can be abused by strangers unless they are
protected. Start the relay with a shared secret in
`GODOT_COLLAB_RELAY_PASSWORD`:

```
GODOT_COLLAB_RELAY_PASSWORD='choose-a-secret' \
  GODOT=/path/to/godot tools/relay_server/run.sh --port 45900
```

(The same environment variable works with `relayctl.sh`, and with Docker via
`docker run -e GODOT_COLLAB_RELAY_PASSWORD=...` or the Compose file.) Every host
and every client must then type that password into the dock's **relay password**
field; the relay rejects registrations with a missing or wrong password before a
room is created. The password is kept in memory only, is never written to
`EditorSettings`, and is **not** embedded in invitation codes — share it
separately. Without the variable the relay stays open, as before. Password
checking uses the relay protocol v2, so relay hosts and clients must all run this
version of the add-on.

## Documentation

The [project wiki](https://github.com/F1dg3tXD/godot-collab/wiki) is the
documentation home:

- [Getting Started](https://github.com/F1dg3tXD/godot-collab/wiki/Getting-Started)
  — install, host/join, workspace modes.
- [Invitation Codes](https://github.com/F1dg3tXD/godot-collab/wiki/Invitation-Codes)
  — `gc1`/`gc2`/short codes, expiry, safety.
- [Scene and File Collaboration](https://github.com/F1dg3tXD/godot-collab/wiki/Scene-and-File-Collaboration)
  — editing, conflicts, saving, file sync, download, Git presence.
- [Connectivity and Relay](https://github.com/F1dg3tXD/godot-collab/wiki/Connectivity-and-Relay)
  — direct, short codes, relay, passwords.
- [Hosting a Relay](https://github.com/F1dg3tXD/godot-collab/wiki/Hosting-a-Relay)
  — deployment, Docker, systemd, mirror, TLS and upgrades.
- [Settings Reference](https://github.com/F1dg3tXD/godot-collab/wiki/Settings-Reference)
  — every `godot_collab/*` Editor Setting and its default.
- [Architecture](https://github.com/F1dg3tXD/godot-collab/wiki/Architecture)
  — components, protocol, data flow, caps, conflict policy.
- [Security](https://github.com/F1dg3tXD/godot-collab/wiki/Security) — threat
  model, protections, safe configuration.
- [Testing](https://github.com/F1dg3tXD/godot-collab/wiki/Testing) — headless
  suite, relay smoke tests, two-editor manual checks.
- [Troubleshooting](https://github.com/F1dg3tXD/godot-collab/wiki/Troubleshooting)
  — common problems and fixes.
- [Limitations](https://github.com/F1dg3tXD/godot-collab/wiki/Limitations) — what
  is not implemented or verified.
- [Contributing](https://github.com/F1dg3tXD/godot-collab/wiki/Contributing) —
  repository conventions and verification commands.
- [FAQ](https://github.com/F1dg3tXD/godot-collab/wiki/FAQ) — short answers to
  common questions.
- [`tools/rendezvous_server/`](tools/rendezvous_server/) — optional short-code
  lookup service.
- [`tools/relay_server/`](tools/relay_server/) — dedicated relay server (headless
  Godot, with a Docker image) for internet sessions without port forwarding; the
  image also bundles the rendezvous service for short codes.

## Repository layout

```
addons/godot_collab/
  plugin.cfg, plugin.gd        EditorPlugin entry point + wiring
  core/                        constants, settings, logging, identity
  network/                     wire protocol, ENet session manager, relay protocol/server, participants
  session/                     session coordinator, invite codes, rendezvous, UPnP, connectivity
  presence/                    cursor sampling/state, live 3D markers, live 2D cursors
  collaboration/               per-scene sync contexts, scene ops, node-id mapping, diff watcher, save, workspace authoring + source-file sync
  project_transfer/            project manifest + chunked transfer manager
  security/                    path validation + rate limiting
  ui/                          editor dock + top-toolbar controls
  tests/                       headless test harness
tests/minimal_project/         minimal 3D project for two-editor tests
tools/rendezvous_server/       optional rendezvous service (Python stdlib)
tools/relay_server/            relay + bundled rendezvous (headless Godot + Dockerfile/compose)
```

## License

MIT. See [`LICENSE`](LICENSE).
