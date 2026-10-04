import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import {
  STORY_TOOL,
  buildStoryMessages,
  storySystemPrompt,
  validateStoryRequest,
  walterSystemPrompt,
  type StoryRequest,
} from '../src/index.ts'

function request(overrides: Partial<StoryRequest> = {}): StoryRequest {
  return {
    language: 'Spanish',
    nativeLanguage: 'English',
    level: 'A1',
    knownWords: ['ir', 'playa', 'comer'],
    newWords: ['pez', 'salir'],
    topic: 'Animals',
    previousEpisode: 'Dr Tusk found a note on the beach.',
    minWords: 70,
    maxWords: 120,
    maxSentenceWords: 8,
    ...overrides,
  }
}

test('system prompt carries the rules, level, length and topic', () => {
  const system = storySystemPrompt(request())
  assert.match(system, /Use ONLY words from ALLOWED_WORDS/)
  assert.match(system, /Use EVERY word in NEW_WORDS at least twice/)
  assert.match(system, /70-120 words, sentences max 8 words, simple tenses for A1/)
  assert.match(system, /Topic: Animals\./)
  assert.match(system, /Questions must be in Spanish/)
  assert.match(system, /Dr Tusk/)
})

test('a later episode says the story so far is already told and must move on', () => {
  const system = storySystemPrompt(request({ episode: 4, recentTitles: ['La nota', 'El viaje'] }))
  assert.match(system, /This is episode 4 of an ongoing series/)
  assert.match(system, /already told — do NOT retell it\): Dr Tusk found a note on the beach\./)
  assert.match(system, /resolve the cliffhanger/)
  assert.match(system, /something NEW happens/)
  assert.match(system, /Never repeat earlier events/)
  assert.match(system, /give today's a different one\): "La nota", "El viaje"/)
})

test('the first episode and a missing topic get sensible defaults', () => {
  const system = storySystemPrompt(request({ previousEpisode: undefined, topic: undefined }))
  assert.match(system, /This is the first episode of an ongoing series/)
  assert.doesNotMatch(system, /do NOT retell/)
  assert.match(system, /Topic: everyday life\./)
})

test('older apps without episode or titles still get the continuity rules', () => {
  const system = storySystemPrompt(request())
  assert.match(system, /This is the next episode of an ongoing series/)
  assert.doesNotMatch(system, /Recent titles/)
})

test('generation is a single user turn with the word lists', () => {
  const messages = buildStoryMessages(request())
  assert.equal(messages.length, 1)
  assert.equal(messages[0].role, 'user')
  assert.match(messages[0].content as string, /ALLOWED_WORDS: ir, playa, comer\nNEW_WORDS: pez, salir/)
})

test('repair replays the draft as a tool call and answers it with the rejected words', () => {
  const draft = {
    title: 'T', story: 'Dr Tusk come una manzana.', new_word_sentences: [], questions: [], episode_summary: 'E',
  }
  const messages = buildStoryMessages(request({
    repair: { draft, unknownWords: ['manzana'], missingNewWords: ['salir'] },
  }))
  assert.deepEqual(messages.map((m) => m.role), ['user', 'assistant', 'user'])
  const call = (messages[1].content as Array<Record<string, unknown>>)[0]
  assert.equal(call.type, 'tool_use')
  assert.equal(call.name, STORY_TOOL.name)
  assert.deepEqual(call.input, draft)
  const result = (messages[2].content as Array<Record<string, unknown>>)[0]
  assert.equal(result.type, 'tool_result')
  assert.equal(result.tool_use_id, call.id)
  assert.match(result.content as string, /not allowed: manzana\./)
  assert.match(result.content as string, /at least twice: salir\./)
  assert.match(result.content as string, /same plot/)
})

test('validation rejects malformed requests', () => {
  assert.equal(validateStoryRequest(request()), null)
  assert.equal(validateStoryRequest(null), 'missing language or level')
  assert.equal(validateStoryRequest(request({ knownWords: Array(501).fill('x') })), 'bad knownWords')
  assert.equal(validateStoryRequest(request({ newWords: ['a', 'b', 'c', 'd', 'e', 'f'] })), 'bad newWords')
  assert.equal(validateStoryRequest(request({ minWords: 200, maxWords: 100 })), 'bad length')
  assert.equal(validateStoryRequest(request({ maxSentenceWords: 100 })), 'bad sentence length')
  assert.equal(validateStoryRequest(request({ topic: 'x'.repeat(81) })), 'context too long')
  assert.equal(validateStoryRequest(request({ episode: 0 })), 'bad episode')
  assert.equal(validateStoryRequest(request({ recentTitles: Array(11).fill('t') })), 'bad recentTitles')
  assert.equal(validateStoryRequest(request({ episode: 3, recentTitles: ['a', 'b'] })), null)
  assert.equal(
    validateStoryRequest(request({ repair: { draft: {} as never, unknownWords: [], missingNewWords: [] } })),
    'bad repair'
  )
})

test('the tool schema matches what the app decodes', () => {
  const props = STORY_TOOL.input_schema.properties
  assert.deepEqual(
    Object.keys(props).sort(),
    ['episode_summary', 'new_word_sentences', 'questions', 'story', 'title']
  )
  assert.deepEqual(props.questions.items.required, ['question', 'options', 'answer_index'])
})

test('a retell call gets the story context; a normal call does not', () => {
  const retell = walterSystemPrompt({ language: 'Spanish', level: 'A1', storyContext: 'Ask them to retell "La nota".' })
  assert.match(retell, /WHAT THIS CALL IS ABOUT\nAsk them to retell "La nota"\./)
  const normal = walterSystemPrompt({ language: 'Spanish', level: 'A1' })
  assert.doesNotMatch(normal, /WHAT THIS CALL IS ABOUT/)
})
