#!/usr/bin/env python3
"""Generate vocabulary entries for any supported target language via the Claude API.

Usage:
    pip install anthropic
    export ANTHROPIC_API_KEY=sk-ant-...

    # Spanish (the original behaviour — default language, doozan source)
    python3 tools/generate_vocab.py --limit 30
    python3 tools/generate_vocab.py --limit 1000

    # French / Italian / German (hermitdave/FrequencyWords source)
    python3 tools/generate_vocab.py --language fr --limit 30
    python3 tools/generate_vocab.py --language it --limit 700
    python3 tools/generate_vocab.py --language de --limit 700

Frequency sources:
  - es: doozan/spanish_data (already lemmatised + POS-tagged, very clean)
  - fr/it/de: hermitdave/FrequencyWords 2018 (word-form frequencies from
    OpenSubtitles, MIT-licensed). The LLM lemmatises and skips inflected
    forms via the `skip: "inflection"` field — costs slightly more API spend
    than doozan but is the best easily-pullable source for these languages.

Output files (one per language, all auto-merged by build_*.py on next run):
  - es: tools/generated_entries.json  (back-compat with prior runs)
  - fr: tools/generated_entries_fr.json
  - it: tools/generated_entries_it.json
  - de: tools/generated_entries_de.json

The cache is resumable: Ctrl-C is safe and re-running picks up where it left off.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import importlib
import json
import os
import re
import sys
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

TOOLS_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = TOOLS_DIR.parent

DEFAULT_MODEL = "claude-sonnet-4-6"
BATCH_SIZE = 20
MAX_WORKERS = 4

# Sonnet 4.6 pricing (USD per million tokens)
PRICE_INPUT_PER_MTOK = 3.0
PRICE_OUTPUT_PER_MTOK = 15.0
PRICE_CACHE_READ_PER_MTOK = 0.30  # ~10% of input
PRICE_CACHE_WRITE_PER_MTOK = 3.75  # ~125% of input (5-min TTL)

TOPIC_DECK_SLUGS = [
    "traveling", "food-and-drink", "shopping", "health",
    "work-and-money", "feelings", "home", "family",
]

CEFR_LEVELS = ["A1", "A2", "B1", "B2", "C1", "C2"]


# ---------------------------------------------------------------------------
# Per-language configuration
# ---------------------------------------------------------------------------

@dataclass
class LangConfig:
    """Everything that differs per target language. Add a new language by
    appending a config here and a frequency-list fetcher."""
    code: str                                  # "es" | "fr" | "it" | "de"
    name: str                                  # "Spanish" | "French" | ...
    endonym_field: str                         # JSON field for the example sentence
    fetch_frequency: Callable[[], list[str]]   # returns lemma candidates, ordered
    valid_lemma: re.Pattern[str]               # which forms pass the prefilter
    build_module: str                          # build_*.py to read existing lemmas from
    cefr_examples: dict[str, str]              # per-level example lemmas for the prompt
    notes: str                                 # one-line "use these conventions" reminder
    output_filename: str                       # tools/{this}


# --- Spanish (doozan, lemmatised) -----------------------------------------

DOOZAN_FREQ_URL = "https://raw.githubusercontent.com/doozan/spanish_data/master/frequency.csv"
DOOZAN_FREQ_CACHE = TOOLS_DIR / "doozan_frequency.csv"
# doozan POS values that are useful flashcard material.
DOOZAN_CONTENT_POS = {"n", "adj", "v", "adv", "num", "interj", "phrase"}

def _fetch_doozan_spanish() -> list[str]:
    import csv
    if not DOOZAN_FREQ_CACHE.exists():
        print(f"Downloading frequency list from {DOOZAN_FREQ_URL}...")
        urllib.request.urlretrieve(DOOZAN_FREQ_URL, DOOZAN_FREQ_CACHE)
    rows: list[tuple[str, int]] = []
    with DOOZAN_FREQ_CACHE.open(encoding="utf-8") as fh:
        reader = csv.DictReader(fh)
        for row in reader:
            pos = (row.get("pos") or "").strip()
            lemma = (row.get("spanish") or "").strip().lower()
            flags = row.get("flags") or ""
            if pos not in DOOZAN_CONTENT_POS:
                continue
            if "NOUSAGE" in flags or "DUPLICATE" in flags:
                continue
            try:
                count = int(row["count"])
            except (KeyError, ValueError):
                continue
            rows.append((lemma, count))
    rows.sort(key=lambda r: -r[1])
    return [lemma for lemma, _ in rows]


# --- Hermitdave (form-frequency from OpenSubtitles, MIT) ------------------

HERMITDAVE_URL = (
    "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/"
    "content/2018/{code}/{code}_50k.txt"
)

# Top function words / pronouns / very-common closed-class items that
# would just get skipped by the LLM. Pre-filtering saves API spend.
HERMITDAVE_STOPLISTS: dict[str, set[str]] = {
    "fr": {
        "le", "la", "les", "un", "une", "des", "de", "du", "au", "aux",
        "à", "et", "ou", "mais", "donc", "or", "ni", "car", "que", "qui",
        "quoi", "dont", "où", "ce", "cette", "ces", "cet", "se", "te", "me",
        "nous", "vous", "ils", "elles", "il", "elle", "je", "tu", "on",
        "mon", "ton", "son", "ma", "ta", "sa", "mes", "tes", "ses",
        "notre", "votre", "leur", "leurs", "ne", "pas", "plus", "rien",
        "pour", "par", "sur", "sous", "dans", "en", "y", "avec", "sans",
        "chez", "vers", "entre", "contre", "pendant", "depuis", "avant",
        "après", "selon", "si", "comme", "quand", "lorsque",
        "est", "sont", "était", "étaient", "été", "fut", "soit",
        "a", "ai", "as", "avons", "avez", "ont", "avait", "avaient",
    },
    "it": {
        "il", "lo", "la", "le", "gli", "un", "una", "uno", "del", "dello",
        "della", "delle", "degli", "dei", "al", "allo", "alla", "ai", "agli",
        "alle", "dal", "dallo", "dalla", "dai", "dagli", "dalle", "nel",
        "nello", "nella", "nei", "negli", "nelle", "sul", "sulla", "sui",
        "e", "o", "ma", "se", "che", "chi", "cui", "non", "né", "ne",
        "io", "tu", "egli", "ella", "noi", "voi", "essi", "esse", "lei", "lui",
        "mio", "tuo", "suo", "mia", "tua", "sua", "miei", "tuoi", "suoi",
        "nostro", "vostro", "loro", "nostra", "vostra", "questo", "questa",
        "quello", "quella", "questi", "queste", "quelli", "quelle",
        "per", "con", "tra", "fra", "di", "da", "in", "su",
        "è", "sono", "era", "erano", "stato", "stata", "sarà",
        "ho", "hai", "ha", "abbiamo", "avete", "hanno",
    },
    "de": {
        "der", "die", "das", "den", "dem", "des", "ein", "eine", "einen",
        "einem", "einer", "eines", "und", "oder", "aber", "denn", "doch",
        "sondern", "weil", "dass", "ob", "wenn", "als", "wie", "wo",
        "ich", "du", "er", "sie", "es", "wir", "ihr", "sie", "mich", "dich",
        "ihn", "uns", "euch", "mir", "dir", "ihm", "ihnen",
        "mein", "dein", "sein", "ihr", "unser", "euer", "ihre",
        "nicht", "nichts", "nie", "sehr", "schon", "noch", "auch", "nur",
        "etwa", "vielleicht",
        "in", "an", "auf", "über", "unter", "vor", "hinter", "neben",
        "mit", "ohne", "bei", "nach", "von", "zu", "aus", "für", "gegen",
        "um", "durch",
        "ist", "sind", "war", "waren", "sein", "gewesen", "wird", "wurde",
        "hat", "hatte", "haben", "habe", "hast", "habt",
    },
}

def _make_hermitdave_fetcher(code: str) -> Callable[[], list[str]]:
    cache_path = TOOLS_DIR / f"hermitdave_{code}_50k.txt"
    url = HERMITDAVE_URL.format(code=code)
    stoplist = HERMITDAVE_STOPLISTS.get(code, set())

    def fetch() -> list[str]:
        if not cache_path.exists():
            print(f"Downloading frequency list from {url}...")
            urllib.request.urlretrieve(url, cache_path)
        lemmas: list[str] = []
        seen: set[str] = set()
        with cache_path.open(encoding="utf-8") as fh:
            for line in fh:
                parts = line.strip().split()
                if len(parts) < 2:
                    continue
                word = parts[0].lower()
                if word in stoplist or word in seen:
                    continue
                seen.add(word)
                lemmas.append(word)
        return lemmas
    return fetch


# --- Lemma regexes ---------------------------------------------------------
# Allow language-appropriate diacritics. Hyphen permitted for FR (peut-être)
# and DE (separable nouns occasionally). Apostrophes excluded — we want the
# lemma not the contracted form.

LEMMA_RE_ES = re.compile(r"^[a-záéíóúüñ]{2,20}$")
LEMMA_RE_FR = re.compile(r"^[a-zàâæçéèêëîïôœùûüÿ\-]{2,25}$")
LEMMA_RE_IT = re.compile(r"^[a-zàèéìíòóùú]{2,20}$")
LEMMA_RE_DE = re.compile(r"^[a-zäöüß\-]{2,30}$")


# --- Per-language CEFR rubric examples (used in the system prompt) --------

CEFR_EXAMPLES_ES = {
    "A1": "casa, comer, agua, madre, día",
    "A2": "trabajo, viajar, dinero, tienda, salud",
    "B1": "lograr, intentar, sociedad",
    "B2": "alcanzar, conseguir, ámbito",
    "C1": "vertiente, esbozar",
    "C2": "aciago, esquiroles",
}
CEFR_EXAMPLES_FR = {
    "A1": "maison, manger, eau, mère, jour",
    "A2": "travail, voyager, argent, magasin, santé",
    "B1": "réussir, essayer, société",
    "B2": "atteindre, parvenir, domaine",
    "C1": "versant, esquisser",
    "C2": "funeste, briseurs",
}
CEFR_EXAMPLES_IT = {
    "A1": "casa, mangiare, acqua, madre, giorno",
    "A2": "lavoro, viaggiare, denaro, negozio, salute",
    "B1": "riuscire, provare, società",
    "B2": "raggiungere, conseguire, ambito",
    "C1": "versante, abbozzare",
    "C2": "funesto, crumiri",
}
CEFR_EXAMPLES_DE = {
    "A1": "Haus, essen, Wasser, Mutter, Tag",
    "A2": "Arbeit, reisen, Geld, Geschäft, Gesundheit",
    "B1": "schaffen, versuchen, Gesellschaft",
    "B2": "erreichen, gelingen, Bereich",
    "C1": "Aspekt, skizzieren",
    "C2": "verhängnisvoll, Streikbrecher",
}


LANG_CONFIGS: dict[str, LangConfig] = {
    "es": LangConfig(
        code="es",
        name="Spanish",
        endonym_field="exampleSpanish",
        fetch_frequency=_fetch_doozan_spanish,
        valid_lemma=LEMMA_RE_ES,
        build_module="build_dataset",
        cefr_examples=CEFR_EXAMPLES_ES,
        notes="Preserve diacritics. Lowercase. No proper nouns.",
        output_filename="generated_entries.json",
    ),
    "fr": LangConfig(
        code="fr",
        name="French",
        endonym_field="exampleNative",
        fetch_frequency=_make_hermitdave_fetcher("fr"),
        valid_lemma=LEMMA_RE_FR,
        build_module="build_french",
        cefr_examples=CEFR_EXAMPLES_FR,
        notes=(
            "Preserve diacritics. Lowercase verbs and adjectives. "
            "Inputs are word forms — return the lemma (infinitive for verbs, "
            "masculine singular for adjectives, singular for nouns) and set "
            "skip='inflection' if the lemma is one you've already produced."
        ),
        output_filename="generated_entries_fr.json",
    ),
    "it": LangConfig(
        code="it",
        name="Italian",
        endonym_field="exampleNative",
        fetch_frequency=_make_hermitdave_fetcher("it"),
        valid_lemma=LEMMA_RE_IT,
        build_module="build_italian",
        cefr_examples=CEFR_EXAMPLES_IT,
        notes=(
            "Preserve diacritics. Lowercase verbs and adjectives. "
            "Inputs are word forms — return the lemma (infinitive for verbs, "
            "masculine singular for adjectives, singular for nouns) and set "
            "skip='inflection' if the lemma is one you've already produced."
        ),
        output_filename="generated_entries_it.json",
    ),
    "de": LangConfig(
        code="de",
        name="German",
        endonym_field="exampleNative",
        fetch_frequency=_make_hermitdave_fetcher("de"),
        valid_lemma=LEMMA_RE_DE,
        build_module="build_german",
        cefr_examples=CEFR_EXAMPLES_DE,
        notes=(
            "Inputs are lowercase forms from subtitles — CAPITALISE the lemma "
            "if it's a noun (German orthography). For nouns also write "
            "partOfSpeech as 'noun (der)', 'noun (die)', or 'noun (das)' so "
            "the gender is preserved. Lowercase verbs and adjectives. "
            "Set skip='inflection' if the lemma is one you've already produced."
        ),
        output_filename="generated_entries_de.json",
    ),
}


# ---------------------------------------------------------------------------
# Prompt templating
# ---------------------------------------------------------------------------

def system_prompt_for(cfg: LangConfig) -> str:
    cefr_lines = "\n    ".join(
        f"{level}: {cfg.cefr_examples[level]}." for level in CEFR_LEVELS
    )
    return f"""You are a {cfg.name} lexicographer producing vocabulary
