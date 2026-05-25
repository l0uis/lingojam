# Walrus Proxy

Cloudflare Worker that sits between the Lingojam iOS app and OpenAI's TTS API. Holds the OpenAI API key as a Worker secret so the app never has to ship it. Per-device rate limiting via KV bounds the damage if the proxy URL leaks.

Currently exposes one endpoint:

- `POST /v1/walrus/tts` → proxies to OpenAI `audio/speech`, returns MP3 audio.

A future revision will add `/v1/walrus/turn` and `/v1/walrus/evaluate` for the Claude chat brain (see [`ClaudeWalrusBrain.swift`](../../lingojam/lingojam/Services/ClaudeWalrusBrain.swift)).

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

# Store the OpenAI key as an encrypted Worker secret
npx wrangler secret put OPENAI_API_KEY
# (paste your sk-... key when prompted)

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
  -H "x-walrus-bundle-id: com.louiscurrie.lingojam" \
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
