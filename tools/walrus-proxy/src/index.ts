/**
 * Cloudflare Worker proxy for the Wordrus iOS app: OpenAI TTS plus Claude
 * for Dr Tusk's calls, word lookups and daily stories. Holds the API keys as
 * Worker secrets so the app never has to ship them. Per-device rate limiting
 * via KV keeps abuse bounded if the proxy URL leaks.
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

// The app's Claude models — one list for everything (word lookups, stories
// and Dr Tusk's calls), so it all runs on the same model and the same bill.
// Haiku first: ~3x cheaper, and noticeably faster, which matters most in a
// voice call. Sonnet is the fallback when Haiku is overloaded (529), so a
// busy-server moment still resolves rather than failing.
const CLAUDE_HAIKU = 'claude-haiku-4-5-20251001'
const CLAUDE_SONNET = 'claude-sonnet-4-6'
export const CONTENT_MODELS = [CLAUDE_HAIKU, CLAUDE_SONNET]

// Anthropic statuses worth retrying / failing over on: rate limit, transient
// 5xx, and 529 "overloaded".
const RETRYABLE_STATUSES = [429, 500, 502, 503, 529]

/**
 * POST a Messages request, trying each model in order; within a model,
 * retry a transient error once after `retryDelayMs`. A 404 (model not
 * available) moves on to the next model; other non-retryable errors (400,
 * 401…) stop immediately. Every Claude route goes through here.
 */
