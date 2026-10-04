# Walrus Proxy

Cloudflare Worker that sits between the Wordrus iOS app and OpenAI's TTS API. Holds the OpenAI API key as a Worker secret so the app never has to ship it. Per-device rate limiting via KV bounds the damage if the proxy URL leaks.

Exposes:

- `POST /v1/walrus/tts` → proxies to OpenAI `audio/speech`, returns MP3 audio.
- `POST /v1/walrus/enrich` → runs a vocabulary lookup through Claude (Anthropic Messages API), returns a structured dictionary entry as JSON. Backs the "Add a word" feature in the Vocabulary tab (see [`WalrusEnrichmentClient.swift`](../../wordrus/wordrus/Services/WalrusEnrichmentClient.swift)).

- `GET|POST /v1/walrus/words` → per-device backup of user-added words (with review progress), so they survive an app delete/reinstall (see [`WordBackupClient.swift`](../../wordrus/wordrus/Services/WordBackupClient.swift)).

- `POST /v1/walrus/turn` → Dr Tusk's next line in a voice call, from Claude. Backs [`ClaudeWalrusBrain.swift`](../../wordrus/wordrus/Services/ClaudeWalrusBrain.swift) and is what makes Walter respond to what the learner actually said instead of reciting a template.

- `POST /v1/walrus/story` → Dr Tusk's daily story, from Claude Haiku 4.5 via a forced `submit_story` tool. Backs [`ClaudeStoryBrain.swift`](../../wordrus/wordrus/Services/ClaudeStoryBrain.swift).

Grading stays on-device — `ChatStore.finalize` recomputes target-word hits with the deterministic lemma matcher no matter what any brain claims — so there's no `/evaluate` endpoint to deploy.

### Conversation — `POST /v1/walrus/turn`

Same required headers as the others; rate-limited under its own `turn:` bucket. Body:

```jsonc
{
  "language": "Spanish",   // English name of the language being learned
  "level": "A2",           // CEFR — controls how hard Walter's language is
  "phase": "open",         // "open" | "reply" | "wrapUp"
  "shouldWrapUp": false,   // true once the call has run its natural length
  "targetWords": ["café", "playa"],          // a steer, never a script
  "history": [ { "role": "walrus" | "user", "text": "…" } ]  // oldest first
}
```

→ `{ "text": "…", "endsConversation": false }`

The history is replayed as real assistant/user message turns rather than a
flattened transcript, which is most of why replies land on what was said.
Two invariants the Messages API enforces are handled in `buildTurnMessages`
and pinned by `test/messages.test.ts`: the conversation must open on a user
turn (ours opens with Walter, so a stage direction stands in), and roles must
alternate (so same-role runs merge and the phase instruction folds into the
trailing user turn). Run them with `npm test`.

Walter's persona lives in `walterSystemPrompt` — that's the file to edit if he
should sound different.

### Models

Every Claude route (`/enrich`, `/turn`, `/story`) uses one model list,
`CONTENT_MODELS` in `src/index.ts`: Claude Haiku 4.5, falling back to Sonnet
4.6 when Haiku is overloaded or unavailable. One model, one bill — change it
there to change it everywhere. All calls go through `callClaude()` (retry
once on 429/5xx/529, fail over on that or a 404, stop on other errors).

### Daily story — `POST /v1/walrus/story`

The app chooses the words and checks every draft on device
(`StoryVocabularyChecker`); the worker only writes. Body:

```json
{ "language": "Spanish", "nativeLanguage": "English", "level": "A2",
  "knownWords": ["ir", "playa", …], "newWords": ["pez", "salir"],
  "topic": "Animals", "previousEpisode": "Dr Tusk found a note…",
  "minWords": 90, "maxWords": 150, "maxSentenceWords": 10 }
```

Returns the `submit_story` tool input: `{title, story, new_word_sentences,
questions, episode_summary}`. A repair adds `"repair": {"draft": <that
object>, "unknownWords": [...], "missingNewWords": [...]}`; the draft is
replayed as the model's previous tool call and the rejected words come back
as its tool result. Rate limited separately (30/day per device). Nothing is
cached — each story is built from one learner's word list.

`/turn` also accepts an optional `storyContext` (English) for the "retell
today's story" call; it's appended to Dr Tusk's system prompt.

### Word backup — `/v1/walrus/words`

Same required headers as the others. Stored in the `ENRICH_CACHE` KV namespace under `words:<deviceID>` (one JSON array per device). The device ID comes from the iOS Keychain, which persists across app delete/reinstall — so reinstalling restores the user's words.

- `GET /v1/walrus/words` → `{ "words": [ {id, lang, localeKey, lemma, partOfSpeech, definition, exampleSentence, exampleTranslation, progress?}, … ] }`
- `POST /v1/walrus/words` with `{ "words": [ … ] }` → **replaces** the device's whole list (the app pushes a full snapshot on add/delete and when it backgrounds). Entries are stored verbatim, so `progress` (Known/Learning state + SRS schedule) and any future fields round-trip untouched.

Per-device, no account system — words follow the Keychain device ID, which is iCloud-synced so the backup restores on a new device too.

## Deploy

You need:
- A Cloudflare account (free tier is enough)
- An OpenAI API key with credit on it
- `npm` and `wrangler` (`npm install -g wrangler`, or use `npx wrangler`)