entries for an English-speaking learner's flashcard app.

For each {cfg.name} input you receive, call the `save_entries` tool with one
entry per input. Process all inputs in the order they were given.

Each entry must include:
- lemma: the dictionary form. {cfg.notes}
- partOfSpeech: one of "noun", "noun (masc.)", "noun (fem.)", "noun (der)",
  "noun (die)", "noun (das)", "verb", "adjective", "adverb", "interjection",
  "number", or "phrase". Use the gender-tagged noun form for {cfg.name} where
  gender is part of the language.
- gloss: concise English translation, 1-6 words. Use commas for alternatives.
- {cfg.endonym_field}: one short natural {cfg.name} sentence using the lemma
  in its most common form. 5-12 words.
- exampleEnglish: idiomatic English translation of the example.
- decks: list of deck slugs. ALWAYS include "common" (the hidden catch-all
  used to populate "All Words"). Add zero or more topic tags from:
    - traveling: trips, hotels, airports, tickets, transport modes, weather
      and nature (the outdoors as part of travel)
    - food-and-drink: groceries, cooking, ingredients, eating, drinks
    - shopping: clothes, stores, prices, sizes, paying for goods
    - health: doctor, pharmacy, body parts, symptoms, illness
    - work-and-money: jobs, offices, banking, salaries, business
    - feelings: emotions, moods, reactions, opinions
    - home: rooms, furniture, household items, daily routines, chores
    - family: relatives, friends, describing or talking about people
  Only tag a topic when the word is clearly central to that domain. Most
  words will be "common" only.
