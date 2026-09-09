# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **A guest picker inside consoles (File ▸ Show Guests, ⌘L).** Switching machines
  no longer means going back to the connect tab: a panel slides in from the left
  with every guest across every signed-in server, filterable by name, VMID, node
  or server, and closes as soon as one is picked. Stopped guests are listed but
  not selectable — there is no console to open, and starting one belongs in the
  tab. Hovering the very left edge reveals it too, but that target is four points
  wide on purpose; over a live guest, a broader one would fire while working.
  The connect tab stays the place a fleet is set up.
- **A per-guest action bar (File ▸ Show Guest Actions, ⇧⌘L).** Power actions and
  the CD-ROM for the guest in the current console, in a strip at the top.
- **ISO attach and eject**, with the two privileges checked before the controls
  are offered. Neither `VM.Config.CDROM` (attaching) nor `Datastore.Audit`
  (listing images) is part of `PVEVMUser`, and both fail quietly: without the
  former, everything else works right up to the write; without the latter Proxmox
  returns an *empty storage list rather than a 403*, so "no images found" would be
  a lie. SpiceMac disables the control and names the missing privilege instead.

- **Connect to Proxmox natively (File ▸ Connect to Proxmox…, ⌘N).** Sign in to a
  node with an API token (or username/password) and pick a VM from a searchable
  list — no more downloading a `.vv` from the web UI for every connection. The
  server and token are remembered (secret in the Keychain, never in
  `UserDefaults`), so launching the app goes straight to the VM list.
- **Reconnect.** Because the app can now mint tickets itself, a dropped Proxmox
  session offers a **Reconnect** button instead of the previous
  "open a fresh `.vv` file" dead end. Ticket lifetime made this impossible before:
  a SPICE ticket is single-use and expires in ~30 seconds.
- **Trust-on-first-use TLS pinning.** Proxmox's self-signed certificate is shown
  once as a SHA-256 fingerprint to confirm against Datacenter ▸ Certificates, then
  pinned; a later certificate change is surfaced as a warning rather than accepted
  silently. Preferred over a blanket "allow insecure" switch, which would accept
  any certificate forever.
- **Tabbed consoles.** Sessions and the connect window share one macOS tab group
  instead of scattering windows: ⌘⇧[ / ⌘⇧] to move between them, drag a tab out to
  give a console its own window, drag it back to rejoin. Because tabs share a frame,
  a tabbed console takes its resolution from the window and every guest in the group
  is asked to match — so switching tabs triggers no mode switch. Standalone windows
  keep sizing themselves to their guest.
- **Guest power management.** Start, Shut Down, Restart, Force Stop, Force Reset,
  Suspend and Resume from the guest list's context menu or the Power menu, so
  routine power cycling no longer means opening the Proxmox web UI. Actions that
  don't apply to a guest's current state are disabled rather than hidden, the two
  that cut power without telling the guest OS confirm first, and the resulting
  Proxmox task is followed to completion before the list is re-read. Opening the
  console on a stopped guest offers to start it and connect once it is up.
  Requires `VM.PowerMgmt` on the token (included in `PVEVMUser`).
- **Send files to the guest.** Drag files onto the session window, or use File ▸ Send
  Files to Guest… (⇧⌘S) / Send Files from Clipboard, with progress and cancel. Wraps
  `spice_main_channel_file_copy_async` in a new `CSSession (FileTransfer)` category.
  ⌘V is deliberately left unbound so paste still reaches the guest.
- **WebDAV shared folder (File ▸ Choose Shared Folder…).** Offers a host folder to
  the guest as a network drive, which is the only way to move files guest → host:
  the SPICE agent's file transfer is client → guest only, with no counterpart in the
  protocol. Read-only by default; the choice is stored as a security-scoped bookmark
  and applies from the next connection. This enables the sharing support that was
  present but deliberately switched off pending a UI for choosing the directory.
