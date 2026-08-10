VERSION := "1.5.0-1~local1"
BUILDER := "cosmic-builder"

# Ensure a buildx builder with a sane cache GC policy exists (see buildkitd.toml)
_ensure-builder:
    @docker buildx inspect {{BUILDER}} >/dev/null 2>&1 || \
        docker buildx create --name {{BUILDER}} --driver docker-container --config buildkitd.toml

# Build all COSMIC monorepo .deb packages
package-debs: _ensure-builder
    @echo "🏗️ Injecting version {{VERSION}}..."
    sed -i "s/@VERSION@/{{VERSION}}/g" images/cosmic-epoch/packaging/debian/control
    sed -i "s/@VERSION@/{{VERSION}}/g" images/cosmic-utils/packaging/debian/control
    @echo "🏗️ Building Cosmic Epoch monodeb..."
    docker buildx --builder {{BUILDER}} build --load -t cosmic-epoch-deb images/cosmic-epoch
    @echo "🏗️ Building Cosmic Utils monodeb..."
    docker buildx --builder {{BUILDER}} build --load -t cosmic-utils-deb images/cosmic-utils
    @echo "⏪ Restoring control files..."
    git checkout images/cosmic-epoch/packaging/debian/control images/cosmic-utils/packaging/debian/control
    mkdir -p dist
    @echo "📦 Extracting packages to ./dist/..."
    docker run --rm -v $(pwd)/dist:/dist cosmic-epoch-deb cp /cosmic-epoch-monorepo.deb /dist/
    docker run --rm -v $(pwd)/dist:/dist cosmic-utils-deb cp /cosmic-utils-monorepo.deb /dist/
    @echo "✅ Build complete. Packages located in ./dist/"

# Clean build artifacts
clean:
    rm -rf dist
