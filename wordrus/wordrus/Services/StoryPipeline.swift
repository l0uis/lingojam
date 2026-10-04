import Foundation

/// Turns a `StoryRequest` into a story the learner can read, trying brains in
/// order and checking every draft with `StoryVocabularyChecker`:
///
/// 1. Generate. Passes the check → done.
/// 2. Otherwise send the repair prompt once (same brain). Passes → done.
/// 3. Still failing but at most `maximumUnknownLemmas` unknown words → accept,
///    with those words highlighted as extra new words.
/// 4. Otherwise generate again (up to `generationsPerBrain`), then move to the
///    next brain. A last-resort brain's draft is accepted as-is.
@MainActor
struct StoryPipeline {
    struct Outcome {
        let story: GeneratedStory
        let report: StoryCoverageReport
        let brainName: String
        /// Generation + repair calls across every brain tried.
        let attempts: Int
        /// Words the check couldn't place but the story was accepted with.
        let extraWords: [String]
    }

    let brains: [StoryGenerating]
    let lexicon: StoryLexicon
    var generationsPerBrain = 2

    func run(_ request: StoryRequest) async throws -> Outcome {
        let checker = StoryVocabularyChecker(
            lexicon: lexicon,
            known: request.knownWords,
            new: request.newWords,
            policy: .init(wordCount: request.length.words)
        )
        var attempts = 0

        for brain in brains {
            for _ in 0..<generationsPerBrain {
                attempts += 1
                guard var draft = try? await brain.generateStory(request) else { break }
                draft.questions = draft.questions.filter(\.isWellFormed)
                var report = Self.check(draft, with: checker)
                if report.passed || brain.isLastResort {
                    return Outcome(story: draft, report: report, brainName: brain.brainName, attempts: attempts, extraWords: extraWords(report, checker))
                }

                attempts += 1
                if let repaired = try? await brain.repairStory(
                    draft, request: request,
                    unknownLemmas: report.unknownLemmas,
                    missingNewWords: report.underusedNewWords
                ) {
                    var repaired = repaired
                    repaired.questions = repaired.questions.filter(\.isWellFormed)
                    let repairedReport = Self.check(repaired, with: checker)
                    // Keep whichever draft is closer: a bad repair shouldn't
                    // throw away a nearly-acceptable original.
                    if repairedReport.passed || repairedReport.unknownLemmas.count <= report.unknownLemmas.count {
                        draft = repaired
                        report = repairedReport
                    }
                }
                if report.passed || report.unknownLemmas.count <= checker.policy.maximumUnknownLemmas {
                    return Outcome(story: draft, report: report, brainName: brain.brainName, attempts: attempts, extraWords: extraWords(report, checker))
                }
            }
        }
        throw StoryGenerationError.noAcceptableStory
    }

    /// Unknown words get highlighted as extra new words only when there are
    /// few enough to learn on the spot. A last-resort draft with dozens of
    /// unknowns highlights none rather than underlining half the story.
    private func extraWords(_ report: StoryCoverageReport, _ checker: StoryVocabularyChecker) -> [String] {
        report.unknownLemmas.count <= checker.policy.maximumUnknownLemmas ? report.unknownLemmas : []
    }

    static func check(_ story: GeneratedStory, with checker: StoryVocabularyChecker) -> StoryCoverageReport {
        checker.check(story: story.story, questions: story.questionTexts)
    }
}
