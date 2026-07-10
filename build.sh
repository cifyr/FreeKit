#!/bin/bash
# FreeSpeech build: vendors whisper.cpp, runs tests, produces dist/FreeSpeech.app,
# and fetches the default whisper model (the only network access, one-time).
# Usage: ./build.sh [--skip-model] [--model base.en|small.en|...]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WHISPER_TAG="v1.9.1"
WHISPER_DIR="$ROOT/vendor/whisper.cpp"
LIB_DIR="$ROOT/vendor/lib"
MODEL_NAME="large-v3-turbo-q5_0"
SKIP_MODEL=0
MODELS_DIR="$HOME/Library/Application Support/FreeSpeech/models"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-model) SKIP_MODEL=1; shift ;;
        --model) MODEL_NAME="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

for tool in git cmake swift codesign; do
    command -v "$tool" >/dev/null || { echo "error: '$tool' not found — install Xcode command line tools (and cmake via 'brew install cmake')" >&2; exit 1; }
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

LINKER_FLAGS=()
for lib in "$LIB_DIR"/*.a; do
    LINKER_FLAGS+=(-Xlinker "$lib")
done

echo "==> Running unit tests"
(cd "$ROOT" && swift test "${LINKER_FLAGS[@]}")

echo "==> Building FreeSpeech (release)"
(cd "$ROOT" && swift build -c release "${LINKER_FLAGS[@]}")

echo "==> Assembling dist/FreeSpeech.app"
APP="$ROOT/dist/FreeSpeech.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/.build/release/FreeSpeech" "$APP/Contents/MacOS/FreeSpeech"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# Icon is pre-generated from assets/logo.svg (qlmanage render + iconutil) and
# committed, so the build has no fragile SVG-rendering dependency.
cp "$ROOT/Resources/FreeSpeech.icns" "$APP/Contents/Resources/FreeSpeech.icns"
# Prefer the stable "FreeSpeech Dev" self-signed identity when present: TCC ties
# permissions to the signing certificate, so Accessibility/Screen Recording
# grants survive rebuilds. Ad-hoc fallback re-prompts after every rebuild.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "FreeSpeech Dev"; then
    echo "==> Signing with FreeSpeech Dev identity (permissions persist across rebuilds)"
    codesign --force --sign "FreeSpeech Dev" --identifier com.cadenwarren.freespeech "$APP"
else
    echo "==> Signing ad-hoc (Accessibility must be re-granted after each rebuild)"
    codesign --force --sign - --identifier com.cadenwarren.freespeech "$APP"
fi

if [[ "$SKIP_MODEL" -eq 0 ]]; then
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
echo "Build complete: $APP"
echo "Run with: open \"$APP\"   (grant Microphone + Accessibility on first run)"
echo "Default hotkey: hold Right Option to dictate."
