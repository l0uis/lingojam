/**
 * Cloudflare Worker proxy for OpenAI TTS. Holds the OpenAI API key as
 * a Worker secret so the iOS app never has to ship it. Per-device rate
 * limiting via KV keeps abuse bounded if the proxy URL leaks.
 *
 * See ../README.md for deployment steps.
 */

export interface Env {
  OPENAI_API_KEY: string
  ANTHROPIC_API_KEY: string
  RATE_LIMIT: KVNamespace
  ENRICH_CACHE: KVNamespace
  DAILY_LIMIT_PER_DEVICE: string
  EXPECTED_BUNDLE_ID: string
}

interface TTSRequest {
  /** Text to synthesize. Required, max 4000 chars. */
  text: string
  /** OpenAI voice preset. Default 'onyx' (deep male). */
  voice?: string
  /** Optional voice-style instruction (gpt-4o-mini-tts only). */
  instructions?: string
  /** OpenAI TTS model. Default 'gpt-4o-mini-tts'. */
  model?: string
}

interface EnrichRequest {
  /** The word or short phrase the user wants to add. Required. */
  word: string
  /** Language the word is in, English name (e.g. "German"). Required. */
  targetLanguage: string
  /** Language the definition should be written in (e.g. "English"). */
  nativeLanguage?: string
}

const MAX_TEXT_LENGTH = 4000
const MAX_WORD_LENGTH = 80

// Models for vocabulary enrichment, tried in order. Haiku first: it's ~3x
// cheaper and faster, and plenty accurate for single-word dictionary entries.
// Sonnet is the fallback when Haiku is overloaded (529), so a busy-server
// moment still resolves rather than failing the lookup.
const ENRICH_MODELS = ['claude-haiku-4-5-20251001', 'claude-sonnet-4-6']

// Anthropic statuses worth retrying / failing over on: rate limit, transient
// 5xx, and 529 "overloaded".
const RETRYABLE_STATUSES = [429, 500, 502, 503, 529]

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === 'OPTIONS') {
      return cors(new Response(null, { status: 204 }))
    }

    const url = new URL(request.url)
    if (url.pathname === '/v1/walrus/tts' && request.method === 'POST') {
      try {
        return cors(await handleTTS(request, env))
      } catch (err) {
        console.error('tts error', err)
        return cors(
          new Response(JSON.stringify({ error: 'internal error' }), {
            status: 500,
            headers: { 'content-type': 'application/json' },
          })
        )
      }
    }

    if (url.pathname === '/v1/walrus/enrich' && request.method === 'POST') {
      try {
        return cors(await handleEnrich(request, env))
      } catch (err) {
        console.error('enrich error', err)
        return cors(json({ error: 'internal error' }, 500))
      }
    }

    // Per-device backup of user-added words, so they survive app
    // delete/reinstall. Keyed by device ID in ENRICH_CACHE.
    if (url.pathname === '/v1/walrus/words') {
      try {
        if (request.method === 'GET') return cors(await handleWordsList(request, env))
        if (request.method === 'POST') return cors(await handleWordsUpsert(request, env))
      } catch (err) {
        console.error('words error', err)
        return cors(json({ error: 'internal error' }, 500))
      }
    }
    if (url.pathname === '/v1/walrus/words/delete' && request.method === 'POST') {
      try {
        return cors(await handleWordsDelete(request, env))
      } catch (err) {
        console.error('words delete error', err)
        return cors(json({ error: 'internal error' }, 500))
      }
    }

    if (url.pathname === '/health') {
      return cors(new Response('ok'))
    }

    return cors(new Response('not found', { status: 404 }))
  },
}

