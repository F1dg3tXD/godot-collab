# Known limitations

This add-on intentionally implements a bounded, host-authoritative subset of
collaboration. The following are **not** implemented or not yet verified. They
are listed explicitly so nothing here is mistaken for working functionality.

## Verification status

- The headless test suite (`addons/godot_collab/tests/run_tests.gd`) covers the
  protocol framing/validation (including the workspace message types with text and
  **byte** payloads), invitation codes, path guard, rate limiter, value
  encode/decode for the general property set (including **slash sub-property
  names**, **null object properties**, and an **embedded-resource round-trip**),
  **inline-resource safety** (script/packed-scene/oversized payloads refused),
  **settings defaults**, file-sync path predicates + baseline scanning
  (including `addons/` exclusion and **open-scene protection**), node-id
  reconciliation, **pending-resource queueing/resolution**, an ENet loopback
  handshake/cursor/disconnect flow, a two-scene loopback
  snapshot/host<->peer edit-propagation flow, a **general inspector-property**
  host<->peer flow (including an **inline `material_override`** host→client, an
  **in-place edit of that embedded material**, and an **in-place edit of a nested
  `BoxShape3D` sub-resource** on a `CollisionShape3D`), a **workspace
  rename/delete** loopback flow, a **rejoin-desync** flow (stale client scene +
  reconnect), a **multi-scene isolation** flow (host focused on scene B while
  a client edits scene A), and a **relay** flow (a `CollabRelayServer` plus a
  relay host and relay client in one process: registration, HELLO routing, cursor
  relay, token rejection, host departure), plus a **workspace join-time
  catch-up** flow (`FILE_SYNC_MANIFEST`) and a **relay project mirror** flow
  (relay pulls the host project into `live_<project>/` and replays it to a
  later-joining client), plus a **relay workspace sync** flow (join-time
  catch-up and live file adds in both directions through a relay), plus
  **file-sync eligibility** (unknown/absent extensions and `*.import` excluded,
  `*.uid` and editor-recognised types kept) and **project-settings sync**
  (allow-list, object-free input-event encoding, packet round trip, applying to
  `ProjectSettings`, dangling `res://` references and renderer keys skipped). It
  passes (see [`TESTING.md`](TESTING.md)).
- The interactive editor behaviours (dock UI, top-toolbar buttons, remote cursor
  drawing, `_forward_3d_gui_input` and the 2D viewport poll, scene
  editing, **Ctrl+S shared save**, project download, approval prompts) require
  **two interactive Godot editor instances** and have a documented manual
  procedure but are **not** asserted by an automated GUI test. In particular the
  toolbar placement and the `scene_saved` interception are only parse/runtime
  smoke-tested headless, not visually verified.
- Testing so far is on **Linux**. Windows and macOS are untested.

## Networking and connectivity

- **No encryption.** ENet over UDP is not encrypted and the invite token is a
  shared bearer secret, not an authenticated identity. Do not treat a session as
  confidential or as strong authentication. This applies to the relay path too.
- **Relay support is present but only loopback-tested.** `tools/relay_server/`
  forwards traffic between a host and its clients so sessions work behind NAT /
  CGNAT / restrictive firewalls with no port forwarding, and the relay path is
  covered by in-process loopback tests (registration, HELLO routing, cursor
  relay, token rejection, host departure). It has **not** been exercised across a
  real internet relay or a real NAT. Relay mode is the **default** hosting path;
  if no relay address is configured the host falls back to a direct session with a
  warning, and direct LAN hosting is still available (uncheck *Use a relay server*).
- **Relay passwords are optional and coarse-grained.** Setting
  `GODOT_COLLAB_RELAY_PASSWORD` on the relay requires every host and client to
  enter the same password in the dock; the check is enforced only at `REGISTER`,
  over plaintext ENet/UDP (so it is anti-abuse, not confidentiality), and there is
  no per-user identity, rotation, or audit trail. The password is never stored in
  `EditorSettings` or embedded in invitation codes, so it must be shared
  separately and re-entered after an editor restart. Protected relays use relay
  protocol v2; peers running an older build cannot register.
