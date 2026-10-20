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
/// 5. Nothing acceptable from any brain → the closest draft seen (fewest
///    unknown words). A story a little above their level beats no story;
///    only a chain that produced nothing at all throws.
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
        var closest: (draft: GeneratedStory, report: StoryCoverageReport, brainName: String)?
        func consider(_ draft: GeneratedStory, _ report: StoryCoverageReport, from brain: StoryGenerating) {
            if let current = closest, !Self.isCloser(report, than: current.report) { return }
            closest = (draft, report, brain.brainName)
        }

        for brain in brains {
            for _ in 0..<generationsPerBrain {
                attempts += 1
                let generated: GeneratedStory
                do {
                    generated = try await brain.generateStory(request)
                } catch {
                    #if DEBUG
                    print("[StoryPipeline] \(brain.brainName) failed: \(error)")
                    #endif
                    break
                }
                var draft = generated
                draft.questions = draft.questions.filter(\.isWellFormed)
                var report = Self.check(draft, with: checker)
                #if DEBUG
                print("[StoryPipeline] \(brain.brainName) draft unknown=\(report.unknownLemmas) underused=\(report.underusedNewWords)")
                #endif
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
                consider(draft, report, from: brain)
            }
        }
        guard let closest else { throw StoryGenerationError.noAcceptableStory }
        return Outcome(
            story: closest.draft, report: closest.report, brainName: closest.brainName,
            attempts: attempts, extraWords: extraWords(closest.report, checker)
        )
    }

    /// Fewer unknown words wins; on a tie, fewer underused new words.
    private static func isCloser(_ report: StoryCoverageReport, than other: StoryCoverageReport) -> Bool {
        if report.unknownLemmas.count != other.unknownLemmas.count {
            return report.unknownLemmas.count < other.unknownLemmas.count
        }
        return report.underusedNewWords.count < other.underusedNewWords.count
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
