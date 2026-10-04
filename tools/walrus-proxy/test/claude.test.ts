import { strict as assert } from 'node:assert'
import { afterEach, test } from 'node:test'
import { CONTENT_MODELS, callClaude, type Env } from '../src/index.ts'

const env = { ANTHROPIC_API_KEY: 'test' } as Env
const realFetch = globalThis.fetch

/** Replies with `statuses` in order and records which model each call asked for. */
function stubFetch(statuses: number[]): string[] {
  const models: string[] = []
  globalThis.fetch = (async (_url: unknown, init?: { body?: string }) => {
    models.push(JSON.parse(init?.body ?? '{}').model)
    return new Response('{}', { status: statuses.shift() ?? 500 })
  }) as typeof fetch
  return models
}

afterEach(() => {
  globalThis.fetch = realFetch
})

test('every route shares one model list, Haiku first', () => {
  assert.deepEqual(CONTENT_MODELS, ['claude-haiku-4-5-20251001', 'claude-sonnet-4-6'])
})

test('success on the first model makes one request', async () => {
  const models = stubFetch([200])
  const { resp } = await callClaude(env, CONTENT_MODELS, {}, 0)
  assert.equal(resp?.ok, true)
  assert.deepEqual(models, [CONTENT_MODELS[0]])
})

test('an unknown model falls through to the next one', async () => {
  const models = stubFetch([404, 200])
  const { resp } = await callClaude(env, CONTENT_MODELS, {}, 0)
  assert.equal(resp?.ok, true)
  assert.deepEqual(models, CONTENT_MODELS)
})

test('overload retries once, then fails over', async () => {
  const models = stubFetch([529, 529, 200])
  const { resp } = await callClaude(env, CONTENT_MODELS, {}, 0)
  assert.equal(resp?.ok, true)
  assert.deepEqual(models, [CONTENT_MODELS[0], CONTENT_MODELS[0], CONTENT_MODELS[1]])
})

test('a bad request stops without trying other models', async () => {
  const models = stubFetch([400])
  const { resp, status } = await callClaude(env, CONTENT_MODELS, {}, 0)
  assert.equal(status, 400)
  assert.equal(resp?.ok, false)
  assert.equal(models.length, 1)
})
