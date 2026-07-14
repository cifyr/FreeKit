#!/bin/bash
# Package FreeKit for sharing. Run ./build.sh first.
#   ./package.sh              -> full zip: app + recommended model (~510MB), works offline
#   ./package.sh --app-only   -> lite zip: app only (~4MB), model self-downloads on first run
#   ./package.sh --model NAME  -> choose which model to bundle (full mode)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$ROOT/dist/FreeKit.app"
MODEL_NAME="large-v3-turbo-q5_0"
MODELS_SRC="$HOME/Library/Application Support/FreeKit/models"
APP_ONLY=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-only) APP_ONLY=1; shift ;;
        --model) MODEL_NAME="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[[ -d "$APP" ]] || { echo "error: $APP not found — run ./build.sh first" >&2; exit 1; }

if [[ "$APP_ONLY" -eq 1 ]]; then
    STAGE="$ROOT/dist/FreeKit-share-lite"; ZIP="$ROOT/dist/FreeKit-share-lite.zip"
else
    STAGE="$ROOT/dist/FreeKit-share"; ZIP="$ROOT/dist/FreeKit-share.zip"
    MODEL_FILE="$MODELS_SRC/ggml-$MODEL_NAME.bin"
    [[ -f "$MODEL_FILE" ]] || { echo "error: model $MODEL_FILE not found — run ./build.sh --model $MODEL_NAME" >&2; exit 1; }
fi

echo "==> Staging share bundle"
rm -rf "$STAGE" "$ZIP"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/FreeKit.app"
if [[ "$APP_ONLY" -eq 0 ]]; then
    mkdir -p "$STAGE/models"
    cp "$MODEL_FILE" "$STAGE/models/"
fi

echo "==> Writing install.command"
cat > "$STAGE/install.command" <<'INSTALL'
#!/bin/bash
# FreeKit installer: copies the app to /Applications, clears the download quarantine,
# installs a bundled model if present, and launches. Requires Apple Silicon + macOS 26.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "Installing FreeKit..."
DEST="/Applications/FreeKit.app"
[[ -w /Applications ]] || DEST="$HOME/Applications/FreeKit.app"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$DIR/FreeKit.app" "$DEST"

# Strip the quarantine flag so Gatekeeper allows the unsigned app to open.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

if compgen -G "$DIR/models/*.bin" > /dev/null; then
    MODELS="$HOME/Library/Application Support/FreeKit/models"
    mkdir -p "$MODELS"
    cp "$DIR/models/"*.bin "$MODELS/"
    echo "Installed bundled speech model."
else
    echo "No bundled model — FreeKit downloads it on first launch (needs internet once)."
fi

echo "Installed to $DEST"
echo "Launching — grant Microphone and Accessibility when prompted."
open "$DEST"
INSTALL
chmod +x "$STAGE/install.command"

echo "==> Writing README"
cp "$ROOT/INSTALL.md" "$STAGE/INSTALL.md" 2>/dev/null || true

echo "==> Zipping"
( cd "$ROOT/dist" && zip -qr -X "$(basename "$ZIP")" "$(basename "$STAGE")" )
rm -rf "$STAGE"

SIZE="$(du -h "$ZIP" | cut -f1)"
echo
echo "Done: $ZIP ($SIZE)"
echo "Send via AirDrop, Google Drive, or WeTransfer."
echo "Friend: unzip, right-click install.command > Open, grant permissions."
