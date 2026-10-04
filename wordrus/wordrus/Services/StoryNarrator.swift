import Foundation
import NaturalLanguage
import Observation
import SwiftData
@preconcurrency import AVFoundation

nonisolated enum StoryNarrationTiming {
    /// Silence after each sentence, so a learner can catch up before the next.
    static let sentencePause: Duration = .milliseconds(700)
    /// A slightly longer beat between the title and the story.
    static let titlePause: Duration = .milliseconds(900)

    /// Sentence ranges of `text`, in order.
    static func sentenceRanges(in text: String, languageCode: String) -> [Range<String.Index>] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.setLanguage(NLLanguage(rawValue: languageCode))
        return tokenizer.tokens(for: text.startIndex..<text.endIndex)
    }

    /// Overall progress (0…1) at `fraction` of clip `clip` out of `clipCount`.
    static func progress(clip: Int, fraction: Double, clipCount: Int) -> Double {
        guard clipCount > 0 else { return 0 }
        return min(1, (Double(clip) + min(max(fraction, 0), 1)) / Double(clipCount))
    }
}

/// Reads a story in Dr Tusk's voice one sentence at a time — the title, then
/// each sentence as its own TTS clip with a short pause after it — and
/// reports which sentence is being read. Per-sentence clips make the
/// highlight exact and leave room for the pauses; the next clip is fetched
/// while the current one plays. Clips are saved in a folder per story
/// (`DailyStory.audioFileName`), so replays and relaunches are free.
@Observable
@MainActor
final class StoryNarrator {
    enum State: Equatable {
        case idle
        case loading
        case playing
        case paused
        case finished
        case failed
    }

    private(set) var state: State = .idle
    /// Index into the story's sentences; nil while the title is read and
    /// between plays. Changes only when a new sentence starts.
    private(set) var currentSentence: Int?
    private(set) var progress: Double = 0

    @ObservationIgnored private weak var story: DailyStory?
    /// Clip texts: the title, then one per sentence.
    @ObservationIgnored private var clips: [String] = []
    /// The clip playing now, or the next one to play.
    @ObservationIgnored private var position = 0
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var playback: Task<Void, Never>?
    @ObservationIgnored private var fetches: [Int: Task<Data?, Never>] = [:]

    var isPlaying: Bool { state == .playing }

    /// Plays from where it left off (from the top once finished).
    func togglePlayback(for story: DailyStory, sentences: [Range<String.Index>]) async {
        switch state {
        case .playing:
            pause()
        case .paused:
            resume()
        case .loading:
            return
        case .idle, .finished, .failed:
            if self.story !== story || clips.isEmpty {
                self.story = story
                clips = [story.title] + sentences.map { String(story.text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
                fetches = [:]
                position = 0
            }
            if state == .finished { position = 0 }
            playback?.cancel()
            playback = Task { await run() }
        }
    }

    func pause() {
        player?.pause()
        state = .paused
    }

    func resume() {
        player?.play()
        state = .playing
    }

    func stop() {
        playback?.cancel()
        playback = nil
        player?.stop()
        player = nil
        if state != .failed { state = .idle }
        currentSentence = nil
        progress = 0
        position = 0
    }

    // MARK: - Playback loop

    private func run() async {
        SpeechService.shared.stop()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif

        while position < clips.count {
            if fetches[position] == nil { state = .loading }
            guard let data = await clip(position), !Task.isCancelled else {
                if !Task.isCancelled { state = .failed }
                return
            }
            fetchClip(position + 1)   // ready by the time this one ends
            guard let player = try? AVAudioPlayer(data: data) else {
                state = .failed
                return
            }
            self.player = player
            currentSentence = position == 0 ? nil : position - 1
            player.prepareToPlay()
            player.play()
            state = .playing

            // Wait for the clip to end; a pause just holds the loop here.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                if state == .paused { continue }
                let fraction = player.duration > 0 ? player.currentTime / player.duration : 1
                progress = StoryNarrationTiming.progress(clip: position, fraction: fraction, clipCount: clips.count)
                if !player.isPlaying { break }
            }
            if Task.isCancelled { return }

            position += 1
            progress = StoryNarrationTiming.progress(clip: position, fraction: 0, clipCount: clips.count)
            if position < clips.count {
                try? await Task.sleep(for: position == 1 ? StoryNarrationTiming.titlePause : StoryNarrationTiming.sentencePause)
                while state == .paused, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Task.isCancelled { return }
            }
        }
        state = .finished
        currentSentence = nil
        progress = 1
        position = 0
        player = nil
    }

    // MARK: - Clips

    private func clip(_ index: Int) async -> Data? {
        fetchClip(index)
        return await fetches[index]?.value
    }

    /// Starts loading clip `index` (cache first, then the TTS proxy) unless
    /// it's already loading or out of range.
    private func fetchClip(_ index: Int) {
        guard clips.indices.contains(index), fetches[index] == nil, let story else { return }
        let text = clips[index]
        let folder = DailyStoryService.storyAudioDirectory.appendingPathComponent(story.id.uuidString, isDirectory: true)
        let file = folder.appendingPathComponent("\(index).mp3")
        let languageCode = story.language?.bcp47 ?? TargetLanguage.spanish.bcp47
        fetches[index] = Task { [weak story] in
            if let cached = try? Data(contentsOf: file) { return cached }
            guard let data = try? await OpenAITTSClient.shared.fetchAudio(
                text: text,
                voice: "onyx",
                instructions: Self.storytellerInstructions(languageCode: languageCode)
            ) else { return nil }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if (try? data.write(to: file, options: .atomic)) != nil, let story, story.audioFileName != folder.lastPathComponent {
                story.audioFileName = folder.lastPathComponent
                try? story.modelContext?.save()
            }
            return data
        }
    }

    /// Dr Tusk's voice from the calls, slowed into a storyteller for learners.
    static func storytellerInstructions(languageCode: String) -> String {
        let language = TargetLanguage.allCases.first { $0.bcp47 == languageCode } ?? .spanish
        return """
        You are Dr Tusk, a middle-aged walrus, reading a short story aloud in \(language.englishName) \
        to a language learner, one line at a time. Deep, gravelly, warm voice with a dry sense of \
        humour. Read this line clearly and a little slower than normal, with natural storytelling \
        intonation, and give any funny moment a little twinkle.
        """
    }
}
