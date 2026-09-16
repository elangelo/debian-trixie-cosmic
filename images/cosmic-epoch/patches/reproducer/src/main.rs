// Reproducer for the COSMIC client busy-loop / log-flood after a fatal Wayland
// protocol error (see images/cosmic-epoch/patches/README.md).
//
// Mimics cosmic-panel's event loop shape: a WaylandSource inserted into calloop,
// driven by `event_loop.dispatch(timeout, ..)?` inside a `loop`.
//
// The protocol error is induced through the normal API rather than by writing raw
// bytes to the socket: `wl_shm.create_pool` with a negative size makes the
// compositor post wl_shm.error(invalid_stride). That is a genuine server-side
// protocol error, so libwayland sets EPROTO on the display -- the exact condition
// cosmic-comp produces when it loses its DRM render node across a suspend. Raw
// socket injection does not work with the sys backend, as it corrupts
// libwayland's own write buffer and surfaces as EINVAL instead.
//
// Unpatched: `dispatch` keeps returning Ok, so the loop spins at full speed.
// Patched: the error propagates out of `dispatch` and ends the process.

use std::io::Write;
use std::os::fd::{AsFd, FromRawFd, OwnedFd};
use std::time::{Duration, Instant};

use calloop::EventLoop;
use calloop_wayland_source::WaylandSource;
use wayland_client::protocol::{wl_registry, wl_shm, wl_shm_pool};
use wayland_client::{Connection, Dispatch, QueueHandle};

#[derive(Default)]
struct State {
    shm: Option<(u32, u32)>, // (name, version)
}

impl Dispatch<wl_registry::WlRegistry, ()> for State {
    fn event(
        state: &mut Self,
        _: &wl_registry::WlRegistry,
        event: wl_registry::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let wl_registry::Event::Global { name, interface, version } = event {
            if interface == "wl_shm" {
                state.shm = Some((name, version));
            }
        }
    }
}

// wl_shm / wl_shm_pool events are irrelevant here; the error arrives on wl_display.
impl Dispatch<wl_shm::WlShm, ()> for State {
    fn event(_: &mut Self, _: &wl_shm::WlShm, _: wl_shm::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}
impl Dispatch<wl_shm_pool::WlShmPool, ()> for State {
    fn event(_: &mut Self, _: &wl_shm_pool::WlShmPool, _: wl_shm_pool::Event, _: &(), _: &Connection, _: &QueueHandle<Self>) {}
}

const BUSY_THRESHOLD: u64 = 10_000;
const TIME_LIMIT: Duration = Duration::from_secs(3);

fn scratch_fd() -> OwnedFd {
    // Any real fd works; the compositor rejects the size before mapping it.
    let fd = unsafe { libc::memfd_create(c"spintest".as_ptr(), 0) };
    assert!(fd >= 0, "memfd_create failed");
    unsafe { libc::ftruncate(fd, 4096) };
    unsafe { OwnedFd::from_raw_fd(fd) }
}

fn main() {
    let conn = Connection::connect_to_env().expect("connect to compositor");
    let display = conn.display();
    let mut event_queue = conn.new_event_queue();
    let qh = event_queue.handle();
    let registry = display.get_registry(&qh, ());

    let mut state = State::default();
    event_queue.roundtrip(&mut state).expect("initial roundtrip");
    let (name, version) = state.shm.expect("compositor advertises wl_shm");
    eprintln!("[harness] connected, wl_shm name={name} version={version}");

    // Provoke a server-side protocol error: negative pool size.
    let shm: wl_shm::WlShm = registry.bind(name, version, &qh, ());
    let fd = scratch_fd();
    let _pool = shm.create_pool(fd.as_fd(), -1, &qh, ());
    conn.flush().expect("flush");
    eprintln!("[harness] sent wl_shm.create_pool(size=-1), entering cosmic-panel-style loop");
    let _ = std::io::stderr().flush();

    let mut event_loop: EventLoop<State> = EventLoop::try_new().expect("event loop");
    WaylandSource::new(conn, event_queue)
        .insert(event_loop.handle())
        .expect("insert WaylandSource");

    let start = Instant::now();
    let mut iters: u64 = 0;

    loop {
        // Exactly cosmic-panel's call: the error is expected to propagate here.
        if let Err(e) = event_loop.dispatch(Duration::from_millis(300), &mut state) {
            println!(
                "RESULT=ERROR_PROPAGATED iters={iters} elapsed_ms={} err={e}",
                start.elapsed().as_millis()
            );
            std::process::exit(0);
        }
        iters += 1;

        if start.elapsed() > TIME_LIMIT {
            let ms = start.elapsed().as_millis().max(1) as u64;
            let rate = iters * 1000 / ms;
            if iters > BUSY_THRESHOLD {
                println!("RESULT=BUSYLOOP iters={iters} elapsed_ms={ms} iters_per_sec={rate}");
                std::process::exit(1);
            }
            println!("RESULT=NOERROR iters={iters} elapsed_ms={ms} iters_per_sec={rate}");
            std::process::exit(2);
        }
    }
}