async function handleTTS(request: Request, env: Env): Promise<Response> {
  // Anti-abuse: device ID identifies the caller for rate limiting;
  // bundle ID acts as a weak "is this our app" filter. Both can be
  // spoofed, but combined with Cloudflare's free IP-based rate limiting
  // they raise the cost of abuse meaningfully.
  const deviceID = request.headers.get('X-Walrus-Device-ID')
  const bundleID = request.headers.get('X-Walrus-Bundle-ID')

  if (!deviceID || deviceID.length < 16 || deviceID.length > 128) {
    return json({ error: 'invalid device id' }, 400)
  }
  if (bundleID !== env.EXPECTED_BUNDLE_ID) {
    return json({ error: 'invalid bundle' }, 403)
  }

  const allowed = await checkRateLimit(env, deviceID, 'tts')
  if (!allowed.ok) {
    return json({ error: 'rate limited', resetAt: allowed.resetAt }, 429)
  }

  const body = (await request.json().catch(() => null)) as TTSRequest | null
  if (!body || typeof body.text !== 'string' || body.text.length === 0) {
    return json({ error: 'missing text' }, 400)
  }
  if (body.text.length > MAX_TEXT_LENGTH) {
    return json({ error: 'text too long' }, 400)
  }

  const model = body.model ?? 'gpt-4o-mini-tts'
  const voice = body.voice ?? 'onyx'

  const openaiBody: Record<string, unknown> = {
    model,
    voice,
    input: body.text,
    response_format: 'mp3',
  }
  if (body.instructions) {
    openaiBody.instructions = body.instructions
  }

  const openaiResp = await fetch('https://api.openai.com/v1/audio/speech', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${env.OPENAI_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify(openaiBody),
  })

  if (!openaiResp.ok) {
    const errText = await openaiResp.text()
    console.error('openai error', openaiResp.status, errText)
    return json({ error: 'upstream error', status: openaiResp.status }, 502)
  }

  // Stream the MP3 audio straight back to the iOS client.
  return new Response(openaiResp.body, {
    status: 200,
    headers: {
      'content-type': 'audio/mpeg',
      'cache-control': 'no-store',
    },
  })
}

