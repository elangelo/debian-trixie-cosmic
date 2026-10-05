# syntax=docker/dockerfile:1
# Stage 1: Builder
FROM debian:trixie AS builder

ENV DEBIAN_FRONTEND=noninteractive

# 1. Add stable build dependencies
RUN apt-get update && apt-get install -y \
    build-essential git curl pkg-config \
    libpipewire-0.3-dev libspa-0.2-dev libwayland-dev libxkbcommon-dev \
    libinput-dev libseat-dev libudev-dev libgbm-dev libdrm-dev \
    libdbus-1-dev libpam0g-dev libfontconfig-dev libfreetype-dev \
    libpolkit-gobject-1-dev libgudev-1.0-dev libglib2.0-dev \
    libjson-glib-dev libpulse-dev libasound2-dev libssl-dev \
    libflatpak-dev libarchive-dev libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev clang llvm-dev cmake \
    libpixman-1-dev libwayland-bin libdisplay-info-dev libxcb-xinput-dev libdav1d-dev \
    wayland-protocols extra-cmake-modules scdoc sed make libclang-dev \
    gtk-update-icon-cache hicolor-icon-theme bsdextrautils patch \
    && rm -rf /var/lib/apt/lists/*

# just >= 1.42 is required from epoch-1.7.0 onwards: the component justfiles depend on
# recipes in submodules (e.g. `clean: cargo::clean`), a syntax added in just 1.42.0.
# Debian Trixie ships 1.40.0, which fails to parse it outright -- not an unstable-feature
# gate, so --unstable does not help. Installed into /usr/local/bin, which precedes
# /usr/bin in PATH, so upstream's require("just") resolves to this one.
ARG JUST_VERSION=1.58.0
RUN curl -fsSL "https://github.com/casey/just/releases/download/${JUST_VERSION}/just-${JUST_VERSION}-x86_64-unknown-linux-musl.tar.gz" \
        | tar -xzC /usr/local/bin just \
    && just --version

WORKDIR /build

# 2. Install Rust via rustup (system rustc in Trixie is too old)
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --no-modify-path
ENV CARGO_HOME=/root/.cargo
ENV PATH=$CARGO_HOME/bin:$PATH
ENV CARGO_PROFILE_RELEASE_LTO=thin
ENV CARGO_PROFILE_RELEASE_CODEGEN_UNITS=16
ENV CARGO_PROFILE_RELEASE_PANIC=abort
ENV LIBCLANG_PATH=/usr/lib/llvm-19/lib

# Mark the directory as safe for git
RUN git config --global --add safe.directory /build && \
    git clone --recursive --branch epoch-1.8.0 https://github.com/pop-os/cosmic-epoch.git . && \
    # Patch: xdg-desktop-portal-cosmic dropped its Makefile in epoch-1.2.0 and migrated to justfile.
    # The upstream cosmic-epoch justfile still calls `make -C xdg-desktop-portal-cosmic`, so we
    # replace those calls with the equivalent `just` invocations.
    sed -i \
        -e 's|{{ make }} -C xdg-desktop-portal-cosmic all|{{ just }} xdg-desktop-portal-cosmic/build|g' \
        -e 's|{{ make }} -C xdg-desktop-portal-cosmic install DESTDIR={{rootdir}} prefix={{prefix}}|{{ just }} rootdir={{rootdir}} prefix={{prefix}} xdg-desktop-portal-cosmic/install|g' \
        justfile && \
    # Patch: from epoch-1.7.0 the component justfiles delegate to a `cargo.just` module
    # whose recipes are all marked [no-cd], meaning they run in the *invocation*
    # directory rather than the justfile's. Upstream's `just <component>/<recipe>` path
    # invocation therefore runs cargo from the monorepo root, where there is no
    # Cargo.toml, and the build dies at cosmic-applibrary. Rewrite every path invocation
    # to cd into the component first, which is correct for [no-cd] recipes and harmless
    # for the components that have not migrated. Verified against all just 1.42-1.58;
    # this is not a just version issue. `{{ make }} -C` lines are left alone, as make
    # handles its own directory. Safe because `just install` is called with an absolute
    # rootdir (/export) below -- a relative rootdir would not survive the cd.
    sed -i -E \
        's|\{\{ just \}\} (.*[[:space:]])?([^[:space:]/]+)/([^[:space:]/]+)[[:space:]]*$|cd \2 \&\& {{ just }} \1\3|' \
        justfile && \
    # Point every component's ./target at the single shared /build/target, which is the
    # BuildKit cache mount used by the build step below. The cd patch above is required
    # so cargo can find each component's Cargo.toml, but it also makes every path the
    # justfiles use -- `target/release/<bin>` and the `target/xdgen` that ten components
    # install their .desktop/.metainfo.xml from -- resolve inside the component instead
    # of at the monorepo root. That yields ~25 separate target dirs, none of them on the
    # cache mount, which overflows the disk partway through the build. Symlinking
    # restores exactly the layout epoch-1.6.0 built with (one shared target, reached via
    # [no-cd] recipes running at /build) while keeping cargo able to find its manifests,
    # and needs no edits to the component justfiles.
    mkdir -p /build/target && \
    for d in */; do \
        d="${d%/}"; \
        if [ -f "$d/Cargo.toml" ]; then rm -rf "$d/target" && ln -sfn /build/target "$d/target"; fi; \
    done

