# Local crate patches

Patches applied to Wayland client crates during the build, wired in via a
`[patch.crates-io]` table written to `$CARGO_HOME/config.toml` (see the Dockerfile step
that consumes `crates.txt`). That mechanism applies to every component's `cargo`
invocation without editing any of the ~25 component manifests.

## Why

After a suspend/resume left `cosmic-comp` without its DRM render node
(`Error::NoDevice(DrmNode { dev: 57984, ty: Render })`, i.e. `renderD128`), the compositor
killed its clients with a fatal Wayland protocol error. Every `calloop`-driven COSMIC
client then spun at 100% CPU reprinting the same line forever instead of exiting.

Measured on 2026-09-08 with COSMIC Epoch 1.7.0: ~15 processes at ~100% CPU, ~170,000 log
lines/sec in aggregate, **17 GB written to `/var/log/syslog` in two hours**, `rsyslogd`
pinned at 245% CPU. `strace` showed 28,798/28,798 `read()` calls failing with no
`sendmsg`/`recvmsg` at all -- the socket was never touched again, yet the loop ran flat
out.

Three upstream defects compose. Each is present in the latest releases and on master, and
any one of them being absent would have bounded the damage:

1. **`wayland-client`** -- `EventQueue::dispatching_impl` did
   `dispatch_inner_queue().unwrap_or_default()`, turning a fatal, *sticky*
   `WaylandError::Protocol` into `Ok(0)` ("nothing pending"). This is what causes the loop:
   the caller can never learn the connection is dead. Its comment assumed "the potential
   socket error will be caught in other places anyway", which is false for protocol errors
   -- see defect 3.

2. **`wayland-backend`** -- `ConnectionState::store_and_return_error` calls `log_error!`
   unconditionally, but the error it stores is permanent, so every later dispatch
   re-enters it and logs again. Without the `log` feature that macro is `eprintln!`:
   unbuffered, unfiltered, not rate-limited, and invisible to the application's
   `tracing`/journald setup. This is what turned a hot loop into 17 GB of syslog.

3. **`calloop-wayland-source`** -- `flush_queue` matched only `WaylandError::Io`, so a
   `WaylandError::Protocol` from `flush()` fell through the `if let` and the function
   returned `Ok(())`, leaving the source registered. This is the "other place" defect 1
   relied on.

Patches 1 and 3 each independently break the loop; 2 bounds the logging.

## Upstream status

Not yet filed as of 2026-09-08. The equivalent patches against `wayland-rs` master
(0813584) and `calloop-wayland-source` master (9828ce3), plus the full writeup and raw
evidence, are in `~/cosmic-wayland-busyloop-20260908/`. These local copies are rebased onto
the exact released versions the build resolves, so they apply to the crates.io tarballs.

Drop a patch from `crates.txt` once its fix lands in a release the build picks up.

## Verification

Against `wayland-rs` master, `cargo test -p wayland-tests --no-fail-fast`, 23 binaries:

| backend | baseline | patched |
|---|---|---|
| `--features client_system` (libwayland -- what COSMIC uses) | 49 passed, 1 failed | 49 passed, 1 failed |
| default (pure Rust) | 51 passed, 0 failed | 51 passed, 0 failed |

No regressions; the single failure (`protocol_errors::client_receive_generic_error`) fails
identically on unmodified master. `calloop-wayland-source`: `cargo check`, `cargo test`,
`cargo clippy` all clean.

Note when touching the `wayland-client` patch: propagating *all* errors breaks the
`buffer_size` test. `wayland-tests`' `roundtrip` helper deliberately relies on I/O errors
being swallowed so already-queued events still dispatch. Only `Protocol` may propagate,
which is why the patch remembers the error, drains the queue, and only then returns it.

## Verifying the patches

`reproducer/` is a self-contained A/B test. It builds a client with cosmic-panel's
event-loop shape (a `WaylandSource` in calloop, driven by
`event_loop.dispatch(timeout, ..)?`), provokes a real server-side protocol error via
`wl_shm.create_pool(size=-1)`, and runs it twice: once against stock crates.io
crates and once with the `[patch.crates-io]` table from this directory.

It needs no COSMIC session and does not touch the running desktop -- it starts its
own headless weston inside the container:

    docker run --rm \
      -v "$PWD/images/cosmic-epoch/patches/reproducer:/src/spintest:ro" \
      -v "$PWD/images/cosmic-epoch/patches:/patches:ro" \
      -w /work rust:1-trixie bash /src/spintest/run.sh

Measured 2026-09-09 (wayland-client 0.31.14, wayland-backend 0.3.15 with
`client_system`, calloop-wayland-source 0.4.1):

| | stock | patched |
|---|---|---|
| outcome | `BUSYLOOP` (exit 1) | `ERROR_PROPAGATED` (exit 0) |
| iterations in 3 s | 390,747 (130,249/s) | 0, exits immediately |
| `Protocol error` lines | 781,494 | 2 |
| stderr written | 28 MB in 3 s | 268 bytes |

Two details corroborate the field diagnosis: the stock run emits exactly 2.0 log
lines per loop iteration, matching the `strace` of the live cosmic-panel, and its
~9.3 MB/s matches the 10-20 MB/s observed growth of /var/log/syslog.

