"""Shared scaffolding for building per-language vocabulary seeds.

Each language has its own build script (build_dataset.py for Spanish,
build_french.py / build_italian.py / build_german.py for the others) that
defines:
  - ENTRIES: a frequency-ordered list of (lemma, part_of_speech,
    english_gloss, native_example, english_translation) tuples
  - TOPIC_DECKS: a dict mapping deck slug → {"lemmas": [...], "new_entries": [...]}
  - DECK_DEFINITIONS: optional override; defaults to DEFAULT_DECKS below

…then calls `build_dataset(...)` to write the seed JSON.

The output schema matches what `SeedDataLoader.swift` expects:
  - `version: 3`
  - `language: "es" | "fr" | "it" | "de"`
  - `decks: [...]`
  - `words: [{ id, rank, lemma, partOfSpeech, definitions, example, decks, cefrLevel }]`

`example.text` carries the native-language sentence; the loader's
SeedExample decoder also accepts the legacy per-language keys (`es`, `fr`,
`it`, `de`) for backward compatibility.
"""

from __future__ import annotations

import glob
import json
from pathlib import Path
from typing import Iterable

# The visible deck taxonomy that ships in the seed JSON.
# `common` is intentionally NOT in this list: it stays as a hidden catch-all
# tag on words (every frequency-list word gets it by default) so they're
# visible under "All Words" without polluting the picker. The Swift app
# iterates this `decks` array to build the gallery, so anything here shows
# up as a filter chip.
DEFAULT_DECKS = [
    {
        "slug": "traveling",
        "displayName": "Traveling",
        "description": "Trips, hotels, airports, tickets.",
        "icon": "airplane",
        "sortOrder": 10,
    },
    {
        "slug": "food-and-drink",
        "displayName": "Food & Drink",
        "description": "Groceries, cooking, ingredients.",
        "icon": "fork.knife",
        "sortOrder": 20,
    },
    {
        "slug": "shopping",
        "displayName": "Shopping",
        "description": "Clothes, stores, prices, sizes.",
        "icon": "bag.fill",
        "sortOrder": 30,
    },
    {
        "slug": "health",
        "displayName": "Health & Body",
        "description": "Doctor, pharmacy, body parts, symptoms.",
        "icon": "heart.fill",
        "sortOrder": 40,
    },
    {
        "slug": "work-and-money",
        "displayName": "Work & Money",
        "description": "Jobs, banking, paying, business.",
        "icon": "briefcase.fill",
        "sortOrder": 50,
    },
    {
        "slug": "feelings",
        "displayName": "Feelings",
        "description": "Emotions, moods, reactions.",
        "icon": "face.smiling",
        "sortOrder": 60,
    },
    {
        "slug": "home",
        "displayName": "Home & Daily Life",
        "description": "Rooms, routines, household items.",
        "icon": "house.fill",
        "sortOrder": 70,
    },
    {
        "slug": "family",
        "displayName": "Family & People",
        "description": "Relatives, friends, describing people.",
        "icon": "person.2.fill",
        "sortOrder": 80,
    },
]

# Old slug -> new slug remap, applied to any deck tags found in legacy
# generator caches (generated_entries*.json) or hand-authored TOPIC_DECKS
# entries still using the pre-2026 taxonomy.
LEGACY_SLUG_REMAP = {
    "travel": "traveling",
    "food": "food-and-drink",
    "work": "work-and-money",
    "money_shopping": "shopping",
    "body_health": "health",
    "nature_weather": "traveling",
}
LEGACY_SLUG_DROP = {"time_numbers"}


def normalize_slugs(slugs):
    """Apply the legacy remap/drop to a list of deck slugs, dedupe, preserve order."""
    out = []
    for s in slugs:
        if s in LEGACY_SLUG_DROP:
            continue
        mapped = LEGACY_SLUG_REMAP.get(s, s)
        if mapped not in out:
            out.append(mapped)
    return out


def cefr_for_rank(rank: int) -> str:
    """Map a frequency rank to a CEFR level using the same calibration as
    Spanish: A1 covers the top of the list (essentials), A2 the next band,
    B1 the long tail. Languages can override by passing `cefr_bands`."""
    if rank <= 150:
        return "A1"
    if rank <= 350:
        return "A2"
    return "B1"