- cefrLevel: one of {", ".join(CEFR_LEVELS)}. Estimate based on the lemma's
  frequency, concreteness, and typical {cfg.name}-as-foreign-language curricula
  (CEFR). Rule of thumb:
    {cefr_lines}

Skip rules — set the "skip" field instead of producing other fields if input is:
- A pure function word: "function word"
- A proper noun: "proper noun"
- An inflected form of a more basic lemma you've already produced: "inflection"
- An obscure technical term that's not flashcard-worthy: "obscure"
- A typo or non-{cfg.name} word: "non-lemma"

Always return exactly one entry per input, in the same order received.
Do not invent meanings — if you're unsure, prefer skip over guessing."""


def save_entries_tool_for(cfg: LangConfig) -> dict[str, Any]:
    """The tool schema mirrors `entries[*]` fields — note the per-language
    example-field name."""
    return {
        "name": "save_entries",
        "description": "Save the vocabulary entries you generated.",
        "input_schema": {
            "type": "object",
            "properties": {
                "entries": {
                    "type": "array",
                    "description": "One entry per input lemma, in the same order.",
                    "items": {
                        "type": "object",
                        "properties": {
                            "lemma": {"type": "string"},
                            "partOfSpeech": {"type": "string"},
                            "gloss": {"type": "string"},
                            cfg.endonym_field: {"type": "string"},
                            "exampleEnglish": {"type": "string"},
                            "decks": {
                                "type": "array",
                                "items": {"type": "string"},
                            },
                            "cefrLevel": {
                                "type": "string",
                                "enum": CEFR_LEVELS,
                                "description": "CEFR proficiency level.",
                            },
                            "skip": {
                                "type": "string",
                                "description": "If set, this entry is skipped. Other fields ignored.",
                            },
                        },
                        "required": ["lemma"],
                    },
                }
            },
            "required": ["entries"],
        },
    }


