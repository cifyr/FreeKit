#!/bin/bash
# FreeKit build: vendors whisper.cpp, runs tests, produces dist/FreeKit.app,
# and fetches the default whisper model (the only network access, one-time).
# Usage: ./build.sh [--skip-model] [--model base.en|small.en|...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHISPER_TAG="v1.9.1"
WHISPER_DIR="$ROOT/vendor/whisper.cpp"
LIB_DIR="$ROOT/vendor/lib"
IMD_INCLUDE_DIR="$ROOT/Sources/CIMobileDevice/include"
MODEL_NAME="large-v3-turbo-q5_0"
SKIP_MODEL=0
MODELS_DIR="$HOME/Library/Application Support/FreeKit/models"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-model) SKIP_MODEL=1; shift ;;
        --model) MODEL_NAME="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for tool in git cmake swift codesign brew; do
    command -v "$tool" >/dev/null || { echo "error: '$tool' not found — install Xcode command line tools (and cmake/brew)" >&2; exit 1; }
done

# iPhone/iPad/Watch battery (Devices module) links against Homebrew's libimobiledevice —
# vendored below the same way whisper.cpp is, but as dylibs (LGPL-2.1: dynamic linking
# keeps the library independently replaceable, the standard compliance path for a
# closed-source app).
IMD_PKGS=(libimobiledevice libimobiledevice-glue libplist libusbmuxd libtatsu "openssl@3")
for pkg in "${IMD_PKGS[@]}"; do
    brew --prefix "$pkg" >/dev/null 2>&1 || {
        echo "error: Homebrew package '$pkg' not found — run 'brew install libimobiledevice' (pulls in the rest)" >&2
        exit 1
    }
done

if [[ ! -d "$WHISPER_DIR" ]]; then
    echo "==> Cloning whisper.cpp $WHISPER_TAG"
    git clone --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp "$WHISPER_DIR"
fi

if [[ ! -f "$LIB_DIR/libwhisper.a" ]]; then
    echo "==> Building whisper.cpp static libraries (Metal, release)"
    cmake -S "$WHISPER_DIR" -B "$WHISPER_DIR/build" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
        -DBUILD_SHARED_LIBS=OFF \
        -DGGML_METAL=ON \
        -DGGML_METAL_EMBED_LIBRARY=ON \
        -DWHISPER_BUILD_EXAMPLES=OFF \
        -DWHISPER_BUILD_TESTS=OFF
    cmake --build "$WHISPER_DIR/build" -j
    mkdir -p "$LIB_DIR"
    find "$WHISPER_DIR/build" -name '*.a' -exec cp {} "$LIB_DIR/" \;
fi

