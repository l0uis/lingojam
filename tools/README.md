# tools/

Build-time scripts. Nothing here ships in the app bundle.

## Vocabulary pipeline

Each supported language has its own seed JSON in `wordrus/wordrus/Resources/`:

| Language | Seed file               | Build script              | LLM cache                          |
|----------|-------------------------|---------------------------|------------------------------------|
| Spanish  | `spanish_top1000.json`  | `tools/build_dataset.py`  | `tools/generated_entries*.json`    |
| French   | `french_top1000.json`   | `tools/build_french.py`   | `tools/generated_entries_fr*.json` |
| Italian  | `italian_top1000.json`  | `tools/build_italian.py`  | `tools/generated_entries_it*.json` |
| German   | `german_top1000.json`   | `tools/build_german.py`   | `tools/generated_entries_de*.json` |

The build scripts share scaffolding via `tools/vocab_pipeline.py` (CEFR
bucketing, deck definitions, JSON emission). Each build script:

1. Reads its inline `ENTRIES` (hand-authored core vocab) and `TOPIC_DECKS`.
2. Merges any `generated_entries_{lang}*.json` files written by the
   generator below.
3. Writes the seed JSON. Duplicate lemmas are deduped; CEFR levels and deck
   memberships are merged.

Re-run the script after appending entries or after a generator run:

```
python3 tools/build_dataset.py     # Spanish
python3 tools/build_french.py
python3 tools/build_italian.py
python3 tools/build_german.py
```

## Story lexicons (`tools/build_story_lexicon.py`)

Walter's daily story checks every generated story on device
(`StoryVocabularyChecker.swift`) against the learner's known words. That check
needs per-language data, written to `Resources/story_lexicon_{es,fr,de,it}.json`
(~115 KB each):

- `frequency`: seed lemmas ordered by corpus frequency (doozan for Spanish,
  hermitdave form counts aggregated over a regular paradigm for FR/DE/IT).
  Used for coverage stats and for picking which known words a story may use.
- `functionWords`: articles, pronouns, prepositions, conjunctions, auxiliaries,
  negation and numbers — always allowed in a story.
- `aliases`: NLTagger lemma quirks (puede → "podar" → poder) plus irregular
  forms of the most frequent verbs (dijo → decir, gestanden → stehen).
- Morphology hints: noun/adjective endings, verb ending classes and stem
  alternations (for when NLTagger has no lemma model — the iOS simulator has
  none for Spanish), Spanish/Italian clitics, German separable prefixes and
  compound linkers.

Stdlib only. Re-run after any seed rebuild:

```
python3 tools/build_story_lexicon.py            # all four languages
python3 tools/build_story_lexicon.py de --report  # also list frequent forms the lexicon can't explain
```

The Swift tests in `wordrusTests/StoryVocabularyCheckerTests.swift` run the real
NLTagger against these files, with and without its lemma model.

## LLM-driven generation (`tools/generate_vocab.py`)

Pulls a frequency list, filters out lemmas already covered, and asks Claude
to produce structured entries (lemma + POS + gloss + example + CEFR level +
deck tags) via tool-use. Resumable cache.

```
pip install anthropic
export ANTHROPIC_API_KEY=sk-ant-...

# Spanish — uses doozan/spanish_data (lemmatised + POS-tagged, very clean)
python3 tools/generate_vocab.py --limit 50              # test run
python3 tools/generate_vocab.py --limit 1000 --yes      # real run, ~$3

# French / Italian / German — uses hermitdave/FrequencyWords (form
# frequencies from OpenSubtitles). The LLM lemmatises inputs and skips
# inflected forms of words it has already produced.
python3 tools/generate_vocab.py --language fr --limit 50 --dry-run
python3 tools/generate_vocab.py --language fr --limit 1000 --yes
python3 tools/generate_vocab.py --language it --limit 1000 --yes
python3 tools/generate_vocab.py --language de --limit 1000 --yes
```

After a generation run, run the matching `build_*.py` to merge the new
entries into the bundled seed JSON. The app's `DeckSyncMigrator` will then
pick them up on next launch without a reset.

### Per-language notes

- **Spanish**: `doozan/spanish_data/frequency.csv` is the gold-standard
  source — already lemmatised, POS-tagged, flagged for usage. Filter
  yields ~10k candidates after stripping `NOUSAGE`/`DUPLICATE` flags and
  non-content POS. Skip rate is low (~5%).
- **French / Italian / German**: hermitdave's frequency lists are
  word-form counts from OpenSubtitles — noisier (`être` and `suis` and
  `était` all appear as separate forms). The system prompt handles this
  by asking Claude to return the dictionary lemma and set `skip:
  "inflection"` when an input is just a conjugated/inflected form of a
  lemma already produced. Skip rate is higher (~25–30%) — plan `--limit`
  accordingly to land your target word count.
- **German nouns are capitalised** by the prompt (the frequency list is
  lowercase from subtitles). Part-of-speech for nouns includes the
  article: `"noun (der)"`, `"noun (die)"`, `"noun (das)"`.

### Estimated cost (claude-sonnet-4-6 pricing)

| Action                                       | Cost   | Wall time |
|----------------------------------------------|--------|-----------|
| 1000 lemmas Spanish                          | ~$3    | ~10 min   |
| 1000 lemmas French/Italian/German (each)     | ~$3    | ~10 min   |
| Bring all 3 new languages to ~1000 entries   | ~$6    | ~30 min   |
| Bring all 3 new languages to Spanish parity (~6700) | ~$60 | ~5 hours |

### Adding a fifth language

In `generate_vocab.py`, append a `LangConfig` to `LANG_CONFIGS`:

- `code`: ISO 639-1 (e.g. `"pt"`).
- `fetch_frequency`: callable returning a frequency-descending list of
  lemmas. Reuse `_make_hermitdave_fetcher("pt")` if hermitdave has the
  language.
- `valid_lemma`: regex allowing language-appropriate diacritics.
- `build_module`: name of `tools/build_*.py` for that language.
- `cefr_examples`: 6 example lemmas per CEFR level used in the prompt's
  rubric.
- `output_filename`: `generated_entries_{code}.json`.

Then create `tools/build_{language}.py` (copy one of the existing FR/IT/DE
ones) and add a `TargetLanguage.{language}` case in
`wordrus/Services/OnboardingStore.swift` plus a matching seed-resource
name. The Swift loader and brain wiring pick it up automatically.

## Attribution

- **Spanish frequency**:
  [doozan/spanish_data](https://github.com/doozan/spanish_data) (MIT).
- **French/Italian/German frequency**:
  [hermitdave/FrequencyWords](https://github.com/hermitdave/FrequencyWords)
  `content/2018/{fr,it,de}/{lang}_50k.txt` (MIT).
- **Example sentences and English glosses** for the hand-authored core
  vocabulary in each `build_*.py` were authored from scratch for this
  project; LLM-generated entries are produced via the Anthropic API and
  cached locally.
