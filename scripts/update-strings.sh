#!/bin/zsh
# Re-extracts user-facing strings from the Swift sources into Resources/Localizable.xcstrings.
# New strings appear untranslated (open the catalog in Xcode, or edit the JSON, to translate them);
# strings no longer used are marked stale. Run after adding or changing UI text.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT
# Rebuild from scratch so every file is compiled and emits its strings.
rm -rf .build/debug/RcloneGUI.build
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT"
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$OUT"/*.stringsdata

# List what still needs a Simplified Chinese translation.
python3 - <<'PY'
import json
d = json.load(open("Resources/Localizable.xcstrings"))
todo = [k for k, v in d["strings"].items()
        if v.get("shouldTranslate", True) and v.get("extractionState") != "stale"
        and "zh-Hans" not in v.get("localizations", {})]
print(f"{len(todo)} string(s) need a zh-Hans translation" + (":" if todo else "."))
for k in todo: print("  " + k)
PY