- **Several Proxmox servers at once (File ▸ Manage Servers…).** SpiceMac is no
  longer a one-server-at-a-time client: configure as many Proxmox servers as you
  like — each with its own nickname, credentials and Keychain item — and every
  guest across all of them appears in a single searchable tree, grouped under the
  server it belongs to. Sign-in happens concurrently and independently per server,
  so a site that is down reports on its own row and the rest of the fleet still
  works; it is no longer a modal failure over the whole app. Anything that blocks
  on a person — the certificate dialog, Keychain access, being asked for a secret
  — is serialised through one queue, so ten servers cannot stack ten dialogs at
  launch. Right-click a server row for Sign In, Sign Out and Refresh.
- **Manage Servers.** A sheet with the server list on the left and the credential
  form on the right: add, remove, rename, and switch between API-token and
  password auth per server. Renaming a server’s host or token moves its Keychain
  item with it, removing one deletes its secret and forgets its pinned
  certificate, and Cancel touches neither the Keychain nor the stored fleet.
- **“Remember in Keychain” off now means “ask me each time.”** A server with no
  stored secret is asked for one at sign-in, through the same prompt queue.
- An existing single saved server is migrated into a fleet of one on first launch,
  keeping its Keychain account and its certificate pin, so nothing is re-entered
  or re-approved.
- `Packages/PVEClient` — the Proxmox API binding *and the fleet model*,
  dependency-free and unit-tested via `swift run pvecheck` (84 checks; 143 across
  all four runners).

### Changed

- **The app now opens the Proxmox browser instead of a `.vv` file picker.** A file
  chooser made sense when a `.vv` was the only way in; it is now the fallback, so
  launch shows the guest list (or the sign-in form) and the file route moved to
  File ▸ Open, an Open .vv File… button in the browser, and dropping a file on the
  app. Clicking the Dock icon with no windows open brings the browser back.

- The pasteboard type map no longer claims HTML, RTF, PDF, file-list or URL support.
  Those entries were unreachable — the SPICE clipboard carries only UTF-8 text and
  PNG/BMP/TIFF/JPEG — and implied a fidelity the protocol cannot deliver.
- Credentials moved out of the connect window’s inline form and into Manage
  Servers. The window keeps a form for the first server so a fresh install still
  has somewhere obvious to type; every other server is edited in the sheet.

### Fixed

- **The connect panel no longer collapses to a sliver on sign-in.** Hiding the
  credentials rows left the grid with no width, and its required width tie dragged
  the whole panel down with it — filter field and guest tree included. It only
  showed once a console had grown the tab group, which made it look like a width
  problem it was not.

- **A blocked network fails in seconds instead of three silent minutes.** An
  unreachable path was parked for the full resource timeout and then reported as
  "Timed out". The wait for a network path is now bounded separately from the wait
  at the certificate prompt — the one that legitimately involves a person — so a
  path that is not coming gives up quickly and names the host.

- **A failed sign-in no longer caches its client**, so Refresh asks for
  credentials again rather than retrying the ones just rejected.

- **Two automatic sign-ins for the same server no longer race**, each minting a
  client. A deliberate Sign In still always goes through.

- **Proxmox errors read properly wherever they surface.** `PVEError` did not
  conform to `LocalizedError`, so any presenter using `localizedDescription`
  showed Foundation's generic "The operation couldn't be completed."

- **A removed server's empty-list diagnosis is discarded** rather than kept and
  rendered against whatever later took its id.

- **A console dragged out of the tab group can be put back.** The Window menu had
  no Merge All Windows, Move Tab to New Window, Show Tab Bar or Show All Tabs —
  AppKit adds the window list to a hand-built Window menu but not those — so a
  popped-out console was one-way, with no tab bar left to drag onto. The ⌘⇧[ /
  ⌘⇧] tab shortcuts come from the same items and now work.

- **The Port field is no longer squeezed to a single digit.** It shared a row with
  Server, whose field carries a required minimum width and takes every spare
  point; a grid cannot wrap, so Port now has its own row.

- **Signing in moved out of the connect window's form and onto the server rows.**
  The inline credentials form was a single-server surface bolted above a fleet: it
  folded itself away on sign-in, could not add a server at all, and duplicated the
  fields Manage Servers owns. Adding and editing a server is now one place —
  Manage Servers, reachable from a button in the window, ⌘, or the **Add a
  Server…** button shown when no server is configured. Signing one in is a row
  action, and a server with no stored secret is asked for one, as before.