async function handleEnrich(request: Request, env: Env): Promise<Response> {
  const deviceID = request.headers.get('X-Walrus-Device-ID')
  const bundleID = request.headers.get('X-Walrus-Bundle-ID')

  if (!deviceID || deviceID.length < 16 || deviceID.length > 128) {
    return json({ error: 'invalid device id' }, 400)
  }
  if (bundleID !== env.EXPECTED_BUNDLE_ID) {
    return json({ error: 'invalid bundle' }, 403)
  }

  const allowed = await checkRateLimit(env, deviceID, 'enrich')
  if (!allowed.ok) {
    return json({ error: 'rate limited', resetAt: allowed.resetAt }, 429)
  }

  const body = (await request.json().catch(() => null)) as EnrichRequest | null
  const word = body?.word?.trim()
  const targetLanguage = body?.targetLanguage?.trim()
  if (!word || word.length === 0) {
    return json({ error: 'missing word' }, 400)
  }
  if (word.length > MAX_WORD_LENGTH) {
    return json({ error: 'word too long' }, 400)
  }
  if (!targetLanguage) {
    return json({ error: 'missing targetLanguage' }, 400)
  }
  const nativeLanguage = body?.nativeLanguage?.trim() || 'English'

  // Shared cache: the same word from any user resolves to the same entry, so
  // serve a prior result instead of paying for another Claude call. Keyed on
  // the lowercased input + both languages; `v1` lets us bust the cache if the
  // prompt/shape changes. Entries never expire — they accumulate into a
  // shared dictionary of everything users have looked up.
  const cacheKey = `enrich:v1:${targetLanguage.toLowerCase()}:${nativeLanguage.toLowerCase()}:${word.toLowerCase()}`
  const cached = await env.ENRICH_CACHE.get(cacheKey)
  if (cached) {
    return new Response(cached, {
      status: 200,
      headers: { 'content-type': 'application/json', 'x-walrus-cache': 'hit' },
    })
  }

  // Force structured output with a single tool the model must call, so we
  // get clean JSON rather than parsing prose.
  const tool = {
    name: 'save_vocabulary_entry',
    description: 'Record the dictionary entry for the word.',
    input_schema: {
      type: 'object',
      properties: {
        lemma: {
          type: 'string',
          description: `The standard dictionary spelling of the SAME word, in ${targetLanguage}, reduced to its base form. Fix only diacritics/casing; never substitute or invent a different word.`,
        },
        partOfSpeech: {
          type: 'string',
          description:
            'One lowercase English word: noun, verb, adjective, adverb, pronoun, preposition, conjunction, or interjection.',
        },
        definition: {
          type: 'string',
          description: `A short ${nativeLanguage} translation gloss, like a dictionary headword — NOT an explanation. Give the direct equivalent in a few words; use a comma-separated list for multiple senses. For a verb, use the infinitive ("to arrive"). Examples: "to arrive"; "common, familiar, fluent"; "house". No full sentences, no "used to describe…", no usage notes.`,
        },
        exampleSentence: {
          type: 'string',
          description: `One short, natural sentence in ${targetLanguage} that actually uses the word. Only real, correctly spelled ${targetLanguage} words.`,
        },
        exampleTranslation: {
          type: 'string',
          description: `The example sentence translated into ${nativeLanguage}.`,
        },
      },
      required: [
        'lemma',
        'partOfSpeech',
        'definition',
        'exampleSentence',
        'exampleTranslation',
      ],
    },
  }

  const system = `You are an accurate bilingual dictionary for a language-learning app. \
You are given one word in ${targetLanguage} and must return its dictionary entry. \
Be precise: use the real, attested meaning and spelling. Never invent words, never \
guess wildly. Keep the definition terse — a short translation gloss like a flashcard \
("to arrive", "common, familiar"), never an explanatory sentence. The example sentence \
MUST contain the word (you may inflect it for grammar) and use only real, correctly \
spelled ${targetLanguage} words.`

  const baseBody = {
    max_tokens: 1024,
    system,
    tools: [tool],
    tool_choice: { type: 'tool', name: 'save_vocabulary_entry' },
    messages: [
      {
        role: 'user',
        content: `Word: ${word}\nLanguage: ${targetLanguage}\nDefinition language: ${nativeLanguage}`,
      },
    ],
  }

  // Try each model in order; within a model, retry transient errors with a
  // short backoff. This rides out a busy-server moment (529 overloaded) and,
  // if Sonnet stays overloaded, fails over to Haiku rather than erroring.
  let anthropicResp: Response | null = null
  let lastStatus = -1
  outer: for (const model of ENRICH_MODELS) {
    for (let attempt = 0; attempt < 2; attempt++) {
      anthropicResp = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'x-api-key': env.ANTHROPIC_API_KEY,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: JSON.stringify({ model, ...baseBody }),
      })
      if (anthropicResp.ok) break outer
      lastStatus = anthropicResp.status
      // Non-retryable (e.g. 400 bad request, 401 auth) — stop entirely.
      if (!RETRYABLE_STATUSES.includes(lastStatus)) break outer
      // Retry the same model once on the first failure; otherwise move on to
      // the next model.
      if (attempt === 0) {
        await new Promise((resolve) => setTimeout(resolve, 500))
      }
    }
  }

  if (!anthropicResp || !anthropicResp.ok) {
    const errText = anthropicResp ? await anthropicResp.text() : 'no response'
    console.error('anthropic error', lastStatus, errText)
    return json({ error: 'upstream error', status: lastStatus }, 502)
  }

  const data = (await anthropicResp.json()) as {
    content?: Array<{ type: string; name?: string; input?: unknown }>
  }
  const toolUse = data.content?.find(
    (block) => block.type === 'tool_use' && block.name === 'save_vocabulary_entry'
  )
  if (!toolUse || typeof toolUse.input !== 'object' || toolUse.input === null) {
    console.error('anthropic returned no tool_use', JSON.stringify(data))
    return json({ error: 'no result' }, 502)
  }

  // Store for everyone else. waitUntil isn't used so we await — the write is
  // fast and we'd rather guarantee the entry lands than shave a few ms.
  const resultJson = JSON.stringify(toolUse.input)
  await env.ENRICH_CACHE.put(cacheKey, resultJson)

  return new Response(resultJson, {
    status: 200,
    headers: { 'content-type': 'application/json', 'x-walrus-cache': 'miss' },
  })
}

// MARK: - Word backup (survives app delete/reinstall)

interface BackupWord {
  id: string
  lang: string
  localeKey: string
  lemma: string
  partOfSpeech: string
  definition: string
  exampleSentence: string
  exampleTranslation: string
  addedAt?: number
}

const MAX_BACKUP_WORDS = 5000

function wordsKey(deviceID: string): string {
  return `words:${deviceID}`
}