COPY patches /tmp/patches

# 2a. Patch the cosmic-epoch submodules themselves. These are git checkouts, not crates.io
# tarballs, so they are patched in place rather than through [patch.crates-io], and the
# submodule commit that `git clone --recursive --branch epoch-1.7.0` pins is the version
# guard -- no sha256 needed. `patch --fuzz=0` fails the build if a submodule moves.
#
# patches/submodules/<component>-NNNN-<slug>.patch, applied in sorted order per component.
# See patches/README.md for the analysis behind each one.
RUN set -eu; \
    if [ -d /tmp/patches/submodules ]; then \
        applied=0; \
        for pf in $(ls /tmp/patches/submodules/*.patch 2>/dev/null | sort); do \
            base=$(basename "$pf"); \
            comp=$(echo "$base" | sed -E 's/-[0-9]{4}-.*$//'); \
            if [ ! -d "/build/$comp" ]; then \
                echo "FAIL $base names component '$comp', which is not a submodule of" >&2; \
                echo "     cosmic-epoch. Rename the patch or drop it." >&2; \
                exit 1; \
            fi; \
            echo "==> $comp: $base"; \
            patch -p1 --fuzz=0 -d "/build/$comp" < "$pf"; \
            applied=$((applied + 1)); \
        done; \
        echo "applied $applied submodule patch(es)"; \
    else \
        echo "no patches/submodules directory; nothing to do"; \
    fi

# 2b. Patch the Wayland client crates that make COSMIC clients busy-loop at 100% CPU and
# flood the log after a fatal protocol error. Full analysis in patches/README.md; in short,
# three upstream defects compose so that a protocol error (as raised when cosmic-comp loses
# its DRM render node across a suspend) is logged unconditionally and then swallowed, so
# every client spins forever instead of exiting. Measured before patching: ~15 processes at
# ~100% CPU, ~170,000 log lines/sec, 17 GB of /var/log/syslog in two hours.
#
# The crates are unpacked as local checkouts under /patched and wired in through a
# [patch.crates-io] table in CARGO_HOME/config.toml. That applies to every component's cargo
# invocation without touching any of the ~25 component manifests, which matters because they
# are independent cargo projects, not one workspace. `just build-release` runs plain
# `cargo build --release` with no --locked, so cargo is free to re-resolve.
#
# Two guards, because a silently-unpatched package is the failure mode worth avoiding:
# tarballs are pinned by sha256 and `patch --fuzz=0` fails the build if a crate's contents
# no longer match, and the cargo-metadata assertion below fails the build if the patches stop
# being picked up at all (e.g. upstream COSMIC moving to a semver-incompatible release, which
# a [patch.crates-io] entry would silently no longer satisfy).
RUN set -eu; \
    mkdir -p /patched; \
    grep -vE '^[[:space:]]*(#|$)' /tmp/patches/crates.txt | while read -r name version sha; do \
        echo "==> $name $version"; \
        curl -fsSL "https://static.crates.io/crates/$name/$name-$version.crate" \
            -o "/tmp/$name.crate"; \
        echo "$sha  /tmp/$name.crate" | sha256sum -c -; \
        tar -xzf "/tmp/$name.crate" -C /patched; \
        rm -f "/tmp/$name.crate"; \
        for pf in /tmp/patches/"$name-$version"-*.patch; do \
            echo "    applying $(basename "$pf")"; \
            patch -p1 --fuzz=0 -d "/patched/$name-$version" < "$pf"; \
        done; \
        printf '%s = { path = "/patched/%s-%s" }\n' "$name" "$name" "$version" \
            >> /tmp/patch-table.toml; \
    done; \
    test -s /tmp/patch-table.toml; \
    { echo ""; echo "[patch.crates-io]"; cat /tmp/patch-table.toml; } >> "$CARGO_HOME/config.toml"; \
    rm -f /tmp/patch-table.toml; \
    echo "--- $CARGO_HOME/config.toml ---"; cat "$CARGO_HOME/config.toml"

# 2c. Assert the patches are actually in the dependency graph. cosmic-panel is used as the
# probe because it depends on all three crates (it was also the process observed spinning).
# Without this, a version bump upstream would produce a cleanly-built but unpatched package.
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    set -eu; \
    cd /build/cosmic-panel; \
    cargo metadata --format-version 1 > /tmp/metadata.json; \
    for d in /patched/*/; do \
        if grep -qF "${d}Cargo.toml" /tmp/metadata.json; then \
            echo "OK   patched crate in graph: ${d}"; \
        else \
            echo "FAIL ${d} is not in cosmic-panel's dependency graph -- the" >&2; \
            echo "     [patch.crates-io] entry no longer satisfies any requirement." >&2; \
            echo "     Re-pin the version in patches/crates.txt." >&2; \
            exit 1; \
        fi; \
    done; \
    rm -f /tmp/metadata.json

# 3. Build and install FULL stack with BuildKit caching
# We cache:
# - Cargo registry (downloaded crates)
# - Cargo git (git dependencies)
# - Target directory (compiled objects)
RUN --mount=type=cache,target=/root/.cargo/registry \
    --mount=type=cache,target=/root/.cargo/git \
    --mount=type=cache,target=/build/target \
    mkdir -p /export/usr && \
    just install /export /usr

# 3b. Install cosmic-greeter's systemd unit files.
# Upstream's cosmic-greeter justfile `install` recipe deliberately does not install
# these: they live under debian/ purely for a real dh_installsystemd pass in
# cosmic-greeter's own Debian packaging, which this monorepo build never runs. Without
# this, cosmic-greeter-daemon.service (needed for the login PAM helper to run at all)
# is silently dropped from the resulting package. cosmic-greeter.service is installed
# too but left disabled, since enabling it would fight with whatever display manager
# is already active.
RUN install -Dm0644 /build/cosmic-greeter/debian/cosmic-greeter-daemon.service \
        /export/usr/lib/systemd/system/cosmic-greeter-daemon.service && \
    install -Dm0644 /build/cosmic-greeter/debian/cosmic-greeter.service \
        /export/usr/lib/systemd/system/cosmic-greeter.service

# 3c. Install cosmic-greeter's PAM stack and greetd session config. Like the systemd
# units above, upstream's justfile never installs these either -- they only exist for
# a real dh_installsystemd/dh_installpam pass. Without the PAM file greetd has no login
# stack to authenticate against, and without the greetd config there is no session to
# hand off to. These land under /export/etc, which only the .deb picks up (the sysext
# stage intentionally stays /usr-only).
RUN install -Dm0644 /build/cosmic-greeter/debian/cosmic-greeter.pam \
        /export/etc/pam.d/cosmic-greeter && \
    install -Dm0644 /build/cosmic-greeter/cosmic-greeter.toml \
        /export/etc/greetd/cosmic-greeter.toml

# 3d. Install systemd drop-ins that bypass nvidia-sleep.sh's "chvt 63" VT switch.
# That VT switch is there for the NVIDIA X driver, but it deactivates the logind
# session, and cosmic-comp does not recover from losing DRM master across a
# suspend -- it ends up with "Device lost" on every card and a frozen desktop.
# See the header comment in each .conf for the full rationale and upstream issues.
# These are inert on machines with no NVIDIA driver, since the units they extend
# will not exist there.
COPY packaging/nvidia/nvidia-suspend.conf \
     packaging/nvidia/nvidia-hibernate.conf \
     packaging/nvidia/nvidia-suspend-then-hibernate.conf \
     /tmp/nvidia-dropins/
RUN for u in nvidia-suspend nvidia-hibernate nvidia-suspend-then-hibernate; do \
        install -Dm0644 /tmp/nvidia-dropins/$u.conf \
            /export/usr/lib/systemd/system/$u.service.d/50-cosmic-no-vt-switch.conf; \
    done && rm -rf /tmp/nvidia-dropins

# 4. SANitization: Remove fundamental system binaries to protect host integrity
RUN rm -f /export/usr/bin/env /export/usr/bin/bash /export/usr/bin/sh /export/usr/bin/dash

# 5. Derive runtime dependencies from what the binaries actually link against.
# The hand-maintained Depends list drifted every time a soname changed upstream
# (e.g. libdisplay-info1 -> 3 while Trixie ships 2) and silently missed libraries
# that were build-depended on but never declared (e.g. libdav1d). This runs here,
# in the builder, because it is the only stage with every runtime library present.
# The result is substituted into DEBIAN/control's @SHLIBS_DEPENDS@ placeholder.
RUN apt-get update && apt-get install -y --no-install-recommends dpkg-dev \
    && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /shlibdeps/debian && \
    printf 'Source: cosmic-epoch-monorepo\n\nPackage: cosmic-epoch-monorepo\nArchitecture: amd64\n' \
        > /shlibdeps/debian/control && \
    cd /shlibdeps && \
    dpkg-shlibdeps -O $(find /export/usr -type f -perm -u+x) > /shlibdeps/raw && \
    sed 's/^shlibs:Depends=//' /shlibdeps/raw > /shlibdeps/depends.txt && \
    test -s /shlibdeps/depends.txt && \
    cat /shlibdeps/depends.txt

# Prepare metadata
RUN echo 'ID=debian' > /export/extension-release.cosmic-epoch && \
    echo 'VERSION_ID=13' >> /export/extension-release.cosmic-epoch && \
    echo 'SYSEXT_LEVEL=1' >> /export/extension-release.cosmic-epoch

# Stage 2: Packaging (Sysext)
FROM busybox AS sysext
COPY --from=builder /export/extension-release.cosmic-epoch /usr/lib/extension-release.d/extension-release.cosmic-epoch
COPY --from=builder /export/usr /usr

# Stage 3: Packaging (.deb)
FROM debian:trixie AS deb-packager
RUN apt-get update && apt-get install -y bsdextrautils && rm -rf /var/lib/apt/lists/*
WORKDIR /pkg
COPY --from=builder /export/usr ./usr
COPY --from=builder /export/etc ./etc
# Final safety check: Remove any essential system binaries that might have leaked in
RUN rm -f ./usr/bin/env ./usr/bin/bash ./usr/bin/sh ./usr/bin/dash ./usr/bin/python*
COPY packaging/debian ./DEBIAN
RUN chmod -R 755 ./DEBIAN
# Substitute the generated runtime dependencies, and refuse to build if the
# placeholder is still present (an empty/failed shlibdeps run must not ship).
COPY --from=builder /shlibdeps/depends.txt /shlibdeps.txt
RUN sed -i "s|@SHLIBS_DEPENDS@|$(cat /shlibdeps.txt)|" ./DEBIAN/control && \
    ! grep -q '@SHLIBS_DEPENDS@' ./DEBIAN/control && \
    grep '^Depends:' ./DEBIAN/control
# Ensure version consistency
RUN dpkg-deb --build . /cosmic-epoch-monorepo.deb

# Final stage: just for artifact extraction
FROM busybox
COPY --from=sysext /usr /usr
COPY --from=deb-packager /cosmic-epoch-monorepo.deb /cosmic-epoch-monorepo.deb

LABEL org.opencontainers.image.source="https://github.com/rickysarraf/desktop-brewery"
LABEL org.opencontainers.image.description="Debian COSMIC System Extension and .deb Package"
LABEL org.opencontainers.image.licenses="GPL-3.0"

CMD ["sh"]
