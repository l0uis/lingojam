import Foundation
import SwiftData
import Testing
@testable import wordrus

/// Every call has to end with Walter's goodbye. When ending was left to the
/// brain's `endsConversation` flag, a goodbye the model forgot to flag kept
/// the call going forever.
@MainActor
struct CallEndingTests {
    /// Never says goodbye on its own and never flags an end — the worst case.
    private struct EndlessBrain: WalrusBrain {
        func openCall(level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            WalrusTurn(text: "Hola.", endsConversation: false)
        }
        func reply(history: [ChatTurn], level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            WalrusTurn(text: "¿Y qué más?", endsConversation: false)
        }
        func wrapUp(level: CEFRLevel, targetWords: [VocabularyWord], history: [ChatTurn]) async -> WalrusTurn {
            WalrusTurn(text: "Las has usado todas.", endsConversation: false)
        }
        func signOff(level: CEFRLevel, targetWords: [VocabularyWord], history: [ChatTurn]) async -> WalrusTurn {
            WalrusTurn(text: "Adiós.", endsConversation: false)
        }
        func evaluate(transcript: [ChatTurn], targetWords: [VocabularyWord], level: CEFRLevel) async -> ChatEvaluation {
            ChatEvaluation(elicitedWordIDs: [], passed: false, encouragement: "")
        }
    }

    @Test func callEndsWithGoodbyeAfterTurnBudget() async throws {
        let store = try makeStore(targetWords: [])
        await store.startIfNeeded()

        var userTurns = 0
        while store.phase != .finished, userTurns < 20 {
            await store.send("Pues nada, aquí estoy.")
            userTurns += 1
        }

        #expect(store.phase == .finished)
        #expect(userTurns == ChatStore.walrusTurnBudget)
        #expect(store.displayMessages.last?.text == "Adiós.")
    }

    @Test func usingEveryWordEndsWithTheCelebration() async throws {
        let word = VocabularyWord(
            id: "es-test-perro", rank: 1, lemma: "perro", partOfSpeech: "noun (masc.)",
            definitionsJSON: "[]", exampleSentence: "", exampleTranslationsJSON: "{}"
        )
        let store = try makeStore(targetWords: [word])
        await store.startIfNeeded()

        await store.send("Tengo un perro muy gordo.")

        #expect(store.phase == .finished)
        #expect(store.displayMessages.last?.text == "Las has usado todas.")
    }

    @Test func fourLearnerTurnsDoNotEndTheCall() async throws {
        let store = try makeStore(targetWords: [])
        await store.startIfNeeded()

        for _ in 0..<4 { await store.send("Pues nada, aquí estoy.") }

        // Five words in four turns was the old ceiling — he hung up on
        // almost everyone with a word still to go.
        #expect(store.phase == .awaitingUser)
    }

    @Test func walterOnlySteersTowardWordsStillToUse() async throws {
        let perro = makeWord("perro")
        let gato = makeWord("gato")
        let brain = RecordingBrain()
        let store = try makeStore(targetWords: [perro, gato], brain: brain)
        await store.startIfNeeded()

        await store.send("Tengo un perro.")

        #expect(brain.replyWords.last == ["gato"])
    }

    @Test func cuttingOffHisGoodbyeStillEndsTheCall() async throws {
        let store = try makeStore(targetWords: [], brain: HangUpBrain())
        let director = CallDirector(store: store)
        await director.start()

        // Reaching for the keyboard mid-goodbye used to cancel the drain
        // that ends the call, leaving the screen up until the red button.
        director.beginComposing()

        #expect(director.stage == .ended)
    }

    @Test func sayGoodbyeAppearsAtThePassMarkAndCompletesTheCall() async throws {
        let store = try makeStore(targetWords: [makeWord("perro"), makeWord("gato"), makeWord("casa")])
        await store.startIfNeeded()

        await store.send("Tengo un perro.")
        #expect(!store.canSayGoodbye)

        await store.send("Y también un gato.")
        #expect(store.canSayGoodbye)

        await store.sayGoodbye()
        #expect(store.phase == .finished)
        #expect(store.displayMessages.last?.text == "Adiós.")
        // Unlike the red button, leaving this way keeps the pass.
        #expect(store.evaluation?.passed == true)
    }

