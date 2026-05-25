import Foundation
import Testing
@testable import lingojam

@MainActor
struct WalrusBrainTests {
    // MARK: - Lemma matcher

    @Test func directLemmaMatches() {
        #expect(SpanishLemmaMatcher.userText("Me gusta el café", mentions: "café", partOfSpeech: "noun"))
    }

    @Test func diacriticInsensitive() {
        #expect(SpanishLemmaMatcher.userText("me gusta el cafe", mentions: "café", partOfSpeech: "noun"))
        #expect(SpanishLemmaMatcher.userText("¿Qué tal?", mentions: "que", partOfSpeech: "pronoun"))
    }

    @Test func verbInflectionMatchesViaStem() {
        // "cocinar" → stem "cocin" → matches "cocino", "cocinas", "cociné"
        #expect(SpanishLemmaMatcher.userText("Yo cocino los domingos", mentions: "cocinar", partOfSpeech: "verb"))
        #expect(SpanishLemmaMatcher.userText("¿Tú cocinas mucho?", mentions: "cocinar", partOfSpeech: "verb"))
    }

    @Test func pluralNounMatches() {
        #expect(SpanishLemmaMatcher.userText("Tengo dos gatos", mentions: "gato", partOfSpeech: "noun"))
        #expect(SpanishLemmaMatcher.userText("Vimos los árboles", mentions: "árbol", partOfSpeech: "noun"))
    }

    @Test func genderSwapMatches() {
        #expect(SpanishLemmaMatcher.userText("Es una niña pequeña", mentions: "pequeño", partOfSpeech: "adjective"))
    }

    @Test func nonMatchingTextIsRejected() {
        #expect(!SpanishLemmaMatcher.userText("Hoy hace frío", mentions: "cocinar", partOfSpeech: "verb"))
        #expect(!SpanishLemmaMatcher.userText("Buenos días", mentions: "gato", partOfSpeech: "noun"))
    }

    @Test func shortStemDoesNotOverMatch() {
        // "ir" (verb) has only a 0-char stem → matcher must NOT match every word.
        #expect(!SpanishLemmaMatcher.userText("Hola amigo", mentions: "ir", partOfSpeech: "verb"))
    }

    // MARK: - CEFR enum

    @Test func cefrOrderingAndPromotion() {
        #expect(CEFRLevel.a1 < CEFRLevel.a2)
        #expect(CEFRLevel.b2 < CEFRLevel.c1)
        #expect(CEFRLevel.a1.next == .a2)
        #expect(CEFRLevel.c2.next == nil)
        #expect(CEFRLevel.a1.previous == nil)
        #expect(CEFRLevel.b1.previous == .a2)
    }

    // MARK: - Mock brain conversation flow

    @Test func mockBrainOpensWithOpener() async {
        let brain = MockWalrusBrain()
        let turn = await brain.openCall(level: .a1, targetWords: [])
        #expect(!turn.text.isEmpty)
        #expect(!turn.endsConversation)
    }

    @Test func mockBrainEndsAfterPromptBudget() async {
        let brain = MockWalrusBrain()
        // Brain produces 1 opener + promptTurnCount prompts + 1 closer.
        // Build history with the opener and all prompt turns already done,
        // then a final user reply — next walrus turn should be the closer.
        var history: [ChatTurn] = [ChatTurn(role: .walrus, text: "opener")]
        for i in 0..<MockWalrusBrain.promptTurnCount {
            history.append(ChatTurn(role: .user, text: "u\(i)"))
            history.append(ChatTurn(role: .walrus, text: "prompt\(i)"))
        }
        history.append(ChatTurn(role: .user, text: "u-final"))
        let turn = await brain.reply(history: history, level: .a1, targetWords: [])
        #expect(turn.endsConversation)
    }

    // MARK: - Migrator

    @Test func vocabularyMigratorMapsCorrectly() {
        let defaults = UserDefaults.standard
        let key = OnboardingDefaultsKey.cefrLevel
        let oldKey = OnboardingDefaultsKey.vocabularyLevel

        defaults.removeObject(forKey: key)
        defaults.set(VocabularyLevel.intermediate.rawValue, forKey: oldKey)

        VocabularyLevelMigrator.migrateIfNeeded()
        #expect(defaults.string(forKey: key) == CEFRLevel.b1.rawValue)

        // Cleanup
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: oldKey)
    }
}