def build_dataset(
    *,
    language_code: str,
    output_filename: str,
    entries: Iterable[tuple[str, str, str, str, str]],
    topic_decks: dict | None = None,
    deck_definitions: list[dict] | None = None,
    project_root: Path | None = None,
    cefr_bands: dict[str, range] | None = None,
    generated_glob: str | None = None,
) -> None:
    """Write `output_filename` under Resources/, populated from ENTRIES + TOPIC_DECKS.

    `cefr_bands` (optional): override CEFR thresholds, e.g.
        {"A1": range(1, 151), "A2": range(151, 351), "B1": range(351, 10**6)}

    `generated_glob` (optional): glob pattern (relative to tools/) for
    additional LLM-generated entry files to merge. Same shape as the
    Spanish `generated_entries*.json` format.
    """
    if project_root is None:
        project_root = Path(__file__).resolve().parent.parent
    output_path = project_root / "wordrus" / "wordrus" / "Resources" / output_filename
    output_path.parent.mkdir(parents=True, exist_ok=True)

    decks = deck_definitions or DEFAULT_DECKS
    topic_decks = topic_decks or {}

    word_index: dict[str, dict] = {}
    order: list[str] = []

    def cefr(rank: int) -> str:
        if cefr_bands:
            for level, span in cefr_bands.items():
                if rank in span:
                    return level
            return "B1"
        return cefr_for_rank(rank)

    def add_entry(lemma, pos, gloss, example_native, example_en, deck, cefr_level=None):
        if lemma in word_index:
            if deck not in word_index[lemma]["decks"]:
                word_index[lemma]["decks"].append(deck)
            if cefr_level and not word_index[lemma].get("cefrLevel"):
                word_index[lemma]["cefrLevel"] = cefr_level
            return
        word_index[lemma] = {
            "lemma": lemma,
            "partOfSpeech": pos,
            "gloss": gloss,
            "example_native": example_native,
            "example_en": example_en,
            "decks": [deck],
            "cefrLevel": cefr_level,
        }
        order.append(lemma)

    for rank, (lemma, pos, gloss, example_native, example_en) in enumerate(entries, start=1):
        add_entry(lemma, pos, gloss, example_native, example_en, "common", cefr(rank))

    for deck_slug, deck_data in topic_decks.items():
        for lemma in deck_data.get("lemmas", []):
            if lemma in word_index:
                if deck_slug not in word_index[lemma]["decks"]:
                    word_index[lemma]["decks"].append(deck_slug)
            else:
                print(f"Warning: topic '{deck_slug}' references unknown lemma '{lemma}'")
        for lemma, pos, gloss, example_native, example_en in deck_data.get("new_entries", []):
            add_entry(lemma, pos, gloss, example_native, example_en, deck_slug)

    if generated_glob:
        tools_dir = Path(__file__).resolve().parent
        for path_str in sorted(glob.glob(str(tools_dir / generated_glob))):
            payload = json.loads(Path(path_str).read_text(encoding="utf-8"))
            for entry in payload.get("entries", []):
                lemma = entry["lemma"]
                explicit_slugs = entry.get("decks")
                if lemma in word_index:
                    if explicit_slugs:
                        for slug in explicit_slugs:
                            if slug not in word_index[lemma]["decks"]:
                                word_index[lemma]["decks"].append(slug)
                    if entry.get("cefrLevel") and not word_index[lemma].get("cefrLevel"):
                        word_index[lemma]["cefrLevel"] = entry["cefrLevel"]
                else:
                    word_index[lemma] = {
                        "lemma": lemma,
                        "partOfSpeech": entry["partOfSpeech"],
                        "gloss": entry["gloss"],
                        "example_native": entry.get("exampleNative") or entry.get("exampleSpanish"),
                        "example_en": entry["exampleEnglish"],
                        "decks": list(explicit_slugs or ["common"]),
                        "cefrLevel": entry.get("cefrLevel"),
                    }
                    order.append(lemma)

    valid_slugs = {d["slug"] for d in decks} | {"common"}

    words = []
    for rank, lemma in enumerate(order, start=1):
        entry_data = word_index[lemma]
        normalized = normalize_slugs(entry_data["decks"])
        # Drop slugs that aren't part of the published taxonomy or the hidden
        # 'common' bucket. This catches stale slugs from legacy generator
        # caches that don't match any current deck.
        final_slugs = [s for s in normalized if s in valid_slugs]
        if not final_slugs:
            final_slugs = ["common"]
        out = {
            "id": f"{language_code}-{rank:04d}",
            "rank": rank,
            "lemma": entry_data["lemma"],
            "partOfSpeech": entry_data["partOfSpeech"],
            "definitions": {"en": entry_data["gloss"]},
            "example": {
                "text": entry_data["example_native"],
                "translations": {"en": entry_data["example_en"]},
            },
            "decks": final_slugs,
        }
        if entry_data.get("cefrLevel"):
            out["cefrLevel"] = entry_data["cefrLevel"]
        words.append(out)

    payload = {
        "version": 4,
        "language": language_code,
        "decks": decks,
        "words": words,
    }

    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(words)} words and {len(decks)} decks to {output_path}")
