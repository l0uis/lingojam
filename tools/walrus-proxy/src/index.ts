/**
 * Cloudflare Worker proxy for OpenAI TTS. Holds the OpenAI API key as
 * a Worker secret so the iOS app never has to ship it. Per-device rate
 * limiting via KV keeps abuse bounded if the proxy URL leaks.
 *
 * See ../README.md for deployment steps.
 */

export interface Env {
  OPENAI_API_KEY: string
  RATE_LIMIT: KVNamespace
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

const MAX_TEXT_LENGTH = 4000

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

  const allowed = await checkRateLimit(env, deviceID)
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

async function checkRateLimit(
  env: Env,
  deviceID: string
): Promise<{ ok: true } | { ok: false; resetAt: number }> {
  const dailyLimit = parseInt(env.DAILY_LIMIT_PER_DEVICE, 10) || 200
  const today = new Date().toISOString().slice(0, 10) // YYYY-MM-DD UTC
  const key = `tts:${deviceID}:${today}`
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
  headers.set('access-control-allow-methods', 'POST, OPTIONS')
  headers.set('access-control-allow-headers', 'content-type, x-walrus-device-id, x-walrus-bundle-id')
  return new Response(resp.body, { status: resp.status, headers })
}
