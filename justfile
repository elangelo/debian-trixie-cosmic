VERSION := "1.9.0-1~local1"
BUILDER := "cosmic-builder"

# Ensure a buildx builder with a sane cache GC policy exists (see buildkitd.toml)
_ensure-builder:
    @docker buildx inspect {{BUILDER}} >/dev/null 2>&1 || \
        docker buildx create --name {{BUILDER}} --driver docker-container --config buildkitd.toml

CONTROLS := "images/cosmic-epoch/packaging/debian/control images/cosmic-epoch/packaging/comp/debian/control images/cosmic-utils/packaging/debian/control"

# Build all COSMIC .deb packages (epoch, comp, utils)
package-debs: _ensure-builder
    @echo "🏗️ Injecting version {{VERSION}}..."
    sed -i "s/@VERSION@/{{VERSION}}/g" {{CONTROLS}}
    @echo "🏗️ Building Cosmic Epoch monodeb..."
    docker buildx --builder {{BUILDER}} build --load -t cosmic-epoch-deb images/cosmic-epoch
    @echo "🏗️ Building Cosmic Utils monodeb..."
    docker buildx --builder {{BUILDER}} build --load -t cosmic-utils-deb images/cosmic-utils
    @echo "⏪ Restoring control files..."
    git checkout {{CONTROLS}}
    mkdir -p dist
    @echo "📦 Extracting packages to ./dist/..."
    docker run --rm -v $(pwd)/dist:/dist cosmic-epoch-deb cp /cosmic-epoch-monorepo.deb /cosmic-epoch-comp.deb /dist/
    docker run --rm -v $(pwd)/dist:/dist cosmic-utils-deb cp /cosmic-utils-monorepo.deb /dist/
    @echo "✅ Build complete. Packages located in ./dist/"

# Clean build artifacts
clean:
    rm -rf dist

# Build only the cosmic-comp package (dist/cosmic-epoch-comp.deb)
package-comp: _ensure-builder
    sed -i "s/@VERSION@/{{VERSION}}/g" {{CONTROLS}}
    docker buildx --builder {{BUILDER}} build --load --target comp -t cosmic-comp-deb images/cosmic-epoch
    git checkout {{CONTROLS}}
    mkdir -p dist
    docker run --rm -v $(pwd)/dist:/dist cosmic-comp-deb cp /cosmic-epoch-comp.deb /dist/
    @echo "✅ dist/cosmic-epoch-comp.deb -- sudo apt install ./dist/cosmic-epoch-comp.deb, then log out and back in"

# --- working on cosmic-comp patches --------------------------------------------
# An editable cosmic-comp checkout for writing patches; `just package-comp` builds
# from the exported patch files, not from this checkout.

COMP_SRC := "work/cosmic-comp"
COMP_PATCHES := "images/cosmic-epoch/patches/submodules"

# Create work/cosmic-comp at the commit cosmic-epoch pins, with our patches as commits
comp-checkout:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -d {{COMP_SRC}} ]; then echo "{{COMP_SRC}} exists; remove it to start over"; exit 0; fi
    tag=$(grep -oP -- '^\s+git clone --recursive --branch \Kepoch-[0-9.]+' images/cosmic-epoch/Dockerfile)
    sha=$(curl -fsS "https://api.github.com/repos/pop-os/cosmic-epoch/contents/cosmic-comp?ref=$tag" \
        | grep -oP '"sha": "\K[0-9a-f]{40}')
    echo "==> cosmic-comp @ $sha (pinned by $tag)"
    git clone https://github.com/pop-os/cosmic-comp.git {{COMP_SRC}}
    git -C {{COMP_SRC}} checkout -q -B debian-cosmic "$sha"
    git -C {{COMP_SRC}} tag -f pinned "$sha"
    for pf in $(ls {{COMP_PATCHES}}/cosmic-comp-*.patch 2>/dev/null | sort); do
        echo "==> $(basename "$pf")"
        patch -p1 --fuzz=0 -d {{COMP_SRC}} < "$pf"
        subject=$(grep -m1 '^Subject:' "$pf" | sed -E 's/^Subject: (\[PATCH[^]]*\] )?//')
        git -C {{COMP_SRC}} add -A
        git -C {{COMP_SRC}} commit -q -m "$subject" -m "Imported from $(basename "$pf")"
    done
    git -C {{COMP_SRC}} tag -f imported
    git -C {{COMP_SRC}} log --oneline pinned..HEAD

# Write commits made on top of the imported patches to patches/submodules/
comp-export:
    #!/usr/bin/env bash
    set -euo pipefail
    n=$(ls {{COMP_PATCHES}}/cosmic-comp-*.patch 2>/dev/null | wc -l)
    git -C {{COMP_SRC}} format-patch --no-signature --zero-commit --start-number $((n + 1)) \
        -o "$PWD/{{COMP_PATCHES}}" imported..HEAD \
        | while read -r f; do
            new="$(dirname "$f")/cosmic-comp-$(basename "$f")"
            mv "$f" "$new"; echo "wrote $new"
          done
    git -C {{COMP_SRC}} tag -f imported HEAD