# ---------------------------------------------------------------------------
# Existing-lemma loading (so we don't pay to regenerate)
# ---------------------------------------------------------------------------

def load_existing_lemmas(cfg: LangConfig) -> set[str]:
    sys.path.insert(0, str(TOOLS_DIR))
    import glob

    existing: set[str] = set()
    try:
        build_mod = importlib.import_module(cfg.build_module)
        existing.update(e[0] for e in build_mod.ENTRIES)
        for deck in build_mod.TOPIC_DECKS.values():
            for entry in deck.get("new_entries", []):
                existing.add(entry[0])
    except (ImportError, AttributeError) as e:
        print(f"warn: couldn't read {cfg.build_module}.ENTRIES: {e}", file=sys.stderr)

    # Also dedup against entries already in generated_entries{,_lang}*.json
    # so we don't pay to regenerate them on resume.
    pattern = cfg.output_filename.replace(".json", "*.json")
    for path in glob.glob(str(TOOLS_DIR / pattern)):
        try:
            data = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for entry in data.get("entries", []):
            lemma = entry.get("lemma")
            if lemma:
                # Normalise to lowercase to match the form we feed Claude.
                # (German nouns are stored capitalised but the frequency
                # list is lowercase.)
                existing.add(lemma.lower())
    return existing