- **A fleet status line.** With several servers the window said only what one of
  them was doing, so it could read "Signed in to Home" while another was
  unreachable — that failure showed only on its own row further down. It now also
  says "All 2 servers connected." or "1 of 2 servers connected. Rack B failed."

- **Searching a server name shows that server's guests.** Filtering the tree to a
  site matched the site but then narrowed its guests to the ones matching the same
  text — none of them — so it produced the row with nothing under it. The tree and
  the console picker now share one rule, which is why only one of them was wrong.

- **Signing in no longer stops at the first server that works.** A server that had
  failed was never retried, and revealing the browser signed in the fleet only
  while nothing was signed in yet — so once one server came up, the rest could
  never join it, and the tree gave no reason why.

- **Manage Servers no longer saves a server that can never sign in.** The sheet
  wrote whatever was on screen, so a half-filled row — a host with no token ID, or
  a token ID like `root` missing its realm and token name — went into the fleet and
  then sat signed-out forever, because signing in silently does nothing for an
  incomplete profile. The failure appeared nowhere near its cause. Done now names
  the offending server and what it is missing, in the same words the connect form
  has always used. Rows never filled in at all are still discarded quietly.

- **Password sign-ins no longer break after about two hours.** The cached login
  ticket was never re-minted, so once it expired every refresh reported a
  credentials failure with a perfectly good password. A 401 on password auth now
  clears the ticket and retries once. API tokens were never affected.

- **A successful sign-in no longer leaves the credentials form filling the window.**
  The form folds away into a status line once connected, giving the space to the guest
  list; the Sign In button becomes Sign Out to bring it back.
- **Signing in no longer costs two Keychain prompts.** The secret was rewritten to the
  Keychain on every successful sign-in even when unchanged, so a read and a write were
  each authorized separately. Unchanged secrets are no longer rewritten. (A single
  recurring prompt is inherent to ad-hoc signing — see the README.)
- **Copying from an app that puts both an image and text on the pasteboard no longer
  loses the text.** The host → guest clipboard grab advertised a single type with
  images ranked above text, so copying from Numbers, Keynote, Preview or many
  browsers offered only the image and pasting into a guest text field silently got
  nothing. Every available representation is now offered and the guest picks.


## [0.1.8] — 2026-08-28

### Added

- **Display zoom (View ▸ Zoom).** On a Retina Mac the client asked the guest for
  the view's full *backing pixel* count, so a 1512×982-point window drove the
  guest at 3024×1964 — the guest has no idea the Mac is HiDPI, so it rendered
  one pixel per pixel and everything came out half size, while the VM pushed
  four times the pixels it needed. Zoom is now **Z = Mac physical pixels per
  guest pixel**: the client requests `points × backing scale ÷ Z` and each guest
  pixel is drawn as a Z×Z block, so readability and cost improve together.
  Shortcuts **⌃⌘+ / ⌃⌘− / ⌃⌘0**.

- **The zoom level is per-window, and a fixed level is absolute.** Each window
  is its own session on its own display, so it carries its own level: picking
  one in the front window leaves the others alone. The commands live on the
  window controller and reach it down the responder chain the way `Connection ▸
  Send Ctrl-Alt-Del` already did, so the submenu greys out with no session open;
  the preference is only the seed a new window starts from. Nothing but the user
  ever changes a level — **Automatic** is the mode for constant apparent size
  across a move.

- **A window that changes display re-applies its geometry.** At a fixed level
  the target guest size is `points × backing scale ÷ Z`, and a move changes the
  backing scale out from under it — which is why it used to need a manual nudge
  of the window before the guest came out right. All four signals AppKit offers
  now drive it, including `NSApplicationDidChangeScreenParameters` for hotplug,
  sleep/wake and Displays scaled-mode changes, which resize the window without a
  live resize. Requests are coalesced, so four triggers cost at most one guest
  mode switch.

- **Without `spice-vdagent`, zoom and screen changes resize the *window***
  (`guest × Z ÷ backing scale` points) rather than doing nothing — the guest
  resolution is fixed, so that is the only side of the equation left. The
  geometry is a new dependency-free package, `Packages/DisplayScale`, with a
  21-check `scalecheck` runner wired into `make test` and CI.

