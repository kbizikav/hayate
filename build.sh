#!/bin/bash
# Build Hayate.app.  ./build.sh          -> build/Hayate.app
#                    ./build.sh install  -> also install to ~/Library/Input Methods and restart
set -euo pipefail
cd "$(dirname "$0")"
BUILD_DIR="${BUILD_DIR:-.build}"

swift build -c release --product Hayate --scratch-path "$BUILD_DIR"
BIN="$BUILD_DIR/release"
CONV="$BUILD_DIR/checkouts/AzooKeyKanaKanjiConverter/Sources/KanaKanjiConverterModuleWithDefaultDictionary"

mkdir -p models
[ -s models/zenz.gguf ] || curl -fL -o models/zenz.gguf \
  https://huggingface.co/Miwa-Keita/zenz-v3.2-small-gguf/resolve/main/ggml-model-Q5_K_M.gguf

APP=build/Hayate.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/Hayate" "$APP/Contents/MacOS/"
cp -R "$BIN"/*.framework "$APP/Contents/Frameworks/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/*.tiff "$APP/Contents/Resources/"
cp -R Resources/*.lproj "$APP/Contents/Resources/"
cp -R "$CONV/azooKey_dictionary_storage/Dictionary" "$APP/Contents/Resources/"
cp "$CONV/azooKey_emoji_dictionary_storage/EmojiDictionary/emoji_all_E16.0.txt" "$APP/Contents/Resources/emoji.txt"
cp models/zenz.gguf "$APP/Contents/Resources/"
codesign --force --deep --sign - "$APP"
echo "built $APP"

if [ "${1:-}" = install ]; then
  DEST="$HOME/Library/Input Methods/Hayate.app"
  # Update in place: never let the enabled input method's bundle vanish (a delete-then-copy
  # window can make macOS drop it from the enabled input sources).
  rsync -a --delete "$APP/" "$DEST/"
  pkill -x Hayate || true
  sleep 0.5
  open "$DEST"  # macOS does not launch a newly installed input method by itself until re-login
  echo "installed and started $DEST"
fi
