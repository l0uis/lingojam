import Foundation
import Testing
@testable import wordrus

/// Covers the two pieces of pure logic behind the voice call: the
/// word-level correction diff shown inside the learner's speech bubble,
/// and the sentence chunker that decides how many bubbles Walter's turn
/// becomes.
@MainActor
struct VoiceCallTests {
    // MARK: - Correction diff

    @Test func identicalSentencesHaveNoChanges() {
        let diff = CorrectionDiff.compare(
            original: "La mujer está en casa",
            corrected: "La mujer está en casa"
        )
        #expect(!diff.hasChanges)
        #expect(diff.fixCount == 0)
    }

    @Test func flagsOnlyTheChangedWord() {
        let diff = CorrectionDiff.compare(
            original: "La mujer estar en casa",
            corrected: "La mujer está en casa"
        )
        #expect(diff.hasChanges)
        #expect(diff.fixCount == 1)
        #expect(diff.corrected.filter { $0.change == .changed }.map(\.text) == ["está"])
        #expect(diff.original.filter { $0.change == .changed }.map(\.text) == ["estar"])
    }

    /// Accents ARE the correction in Spanish — folding them away during
    /// comparison would hide the only thing the learner got wrong.
    @Test func accentOnlyDifferenceCounts() {
        let diff = CorrectionDiff.compare(original: "como estas", corrected: "cómo estás")
        #expect(diff.fixCount == 2)
    }

    // MARK: - Punctuation is the transcriber's, not the learner's

    /// The learner dictated this; the recogniser chose not to end it with a
    /// full stop. That is not something to correct anyone for.
    @Test func addedFullStopIsNotACorrection() {
        let diff = CorrectionDiff.compare(
            original: "La mujer está en casa",
            corrected: "La mujer está en casa."
        )
        #expect(!diff.hasChanges)
    }

    @Test func addedQuestionMarksAndCommasAreNotCorrections() {
        #expect(!CorrectionDiff.compare(
            original: "Cómo estás hoy",
            corrected: "¿Cómo estás hoy?"
        ).hasChanges)

        #expect(!CorrectionDiff.compare(
            original: "Sí claro me gusta",
            corrected: "Sí, claro, me gusta"
        ).hasChanges)
    }

    /// Same for the capital on the opening word — dictation decides that.
    @Test func openingCapitalIsNotACorrection() {
        let diff = CorrectionDiff.compare(original: "voy a casa", corrected: "Voy a casa.")
        #expect(!diff.hasChanges)
    }

    /// Punctuation is ignored, but a real error in the same sentence still
    /// surfaces — and only that word lights up.
    @Test func realFixSurvivesAlongsideIgnoredPunctuation() {
        let diff = CorrectionDiff.compare(
            original: "la mujer estar en casa",
            corrected: "La mujer está en casa."
        )
        #expect(diff.fixCount == 1)
        #expect(diff.corrected.filter { $0.change == .changed }.map(\.text) == ["está"])
    }

    /// An apostrophe carries meaning, so it is deliberately NOT treated as
    /// ignorable punctuation.
    @Test func apostropheDifferenceStillCounts() {
        let diff = CorrectionDiff.compare(original: "Dammi un ora", corrected: "Dammi un'ora")
        #expect(diff.hasChanges)
    }

    /// Same for German capitalisation.
    @Test func capitalisationDifferenceCounts() {
        let diff = CorrectionDiff.compare(original: "das haus ist groß", corrected: "das Haus ist groß")
        #expect(diff.fixCount == 1)
        #expect(diff.corrected.filter { $0.change == .changed }.map(\.text) == ["Haus"])
    }

    @Test func handlesInsertionsAndDeletions() {
        let insertion = CorrectionDiff.compare(original: "Voy casa", corrected: "Voy a casa")
        #expect(insertion.fixCount == 1)
        #expect(insertion.original.allSatisfy { $0.change == .unchanged })

        let deletion = CorrectionDiff.compare(original: "Yo me voy a casa", corrected: "Me voy a casa")
        #expect(deletion.original.contains { $0.change == .changed })
    }

    @Test func emptyOriginalMarksEverythingAsAFix() {
        let diff = CorrectionDiff.compare(original: "", corrected: "Está bien")
        #expect(diff.fixCount == 2)
    }

    // MARK: - Chunking

    @Test func splitsTurnIntoOneBubblePerSentence() {
        let chunks = CallDirector.chunk("Buenos días. ¿Cómo te va la semana? Cuéntame algo.")
        #expect(chunks.count == 3)
        // Indexed safely — a wrong count should fail the expectation above,
        // not trap and take the whole test process down with it.
        #expect(chunks.dropFirst().first == "¿Cómo te va la semana?")
    }

    @Test func singleSentenceStaysOneBubble() {
        #expect(CallDirector.chunk("¿Qué tal el trabajo hoy?").count == 1)
    }

    /// A stub like "¡Hola!" on its own would flash past before it could be
    /// read, so it rides along with the sentence that follows.
    @Test func stubSentenceMergesForward() {
        let chunks = CallDirector.chunk("¡Hola! Me alegro mucho de escucharte otra vez.")
        #expect(chunks.count == 1)
        #expect(chunks.first?.hasPrefix("¡Hola!") == true)
    }

    /// A trailing stub has nothing to merge into, so it joins the bubble
    /// before it rather than becoming a bubble of its own.
    @Test func trailingStubMergesBackward() {
        let chunks = CallDirector.chunk("Me alegro mucho de escucharte otra vez. Sí.")
        #expect(chunks.count == 1)
        #expect(chunks.first?.hasSuffix("Sí.") == true)
    }

    /// Some brains return a wall of text with no terminal punctuation.
    /// One bubble is the honest answer, never zero.
    @Test func unpunctuatedTextStillYieldsABubble() {
        let chunks = CallDirector.chunk("hola que tal como estas hoy")
        #expect(chunks.count == 1)
    }

    @Test func emptyTurnYieldsNoBubbles() {
        #expect(CallDirector.chunk("   ").isEmpty)
    }

    /// A runaway sentence gets broken at its clauses so a single bubble
    /// never becomes a wall of text.
    @Test func overlongSentenceSplitsAtClauses() {
        let long = "Ayer fui al mercado que está cerca de mi casa, "
            + "compré verduras frescas para la cena de la familia, "
            + "y después caminé por el parque durante casi una hora entera"
        let chunks = CallDirector.chunk(long)
        #expect(chunks.count > 1)
        #expect(chunks.allSatisfy { $0.count <= 160 })
        // Nothing may be dropped on the way through the splitter.
        let rejoined = chunks.joined(separator: " ").replacingOccurrences(of: " ,", with: ",")
        #expect(rejoined.count >= long.count - 4)
    }
}
