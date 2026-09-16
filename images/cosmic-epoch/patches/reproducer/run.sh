#!/bin/bash
# Runs the reproducer twice: once against stock crates.io crates, once against the
# patched checkouts. Prints a comparison of exit status, iteration count and how
# many "Protocol error" lines each variant wrote to stderr.
set -eu

apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq curl patch libwayland-dev pkg-config weston >/dev/null 2>&1

# --- prepare patched crate checkouts ---
mkdir -p /patched
grep -vE '^[[:space:]]*(#|$)' /patches/crates.txt | while read -r name version sha; do
    curl -fsSL "https://static.crates.io/crates/$name/$name-$version.crate" -o "/tmp/$name.crate"
    echo "$sha  /tmp/$name.crate" | sha256sum -c - >/dev/null
    tar -xzf "/tmp/$name.crate" -C /patched
    for pf in /patches/"$name-$version"-*.patch; do
        patch -s -p1 --fuzz=0 -d "/patched/$name-$version" < "$pf"
    done
done
echo "[setup] patched crates ready"

# --- start a headless compositor ---
export XDG_RUNTIME_DIR=/run/user/0
mkdir -p "$XDG_RUNTIME_DIR" && chmod 700 "$XDG_RUNTIME_DIR"
weston --backend=headless --socket=wayland-test --idle-time=0 >/tmp/weston.log 2>&1 &
for _ in $(seq 1 50); do
    [ -S "$XDG_RUNTIME_DIR/wayland-test" ] && break
    sleep 0.2
done
if [ ! -S "$XDG_RUNTIME_DIR/wayland-test" ]; then
    echo "[setup] FAILED to start weston:"; cat /tmp/weston.log; exit 1
fi
export WAYLAND_DISPLAY=wayland-test
echo "[setup] weston headless up on \$WAYLAND_DISPLAY=$WAYLAND_DISPLAY"

cd /work
cp -r /src/spintest /work/spintest
cd /work/spintest

run_variant() {
    local label="$1"
    echo
    echo "================ $label ================"
    cargo build --release 2>&1 | grep -iE "warning|error" | head -8 || true
    # Confirm from the resolved dependency graph which sources were compiled in.
    local np
    np=$(cargo metadata --format-version 1 2>/dev/null | tr ',' '\n' | grep -c '"/patched/' || true)
    echo "[check] patched crate manifests in dependency graph: $np"
    cargo metadata --format-version 1 2>/dev/null | tr ',{' '\n\n' \
        | grep -oE '"id":"[^"]*(wayland-client|wayland-backend|calloop-wayland-source)[^"]*"' \
        | sed -E 's/"id":"//; s/"$//' | sort -u | sed 's/^/        /'
    local stderr_bytes
    set +e
    timeout 30 ./target/release/spintest >/tmp/out.txt 2>/tmp/err.txt
    local rc=$?
    set -e
    local flood
    flood=$(grep -c "Protocol error" /tmp/err.txt || true)
    echo "[run] exit=$rc"
    echo "[run] $(cat /tmp/out.txt)"
    echo "[run] 'Protocol error' lines on stderr: $flood ($(wc -c </tmp/err.txt) bytes)"
    echo "[run] stderr head:"; head -4 /tmp/err.txt | sed 's/^/        /'
}

run_variant "VARIANT 1: STOCK crates (expect BUSYLOOP + flood)"

# --- wire in the patches and rebuild ---
{
  echo ""
  echo "[patch.crates-io]"
  for d in /patched/*/; do
      n=$(basename "$d" | sed -E 's/-[0-9]+\.[0-9]+\.[0-9]+$//')
      printf '%s = { path = "%s" }\n' "$n" "${d%/}"
  done
} >> "$CARGO_HOME/config.toml"

run_variant "VARIANT 2: PATCHED crates (expect clean error exit, 1 log line)"
