#!/usr/bin/env python3
"""Generate english_top1000.json — British English for es/fr/it/de speakers.

Build-time tool, NOT bundled in the app. Run:
    python3 tools/generate_vocab.py --language en --limit 8000
    python3 tools/build_english.py

Unlike the other seeds there is no hand-authored core: every word comes from
the generator cache (hermitdave/FrequencyWords en_50k, MIT, + Claude), whose
entries carry glosses and example translations keyed es/fr/it/de. Those
become the seed's `definitions` / `example.translations` maps, which the app
reads under the learner's native-language code (LocaleService).
"""

from vocab_pipeline import build_dataset

# (lemma, part_of_speech, english_gloss, english_example, english_translation)
# — the hand-authored tuple shape is English-gloss-only, so the English seed
# doesn't use it.
ENTRIES: list[tuple[str, str, str, str, str]] = []

TOPIC_DECKS: dict = {}


if __name__ == "__main__":
    build_dataset(
        language_code="en",
        output_filename="english_top1000.json",
        entries=ENTRIES,
        topic_decks=TOPIC_DECKS,
        generated_glob="generated_entries_en*.json",
    )