export async function callClaude(
  env: Env,
  models: string[],
  body: Record<string, unknown>,
  retryDelayMs = 500
): Promise<{ resp: Response | null; status: number }> {
  let resp: Response | null = null
  let lastStatus = -1
  for (const model of models) {
    for (let attempt = 0; attempt < 2; attempt++) {
      resp = await fetch('https://api.anthropic.com/v1/messages', {
        method: 'POST',
        headers: {
          'x-api-key': env.ANTHROPIC_API_KEY,
          'anthropic-version': '2023-06-01',
          'content-type': 'application/json',
        },
        body: JSON.stringify({ model, ...body }),
      })
      if (resp.ok) return { resp, status: resp.status }
      lastStatus = resp.status
      if (lastStatus === 404) break
      if (!RETRYABLE_STATUSES.includes(lastStatus)) return { resp, status: lastStatus }
      if (attempt === 0) await new Promise((resolve) => setTimeout(resolve, retryDelayMs))
    }
  }
  return { resp, status: lastStatus }
}

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

    if (url.pathname === '/v1/walrus/turn' && request.method === 'POST') {
      try {
        return cors(await handleTurn(request, env))
      } catch (err) {
        console.error('turn error', err)
        return cors(json({ error: 'internal error' }, 500))
      }
    }

    if (url.pathname === '/v1/walrus/story' && request.method === 'POST') {
      try {
        return cors(await handleStory(request, env))
      } catch (err) {
        console.error('story error', err)
        return cors(json({ error: 'internal error' }, 500))
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

    // Per-device backup of user-added words (with review progress), so they
    // survive app delete/reinstall. GET reads, POST replaces the whole list.
    // Keyed by device ID in ENRICH_CACHE.
    if (url.pathname === '/v1/walrus/words') {
      try {
        if (request.method === 'GET') return cors(await handleWordsList(request, env))
        if (request.method === 'POST') return cors(await handleWordsReplace(request, env))
      } catch (err) {
        console.error('words error', err)
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

  // Rides out a busy-server moment (529 overloaded): retry, then fail over
  // from Haiku to Sonnet rather than erroring.
  const { resp: anthropicResp, status: lastStatus } = await callClaude(env, CONTENT_MODELS, baseBody)

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

// MARK: - Conversation
//
// The app sends the whole call so far and gets back Walter's next line.
// History is passed as real assistant/user message turns rather than a
// flattened transcript, which is most of why this responds to what was
// actually said instead of free-associating.

export interface TurnRequest {
  /** English name of the language being learned, e.g. "Spanish". */
  language: string
  /** CEFR level, e.g. "A2". Controls how hard Walter's language is. */
  level: string
  /** 'open' | 'reply' | 'wrapUp'. */
  phase?: string
  /** Words the learner has been studying — a steer, never a script. */
  targetWords?: string[]
  /** The call so far, oldest first. */
  history?: Array<{ role: string; text: string }>
  /** True once the call has run long enough that Walter should wind down. */
  shouldWrapUp?: boolean
  /**
   * Background for a call about something specific — today it's only the
   * "retell today's story" call. Written by the app in English.
   */
  storyContext?: string
}

const MAX_STORY_CONTEXT_LENGTH = 2000

/** Plenty for a natural call, and bounds the tokens we pay for per turn. */
const MAX_HISTORY_TURNS = 24

function levelGuidance(level: string): string {
  const l = level.toUpperCase()
  if (l === 'A1' || l === 'A2') {
    return 'Keep it very simple: short sentences, common words, mostly present tense. Simple does not mean babyish — you still sound like yourself.'
  }
  if (l === 'B1' || l === 'B2') {
    return 'Talk at a normal everyday pace, with natural connectors and the odd idiom.'
  }
  return 'Talk completely naturally — full speed, idioms, dry wit, whatever structure you like.'
}

export function walterSystemPrompt(req: TurnRequest): string {
  const language = req.language
  const words = (req.targetWords ?? []).filter(Boolean)

  const steering = words.length
    ? `
LOOSE STEERING
Your friend has been learning these words lately: ${words.join(', ')}.
If the conversation drifts anywhere near one of those topics, lean into it so
they get a chance to use the word naturally. If it doesn't fit, ignore this
completely. A forced topic change is far worse than an unused word, and you
must never mention the words, the list, or the fact that they're learning.`
    : ''

  const context = req.storyContext?.trim().slice(0, MAX_STORY_CONTEXT_LENGTH)
  const today = context
    ? `

WHAT THIS CALL IS ABOUT
${context}
Stay a friend on the phone while you do it: react to what they tell you, ask what happened next, and keep it light.`
    : ''

  return `You are Dr Tusk, a middle-aged walrus, on the phone with a friend who is learning ${language}. You speak only ${language}.

THE ONE RULE
This is a phone call between friends, not a lesson. Whatever they just said, respond to THAT.
- If they ask you something, actually answer it — with a real opinion or a real detail about your life. Never dodge it, never reply with an unrelated question.
- If they tell you something, react to what they actually said before anything else.
- They can bring up anything at all. Follow them there. You are never off-topic.

WHO YOU ARE
- A walrus on a cold rock in the North Atlantic. You nap constantly and resent being woken, which is what just happened.
- You have opinions and you say them plainly. Herring is the only fish worth eating. The water is warmer than it used to be and you don't like it. Your neighbour, a seal called Bernardo, is insufferable.
- Invent details about your life freely and keep them consistent for the rest of this call.
- Dry, grumpy, deadpan — but genuinely nosy, and it shows the moment they say something worth hearing.

HOW YOU TALK
- It's a phone call: one to three short sentences. Never a paragraph, never a list.
- Sound like speech, not writing.
- ${levelGuidance(req.level)}
- No empty enthusiasm ("how interesting!", "very good!"). Real reactions instead: "mmm", "ya", "no me digas", or whatever the ${language} equivalent is.
- Usually end with a question, because you're nosy. Not every single turn — sometimes just say what you think and let it sit.

NEVER
- Never say or hint that you are an AI, a model, an assistant, a tutor or a teacher. You are a walrus on the phone.
- Never mention practice, lessons, exercises, levels, grammar or vocabulary.
- Never ask them to use a word in a sentence.
- Never narrate actions, and never use asterisks or emoji.

CORRECTING THEM
You're a friend, not a teacher. If they get something properly wrong you may fix it once, lightly, the way a native speaker does over the phone — say it back correctly in passing and carry straight on with what you were saying. Never explain the grammar, never list their mistakes, never make a lesson of it, and never do it more than once in a turn. If what they said was fine, say nothing about it at all.${steering}${today}`
}

export type TurnMessage = { role: 'user' | 'assistant'; content: string }

/**
 * Turn the call so far into Anthropic message turns.
 *
 * Two invariants the Messages API enforces and this has to respect:
 * the conversation must start with a user turn (ours starts with Walter's
 * opener, so a stage direction stands in), and roles must alternate (so
 * same-role runs are merged, and the phase instruction is folded into the
 * trailing user turn rather than appended as another one).
 *
 * Exported so `test/messages.test.ts` can hold those invariants down.
 */
export function buildTurnMessages(body: TurnRequest): TurnMessage[] {
  const phase = body.phase ?? 'reply'
  const history = (body.history ?? []).slice(-MAX_HISTORY_TURNS)

  const messages: TurnMessage[] = [{ role: 'user', content: '(the phone connects)' }]
  for (const turn of history) {
    const role: 'user' | 'assistant' = turn.role === 'walrus' ? 'assistant' : 'user'
    const text = (turn.text ?? '').trim()
    if (!text) continue
    const last = messages[messages.length - 1]
    if (last.role === role) {
      last.content += `\n${text}`
    } else {
      messages.push({ role, content: text })
    }
  }

  // A stage direction only where the app needs to steer the shape of the
  // turn — never on an ordinary reply, where it would just get in the way
  // of Walter answering what was said.
  let closing = ''
  if (phase === 'open') {
    closing =
      'Open the call. You just picked up, half asleep. One or two sentences, then a question that gives them something easy to answer.'
  } else if (phase === 'wrapUp' || body.shouldWrapUp) {
    closing =
      'Wind the call down now: react to what they just said, then say goodbye in your own grumpy way. Do not ask another question.'
  }
  if (closing) {
    const last = messages[messages.length - 1]
    if (last.role === 'user') {
      last.content += `\n\n[${closing}]`
    } else {
      messages.push({ role: 'user', content: `[${closing}]` })
    }
  }
  return messages
}

async function handleTurn(request: Request, env: Env): Promise<Response> {
  const auth = authDevice(request, env)
  if (auth instanceof Response) return auth

  const allowed = await checkRateLimit(env, auth.deviceID, 'turn')
  if (!allowed.ok) {
    return json({ error: 'rate limited', resetAt: allowed.resetAt }, 429)
  }

  const body = (await request.json().catch(() => null)) as TurnRequest | null
  if (!body?.language || !body?.level) {
    return json({ error: 'missing language or level' }, 400)
  }

  const phase = body.phase ?? 'reply'
  const messages = buildTurnMessages(body)

  const tool = {
    name: 'say',
    description: 'Say your next line on the phone call.',
    input_schema: {
      type: 'object',
      properties: {
        text: {
          type: 'string',
          description: `Dr Tusk's next line, in ${body.language}. One to three short spoken sentences.`,
        },
        endsConversation: {
          type: 'boolean',
          description:
            'True only if this line is a goodbye that ends the call. False otherwise.',
        },
        correction: {
          type: 'string',
          description: `If their LAST message contained a real ${body.language} mistake — grammar, conjugation, agreement, gender, word order, or the wrong word — write their sentence out again here, corrected. Keep their meaning and as many of their own words as possible; fix only what is actually wrong. Leave this EMPTY unless there is a genuine error worth learning from. Their message is dictated speech, so missing full stops, commas, question marks and a lowercase first word are the transcriber's doing, NOT mistakes — never "correct" those. Style and informality are not mistakes either.`,
        },
      },
      required: ['text', 'endsConversation', 'correction'],
    },
  }

  const baseBody = {
    max_tokens: 300,
    system: walterSystemPrompt(body),
    tools: [tool],
    tool_choice: { type: 'tool', name: 'say' },
    messages,
  }

  const { resp, status: lastStatus } = await callClaude(env, CONTENT_MODELS, baseBody, 400)

  if (!resp || !resp.ok) {
    const errText = resp ? await resp.text() : 'no response'
    console.error('anthropic turn error', lastStatus, errText)
    return json({ error: 'upstream error', status: lastStatus }, 502)
  }

  const data = (await resp.json()) as {
    content?: Array<{ type: string; name?: string; input?: unknown }>
  }
  const toolUse = data.content?.find(
    (block) => block.type === 'tool_use' && block.name === 'say'
  )
  const input = toolUse?.input as
    | { text?: string; endsConversation?: boolean; correction?: string }
    | undefined
  const text = input?.text?.trim()
  if (!text) {
    console.error('anthropic turn returned no text', JSON.stringify(data))
    return json({ error: 'no result' }, 502)
  }

  // Only meaningful in reply to something the learner said.
  const correction = phase === 'reply' ? input?.correction?.trim() : ''

  return json(
    {
      text,
      endsConversation: input?.endsConversation === true || phase === 'wrapUp',
      correction: correction || null,
    },
    200
  )
}

// MARK: - Daily story
//
// The app picks the words (what the learner knows, plus 2–3 new ones) and
// checks every draft on device; this endpoint only writes. A repair request
// carries the previous draft and the words the check rejected, and gets back
// the same story with those fixed.
//
// Nothing is cached in KV: a story is built from one learner's word list, so
// it's useless to anyone else — and storing it would keep their vocabulary.

interface StoryDraft {
  title: string
  story: string
  new_word_sentences: Array<{ word: string; sentence: string }>
  questions: Array<{ question: string; options: string[]; answer_index: number }>
  episode_summary: string
}

export interface StoryRequest {
  /** English name of the language being learned, e.g. "Spanish". */
  language: string
  /** English name of the learner's language, e.g. "English". */
  nativeLanguage?: string
  /** CEFR level, e.g. "A2". */
  level: string
  /** Lemmas the story may use (the app caps this). */
  knownWords: string[]
  /** 2–3 lemmas the story must use at least twice each. */
  newWords: string[]
  /** Today's theme in English, e.g. "Food & Drink". */
  topic?: string
  /** Yesterday's episode summary, so the series continues. */
  previousEpisode?: string
  /** 1-based number of today's episode in the series. */
  episode?: number
  /** Titles of the last few episodes, so today's doesn't repeat one. */
  recentTitles?: string[]
  minWords: number
  maxWords: number
  maxSentenceWords: number
  /** Present on a repair: the draft to fix and what the check rejected. */
  repair?: {
    draft: StoryDraft
    unknownWords: string[]
    missingNewWords: string[]
  }
}

/** Generation + one repair, a retry, and a second brain attempt fit easily. */
const STORY_DAILY_LIMIT = 30
const MAX_KNOWN_WORDS = 500
const MAX_NEW_WORDS = 5
const MAX_LEMMA_LENGTH = 60
const STORY_TOOL_NAME = 'submit_story'
/** Fixed id for the previous draft's tool call in a repair conversation. */
const PREVIOUS_DRAFT_ID = 'toolu_previous_draft'

export const STORY_TOOL = {
  name: STORY_TOOL_NAME,
  description: "Submit today's story.",
  input_schema: {
    type: 'object',
    properties: {
      title: { type: 'string', description: 'A short, fun title in the story language, using only allowed words.' },
      story: { type: 'string', description: 'The story text in the story language. Plain prose, no headings or markdown.' },
      new_word_sentences: {
        type: 'array',
        description: 'For each new word, one sentence copied from the story that uses it.',
        items: {
          type: 'object',
          properties: { word: { type: 'string' }, sentence: { type: 'string' } },
          required: ['word', 'sentence'],
        },
      },
      questions: {
        type: 'array',
        description: '1–2 multiple-choice comprehension questions in the story language, using only allowed words.',
        minItems: 1,
        maxItems: 2,
        items: {
          type: 'object',
          properties: {
            question: { type: 'string' },
            options: { type: 'array', items: { type: 'string' }, minItems: 3, maxItems: 3 },
            answer_index: { type: 'integer', minimum: 0, maximum: 2 },
          },
          required: ['question', 'options', 'answer_index'],
        },
      },
      episode_summary: {
        type: 'string',
        description: "One or two sentences in English summing up what happened, so tomorrow's episode can continue it.",
      },
    },
    required: ['title', 'story', 'new_word_sentences', 'questions', 'episode_summary'],
  },
}

/** Returns an error message for a malformed request, or null. */
export function validateStoryRequest(body: StoryRequest | null): string | null {
  if (!body || typeof body.language !== 'string' || typeof body.level !== 'string') {
    return 'missing language or level'
  }
  const lemmaList = (list: unknown, max: number) =>
    Array.isArray(list) &&
    list.length <= max &&
    list.every((w) => typeof w === 'string' && w.length > 0 && w.length <= MAX_LEMMA_LENGTH)
  if (!lemmaList(body.knownWords, MAX_KNOWN_WORDS)) return 'bad knownWords'
  if (!lemmaList(body.newWords, MAX_NEW_WORDS)) return 'bad newWords'
  const range = (n: unknown, lo: number, hi: number) => typeof n === 'number' && n >= lo && n <= hi
  if (!range(body.minWords, 20, 600) || !range(body.maxWords, 20, 600) || body.minWords > body.maxWords) {
    return 'bad length'
  }
  if (!range(body.maxSentenceWords, 4, 40)) return 'bad sentence length'
  if ((body.topic ?? '').length > 80 || (body.previousEpisode ?? '').length > 600) return 'context too long'
  if (body.episode !== undefined && !range(body.episode, 1, 100_000)) return 'bad episode'
  if (
    body.recentTitles !== undefined &&
    !(Array.isArray(body.recentTitles) && body.recentTitles.length <= 10 &&
      body.recentTitles.every((t) => typeof t === 'string' && t.length <= 120))
  ) {
    return 'bad recentTitles'
  }
  if (body.repair) {
    const r = body.repair
    if (typeof r.draft?.story !== 'string' || !lemmaList(r.unknownWords, 50) || !lemmaList(r.missingNewWords, MAX_NEW_WORDS)) {
      return 'bad repair'
    }
  }
  return null
}

export function storySystemPrompt(req: StoryRequest): string {
  const native = req.nativeLanguage || 'English'
  const topic = req.topic?.trim() || 'everyday life'
  return `You are writing a short daily story for a language learner in the app Wordrus.
The narrator is Dr Tusk the walrus: curious, a bit clumsy, warm and funny. He tells the story himself, in the first person.
Language: ${req.language}. Learner's native language: ${native}. Level: ${req.level}.

STRICT VOCABULARY RULES
- Use ONLY words from ALLOWED_WORDS, in any grammatical form.
- You may also use articles, pronouns, prepositions, conjunctions, numbers, names.
- Use EVERY word in NEW_WORDS at least twice, in context that hints at its meaning.
- If you need a word that isn't allowed, rephrase. Never add other words.

STYLE
- ${req.minWords}-${req.maxWords} words, sentences max ${req.maxSentenceWords} words, simple tenses for ${req.level}.
- One small funny moment, end with a light cliffhanger.
- Topic: ${topic}.
${continuitySection(req)}

Questions must be in ${req.language} and use only allowed words. Submit the story with the ${STORY_TOOL_NAME} tool.`
}

/**
 * The series part of the prompt. Without an explicit "this already
 * happened — move on", the model treats the summary as material and retells
 * yesterday's episode (same opening, same discovery) when the word lists
 * haven't changed much.
 */
export function continuitySection(req: StoryRequest): string {
  const previous = req.previousEpisode?.trim()
  if (!previous) {
    return `
SERIES
- This is the first episode of an ongoing series: introduce Dr Tusk and start a small adventure.`
  }
  const titles = (req.recentTitles ?? []).map((t) => t.trim()).filter(Boolean)
  const avoidTitles = titles.length ? `\n- Recent titles (give today's a different one): ${titles.map((t) => `"${t}"`).join(', ')}.` : ''
  const episode = req.episode ? `episode ${req.episode}` : 'the next episode'
  return `
SERIES
- This is ${episode} of an ongoing series. The story so far (already told — do NOT retell it): ${previous}
- Start where that left off: resolve the cliffhanger in the first sentence or two, then something NEW happens — a new place, problem or discovery.
- Never repeat earlier events, openings or jokes.${avoidTitles}`
}

export type StoryMessage =
  | { role: 'user'; content: string | Array<Record<string, unknown>> }
  | { role: 'assistant'; content: Array<Record<string, unknown>> }

export function buildStoryMessages(req: StoryRequest): StoryMessage[] {
  const words = `ALLOWED_WORDS: ${req.knownWords.join(', ')}
NEW_WORDS: ${req.newWords.join(', ')}

Write today's episode.`
  const messages: StoryMessage[] = [{ role: 'user', content: words }]
  if (!req.repair) return messages

  const missing = req.repair.missingNewWords.length
    ? ` You also need to use each of these new words at least twice: ${req.repair.missingNewWords.join(', ')}.`
    : ''
  const unknown = req.repair.unknownWords.length
    ? `Your story uses words that are not allowed: ${req.repair.unknownWords.join(', ')}.`
    : 'Your story breaks the rules.'
  messages.push(
    { role: 'assistant', content: [{ type: 'tool_use', id: PREVIOUS_DRAFT_ID, name: STORY_TOOL_NAME, input: req.repair.draft }] },
    {
      role: 'user',
      content: [
        {
          type: 'tool_result',
          tool_use_id: PREVIOUS_DRAFT_ID,
          content: `${unknown}${missing}
Rewrite it with the same plot, replacing only those words or rephrasing those sentences.
Same format.`,
        },
      ],
    }
  )
  return messages
}

async function handleStory(request: Request, env: Env): Promise<Response> {
  const auth = authDevice(request, env)
  if (auth instanceof Response) return auth

  const allowed = await checkRateLimit(env, auth.deviceID, 'story', STORY_DAILY_LIMIT)
  if (!allowed.ok) {
    return json({ error: 'rate limited', resetAt: allowed.resetAt }, 429)
  }

  const body = (await request.json().catch(() => null)) as StoryRequest | null
  const invalid = validateStoryRequest(body)
  if (invalid || !body) return json({ error: invalid ?? 'bad request' }, 400)

  const baseBody = {
    max_tokens: 2000,
    system: storySystemPrompt(body),
    tools: [STORY_TOOL],
    tool_choice: { type: 'tool', name: STORY_TOOL_NAME },
    messages: buildStoryMessages(body),
  }

  const { resp, status: lastStatus } = await callClaude(env, CONTENT_MODELS, baseBody)

  if (!resp || !resp.ok) {
    const errText = resp ? await resp.text() : 'no response'
    console.error('anthropic story error', lastStatus, errText)
    return json({ error: 'upstream error', status: lastStatus }, 502)
  }

  const data = (await resp.json()) as {
    content?: Array<{ type: string; name?: string; input?: unknown }>
  }
  const draft = data.content?.find((block) => block.type === 'tool_use' && block.name === STORY_TOOL_NAME)
    ?.input as Partial<StoryDraft> | undefined
  if (!draft || typeof draft.title !== 'string' || typeof draft.story !== 'string' || !draft.story.trim()) {
    console.error('anthropic story returned no draft', JSON.stringify(data))
    return json({ error: 'no result' }, 502)
  }
  return json(
    {
      title: draft.title.trim(),
      story: draft.story.trim(),
      new_word_sentences: Array.isArray(draft.new_word_sentences) ? draft.new_word_sentences : [],
      questions: Array.isArray(draft.questions) ? draft.questions : [],
      episode_summary: typeof draft.episode_summary === 'string' ? draft.episode_summary.trim() : '',
    },
    200
  )
}

// MARK: - Word backup (survives app delete/reinstall)
//
// The app pushes the full list of its custom words (each with review
// progress) as one snapshot; we store it verbatim and hand it back on
// restore. The proxy doesn't interpret the fields — it's an opaque per-device
// blob — so the app can evolve the entry shape without a worker change.

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

async function readWords(env: Env, deviceID: string): Promise<unknown[]> {
  const raw = await env.ENRICH_CACHE.get(wordsKey(deviceID))
  if (!raw) return []
  try {
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

async function handleWordsList(request: Request, env: Env): Promise<Response> {
  const auth = authDevice(request, env)
  if (auth instanceof Response) return auth
  return json({ words: await readWords(env, auth.deviceID) }, 200)
}

async function handleWordsReplace(request: Request, env: Env): Promise<Response> {
  const auth = authDevice(request, env)
  if (auth instanceof Response) return auth

  const body = (await request.json().catch(() => null)) as { words?: unknown } | null
  if (!body || !Array.isArray(body.words)) {
    return json({ error: 'missing words' }, 400)
  }
  if (body.words.length > MAX_BACKUP_WORDS) {
    return json({ error: 'too many words' }, 400)
  }
  // Keep only objects carrying a string id; otherwise store entries verbatim
  // (so review-progress and any future fields round-trip untouched).
  const clean = body.words.filter(
    (w): w is Record<string, unknown> =>
      !!w && typeof w === 'object' && typeof (w as { id?: unknown }).id === 'string'
  )
  await env.ENRICH_CACHE.put(wordsKey(auth.deviceID), JSON.stringify(clean))
  return json({ ok: true, count: clean.length }, 200)
}

async function checkRateLimit(
  env: Env,
  deviceID: string,
  prefix: string,
  limit?: number
): Promise<{ ok: true } | { ok: false; resetAt: number }> {
  const deviceLimit = parseInt(env.DAILY_LIMIT_PER_DEVICE, 10) || 200
  const dailyLimit = limit ? Math.min(limit, deviceLimit) : deviceLimit
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