- The relay password is checked when a peer registers. A peer that already
  registered before the operator changed the password keeps its room until it
  disconnects; changing the password requires restarting the relay.
- The **relay project mirror** (opt-in via `--projects-dir`) is host-authoritative
  and loopback-tested only. Files above `MAX_WORKSPACE_FILE_BYTES` (2 MiB) and
  content beyond `MAX_MIRROR_FILES` (20000) / the pull caps are not mirrored;
  the mirror is a convenience cache for late joiners, not a backup or the
  authoritative project copy. Nothing is ever mirrored back onto the host.
- The relay mirror stores `project.godot` only from its initial project pull;
  later **project-setting changes are not written into the mirror** (they are
  still applied live to connected clients). A client that joins after a
  settings change and relies on the mirror gets the older configuration.
- **`relayctl.sh` is a convenience wrapper**, not a service manager: it does not
  install a supervisor, restart on crash, or survive a reboot. Use systemd, a
  process supervisor, or the Docker image for unattended deployments.
  In Docker the mirror directory must be **bind-mounted**; without it the
  image's `VOLUME` declaration creates an anonymous volume, so the mirrored
  projects are invisible on the host and are lost when the container is
  recreated (`docker-compose.yml` bind-mounts it by default). The relay logs
  the resolved mirror directory on startup.
- **After a relay or direct connection is established, there is no relay
  fallback.** If the relay process stops or the host leaves, clients are
  disconnected; there is no automatic reconnection or migration.
- **UPnP is best-effort** and may silently fail on many routers. Failures are
  reported in the dock; manual port forwarding is the fallback.
- The rendezvous service maps short codes to endpoints (direct **or** relay
  rooms); it is **not** an ENet relay and does not carry session traffic. It runs
  as part of the relay Docker image but is a separate plain-HTTP service on
  `9080/tcp`; short codes only work when that port is reachable (or fronted by
  HTTPS). When short-code registration fails, the host falls back to the long
  `gc2.…` invitation, which still works.
- The long relay invitation embeds the rendezvous URL so a client that pastes it
  auto-configures the service; this is stored in editor settings and is a
  convenience, not a trust decision.
- Short code lookup, direct connection and the relay have only been exercised in
  local and loopback-style testing, not across real NATs between two networks.

## Scene collaboration

