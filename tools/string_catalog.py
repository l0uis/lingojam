#!/usr/bin/env python3
"""Keep the app's String Catalogs in sync and translated without Xcode's IDE.

`xcodebuild` compiles `.xcstrings` but never writes newly extracted keys back
into them (only the IDE does), so this mirrors that step from the compiler's
`.stringsdata` output and adds an export/import loop for translations.

    # 1. Build once so the compiler emits .stringsdata, then sync keys:
    python3 tools/string_catalog.py sync --derived-data wordrus/build/dd

    # 2. Keys still missing a translation for a language, as JSON:
    python3 tools/string_catalog.py export --lang es > /tmp/es.json

    # 3. Merge translations back (same JSON shape, values filled in):
    python3 tools/string_catalog.py import --lang es /tmp/es.json

Export/import JSON: {catalog_path: {key: {"comment": str, "plural": bool,
"value": str | {"one": str, "other": str, ...}}}}. `plural` keys (those with
an integer format specifier) take a dict of CLDR categories; at minimum
"one" and "other". `en` plural variations are generated from the import too,
so pass `--lang en` with English one/other forms for count keys.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = {
    # catalog path → build-intermediates directory of the target that owns it
    ROOT / "wordrus" / "wordrus" / "Localizable.xcstrings": "wordrus.build",
    ROOT / "wordrus" / "WordrusWidget" / "Localizable.xcstrings": "WordrusWidgetExtension.build",
}
INT_SPECIFIER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|lu|llu|u)")


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def _xcode_json(value, indent: int = 0) -> str:
    """Xcode's catalog style: " : " separators, empty objects as "{\n\n}".
    Key order is preserved (new keys are appended); the IDE re-sorts on its
    next save, which this can't reproduce exactly."""
    pad = "  " * (indent + 1)
    if isinstance(value, dict):
        if not value:
            return "{\n\n" + "  " * indent + "}"
        items = [f"{pad}{json.dumps(k, ensure_ascii=False)} : {_xcode_json(v, indent + 1)}" for k, v in value.items()]
        return "{\n" + ",\n".join(items) + "\n" + "  " * indent + "}"
    if isinstance(value, list):
        if not value:
            return "[\n\n" + "  " * indent + "]"
        items = [pad + _xcode_json(v, indent + 1) for v in value]
        return "[\n" + ",\n".join(items) + "\n" + "  " * indent + "]"
    return json.dumps(value, ensure_ascii=False)


def save(path: Path, catalog: dict) -> None:
    path.write_text(_xcode_json(catalog), encoding="utf-8")  # Xcode omits the final newline


def extracted_keys(derived_data: Path, target_dir: str) -> dict[str, str]:
    """key → comment from every .stringsdata of one target (Localizable table)."""
    keys: dict[str, str] = {}
    pattern = f"Build/Intermediates.noindex/**/{target_dir}/**/*.stringsdata"
    for path in derived_data.glob(pattern):
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, UnicodeDecodeError):
            continue  # App Intents metadata etc. share the extension
        for entry in data.get("tables", {}).get("Localizable", []):
            key = entry.get("key")
            if key is not None:
                keys.setdefault(key, entry.get("comment") or "")
    return keys


def cmd_sync(args: argparse.Namespace) -> None:
    derived = Path(args.derived_data).resolve()
    for catalog_path, target_dir in CATALOGS.items():
        if not catalog_path.exists():
            continue
        catalog = load(catalog_path)
        strings = catalog.setdefault("strings", {})
        found = extracted_keys(derived, target_dir)
        if not found:
            print(f"{catalog_path.name} ({target_dir}): no .stringsdata found — build first", file=sys.stderr)
            continue
        added = stale = revived = 0
        for key, comment in found.items():
            entry = strings.get(key)
            if entry is None:
                strings[key] = {"comment": comment} if comment else {}
                added += 1
            else:
                if entry.get("extractionState") == "stale":
                    del entry["extractionState"]
                    revived += 1
                if comment and not entry.get("comment"):
                    entry["comment"] = comment
        for key, entry in strings.items():
            if key not in found and entry.get("extractionState") not in ("manual", "stale"):
                entry["extractionState"] = "stale"
                stale += 1
        save(catalog_path, catalog)
        live = sum(1 for e in strings.values() if e.get("extractionState") != "stale")
        print(f"{catalog_path.relative_to(ROOT)}: {live} live keys (+{added} new, {revived} revived, {stale} newly stale)")


def is_plural(key: str) -> bool:
    return bool(INT_SPECIFIER.search(key))


def has_translation(entry: dict, lang: str) -> bool:
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return False
    if "stringUnit" in loc:
        return bool(loc["stringUnit"].get("value"))
    return "variations" in loc


def cmd_export(args: argparse.Namespace) -> None:
    out: dict = {}
    for catalog_path in CATALOGS:
        if not catalog_path.exists():
            continue
        strings = load(catalog_path).get("strings", {})
        pending = {}
        for key, entry in sorted(strings.items()):
            if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
                continue
            if args.lang == "en" and not is_plural(key):
                continue  # the key is the English text
            if has_translation(entry, args.lang):
                continue
            pending[key] = {"comment": entry.get("comment", ""), "plural": is_plural(key), "value": None}
        if pending:
            out[str(catalog_path.relative_to(ROOT))] = pending
    json.dump(out, sys.stdout, ensure_ascii=False, indent=2)
    print()


def specifiers(s: str) -> list[str]:
    """Format specifiers with positional indices dropped (%1$@ ≡ %@)."""
    return sorted(re.sub(r"\d+\$", "", m) for m in re.findall(r"%(?:\d+\$)?(?:lld|ld|d|lu|llu|u|@|f|\.\d+f)", s))


def cmd_import(args: argparse.Namespace) -> None:
    payload = json.loads(Path(args.file).read_text(encoding="utf-8"))
    problems = 0
    for rel, entries in payload.items():
        catalog_path = ROOT / rel
        catalog = load(catalog_path)
        strings = catalog["strings"]
        written = 0
        for key, item in entries.items():
            value = item.get("value")
            if key not in strings or value in (None, "", {}):
                continue
            expected = specifiers(key)
            forms = value if isinstance(value, dict) else {"other": value}
            bad = [f for f, text in forms.items() if specifiers(text) != expected
                   and not (f == "one" and specifiers(text) == [s for s in expected if not INT_SPECIFIER.fullmatch(s)])]
            if bad:
                print(f"skip {args.lang} {key!r}: format specifiers differ in {bad}", file=sys.stderr)
                problems += 1
                continue
            locs = strings[key].setdefault("localizations", {})
            if isinstance(value, dict):
                locs[args.lang] = {"variations": {"plural": {
                    category: {"stringUnit": {"state": "translated", "value": text}}
                    for category, text in value.items()
                }}}
            else:
                locs[args.lang] = {"stringUnit": {"state": "translated", "value": value}}
            written += 1
        save(catalog_path, catalog)
        print(f"{rel}: wrote {written} {args.lang} translations")
    if problems:
        sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sync")
    s.add_argument("--derived-data", required=True)
    s.set_defaults(func=cmd_sync)
    e = sub.add_parser("export")
    e.add_argument("--lang", required=True)
    e.set_defaults(func=cmd_export)
    i = sub.add_parser("import")
    i.add_argument("--lang", required=True)
    i.add_argument("file")
    i.set_defaults(func=cmd_import)
    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