```bash
cd tools/walrus-proxy
npm install

# Authenticate with Cloudflare
npx wrangler login

# Create the KV namespace for rate limiting
npx wrangler kv namespace create RATE_LIMIT
# → copy the printed `id = "..."` into wrangler.toml

# Create the KV namespace for the shared enrichment cache
npx wrangler kv namespace create ENRICH_CACHE
# → copy the printed `id = "..."` into wrangler.toml (replaces PASTE_ENRICH_CACHE_ID_HERE)

# Store the OpenAI key as an encrypted Worker secret
npx wrangler secret put OPENAI_API_KEY
# (paste your sk-... key when prompted)

# Store the Anthropic key (for /v1/walrus/enrich, /turn and /story)
npx wrangler secret put ANTHROPIC_API_KEY
# (paste your sk-ant-... key when prompted)

# Deploy
npx wrangler deploy
# → prints something like: https://walrus-proxy.your-subdomain.workers.dev
```

Take that URL and paste it into the iOS app under **Settings → Walter's voice → Proxy URL**.

## Test locally

```bash
npx wrangler dev
```

Then from another shell:

```bash
curl -X POST http://localhost:8787/v1/walrus/tts \
  -H "content-type: application/json" \
  -H "x-walrus-device-id: $(uuidgen)" \
  -H "x-walrus-bundle-id: com.louiscurrie.wordrus" \
  -d '{"text":"Ay, otra vez tú. ¿Qué quieres ahora?","voice":"onyx","instructions":"Speak as a grumpy, sleepy older Spaniard"}' \
  --output walter.mp3
open walter.mp3
```

## Request contract

`POST /v1/walrus/tts`

Required headers:

| Header | Purpose |
|---|---|
| `X-Walrus-Device-ID` | Per-install UUID from the iOS Keychain. Used for rate limiting. |
| `X-Walrus-Bundle-ID` | Must equal `EXPECTED_BUNDLE_ID` in [wrangler.toml](./wrangler.toml). Weak app-identity check. |

Body (JSON):

```jsonc
{
  "text": "Ay, otra vez tú. ¿Qué quieres ahora?",   // required, ≤ 4000 chars
  "voice": "onyx",                                  // optional, default 'onyx'
  "instructions": "Speak as a grumpy older Spaniard", // optional, gpt-4o-mini-tts only
  "model": "gpt-4o-mini-tts"                         // optional, default 'gpt-4o-mini-tts'
}
```

Responses:

- `200` → `audio/mpeg` body (raw MP3)
- `400` → bad request (`{error, ...}` JSON)
- `403` → wrong bundle ID
- `429` → rate-limit hit (`{error, resetAt}` JSON; `resetAt` is unix seconds)
- `502` → OpenAI returned an error

### `POST /v1/walrus/enrich`

Same required headers as TTS. Body (JSON):

```jsonc
{
  "word": "geläufig",        // required, ≤ 80 chars
  "targetLanguage": "German", // required, English name of the word's language
  "nativeLanguage": "English" // optional, language to define/translate into; default 'English'
}
```

Returns the dictionary entry as JSON (forced via a Claude tool call, so it's always well-formed):

```jsonc
{
  "lemma": "geläufig",
  "partOfSpeech": "adjective",
  "definition": "common, familiar, fluent",
  "exampleSentence": "Dieses Wort ist mir geläufig.",
  "exampleTranslation": "This word is familiar to me."
}
```

**Shared cache.** Results are cached in the `ENRICH_CACHE` KV namespace keyed by `enrich:v1:<targetLang>:<nativeLang>:<lowercased-word>`, with no expiry. The first lookup of a word calls Claude (response header `x-walrus-cache: miss`); every later lookup of that word — from any user — is served from KV for free (`x-walrus-cache: hit`). The cache also accumulates into a shared dictionary you can export:

```bash
# list cached keys
npx wrangler kv key list --binding ENRICH_CACHE
# read one entry
npx wrangler kv key get --binding ENRICH_CACHE "enrich:v1:german:english:geläufig"
```

Bump the `v1` prefix in `src/index.ts` if you change the prompt/output shape and want to invalidate old entries.

Responses:

- `200` → entry JSON above
- `400` → missing/oversized `word` or missing `targetLanguage`
- `403` → wrong bundle ID
- `429` → rate-limit hit
- `502` → Anthropic returned an error or no tool call

Test it locally:

```bash
curl -X POST http://localhost:8787/v1/walrus/enrich \
  -H "content-type: application/json" \
  -H "x-walrus-device-id: $(uuidgen)" \
  -H "x-walrus-bundle-id: com.louiscurrie.wordrus" \
  -d '{"word":"geläufig","targetLanguage":"German","nativeLanguage":"English"}'
```

## Rate limiting

`DAILY_LIMIT_PER_DEVICE` (default `200`) caps daily TTS calls per device ID, stored in KV with a UTC-midnight TTL. Bump it in [wrangler.toml](./wrangler.toml) and `wrangler deploy` to change.

Cloudflare's free per-IP rate limiting kicks in automatically as a second layer.

## Cost guardrails

OpenAI `gpt-4o-mini-tts` is roughly $0.015/minute → ~$0.012 per chat (7 utterances at ~80 chars each). With the 200-call daily cap per device, a single abusive device can cost you at most ~$2.40/day. Cloudflare KV reads/writes stay inside the free tier at this scale.

## Threat model

This proxy is "anti-abuse," not "auth." The device ID is anonymous (no account system), the bundle ID is trivially spoofable, and the proxy URL is shipped inside the iOS binary. The defenses that matter:

1. Per-device daily cap (KV) — bounds any single attacker.
2. Cloudflare per-IP rate limit — bounds distributed abuse.
3. OpenAI's own per-minute rate limits — final backstop.

If you need stronger guarantees, add a real account system or rotate per-install signing keys. Not worth it at indie scale.