def filter_candidates(freq: list[str], known: set[str], cfg: LangConfig) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for lemma in freq:
        if lemma in known or lemma in seen:
            continue
        if not cfg.valid_lemma.match(lemma):
            continue
        seen.add(lemma)
        out.append(lemma)
    return out


# ---------------------------------------------------------------------------
# Cache I/O
# ---------------------------------------------------------------------------

def load_cache(cfg: LangConfig) -> dict[str, dict[str, Any]]:
    path = TOOLS_DIR / cfg.output_filename
    if not path.exists():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    cache: dict[str, dict[str, Any]] = {}
    for entry in data.get("entries", []):
        # Cache by lowercased lemma so resume-dedup works for DE nouns too.
        cache[entry["lemma"].lower()] = entry
    for skipped in data.get("skipped", []):
        cache[skipped["input"].lower()] = {"_skip": skipped["reason"], "input": skipped["input"]}
    return cache


def save_cache(cfg: LangConfig, cache: dict[str, dict[str, Any]]) -> None:
    path = TOOLS_DIR / cfg.output_filename
    entries = [v for v in cache.values() if "_skip" not in v]
    skipped = [
        {"input": v["input"], "reason": v["_skip"]}
        for v in cache.values()
        if "_skip" in v
    ]
    payload = {
        "version": 2,
        "language": cfg.code,
        "source": (
            "doozan/spanish_data + Claude API" if cfg.code == "es"
            else f"hermitdave/FrequencyWords ({cfg.code}, MIT) + Claude API"
        ),
        "entries": entries,
        "skipped": skipped,
    }
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


# ---------------------------------------------------------------------------
# Claude call
# ---------------------------------------------------------------------------

def call_claude(client: Any, model: str, lemmas: list[str], cfg: LangConfig) -> tuple[list[dict[str, Any]], Any]:
    numbered = "\n".join(f"{i + 1}. {lemma}" for i, lemma in enumerate(lemmas))
    user_msg = f"Produce entries for these {len(lemmas)} {cfg.name} words:\n{numbered}"

    message = client.messages.create(
        model=model,
        max_tokens=8192,
        system=[
            {
                "type": "text",
                "text": system_prompt_for(cfg),
                "cache_control": {"type": "ephemeral"},
            }
        ],
        tools=[save_entries_tool_for(cfg)],
        tool_choice={"type": "tool", "name": "save_entries"},
        messages=[{"role": "user", "content": user_msg}],
    )

    for block in message.content:
        if block.type == "tool_use" and block.name == "save_entries":
            return block.input.get("entries", []), message.usage
    raise RuntimeError(f"No tool_use block in response: stop_reason={message.stop_reason}")


def validate_entry(entry: dict[str, Any], cfg: LangConfig) -> tuple[bool, str]:
    if not isinstance(entry, dict):
        return False, "non-object entry"
    if entry.get("skip"):
        return False, str(entry["skip"])
    required = ("lemma", "partOfSpeech", "gloss", cfg.endonym_field, "exampleEnglish", "decks", "cefrLevel")
    for k in required:
        if not entry.get(k):
            return False, f"missing field: {k}"
    if not isinstance(entry["decks"], list) or "common" not in entry["decks"]:
        return False, "decks must be a list including 'common'"
    if entry["cefrLevel"] not in CEFR_LEVELS:
        return False, f"invalid cefrLevel: {entry['cefrLevel']}"
    return True, "ok"