The patches were rebased onto wayland-client 0.31.15 and wayland-backend 0.3.17 for
epoch-1.9.0, whose lockfiles resolve to those releases: with the old 0.31.14 / 0.3.15
pins the `[patch.crates-io]` entries were ignored. Content is unchanged; the
wayland-backend hunk only moved by three lines.

Note the `=` version pins in `reproducer/Cargo.toml`. They are required: with loose
requirements cargo can resolve newer registry versions, the `[patch.crates-io]`
entries pinned here no longer get selected, and the run silently tests unpatched
code. The `[check]` line in `run.sh` prints the resolved graph so
this is visible rather than assumed -- the same hazard the cargo-metadata assertion
in the Dockerfile guards against for real builds.

## Submodule patches (`submodules/`)

Patches applied directly to the cosmic-epoch git submodules, rather than through
`[patch.crates-io]`. Named `<component>-NNNN-<slug>.patch`; the Dockerfile derives
the component by stripping `-NNNN-<slug>.patch` and fails the build if no submodule
of that name exists. The submodule commit pinned by
`git clone --recursive --branch epoch-1.9.0` is the version guard, so no sha256 is
needed -- `patch --fuzz=0` fails loudly if a submodule moves under a patch.

### cosmic-comp-0001-finish-teardown-on-failed-reopen.patch

Fixes the state corruption that a failed device re-open leaves behind on resume, and
which the VT bounce in `cosmic-drm-recover.service` cannot repair -- that restores the
display, but not the compositor's internal bookkeeping.

`reopen_device` (src/backend/kms/device.rs) tears the old device down *before*
constructing the replacement, then calls `Device::new` with `?`. On failure it returns
with the device already `shift_remove`d from `backend.drm_devices`, its surfaces
dropped, and `syncobj_state.close_device()` already called -- and none of the
end-of-function cleanup done. `resume_session` then calls `device_removed`, which
cannot help because it resolves its `DrmNode` by iterating `backend.drm_devices` and so
fails with "Couldn't find drm node" before removing anything.

Observed 2026-09-09 after a resume that left the machine without its Intel iGPU
(verified against the installed binary via journald `CODE_LINE` 413/421/427 in
src/backend/kms/mod.rs):

  * Two `eDP-1` `wl_output` globals (protocol names 58 and 62) at conflicting positions
    0,927 and 7040,0 -- the orphaned set plus a fresh set added later. The internal
    panel was unreachable and neither global could be addressed by name, since
    `cosmic-randr` resolves by name and both were `eDP-1`.
  * A syncobj manager advertising its global with a closed device, so Electron apps
    died at launch: `wp_linux_drm_syncobj_manager_v1: error 1: failed to import syncobj
    timeline: No device`, which Chromium turns into `__builtin_trap()` -> SIGTRAP.
    `--disable-features=WaylandSyncobjReleaseTimeline` does not avoid it; the client
    just dies slightly later on `Connection reset by peer`.

The patch finishes the teardown on the failure path instead: it withdraws the orphaned
outputs exactly as the success path and `device_removed` do, and withdraws the syncobj
global rather than leaving it bound to nothing (the same fallback already used when a
replacement device turns out not to support syncobj eventfds, after which clients fall
back to implicit sync). It does not attempt to make the re-open succeed -- the device
really is gone -- it confines the damage to the lost device so the session stays usable.

Verified with `cargo check --release` against the pinned submodule commit
31827ed2409f92d3bc224d3ce601c6f2136183fb (clean) and `patch -p1 --fuzz=0 --dry-run`
against a pristine checkout.

### cosmic-comp-0002-no-blocking-node-sync-under-device-locks.patch

Fixes the "whole machine freezes" when the WD19TB dock's ultrawides (card1 `DP-3`/`DP-4`,
NVIDIA dGPU) are turned on while the session is running only on the Intel `eDP-1`. Observed
2026-10-05: four hard resets in a row, plus a blank greeter when booting with the dock
attached. The kernel was fine (logind still handled the power key and the journal kept
logging); the compositor was deadlocked.

`cosmic-randr enable` runs `KmsGuard::apply_config_for_outputs`, which holds every device's
`DrmOutputManager` lock. The first enabled output on the dGPU makes its render node "used",
so `refresh_used_devices` -> `update_surface_nodes` calls `Surface::add_node` on every
surface, and `add_node` blocks until the surface thread acknowledges `NodeAdded`. The
`surface-eDP-1` thread was mid-`redraw`, in `DrmOutput::with_compositor`, blocked on a read
lock of that same manager, so it never acknowledged. gdb backtraces from the hung
compositor are in the patch description.

The patch adds a `wait` flag to `add_node`/`remove_node`/`update_surface_nodes`. Only the
`KmsGuard` path passes `false`. The command channel is ordered, so the surface thread still
handles the node change before anything sent after it. The lock-free callers keep waiting,
which keeps the fd-closed-before-udev-callback guarantee for `device_removed`.

Verified with `patch -p1 --fuzz=0` (after 0001) against a pristine checkout of the
submodule commit pinned by epoch-1.8.0, a55785993e8ef6aad38862cb1a9e1ccaad3c340d.

Both cosmic-comp patches also apply with `patch -p1 --fuzz=0`, in order, to the
submodule commit pinned by epoch-1.9.0, 0fbd4574ef4caf74769a617d205fd1fc909ac9b1.
