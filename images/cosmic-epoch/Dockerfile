# syntax=docker/dockerfile:1
# Stage 1: Builder
FROM debian:trixie AS builder

ENV DEBIAN_FRONTEND=noninteractive

# 1. Add stable build dependencies
RUN apt-get update && apt-get install -y \
    build-essential git just curl pkg-config \
    libpipewire-0.3-dev libspa-0.2-dev libwayland-dev libxkbcommon-dev \
    libinput-dev libseat-dev libudev-dev libgbm-dev libdrm-dev \
    libdbus-1-dev libpam0g-dev libfontconfig-dev libfreetype-dev \
    libpolkit-gobject-1-dev libgudev-1.0-dev libglib2.0-dev \
    libjson-glib-dev libpulse-dev libasound2-dev libssl-dev \
    libflatpak-dev libarchive-dev libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev clang llvm-dev cmake \
    libpixman-1-dev libwayland-bin libdisplay-info-dev libxcb-xinput-dev libdav1d-dev \
    wayland-protocols extra-cmake-modules scdoc sed make libclang-dev \
    gtk-update-icon-cache hicolor-icon-theme bsdextrautils \
    && rm -rf /var/lib/apt/lists/*

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
    git clone --recursive --branch epoch-1.5.0 https://github.com/pop-os/cosmic-epoch.git . && \
    # Patch: xdg-desktop-portal-cosmic dropped its Makefile in epoch-1.2.0 and migrated to justfile.
    # The upstream cosmic-epoch justfile still calls `make -C xdg-desktop-portal-cosmic`, so we
    # replace those calls with the equivalent `just` invocations.
    sed -i \
        -e 's|{{ make }} -C xdg-desktop-portal-cosmic all|{{ just }} xdg-desktop-portal-cosmic/build|g' \
        -e 's|{{ make }} -C xdg-desktop-portal-cosmic install DESTDIR={{rootdir}} prefix={{prefix}}|{{ just }} rootdir={{rootdir}} prefix={{prefix}} xdg-desktop-portal-cosmic/install|g' \
        justfile

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