// Validate the caller and return its device ID, or an error Response.
function authDevice(request: Request, env: Env): { deviceID: string } | Response {
  const deviceID = request.headers.get('X-Walrus-Device-ID')
  const bundleID = request.headers.get('X-Walrus-Bundle-ID')
  if (!deviceID || deviceID.length < 16 || deviceID.length > 128) {
    return json({ error: 'invalid device id' }, 400)
  }
  if (bundleID !== env.EXPECTED_BUNDLE_ID) {
    return json({ error: 'invalid bundle' }, 403)
  }
  return { deviceID }
}

async function readWords(env: Env, deviceID: string): Promise<BackupWord[]> {
  const raw = await env.ENRICH_CACHE.get(wordsKey(deviceID))
  if (!raw) return []
  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? (parsed as BackupWord[]) : []
  } catch {
    return []
  }
}

async function handleWordsList(request: Request, env: Env): Promise<Response> {
  const auth = authDevice(request, env)
  if (auth instanceof Response) return auth
  return json({ words: await readWords(env, auth.deviceID) }, 200)
}

async function handleWordsUpsert(request: Request, env: Env): Promise<Response> {
  const auth = authDevice(request, env)
  if (auth instanceof Response) return auth

  const body = (await request.json().catch(() => null)) as Partial<BackupWord> | null
  if (!body || typeof body.id !== 'string' || body.id.length === 0) {
    return json({ error: 'missing id' }, 400)
  }
  const str = (v: unknown, fallback = ''): string => (typeof v === 'string' ? v : fallback)
  const entry: BackupWord = {
    id: body.id,
    lang: str(body.lang),
    localeKey: str(body.localeKey, 'en'),
    lemma: str(body.lemma),
    partOfSpeech: str(body.partOfSpeech),
    definition: str(body.definition),
    exampleSentence: str(body.exampleSentence),
    exampleTranslation: str(body.exampleTranslation),
    addedAt: typeof body.addedAt === 'number' ? body.addedAt : undefined,
  }

  const words = await readWords(env, auth.deviceID)
  const idx = words.findIndex((w) => w.id === entry.id)
  if (idx >= 0) {
    words[idx] = entry
  } else {
    if (words.length >= MAX_BACKUP_WORDS) return json({ error: 'backup full' }, 409)
    words.push(entry)
  }
  await env.ENRICH_CACHE.put(wordsKey(auth.deviceID), JSON.stringify(words))
  return json({ ok: true, count: words.length }, 200)
}

async function handleWordsDelete(request: Request, env: Env): Promise<Response> {
  const auth = authDevice(request, env)
  if (auth instanceof Response) return auth
  const body = (await request.json().catch(() => null)) as { id?: string } | null
  if (!body || typeof body.id !== 'string') return json({ error: 'missing id' }, 400)
  const words = (await readWords(env, auth.deviceID)).filter((w) => w.id !== body.id)
  await env.ENRICH_CACHE.put(wordsKey(auth.deviceID), JSON.stringify(words))
  return json({ ok: true, count: words.length }, 200)
}

async function checkRateLimit(
  env: Env,
  deviceID: string,
  prefix: string
): Promise<{ ok: true } | { ok: false; resetAt: number }> {
  const dailyLimit = parseInt(env.DAILY_LIMIT_PER_DEVICE, 10) || 200
  const today = new Date().toISOString().slice(0, 10) // YYYY-MM-DD UTC
  const key = `${prefix}:${deviceID}:${today}`
  const tomorrow = new Date()
  tomorrow.setUTCDate(tomorrow.getUTCDate() + 1)
  tomorrow.setUTCHours(0, 0, 0, 0)
  const expiration = Math.floor(tomorrow.getTime() / 1000)

  const raw = await env.RATE_LIMIT.get(key)
  const count = raw ? parseInt(raw, 10) || 0 : 0
  if (count >= dailyLimit) {
    return { ok: false, resetAt: expiration }
  }
  await env.RATE_LIMIT.put(key, String(count + 1), { expiration })
  return { ok: true }
}

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' },
  })
}

function cors(resp: Response): Response {
  const headers = new Headers(resp.headers)
  headers.set('access-control-allow-origin', '*')
  headers.set('access-control-allow-methods', 'GET, POST, OPTIONS')
  headers.set('access-control-allow-headers', 'content-type, x-walrus-device-id, x-walrus-bundle-id')
  return new Response(resp.body, { status: resp.status, headers })
}