- Synchronized edits:
  - Node creation for supported node types.
  - Node removal, rename, reparent.
  - `Node3D` position/rotation/scale.
  - **Every syncable/storable property** the Inspector exposes, driven by
    `get_property_list()` (`CollabSceneOperations.collect_syncable_props`). This
    is not a fixed whitelist: bool, int, float, String, `StringName`,
    `Vector2(i)`, `Vector3(i)`, `Color`, `Rect2(i)`, `Transform2D/3D`, `Basis`,
    `Quaternion`, `Plane`, `AABB`, `Projection`, `NodePath`, arrays, packed
    arrays, dictionaries, and `Resource`/`Object` references, within
    depth/element caps.
  - **Slash sub-properties** such as `surface_material_override/0` and
    `theme_override_colors/font_color` are synced.
  - **Resource references.** A file-backed resource is sent as its validated
    `res://` path. A **path-less/embedded** resource (a material created in the
    Inspector, a texture dragged from the filesystem) is serialized inline (capped
    at 64 KiB) and rebuilt on the receiver. Inline payloads carrying
    executable/referenced content (scripts, packed scenes) are refused, and an
    unresolvable **path-backed** resource is queued and retried (up to 20 s)
    rather than clearing the property.
  - **In-place / nested resource edits** (a material's colour, a `BoxShape3D`'s
    size, an `Environment`'s mode, including sub-resources owned by a node) are
    detected by re-serializing embedded resources on a slower cadence (1.5 s),
    because most resource types do **not** emit `changed` for ordinary property
    edits. A consequence: an embedded-resource edit can take up to ~1.5 s to
    appear on the other peer, and two edits to the same embedded resource that
    both complete within one 1.5 s window may collapse into the final value.
  - Reserved properties are excluded from the generic property path because they
    have dedicated handling: `name`, `owner`, `transform`, `global_transform`,
    and `script`.
- **Not synchronized:** arbitrary *live script text about to be reloaded*, import
  settings, project settings, animation editors, shaders, particle/tilemap/
  material sub-editors, and custom inspectors that render to a texture. Editing
  a **source file** on disk is synchronized by the file-sync watcher (see
  below), but a script change does not hot-reload a running editor session.
- Resource references are carried as validated resource paths or inline-serialized
  embedded resources; not every resource kind is handled, and an embedded
  resource larger than 64 KiB cannot be sent inline (use a saved `res://` file).
- Container values (arrays/dictionaries) are bounded by
  `MAX_CONTAINER_ELEMENTS` (4096) and `MAX_CONTAINER_DEPTH` (6); values holding
  live `Object`s that cannot be represented as a path are refused rather than
  silently lossy.
- Stable node identity is **host-authoritative**: only the host allocates the
  positive id space. Every non-host (including an editor that has not joined yet)
  uses non-authoritative negative ids, so a client op can never resolve to a
  *different* node that merely shares a number. On join the client requests a
  snapshot and reconciles its node ids to the host's by path
  (`CollabSceneSyncService.reconcile_ids_from_snapshot`), which is what prevents
  the "toggle hit the wrong node after a crash/rejoin" desync.
- The diff watcher is bounded and best-effort. Very rapid edits or unsupported
  panels may produce changes that are not detected until the next scan or a
  resynchronization.
- Joining a host-workspace session **mirrors the host scene**: the host sends a
  snapshot and the peer applies it automatically (unless
  `collaboration/auto_apply_snapshot` is turned off). This replaces the peer's
  local scene children with the host's, so unsaved local edits made before
  joining are discarded by design.
- A snapshot is sent as a single packet and is capped at
  `CollabConstants.MAX_PACKET_PAYLOAD` (4 MiB). A scene whose serialized
  snapshot exceeds that cannot be sent and is reported as an error; snapshots
  are not chunked across packets.
- Node scripts are shared as `res://` paths. The script must exist at the same
  path on each peer; otherwise the node is created without its script.
- Conflict handling is deterministic (host order + revision) but is not a full
  CRDT/operational-transform system.
- Revisions are tracked **per scene**. A peer and the host can be working on
  different open scenes simultaneously; operations are routed by scene path.
- Host-side persistence of remote edits rewrites the scene file on the host
  (after a debounce, for scenes the host is not focused on, or when the host uses
  *Save shared scene*). The editor's open tab is not force-reloaded; the on-disk
  and in-memory copies are kept in sync because the same root was edited.
- A detached host context is a plain model loaded from disk. It has no editor
  environment, so editor-only side effects (for example `@tool` `_ready` logic
  that expects the edited scene) do not run for it.

## Presence and cursors

- A remote 3D cursor is a configurable point on the remote user's camera ray. It
  is **not** guaranteed to lie on the exact surface under the remote pointer
  (no guaranteed surface picking).
- Cursors for users viewing a different scene or outside the local view may be
  hidden. A peer editing in the 2D view is represented by a 2D canvas cursor and
  no 3D body; the reverse also holds.
- The live 3D markers (`CollabMarkerManager` / `assets/editorNodeVis.tscn`) are
  only shown while a session is active and the editor has a 3D viewport. If the
  editor is opened in a layout without a 3D viewport the markers are skipped.
  Markers follow the same configurable ray depth as the 2D cursors and are not
  surface-picked.
- The cursor animation (`grab`, `idle_hover`, `grab_file_*`) is inferred
  heuristically from the local input: which mouse buttons are held and whether
  the editor reports an active drag-and-drop payload of a recognised kind.
  Surface/object "hover" (as opposed to recent motion) is not detected, and a
  drag started from an editor panel that does not expose its payload is shown as
  a plain `grab`.
- 2D cursors are only produced while the editor's 2D view is the visible main
  screen: the add-on polls that viewport each frame (regular add-ons do not
  receive canvas input forwarding), so when the 3D/Script screens are active the
  last 2D position simply goes stale. The rendered cursor is a scene node in the
  2D view's canvas space; a peer whose view is scrolled far away may see it
  off-screen until they pan. Cursor sprites are cosmetic and never surface-picked.

## Saving

- The explicit **Save shared scene** action first persists every scene with
  unpersisted remote edits, then saves the **currently active** edited scene via
  `EditorInterface.save_scene()`. Scenes with no remote edits and no local
  changes are not force-saved.
- Remote edits to a scene the host is not focused on are written back after a
  short debounce (1.2 s) so they survive even if the host never clicks save.
  This is a file write to the host's own scene path, not a transactional save.
- Auto-save is optional and time-based (after an inactivity period), not a
  robust transactional save.
- **Ctrl+S** inside a host-workspace session is promoted to a full shared save on
  the host (persist every scene with remote edits, then save the active scene) and
  on a client is forwarded as a save request. Git presence mode ignores it, so
  Ctrl+S stays purely local there. This is only smoke-tested headless, not
  asserted by an automated GUI test.

## Workspace authoring (new scenes / added files)

- Only files with an allowed extension (`WRITABLE_EXTENSIONS`) are accepted, up to
  `MAX_WORKSPACE_FILE_BYTES` (2 MiB). A request may carry UTF-8 text or raw bytes,
  so a binary asset dropped into the Filesystem dock is included. Larger files
  must use project transfer.
- New scenes are limited to the root classes in `SCENE_ROOT_CLASSES`
  (`Node`, `Node2D`, `Node3D`, `Control`, `CanvasLayer`) and are created empty.
- Transferred files are written to disk but are **never executed or imported** by
  the add-on; the editor may scan them like any project file.
- **File rename/delete** is propagated as add-then-delete (there is no dedicated
  rename op). A renamed file is delivered to its new path and the old path is
  removed, so peers converge rather than accumulating duplicates. Because the
  removal is host-authoritative, a file deleted on a client is deleted on the
  host and every peer.
- `.import` sidecars are deliberately **not** synced (an import-churn loop
  between editors was observed). A renamed imported asset (image/model/audio) may
  therefore re-import with a fresh UID on a peer; path-based references still
  resolve, but UID-based references to the renamed asset may not.
- The scene list is a directory scan of `res://` and is capped at
  `MAX_SCENE_LIST` (2048) entries; generated/hidden folders are skipped.
- Workspace authoring is disabled in Git presence mode and can be turned off with
  `godot_collab/collaboration/allow_workspace_authoring`.

## Source file sync (host-authoritative)

- When enabled (`godot_collab/collaboration/sync_source_files`, default on) the
  host and clients watch project files and relay changed contents to the host,
  which applies and re-broadcasts them. Eligibility follows what the **editor can
  represent**: recognised resource/import/text extensions plus `.uid` sidecars,
  with generated/vendor directories (`.godot/`, `.git/`, `.vscode/`, `.idea/`,
  `.import/`, `android/`), **`addons/`**, `project.godot`, `*.import` metadata,
  and temporary junk (`.tmp`, `.swp`, `.swo`, `.part`, `.crdownload`) excluded.
  Excluded directories are matched per path segment.
- **Files the editor does not list are not synced**: extension-less files
  (`LICENSE`, `README`), unknown extensions, and `*.import` metadata (which is
  machine-local and regenerated on import) stay local. Keeping `project.godot`
  out of the file stream is deliberate: it is editor state, not content, and is
  synced separately (see below).
- Per-file content is capped at `MAX_WORKSPACE_FILE_BYTES` (2 MiB); larger files
  must use the full project download.
- **Join-time catch-up is bounded.** On admit, the host sends a file manifest and
  pushes its own files (256 files / 64 MiB caps, per-file 2 MiB); the client
  uploads only files the host lacks (same caps). Projects beyond those caps need
  the full project-download path to converge fully. Conflict rule: host wins per
  file; a client's file is uploaded only when the host does not have that path.
- Scene files (`.tscn`/`.scn`/`.escn`) that are **open in the editor** are
  protected on receivers: they go through the structured scene-operation stream,
  so an incoming `FILE_APPLY` never overwrites them underneath the editor. On the
  host, a *saved* open scene is relayed raw so peers without it open — and the
  relay's server-side mirror — see the scene content. A scene file that is
  dropped but not open travels as an ordinary file.
- Written to disk only; never imported or executed by the add-on, and only
  inside the approved project root.
- **Generated/cache data is excluded:** `.godot/`, `.git/`, and, critically,
  **`addons/`**. See the warning below.
- Bounded: `FILESYNC_MAX_FILES` (8000) tracked files, per-file size capped by
  `MAX_WORKSPACE_FILE_BYTES`, scan interval `FILESYNC_INTERVAL_MS` (1200 ms).
  Very large projects or rapid save storms may lag behind the scan interval.
- File sync does **not** hot-reload a running editor. A received `.gd`/`.tres`
  takes effect when the editor recompiles/reloads it, not instantly on arrival.

### Project settings (editor state)

- `project.godot` is never transferred as a file. The host sends an allow-listed
  subset of `ProjectSettings` (`application/config/*` basics, main scene, window
  size/stretch, physics gravity, default audio bus, translations, plus the
  `autoload/`, `global_group/`, `input/` and `layer_names/` groups) as the
  `PROJECT_SETTINGS` message on join and whenever it changes.
- Clients apply it **in memory only**; their `project.godot` on disk is not
  rewritten. A setting they had changed locally is overridden by the host's value
  while the session is live.
- Settings that reference a `res://` path the client does not have yet are
  skipped rather than applied to a dangling path.
- `rendering/*` and `application/config/features` are intentionally **not**
  synced, so a client is not forced onto the host's renderer.
- Editor subsystems that read settings only at startup (renderer selection,
  some feature tags) will not reflect an applied change until the editor
  restarts; the Project Settings dock may also need to be reopened to repaint
  new values. Changes are not saved to disk by the add-on.

### Warning: do not edit the add-on's own files during a live session

- Editing anything under `addons/` while a session is live is **forbidden**.
  The add-on's scripts are executing inside the editor; changing them live can
  crash the local editor and, because a large transfer can also be relayed to
  other participants, crash their clients and corrupt their project copies.
- The guard is twofold: `addons/` is excluded from `EXCLUDED_PREFIXES` (file
  authoring) and `FILESYNC_EXCLUDED_PREFIXES` (file sync), and the dock shows a
  warning when a session starts. The exclusion is the enforced part; treat the
  warning as the rule.

## Project download

- A **complete snapshot** download is the supported path. Partial/on-demand file
  streaming is **not** implemented.
- Generated import/cache data (`.godot/`) is excluded. `.git/` is excluded from
  ordinary workspace downloads.
- After download the user opens the copied project in a new editor instance; the
  add-on does not hot-swap the current project.
- Downloads respect per-file and total size limits; larger projects must raise
  the limits or exclude files.

## Git presence mode

- Presence + cursors only. Local files are never overwritten.
- Uncommitted changes do **not** travel between machines through the add-on or
  through Git. Normal Git operations remain responsible for distributing and
  merging commits.
- Presence-only mode is independent of host-workspace mode; the two do not
  interconvert automatically.

## Scale and lifecycle

- The primary target is **two people**. More peers are allowed up to the
  configured maximum, but behaviour at higher counts is not load-tested.
- The add-on tracks connected peer ids manually because this engine build's
  `MultiplayerPeer` exposes no peer enumeration; this is correct but means peer
  state is derived from signals rather than queried from the peer.