### Changed

- **The default zoom is Automatic (Z = the screen's backing scale), which
  changes behaviour on upgrade.** The guest resolution now tracks the window's
  *point* size instead of its backing-pixel size, so on first connect after
  updating a Retina guest drops to roughly half its previous resolution and
  everything in it gets twice as big. That is the fix; **View ▸ Zoom ▸ 100%**
  restores the old behaviour. Automatic also means the requested resolution is
  the window's point size on *any* display, so dragging between screens needs no
  guest reconfiguration.

### Fixed

- **A dead connection no longer hides its own explanation.** When a session
  ended, the last guest frame stayed frozen over the window (the Metal view is
  opaque and `detach()` leaves it showing its final texture), so the
  "Disconnected — open a fresh .vv file" hint or the failure reason was drawn
  invisibly behind it and the window just looked hung. The display view now
  hides when the session ends and returns on the next connect, revealing the
  centered status message. A specific failure reason (`.failed`) is also kept
  if the generic disconnect callback arrives after the error one, instead of
  being downgraded to "Disconnected."

- **ISO / French Magic Keyboard `<>` key now reaches the guest.** The keymap was
  ANSI-only and omitted `kVK_ISO_Section` (`0x0A`), the key next to Left Shift on
  ISO hardware (e.g. French AZERTY `<` / `>`). Presses produced no guest event.
  Map it to PC set-1 `KEY_102ND` (`0x56`); `inputcheck` covers the mapping.
  (#4)

- **Guest text was blurry at some window sizes and not others**, worst on a
  normal-DPI monitor. The sampler only went nearest-neighbour at 2× or more, so
  a 1:1 presentation — what 100% means on a 1x screen — always took the bilinear
  path; and because the requested mode is floored onto the 8-wide/2-high grid
  guest drivers want, the centred quad landed on a **half-pixel** offset
  whenever that slack was odd. Nearest now applies at any whole-number
  magnification, and `viewportOrigin` nudges the quad onto whole pixels — the
  input router subtracts the same origin, so the cursor stays locked.

- **Dragging a window between a Retina panel and a 1x monitor did not re-scale
  the guest.** `MTKView` refreshes `drawableSize` lazily, so inside
  `viewDidChangeBackingProperties` — the one moment such a move offers — it
  still holds the *previous* screen's value: on a real 2.0↔1.0 drag the callback
  reports `backingScaleFactor` 1.0 while `drawableSize` is still 1800×1200 for a
  view that is now 900×600 physical pixels. The fit now measures with
  `convertToBacking(bounds)`, which follows the backing store immediately, and
  pulls the drawable up to match.
## [0.1.7] — 2026-06-15

### Fixed

- **Copying a spreadsheet cell in the guest now pastes onto the Mac.** A guest
  copy offers several clipboard representations at once (a cell = UTF-8 text + a
  bitmap image); the guest→host bridge cleared the Mac pasteboard on every write,
  so the representations clobbered each other and only the last survived — usually
  the image, leaving nothing to paste as text. The bridge now clears once per
  guest grab and accumulates the rest, so the cell's text (and image) both land.
  Plain-text copy was unaffected because it's a single type. (Fork change — see
  `ThirdParty/CocoaSpice/FORK-NOTES.md`.)

### Security

- **Hardened the `.vv` parser** (the one attacker-influenced file the app opens):
  a **1 MiB file-size cap** + UTF-8 enforcement in `VVConfig(contentsOf:)`,
  **control-character stripping** from values (a `NUL` in `host`/`proxy` would
  otherwise survive Swift validation but truncate inside the C SPICE stack — a
  smuggle), **port-range validation** (only 1–65535; junk/negative/overflow become
  "absent"), and leading-BOM tolerance. Added a deterministic **20k-iteration
  fuzzer** + edge-case tests (`vvcheck`, now 24 checks) proving the parser never
  crashes on arbitrary input.

## [0.1.6] — 2026-06-09

### Security

- **OpenSSL upgraded to 3.5.6 (LTS, maintained to 2030)**, retiring the EOL 1.1.1
  branch — the server-facing TLS stack is now current. It's built under the old
  `ssl.1.1`/`crypto.1.1` install names so spice-gtk (compiled against 1.1.1) loads it
  unchanged, and `upgrade-openssl.sh` verifies all ~72 of spice-gtk's OpenSSL symbols
  resolve in 3.x before swapping (then a real TLS connection was confirmed). The
  pinned default sysroot (`sysroot-arm64-v2`) ships 3.5.6, so a fresh clone is current
  with no extra step.

## [0.1.5] — 2026-06-09

### Changed

- **Hardened `run-as-root.sh`** (the supported USB-capture path): a clear
  trust-boundary warning + confirmation prompt (`-y` to skip), absolute-path
  resolution of the `.vv`, and a `sudo --` option-injection guard. Documented
  run-as-root honestly in the README and SECURITY.md — including **why a privileged
  USB helper was scoped and deferred**: macOS forces the boundary at the usbredirhost
  seam (a partial win that still parses guest data in root, needing a spice-gtk fork +
  framework rebuild and a sudo-installed LaunchDaemon); the genuinely clean fix is the
  `com.apple.vm.device-access` entitlement, gated on a Developer ID.

### Fixed

- **`.vv` is no longer moved to root's Trash** when launched via `run-as-root.sh`. The
  "Move .vv to Trash after connecting" preference is skipped under root (it would
  otherwise land in `/var/root/.Trash` instead of yours); the file is left in place.

## [0.1.4] — 2026-06-09

### Security

- **Multi-head monitor-config crash (DoS), second site.** A guest reporting more
  than one monitor config on a display channel — a protocol-legal multi-head
  configuration — tripped `g_assert(cfgs->len == 1)` in `cs_display_monitors` and
  aborted the whole client. Removed the assert; the handler now just creates/updates
  the (single-display-per-channel) display on any non-empty config, leaving per-head
  geometry to `cs_update_monitor_area`. Same DoS class as the `cs_update_monitor_area`
  fix already shipped. (Fork change — see `ThirdParty/CocoaSpice/FORK-NOTES.md`.)

## [0.1.3] — 2026-06-09

### Added

- **Move `.vv` to Trash after connecting** (File menu, default on). Proxmox SPICE
  tickets are single-use and the file also carries the cluster CA, so the used file
  is moved to the Trash (recoverable, not a hard delete) once it's opened a
  connection. Toggle off in **File ▸ Move .vv to Trash After Connecting**.

### Fixed

- **Blank screen on connect.** The display stayed black until the guest next
  repainted (e.g. a mouse click) because the SPICE loop (its own thread) created the
  primary surface before a Metal device was available — the device only arrives when
  a renderer attaches, from the app thread — so `rebuildCanvasTexture` early-returned
  and no Metal canvas was ever built. `-addRenderer:` now repaints the current
  framebuffer on the SPICE context once a device is attached, and
  `updateVisibleAreaWithRect:` orders vertices/ready before the initial draw. (Fork
  change — see `ThirdParty/CocoaSpice/FORK-NOTES.md`.)

### Changed

- **Reproducible builds** — `fetch-sysroot.sh` now downloads a **pinned,
  SHA-256-checksummed** native-dependency tarball from the repo's releases by
  default (the 26-framework + 19-plugin closure; LGPL/MIT/BSD/OpenSSL only, no GPL;
  OpenSSL already 1.1.1w). A fresh clone builds with **no `gh`/UTM artifact and no
  extra env vars** — fixing the prior reliance on UTM CI artifacts that expire ~90
  days. A fresh UTM build is still available via `SPICEMAC_SYSROOT_FROM_GH=1`.

## [0.1.2] — 2026-06-09

### Added

- **App icon** — a warm "spice"-palette squircle with a glowing remote-console
  screen and signal arcs. Wired in via `CFBundleIconFile`; shows in the Dock,
  Finder, and ⌘-Tab. Source art + the masking pipeline live in `design/icon/`;
  regenerate the `.icns` with `scripts/make-icon.sh`.

## [0.1.1] — 2026-06-09

Adds a **prebuilt download** alongside the source release.

### Added

- **Prebuilt `SpiceMac.app`** attached to the GitHub release (Apple Silicon),
  **ad-hoc signed** (not Developer-ID-signed/notarized — that needs a paid Apple
  Developer membership the project can't yet fund). README documents how to open it
  past Gatekeeper, and each release publishes a **SHA-256** of the zipped app.
- **`.github/FUNDING.yml`** — sponsorship to fund Developer-ID signing + notarization.
- **In-bundle license notices** — `build-app.sh` now copies the verbatim LGPL-2.1 /
  Apache-2.0 / OpenSSL / BSD-3-Clause / MIT texts and `THIRD-PARTY-LICENSES.txt` into
  `Contents/Resources/Licenses/`, so a distributed binary self-carries the required
  notices (LGPL-2.1 §6/§1, Apache-2.0 §4(a), OpenSSL/BSD/MIT binary clauses).
- **`licenses/`** — the verbatim upstream license texts, in the repo.

### Changed

- `THIRD-PARTY-LICENSES.txt` now records the bundled library versions and a proper
  **LGPL §6 written offer** (valid 3 years, to any third party), replacing the
  informal source pointer.
- `build-app.sh` packages the app with `ditto` (preserves symlinks + nested ad-hoc
  signatures) and strips the leftover absolute Xcode toolchain rpath from the binary.

## [0.1.0] — 2026-06-08

First public release. A native macOS (Apple Silicon) SPICE client that opens
Proxmox VE consoles from `.vv` files, rendering through Metal over a forked
CocoaSpice.

### Added

- **Display** — Metal-rendered SPICE display with aspect-fit scaling, live window
  resize, and dynamic guest resolution (requires `spice-vdagent`).
- **Keyboard** — full keymap (macOS keycode → PC set-1 scancodes, `0xE0`
  extended), including ⌘/modifiers with self-healing on missed key-up, Caps Lock,
  and Ctrl-Alt-Del / Release-Cursor menu commands.
- **Mouse & cursor** — absolute/relative motion, scroll, buttons; guest cursor
  aligned to the macOS pointer; optional hide-Mac-cursor (View menu, off by
  default).
- **Clipboard** — bidirectional text sharing between Mac and guest, on by default
  with a Connection-menu toggle and a 64 MB transfer cap.
- **Audio** — guest audio playback (requires a SPICE audio device on the VM).
- **USB redirection** — Connection ▸ USB Devices picker; documented the macOS
  device-capture gate and shipped `scripts/run-as-root.sh` for kernel-claimed
  devices.
- **Proxmox connection** — `.vv` parser (opaque host token, proxy, tls-port,
  one-time ticket, host-subject, CA), connecting over TLS through the node's
  `spiceproxy` with certificate-subject verification.
- **Forked CocoaSpice** — adds `-[CSConnection setProxy:ca:certSubject:]` (the one
  method needed for Proxmox's proxy + subject-verify TLS); see
  `ThirdParty/CocoaSpice/FORK-NOTES.md`.
- **Tooling** — `scripts/fetch-sysroot.sh` (pinned, checksummed native frameworks),
  `scripts/build-app.sh` (compiles the Metal shader, bundles only the runtime
  closure), and dependency-free test runners (`vvcheck`, `inputcheck`).

### Security

- Upgraded the bundled OpenSSL from the EOL 1.1.1b to **1.1.1w**
  (`scripts/upgrade-openssl.sh`), fixing CVE-2022-0778.
- TLS fails closed: a TLS+subject-verify connection with no CA is rejected.
- Fixed display channel DoS crashes (multi-head `g_assert`, non-UTF8 clipboard).
- Bundle only the 26-framework runtime closure — the upstream sysroot's GPL-2.0
  QEMU frameworks are no longer shipped (app size 443 MB → 23 MB).
- See [SECURITY.md](SECURITY.md) for the threat model and residual risks.

[Unreleased]: https://github.com/Ching367436/spice-mac/compare/v0.1.8...HEAD
[0.1.8]: https://github.com/Ching367436/spice-mac/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/Ching367436/spice-mac/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/Ching367436/spice-mac/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/Ching367436/spice-mac/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/Ching367436/spice-mac/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/Ching367436/spice-mac/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/Ching367436/spice-mac/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/Ching367436/spice-mac/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Ching367436/spice-mac/releases/tag/v0.1.0