# ---------------------------------------------------------------------------
# Cost estimation
# ---------------------------------------------------------------------------

def estimate_cost(n_lemmas: int, batch_size: int) -> tuple[float, int]:
    n_batches = (n_lemmas + batch_size - 1) // batch_size
    # ~900 tokens system + tools (cached after first), ~50 tokens user prompt,
    # ~120 tokens per entry output.
    system_tokens = 900
    cached_input = system_tokens * (n_batches - 1)
    fresh_input = system_tokens + 50 * n_batches
    output_tokens = 120 * n_lemmas

    cost = (
        fresh_input / 1e6 * PRICE_INPUT_PER_MTOK
        + cached_input / 1e6 * PRICE_CACHE_READ_PER_MTOK
        + system_tokens / 1e6 * PRICE_CACHE_WRITE_PER_MTOK
        + output_tokens / 1e6 * PRICE_OUTPUT_PER_MTOK
    )
    return cost, n_batches


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument("--language", choices=sorted(LANG_CONFIGS.keys()), default="es",
                    help="Target language (default: es).")
    ap.add_argument("--limit", type=int, default=50,
                    help="Max new lemmas to process this run (default: 50)")
    ap.add_argument("--start-rank", type=int, default=0,
                    help="Skip the first N candidates (after filtering)")
    ap.add_argument("--model", default=DEFAULT_MODEL,
                    help=f"Claude model (default: {DEFAULT_MODEL})")
    ap.add_argument("--batch-size", type=int, default=BATCH_SIZE,
                    help=f"Lemmas per API call (default: {BATCH_SIZE})")
    ap.add_argument("--workers", type=int, default=MAX_WORKERS,
                    help=f"Parallel API workers (default: {MAX_WORKERS})")
    ap.add_argument("--dry-run", action="store_true",
                    help="Show candidates and cost estimate without calling the API")
    ap.add_argument("--yes", action="store_true",
                    help="Skip the confirmation prompt")
    args = ap.parse_args()

    cfg = LANG_CONFIGS[args.language]
    print(f"Target language: {cfg.name} ({cfg.code}) → tools/{cfg.output_filename}")

    freq = cfg.fetch_frequency()
    known = load_existing_lemmas(cfg)
    print(f"Loaded {len(freq)} frequency rows; {len(known)} lemmas already in {cfg.build_module}.py.")

    candidates = filter_candidates(freq, known, cfg)
    print(f"After filtering: {len(candidates)} candidate lemmas.")

    cache = load_cache(cfg)
    if cache:
        cached_entries = sum(1 for v in cache.values() if "_skip" not in v)
        cached_skips = len(cache) - cached_entries
        print(f"Cache: {cached_entries} entries, {cached_skips} skipped (will reuse).")

    slice_ = candidates[args.start_rank: args.start_rank + args.limit]
    pending = [l for l in slice_ if l not in cache]
    print(f"This run: {len(pending)} new lemmas to process "
          f"(slice rank {args.start_rank}-{args.start_rank + args.limit}, "
          f"{len(slice_) - len(pending)} already cached).")

    if not pending:
        print("Nothing to do.")
        return

    cost, n_batches = estimate_cost(len(pending), args.batch_size)
    print(f"Estimated: {n_batches} batches, ~${cost:.2f} ({args.model} pricing).")
    print(f"Sample: {pending[:10]}{'...' if len(pending) > 10 else ''}")

    if args.dry_run:
        print("--dry-run: stopping before any API calls.")
        return

    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("\nERROR: set ANTHROPIC_API_KEY in your environment.", file=sys.stderr)
        sys.exit(1)

    if not args.yes:
        try:
            ans = input("\nProceed? [y/N] ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return
        if ans not in ("y", "yes"):
            print("Aborted.")
            return

    try:
        import anthropic
    except ImportError:
        print("\nERROR: the `anthropic` package is not installed.", file=sys.stderr)
        print("Install it with: pip install anthropic", file=sys.stderr)
        sys.exit(1)

    client = anthropic.Anthropic()

    batches = [pending[i: i + args.batch_size]
               for i in range(0, len(pending), args.batch_size)]

    total_in = total_out = total_cache_read = total_cache_write = 0
    n_ok = n_skip = n_err = 0
    t_start = time.monotonic()

    def absorb(batch: list[str], entries: list[dict[str, Any]]) -> tuple[int, int]:
        ok = skip = 0
        for inp, entry in zip(batch, entries):
            valid, reason = validate_entry(entry, cfg)
            if valid:
                cleaned = {
                    "lemma": entry["lemma"],
                    "partOfSpeech": entry["partOfSpeech"],
                    "gloss": entry["gloss"],
                    cfg.endonym_field: entry[cfg.endonym_field],
                    "exampleEnglish": entry["exampleEnglish"],
                    "decks": entry["decks"],
                    "cefrLevel": entry["cefrLevel"],
                }
                cache[entry["lemma"].lower()] = cleaned
                ok += 1
            else:
                cache[inp.lower()] = {"_skip": reason, "input": inp}
                skip += 1
        return ok, skip

    def process_batch(batch_idx: int, batch: list[str]) -> tuple[int, list[str], list[dict[str, Any]] | None, Any, Exception | None]:
        try:
            entries, usage = call_claude(client, args.model, batch, cfg)
            return batch_idx, batch, entries, usage, None
        except Exception as e:  # noqa: BLE001
            return batch_idx, batch, None, None, e

    # Warm the cache: run batch 1 alone so the cache write happens before
    # parallel workers fire. Subsequent batches will hit cache_read on the
    # system prompt.
    if batches:
        print(f"\nWarming cache with batch 1/{len(batches)}...")
        _, _, entries, usage, err = process_batch(0, batches[0])
        if err:
            print(f"  WARN: first batch failed: {err}", file=sys.stderr)
            n_err += len(batches[0])
        else:
            assert entries is not None
            ok, skip = absorb(batches[0], entries)
            n_ok += ok
            n_skip += skip
            total_in += usage.input_tokens
            total_out += usage.output_tokens
            total_cache_read += getattr(usage, "cache_read_input_tokens", 0) or 0
            total_cache_write += getattr(usage, "cache_creation_input_tokens", 0) or 0
            save_cache(cfg, cache)
            print(f"  batch 1/{len(batches)}: {ok} ok, {skip} skipped.")

    if len(batches) > 1:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
            futures = [
                ex.submit(process_batch, i, batch)
                for i, batch in enumerate(batches[1:], start=1)
            ]
            for fut in concurrent.futures.as_completed(futures):
                batch_idx, batch, entries, usage, err = fut.result()
                if err:
                    print(f"  batch {batch_idx + 1}/{len(batches)}: ERROR {err}", file=sys.stderr)
                    n_err += len(batch)
                    continue
                assert entries is not None
                total_in += usage.input_tokens
                total_out += usage.output_tokens
                total_cache_read += getattr(usage, "cache_read_input_tokens", 0) or 0
                total_cache_write += getattr(usage, "cache_creation_input_tokens", 0) or 0
                ok, skip = absorb(batch, entries)
                n_ok += ok
                n_skip += skip
                save_cache(cfg, cache)
                print(f"  batch {batch_idx + 1}/{len(batches)}: "
                      f"{ok} ok, {skip} skipped "
                      f"(running total: {n_ok}/{n_skip}/{n_err}).")

    elapsed = time.monotonic() - t_start
    actual_cost = (
        total_in / 1e6 * PRICE_INPUT_PER_MTOK
        + total_cache_read / 1e6 * PRICE_CACHE_READ_PER_MTOK
        + total_cache_write / 1e6 * PRICE_CACHE_WRITE_PER_MTOK
        + total_out / 1e6 * PRICE_OUTPUT_PER_MTOK
    )

    print(f"\nDone in {elapsed:.1f}s.")
    print(f"  Entries: {n_ok} generated, {n_skip} skipped, {n_err} errored.")
    print(f"  Tokens: in={total_in}, cache_read={total_cache_read}, "
          f"cache_write={total_cache_write}, out={total_out}.")
    print(f"  Cost: ~${actual_cost:.3f}")
    print(f"  Output: tools/{cfg.output_filename}")
    print(f"\nNext: run `python3 tools/build_{cfg.code if cfg.code != 'es' else 'dataset'}"
          f"{'' if cfg.code == 'es' else f'_{cfg.code}'}.py` to merge into the seed JSON.")


if __name__ == "__main__":
    main()
