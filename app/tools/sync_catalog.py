#!/usr/bin/env python3
"""Adds every string the compiler extracted (SWIFT_EMIT_LOC_STRINGS=YES builds of both app
targets) to Localizable.xcstrings without touching existing translations, and marks keys no
build found as stale. Xcode does the same on build in the IDE; this is for the command line.

    xcodebuild -project LofiBossa.xcodeproj -scheme LofiBossaiOS -destination 'generic/platform=iOS Simulator' build SWIFT_EMIT_LOC_STRINGS=YES
    xcodebuild -project LofiBossa.xcodeproj -scheme LofiBossa -destination 'platform=macOS' build SWIFT_EMIT_LOC_STRINGS=YES
    python3 tools/sync_catalog.py
"""
import glob, json, os, sys

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCES = os.path.realpath(os.path.join(HERE, "..", "Sources")) + os.sep
CATALOG = os.path.join(HERE, "..", "Localizable.xcstrings")
# Names looked up at runtime (enum raw values, instrument names), so no literal for the
# compiler to find. Kept here so the sync doesn't mark them stale.
MANUAL = [l.strip() for l in open(os.path.join(HERE, "manual_keys.txt"), encoding="utf-8") if l.strip()]

def extracted():
    keys = set()
    pattern = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/LofiBossa-*/Build/Intermediates.noindex/LofiBossa.build/*/*.build/Objects-normal/*/*.stringsdata")
    for f in glob.glob(pattern):
        d = json.load(open(f))
        # DerivedData folders of other checkouts of this project match the glob too.
        if not os.path.realpath(d["source"]).startswith(SOURCES):
            continue
        for table, items in d["tables"].items():
            if table == "Localizable":
                keys.update(i["key"] for i in items if i["key"])
    return keys

def main():
    cat = json.load(open(CATALOG, encoding="utf-8"))
    strings = cat["strings"]
    found = extracted() | set(MANUAL)
    for k in sorted(found):
        entry = strings.setdefault(k, {})
        if k in MANUAL:
            entry["extractionState"] = "manual"
        else:
            entry.pop("extractionState", None)
    for k, entry in strings.items():
        if k not in found:
            entry["extractionState"] = "stale"
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(cat, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"{len(found)} keys, {sum(1 for e in strings.values() if e.get('extractionState') == 'stale')} stale")

if __name__ == "__main__":
    sys.exit(main())
