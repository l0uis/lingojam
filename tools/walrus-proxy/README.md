# Walrus Proxy

Cloudflare Worker that sits between the Wordrus iOS app and OpenAI's TTS API. Holds the OpenAI API key as a Worker secret so the app never has to ship it. Per-device rate limiting via KV bounds the damage if the proxy URL leaks.

Exposes:

- `POST /v1/walrus/tts` → proxies to OpenAI `audio/speech`, returns MP3 audio.
- `POST /v1/walrus/enrich` → runs a vocabulary lookup through Claude (Anthropic Messages API), returns a structured dictionary entry as JSON. Backs the "Add a word" feature in the Vocabulary tab (see [`WalrusEnrichmentClient.swift`](../../wordrus/wordrus/Services/WalrusEnrichmentClient.swift)).

- `GET|POST /v1/walrus/words` + `POST /v1/walrus/words/delete` → per-device backup of user-added words, so they survive an app delete/reinstall (see [`WordBackupClient.swift`](../../wordrus/wordrus/Services/WordBackupClient.swift)).

A future revision will add `/v1/walrus/turn` and `/v1/walrus/evaluate` for the Claude chat brain (see [`ClaudeWalrusBrain.swift`](../../wordrus/wordrus/Services/ClaudeWalrusBrain.swift)).

### Word backup — `/v1/walrus/words`

Same required headers as the others. Stored in the `ENRICH_CACHE` KV namespace under `words:<deviceID>` (one JSON array per device). The device ID comes from the iOS Keychain, which persists across app delete/reinstall — so reinstalling restores the user's words.

- `GET /v1/walrus/words` → `{ "words": [ {id, lang, localeKey, lemma, partOfSpeech, definition, exampleSentence, exampleTranslation, addedAt}, … ] }`
- `POST /v1/walrus/words` with one word entry as the body → upsert (add or update by `id`).
- `POST /v1/walrus/words/delete` with `{ "id": "custom-…" }` → remove one word.

Per-device, no account system — words follow the Keychain device ID (same device only; cross-device would need an iCloud-synced key).

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

# Store the Anthropic key (for /v1/walrus/enrich)
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
