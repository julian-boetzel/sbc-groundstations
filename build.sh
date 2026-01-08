#!/bin/bash

# Useful make targets
# make menuconfig
# make uboot-menuconfig
# make savedefconfig
# make runcam_wifilink_defconfig
# make O=/tmp/buildroot-sbc-gs-output BR2_EXTERNAL=$PWD -C buildroot all

set -e

# Default configuration
BUILDROOT_VERSION="2025.08.1"
BUILDROOT_SOURCE="https://buildroot.org/downloads/buildroot-${BUILDROOT_VERSION}.tar.gz"
BUILDROOT_DIR="buildroot"
BUILDROOT_TARBALL="buildroot-${BUILDROOT_VERSION}.tar.gz"
DEFCONFIG="${DEFCONFIG:-runcam_wifilink_defconfig}"
mkdir -p board/local/overlay/etc/network/interfaces.d

# Parse command line options
OUTPUT_DIR="$(pwd)/output"
TARGET="all"
while getopts "o:h" opt; do
    case $opt in
        o)
            OUTPUT_DIR="$OPTARG"
            ;;
        h)
            echo "Usage: $0 [-o output-dir] [target, default all]"
            echo "  -o output-dir  Buildroot O= output directory"
            echo "  -h             Show this help"
            echo ""
            echo "Targets:"
            echo "  all                 Full build (default)"
            echo "  pixelpilot_fast      Rebuild PixelPilot + regenerate rootfs/images + package tar"
            exit 0
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            exit 1
            ;;
    esac
done

shift $((OPTIND-1))
if [ $# -gt 0 ]; then
    TARGET="$1"
fi

# Function to download and extract Buildroot
setup_buildroot() {
    if [ ! -d "$BUILDROOT_DIR" ]; then
        echo "Downloading Buildroot ${BUILDROOT_VERSION}..."
        if command -v wget >/dev/null 2>&1; then
            wget "$BUILDROOT_SOURCE" -O "$BUILDROOT_TARBALL"
        elif command -v curl >/dev/null 2>&1; then
            curl -L -o "$BUILDROOT_TARBALL" "$BUILDROOT_SOURCE"
        else
            echo "Error: Neither wget nor curl found. Please install one of them."
            exit 1
        fi

        echo "Extracting Buildroot..."
        tar -xzf "$BUILDROOT_TARBALL"
        rm "$BUILDROOT_TARBALL"
        mv "buildroot-${BUILDROOT_VERSION}" "$BUILDROOT_DIR"
    else
        echo "Buildroot source already exists at $BUILDROOT_DIR"
    fi
}

# Find the PixelPilot Buildroot package name
detect_pixelpilot_pkg() {
    # Adjust candidates if your package has a different name
    local candidates=("pixelpilot-rk" "pixelpilot")
    for pkg in "${candidates[@]}"; do
        if grep -R --line-number -E "^${pkg}[[:space:]]" "$OUTPUT_DIR/$DEFCONFIG/.config" >/dev/null 2>&1; then
            echo "$pkg"
            return 0
        fi
        # Fallback: check if Buildroot knows this target by asking make help-ish (cheap)
        # Not all buildroot versions expose it, so we just test if a package directory exists in BR2_EXTERNAL
        if find "$(pwd)" -maxdepth 4 -type f -name "${pkg}.mk" | grep -q .; then
            echo "$pkg"
            return 0
        fi
    done
    return 1
}

package_images() {
    cd "$OUTPUT_DIR/$DEFCONFIG/images"
    cp u-boot-rockchip.bin u-boot.bin

    for file in sdcard.img u-boot.bin emmc_bootloader.img rootfs.squashfs ; do
        if [ -f "$file" ]; then
            cp "$file" "$(basename $DEFCONFIG _defconfig)_${file}"
        fi
    done

    md5sum rootfs.squashfs > rootfs.squashfs.md5sum
    md5sum u-boot.bin > u-boot.bin.md5sum
    tar zcvf "$(basename $DEFCONFIG _defconfig)".tar.gz rootfs.squashfs u-boot.bin *.md5sum
    cd - >/dev/null
}

# Function to build the project
build_project() {
    local build_cmd=""

    echo "Using output directory: $OUTPUT_DIR/$DEFCONFIG"
    build_cmd="make -C $BUILDROOT_DIR O=$OUTPUT_DIR/$DEFCONFIG"
    mkdir -p "$OUTPUT_DIR"

    # Check if we're in a BR_EXTERNAL directory
    if [ ! -f "external.mk" ] && [ ! -f "external.desc" ]; then
        echo "Warning: This doesn't appear to be a BR_EXTERNAL directory"
        echo "Make sure you're running this script from your BR_EXTERNAL project root"
    fi

    # Set BR2_EXTERNAL to current directory
    export BR2_EXTERNAL=$(pwd)
    echo "Building with BR2_EXTERNAL=$BR2_EXTERNAL"

    # Always ensure defconfig is applied unless we're explicitly saving it
    if [ "$TARGET" != "savedefconfig" ]; then
        echo "Running defconfig: $DEFCONFIG"
        $build_cmd "$DEFCONFIG"
    fi

    if [ "$TARGET" = "pixelpilot_fast" ]; then
        echo "Fast path: rebuild PixelPilot and regenerate images"

        # Detect package name (adjust candidates above if needed)
        local pixelpkg=""
        if pixelpkg=$(detect_pixelpilot_pkg); then
            echo "Detected PixelPilot package: $pixelpkg"
        else
            echo "ERROR: Could not detect PixelPilot Buildroot package name."
            echo "Search your BR2_EXTERNAL for the package .mk file and update detect_pixelpilot_pkg candidates."
            echo "Tip: grep -R -i pixelpilot . | head"
            exit 1
        fi

        # Rebuild and reinstall PixelPilot into target rootfs
        $build_cmd "${pixelpkg}-dirclean"
        $build_cmd "${pixelpkg}"
        $build_cmd "${pixelpkg}-reinstall"

        # Regenerate rootfs + images; keep this minimal but reliable.
        # These targets exist in standard Buildroot flows.
        $build_cmd target-finalize
        $build_cmd rootfs-squashfs || true
        $build_cmd legal-info || true

        # Image generation can be board-specific; "all" is safest but may rebuild too much.
        # Prefer explicit image targets if present; fall back to "all".
        if $build_cmd -n sdcard.img >/dev/null 2>&1; then
            $build_cmd sdcard.img
        else
            # fallback to full image generation (should be faster with caches)
            $build_cmd all
        fi

        package_images
        echo "Fast build completed successfully!"
        return 0
    fi

    # Default behavior: Run full make target
    echo "Starting build..."
    $build_cmd "$TARGET"

    if [ "$TARGET" = "all" ]; then
        package_images
    fi

    echo "Build completed successfully!"
}

# Main execution
main() {
    echo "Starting Buildroot build for $DEFCONFIG"

    setup_buildroot
    build_project
}

main "$@"