echo "==> Copying whisper headers into Sources/CWhisper/include"
cp "$WHISPER_DIR/include/whisper.h" "$WHISPER_DIR"/ggml/include/*.h "$ROOT/Sources/CWhisper/include/"

echo "==> Copying libimobiledevice headers into Sources/CIMobileDevice/include"
mkdir -p "$IMD_INCLUDE_DIR/libimobiledevice" "$IMD_INCLUDE_DIR/plist"
IMD_HEADER_PREFIX="$(brew --prefix libimobiledevice)"
cp "$IMD_HEADER_PREFIX/include/libimobiledevice/libimobiledevice.h" \
   "$IMD_HEADER_PREFIX/include/libimobiledevice/lockdown.h" \
   "$IMD_HEADER_PREFIX/include/libimobiledevice/companion_proxy.h" \
   "$IMD_INCLUDE_DIR/libimobiledevice/"
cp "$(brew --prefix libplist)/include/plist/plist.h" "$IMD_INCLUDE_DIR/plist/"

if [[ ! -f "$LIB_DIR/.imobiledevice-vendored" ]]; then
    echo "==> Vendoring libimobiledevice dylibs (dynamic, LGPL-2.1 compliance)"
    mkdir -p "$LIB_DIR"
    # (brew package, filename glob within its lib/, matched against the physical file —
    # not brew's unversioned symlink — so the copy is self-contained).
    IMD_LIB_SPECS=(
        "libimobiledevice:libimobiledevice-1.0.*.dylib"
        "libimobiledevice-glue:libimobiledevice-glue-1.0.*.dylib"
        "libplist:libplist-2.0.*.dylib"
        "libusbmuxd:libusbmuxd-2.0.*.dylib"
        "libtatsu:libtatsu.*.dylib"
        "openssl@3:libssl.3.dylib"
        "openssl@3:libcrypto.3.dylib"
    )
    IMD_VENDORED_NAMES=()
    for spec in "${IMD_LIB_SPECS[@]}"; do
        pkg="${spec%%:*}"; pattern="${spec#*:}"
        prefix="$(brew --prefix "$pkg")"
        src="$(find "$prefix/lib" -maxdepth 1 -name "$pattern" ! -type l | sort | head -1)"
        [[ -n "$src" ]] || { echo "error: no dylib matching '$pattern' under $prefix/lib" >&2; exit 1; }
        name="$(basename "$src")"
        cp "$src" "$LIB_DIR/$name"
        IMD_VENDORED_NAMES+=("$name")
    done
    # Rewrite each vendored dylib's own id and its references to its siblings from the
    # absolute Homebrew path to @rpath, so the app doesn't hardcode /opt/homebrew paths.
    # Homebrew isn't internally consistent about which path form (the "opt/<pkg>"
    # symlink vs. the resolved "Cellar/<pkg>/<version>" path) a given dylib uses for
    # its own -id vs. how *other* dylibs reference it — so rather than precompute an
    # expected original path, read each dylib's own recorded dependency paths and
    # rewrite whichever ones match a vendored sibling's filename.
    for name in "${IMD_VENDORED_NAMES[@]}"; do
        lib="$LIB_DIR/$name"
        install_name_tool -id "@rpath/$name" "$lib"
        while IFS= read -r dep; do
            dep_base="$(basename "$dep")"
            for sibling in "${IMD_VENDORED_NAMES[@]}"; do
                [[ "$dep_base" == "$sibling" ]] || continue
                install_name_tool -change "$dep" "@rpath/$sibling" "$lib" 2>/dev/null || true
            done
        done < <(otool -L "$lib" | tail -n +2 | awk '{print $1}')
        # install_name_tool invalidates Homebrew's original signature; an unsigned
        # dylib gets SIGKILLed (Code Signature Invalid) the moment anything loads it,
        # including a plain local `swift test`/`swift build` run — ad-hoc-sign it back.
        codesign --force --sign - "$lib"
    done
    touch "$LIB_DIR/.imobiledevice-vendored"
fi

LINKER_FLAGS=()
for lib in "$LIB_DIR"/*.a "$LIB_DIR"/*.dylib; do
    [[ -e "$lib" ]] || continue
    LINKER_FLAGS+=(-Xlinker "$lib")
done
# @rpath candidates for the FreeKit binary: vendor/lib resolves the vendored dylibs
# when running straight out of .build (swift test / swift build), Frameworks resolves
# them once the binary is copied into dist/FreeKit.app below.
LINKER_FLAGS+=(-Xlinker -rpath -Xlinker "$LIB_DIR")
LINKER_FLAGS+=(-Xlinker -rpath -Xlinker "@executable_path/../Frameworks")

# The vendored libimobiledevice/plist headers use <libimobiledevice/...> / <plist/...>
# angle-bracket includes (matching Homebrew's own layout), which need this directory
# on the Clang search path — SPM's automatic per-target include dir only covers the
# systemLibrary's own umbrella header, not angle-bracket lookups from within it.
CC_FLAGS=(-Xcc "-I$IMD_INCLUDE_DIR")

echo "==> Running unit tests"
(cd "$ROOT" && swift test "${LINKER_FLAGS[@]}" "${CC_FLAGS[@]}")

echo "==> Building FreeKit (release)"
(cd "$ROOT" && swift build -c release "${LINKER_FLAGS[@]}" "${CC_FLAGS[@]}")

echo "==> Assembling dist/FreeKit.app"
APP="$ROOT/dist/FreeKit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/FreeKit" "$APP/Contents/MacOS/FreeKit"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Icon is pre-generated from assets/logo.svg (qlmanage render + iconutil) and
# committed, so the build has no fragile SVG-rendering dependency.
cp "$ROOT/Resources/FreeKit.icns" "$APP/Contents/Resources/FreeKit.icns"
# libimobiledevice's LGPL-2.1 text, bundled alongside its dylibs for attribution.
cp "$ROOT/Resources/libimobiledevice-COPYING.txt" "$APP/Contents/Resources/libimobiledevice-COPYING.txt"
# Record where this build came from so the in-app updater can fetch/pull/rebuild.
SOURCE_REV="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)"
plutil -replace FSSourceRevision -string "$SOURCE_REV" "$APP/Contents/Info.plist"
plutil -replace FSSourcePath -string "$ROOT" "$APP/Contents/Info.plist"

echo "==> Embedding libimobiledevice dylibs into dist/FreeKit.app"
mkdir -p "$APP/Contents/Frameworks"
cp "$LIB_DIR"/*.dylib "$APP/Contents/Frameworks/"

# Prefer the stable "FreeSpeech Dev" self-signed identity when present: TCC ties
# permissions to the signing certificate, so Accessibility/Screen Recording
# grants survive rebuilds. Ad-hoc fallback re-prompts after every rebuild.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "FreeSpeech Dev"; then
    SIGN_IDENTITY="FreeSpeech Dev"
    echo "==> Signing with FreeSpeech Dev identity (permissions persist across rebuilds)"
else
    SIGN_IDENTITY="-"
    echo "==> Signing ad-hoc (Accessibility must be re-granted after each rebuild)"
fi
# Embedded dylibs need their own signature — codesigning the app bundle afterward
# doesn't recursively sign loose files dropped into Frameworks/.
for dylib in "$APP/Contents/Frameworks"/*.dylib; do
    codesign --force --sign "$SIGN_IDENTITY" "$dylib"
done
codesign --force --sign "$SIGN_IDENTITY" --identifier com.cadenwarren.freekit "$APP"

# Install: keep /Applications current so the copy Caden actually runs is always
# the latest signed build. A running instance keeps its old code until relaunch.
INSTALL_APP="/Applications/FreeKit.app"
echo "==> Installing to $INSTALL_APP"
rm -rf "$INSTALL_APP"
cp -R "$APP" "$INSTALL_APP"
# Remove the old product name after the renamed app is safely installed.
rm -rf "/Applications/FreeSpeech.app"

if [[ "$SKIP_MODEL" -eq 0 ]]; then
    # Carry over a pre-rename "FreeSpeech" app-support dir (already-downloaded models
    # included) so a first post-rename build doesn't re-download ~1.6GB. The app itself
    # does the same migration at launch (AppPaths.migrateLegacyDirectoryIfNeeded); this
    # covers the case where build.sh runs before the app has ever launched once.
    LEGACY_SUPPORT="$HOME/Library/Application Support/FreeSpeech"
    NEW_SUPPORT="$HOME/Library/Application Support/FreeKit"
    if [[ ! -d "$NEW_SUPPORT" && -d "$LEGACY_SUPPORT" ]]; then
        echo "==> Migrating $LEGACY_SUPPORT -> $NEW_SUPPORT"
        mv "$LEGACY_SUPPORT" "$NEW_SUPPORT"
    fi
    MODEL_FILE="$MODELS_DIR/ggml-$MODEL_NAME.bin"
    if [[ ! -f "$MODEL_FILE" ]]; then
        # Official ggml conversions hosted by the whisper.cpp author.
        MODEL_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-$MODEL_NAME.bin"
        echo "==> Downloading model $MODEL_NAME (one-time) from $MODEL_URL"
        mkdir -p "$MODELS_DIR"
        curl -L --fail --progress-bar -o "$MODEL_FILE.part" "$MODEL_URL"
        mv "$MODEL_FILE.part" "$MODEL_FILE"
    else
        echo "==> Model $MODEL_NAME already present, skipping download"
    fi
fi

echo
echo "Build complete: $APP (installed to $INSTALL_APP)"
echo "Run with: open \"$INSTALL_APP\"   (grant Microphone + Accessibility on first run)"
echo "Default hotkey: hold Right Option to dictate."
