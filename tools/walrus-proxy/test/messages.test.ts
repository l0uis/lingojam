import { strict as assert } from 'node:assert'
import { test } from 'node:test'
import { buildTurnMessages } from '../src/index.ts'

/**
 * The Messages API rejects a conversation that doesn't start with a user
 * turn or that repeats a role. Both are easy to break by accident here
 * (our call starts with Walter, and the phase instruction is a user turn
 * appended after the learner's own), and either one fails every single
 * request — so they're pinned down.
 */
function assertValidShape(messages: Array<{ role: string; content: string }>) {
  assert.ok(messages.length > 0, 'must not be empty')
  assert.equal(messages[0].role, 'user', 'must open with a user turn')
  for (let i = 1; i < messages.length; i++) {
    assert.notEqual(
      messages[i].role,
      messages[i - 1].role,
      `roles must alternate (index ${i})`
    )
  }
  for (const m of messages) {
    assert.ok(m.content.trim().length > 0, 'no empty message content')
  }
}

const base = { language: 'Spanish', level: 'A2' }

test('opening a call is a single valid user turn', () => {
  const messages = buildTurnMessages({ ...base, phase: 'open', history: [] })
  assertValidShape(messages)
  assert.equal(messages.length, 1)
  assert.match(messages[0].content, /Open the call/)
})

test('a reply keeps Walter as assistant and the learner as user', () => {
  const messages = buildTurnMessages({
    ...base,
    phase: 'reply',
    history: [
      { role: 'walrus', text: '¿Qué tal?' },
      { role: 'user', text: 'Bien, gracias' },
    ],
  })
  assertValidShape(messages)
  assert.equal(messages[messages.length - 1].role, 'user')
  assert.equal(messages[messages.length - 1].content, 'Bien, gracias')
})

test('an ordinary reply carries no stage direction', () => {
  const messages = buildTurnMessages({
    ...base,
    phase: 'reply',
    history: [
      { role: 'walrus', text: '¿Qué tal?' },
      { role: 'user', text: '¿Dónde vives?' },
    ],
  })
  assert.ok(!messages.some((m) => m.content.includes('[')), 'no bracketed aside')
})

/// The learner's turn is always last, so a naively pushed instruction
/// would be a second consecutive user message and 400 the whole request.
test('the wrap-up instruction folds into the learner’s turn', () => {
  const messages = buildTurnMessages({
    ...base,
    phase: 'wrapUp',
    history: [
      { role: 'walrus', text: '¿Qué tal?' },
      { role: 'user', text: 'Bien' },
    ],
  })
  assertValidShape(messages)
  const last = messages[messages.length - 1]
  assert.equal(last.role, 'user')
  assert.match(last.content, /^Bien\n\n\[Wind the call down/)
})

test('shouldWrapUp on a reply behaves the same way', () => {
  const messages = buildTurnMessages({
    ...base,
    phase: 'reply',
    shouldWrapUp: true,
    history: [
      { role: 'walrus', text: 'Hola' },
      { role: 'user', text: 'Adiós' },
    ],
  })
  assertValidShape(messages)
  assert.match(messages[messages.length - 1].content, /Wind the call down/)
})

/// Walter's silence nudges mean two of his lines can land back to back.
test('consecutive same-role turns are merged', () => {
  const messages = buildTurnMessages({
    ...base,
    phase: 'reply',
    history: [
      { role: 'walrus', text: '¿Qué tal?' },
      { role: 'walrus', text: '¿Sigues ahí?' },
      { role: 'user', text: 'Perdona' },
    ],
  })
  assertValidShape(messages)
  const walrus = messages.find((m) => m.role === 'assistant')
  assert.equal(walrus?.content, '¿Qué tal?\n¿Sigues ahí?')
})

/// A nudge can also be the final thing said before the app asks for a turn.
test('history ending on Walter still produces a valid shape', () => {
  const messages = buildTurnMessages({
    ...base,
    phase: 'wrapUp',
    history: [
      { role: 'user', text: 'Hola' },
      { role: 'walrus', text: '¿Sigues ahí?' },
    ],
  })
  assertValidShape(messages)
  assert.equal(messages[messages.length - 1].role, 'user')
})

test('blank turns are dropped rather than sent as empty content', () => {
  const messages = buildTurnMessages({
    ...base,
    phase: 'reply',
    history: [
      { role: 'walrus', text: 'Hola' },
      { role: 'user', text: '   ' },
      { role: 'user', text: 'Aquí estoy' },
    ],
  })
  assertValidShape(messages)
})

test('history is capped so a long call cannot grow unbounded', () => {
  const history = Array.from({ length: 100 }, (_, i) => ({
    role: i % 2 === 0 ? 'walrus' : 'user',
    text: `line ${i}`,
  }))
  const messages = buildTurnMessages({ ...base, phase: 'reply', history })
  assertValidShape(messages)
  assert.ok(messages.length <= 26, `expected a capped history, got ${messages.length}`)
})