    @Test func hisLastReplyWarnsBeforeTheGoodbye() async throws {
        let store = try makeStore(targetWords: [], brain: LeavingSoonBrain())
        await store.startIfNeeded()

        while store.phase != .finished {
            await store.send("Pues nada, aquí estoy.")
        }

        let walrusLines = store.displayMessages.filter { $0.role == .walrus }.map(\.text)
        #expect(walrusLines.suffix(2) == ["Me tengo que ir pronto.", "Adiós."])
        #expect(walrusLines.filter { $0 == "Me tengo que ir pronto." }.count == 1)
    }

    /// Endless, except for the "I'll have to go soon" line.
    private struct LeavingSoonBrain: WalrusBrain {
        func openCall(level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            WalrusTurn(text: "Hola.", endsConversation: false)
        }
        func reply(history: [ChatTurn], level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            WalrusTurn(text: "¿Y qué más?", endsConversation: false)
        }
        func lastReply(history: [ChatTurn], level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            WalrusTurn(text: "Me tengo que ir pronto.", endsConversation: false)
        }
        func wrapUp(level: CEFRLevel, targetWords: [VocabularyWord], history: [ChatTurn]) async -> WalrusTurn {
            WalrusTurn(text: "Las has usado todas.", endsConversation: true)
        }
        func signOff(level: CEFRLevel, targetWords: [VocabularyWord], history: [ChatTurn]) async -> WalrusTurn {
            WalrusTurn(text: "Adiós.", endsConversation: true)
        }
        func evaluate(transcript: [ChatTurn], targetWords: [VocabularyWord], level: CEFRLevel) async -> ChatEvaluation {
            ChatEvaluation(elicitedWordIDs: [], passed: false, encouragement: "")
        }
    }

    /// Says goodbye in the opener.
    private struct HangUpBrain: WalrusBrain {
        func openCall(level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            WalrusTurn(text: "Adiós.", endsConversation: true)
        }
        func reply(history: [ChatTurn], level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            WalrusTurn(text: "Adiós.", endsConversation: true)
        }
        func wrapUp(level: CEFRLevel, targetWords: [VocabularyWord], history: [ChatTurn]) async -> WalrusTurn {
            WalrusTurn(text: "Adiós.", endsConversation: true)
        }
        func signOff(level: CEFRLevel, targetWords: [VocabularyWord], history: [ChatTurn]) async -> WalrusTurn {
            WalrusTurn(text: "Adiós.", endsConversation: true)
        }
        func evaluate(transcript: [ChatTurn], targetWords: [VocabularyWord], level: CEFRLevel) async -> ChatEvaluation {
            ChatEvaluation(elicitedWordIDs: [], passed: false, encouragement: "")
        }
    }

    /// Records the words Walter was asked to steer toward on each reply.
    private final class RecordingBrain: WalrusBrain {
        var replyWords: [[String]] = []
        func openCall(level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            WalrusTurn(text: "Hola.", endsConversation: false)
        }
        func reply(history: [ChatTurn], level: CEFRLevel, targetWords: [VocabularyWord]) async -> WalrusTurn {
            replyWords.append(targetWords.map(\.lemma))
            return WalrusTurn(text: "¿Y qué más?", endsConversation: false)
        }
        func wrapUp(level: CEFRLevel, targetWords: [VocabularyWord], history: [ChatTurn]) async -> WalrusTurn {
            WalrusTurn(text: "Las has usado todas.", endsConversation: true)
        }
        func signOff(level: CEFRLevel, targetWords: [VocabularyWord], history: [ChatTurn]) async -> WalrusTurn {
            WalrusTurn(text: "Adiós.", endsConversation: true)
        }
        func evaluate(transcript: [ChatTurn], targetWords: [VocabularyWord], level: CEFRLevel) async -> ChatEvaluation {
            ChatEvaluation(elicitedWordIDs: [], passed: false, encouragement: "")
        }
    }

    private func makeWord(_ lemma: String) -> VocabularyWord {
        VocabularyWord(
            id: "es-test-\(lemma)", rank: 1, lemma: lemma, partOfSpeech: "noun (masc.)",
            definitionsJSON: "[]", exampleSentence: "", exampleTranslationsJSON: "{}"
        )
    }

    private func makeStore(targetWords: [VocabularyWord], brain: WalrusBrain? = nil) throws -> ChatStore {
        let schema = Schema([VocabularyWord.self, LearningProgress.self, ReviewLog.self, Deck.self, ChatSession.self, ChatMessage.self, DailyStory.self])
        let context = ModelContext(try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)))
        let store = ChatStore(brain: brain ?? EndlessBrain(), context: context, level: .a1, targetWords: targetWords)
        // Take over voicing so the test never reaches the speech engine.
        store.onWalrusUtterance = { _ in }
        return store
    }
}
