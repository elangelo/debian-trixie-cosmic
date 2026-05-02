# 🌌 Debian COSMIC

Welcome to the standalone **Debian COSMIC** project. This repository provides a unified delivery pipeline for the [System76 COSMIC Desktop Environment](https://github.com/pop-os/cosmic) on Debian Testing (Trixie) and Unstable (Sid).

By carving this out of the Desktop Brewery, we ensure dedicated attention to the unique packaging and delivery needs of COSMIC on Debian.

---

## 🏗️ Delivery Formats

We provide two primary delivery formats to cater to different user needs:

### 1. Monorepo .deb Packages
Unified Debian packages for traditional installation.
- **`cosmic-epoch-monorepo`**: The full Core DE stack (Compositor, Panel, Settings, etc.).
- **`cosmic-utils-monorepo`**: The community utilities stack (Tweaks, Vigil, Chronos, etc.).

### 2. System Extensions (`sysext`)
Optimized OCI images for `systemd-sysext`, allowing you to run COSMIC without polluting your host's `/usr`.
- Delivered via the GitHub Container Registry (GHCR).

---

## 🛠️ Getting Started

### Prerequisites
- **Debian Testing or Sid** host.
- **systemd** >= 248 (for sysext).
- **Docker** (for `cosmic-update` and local builds).

### Building Locally
You can build the monorepo packages locally using the provided `justfile`:
```bash
# Build and extract .debs to ./dist/
just package-debs
```

### Installation
For detailed instructions on using the `sysext` approach with `cosmic-toggle` and `cosmic-update`, see the `bin/` directory documentation.

---

## 🤝 Contributing
We use a **"Sanitized Host"** principle. All development and builds must occur in isolated environments (Docker or chroot) to prevent host contamination.

See `GEMINI.md` for core mandates and technical architecture.
