import Foundation

/// Deterministic, no-network story for previews, tests and the simulator.
/// One fixed episode per language with the new words spliced in as quoted
/// mentions — never conjugated or declined, because the mock can't know a
/// word's part of speech (the same rule as `MockWalrusBrain` templates).
///
/// It ignores the learner's known words, so its stories usually fail the
/// vocabulary check; it's a last-resort brain and never ships in release
/// builds (see `StoryBrainFactory`).
struct MockStoryBrain: StoryGenerating {
    let brainName = "mock"
    let isLastResort = true

    func generateStory(_ request: StoryRequest) async throws -> GeneratedStory {
        Self.story(for: request)
    }

    func repairStory(
        _ story: GeneratedStory,
        request: StoryRequest,
        unknownLemmas: [String],
        missingNewWords: [String]
    ) async throws -> GeneratedStory {
        // A template has nothing to rephrase with.
        story
    }

    static func story(for request: StoryRequest) -> GeneratedStory {
        let template = Template.for(request.language)
        let lemmas = request.newWords.map(\.lemma)
        let first = lemmas.first ?? template.fallbackWord
        let words = [first, lemmas.count > 1 ? lemmas[1] : first, lemmas.count > 2 ? lemmas[2] : first]

        func fill(_ text: String) -> String {
            text.replacingOccurrences(of: "{N1}", with: words[0])
                .replacingOccurrences(of: "{N2}", with: words[1])
                .replacingOccurrences(of: "{N3}", with: words[2])
        }

        let text = fill(template.story)
        let sentences = text.split(whereSeparator: { ".!?".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        let wordSentences = lemmas.map { lemma in
            StoryWordSentence(word: lemma, sentence: sentences.first { $0.contains(lemma) }.map { $0 + "." } ?? text)
        }
        return GeneratedStory(
            title: template.title,
            story: text,
            newWordSentences: wordSentences,
            questions: template.questions,
            episodeSummary: fill(template.summary)
        )
    }

    private struct Template {
        let title: String
        let story: String
        let questions: [StoryQuestion]
        let summary: String
        /// Spliced in when the request has no new words at all.
        let fallbackWord: String

        static func `for`(_ language: TargetLanguage) -> Template {
            switch language {
            case .spanish:
                Template(
                    title: "Dr Tusk y la nota misteriosa",
                    story: """
                    Hoy Dr Tusk se despierta muy temprano. En la playa hay una botella con una nota. \
                    La nota dice solo una palabra: «{N1}». Dr Tusk lee la nota otra vez. «{N1}», dice en voz alta. \
                    Un pez sale del agua y lo mira. «¿Sabes qué es {N2}?», pregunta el pez. Dr Tusk piensa y piensa. \
                    Luego dice: «{N2} es mi palabra favorita». El pez se ríe tanto que cae al agua. \
                    Dr Tusk también se ríe, pero resbala en una roca. ¡Plaf! Ahora los dos están en el agua. \
                    Al final, Dr Tusk encuentra otra nota: «{N3}… y mañana, {N3} otra vez». ¿Quién escribe estas notas?
                    """,
                    questions: [
                        StoryQuestion(question: "¿Dónde está la botella?", options: ["En la playa", "En la casa", "En un árbol"], answerIndex: 0),
                        StoryQuestion(question: "¿Quién sale del agua?", options: ["Un gato", "Un pez", "Un niño"], answerIndex: 1),
                    ],
                    summary: "Dr Tusk encontró notas misteriosas en la playa con las palabras {N1}, {N2} y {N3}.",
                    fallbackWord: "mar"
                )
            case .french:
                Template(
                    title: "Dr Tusk et le message mystérieux",
                    story: """
                    Aujourd'hui, Dr Tusk se réveille très tôt. Sur la plage, il y a une bouteille avec un message. \
                    Le message dit un seul mot : « {N1} ». Dr Tusk lit le message encore une fois. « {N1} », dit-il à voix haute. \
                    Un poisson sort de l'eau et le regarde. « Tu sais ce que veut dire {N2} ? » demande le poisson. \
                    Dr Tusk réfléchit longtemps. Puis il dit : « {N2}, c'est mon mot préféré. » \
                    Le poisson rit tellement qu'il tombe dans l'eau. Dr Tusk rit aussi, mais il glisse sur un rocher. \
                    Plouf ! Maintenant, les deux sont dans l'eau. \
                    À la fin, Dr Tusk trouve un autre message : « {N3}… et demain, encore {N3}. » Qui écrit ces messages ?
                    """,
                    questions: [
                        StoryQuestion(question: "Où est la bouteille ?", options: ["Sur la plage", "Dans la maison", "Dans un arbre"], answerIndex: 0),
                        StoryQuestion(question: "Qui sort de l'eau ?", options: ["Un chat", "Un poisson", "Un enfant"], answerIndex: 1),
                    ],
                    summary: "Dr Tusk a trouvé des messages mystérieux sur la plage avec les mots {N1}, {N2} et {N3}.",
                    fallbackWord: "mer"
                )
            case .german:
                Template(
                    title: "Dr Tusk und der geheimnisvolle Zettel",
                    story: """
                    Heute wacht Dr Tusk sehr früh auf. Am Strand liegt eine Flasche mit einem Zettel. \
                    Auf dem Zettel steht nur ein Wort: „{N1}“. Dr Tusk liest den Zettel noch einmal. „{N1}“, sagt er laut. \
                    Ein Fisch springt aus dem Wasser und schaut ihn an. „Weißt du, was {N2} bedeutet?“, fragt der Fisch. \
                    Dr Tusk denkt lange nach. Dann sagt er: „{N2} ist mein Lieblingswort.“ \
                    Der Fisch lacht so sehr, dass er ins Wasser fällt. Dr Tusk lacht auch, aber er rutscht auf einem Stein aus. \
                    Platsch! Jetzt sind beide im Wasser. \
                    Am Ende findet Dr Tusk noch einen Zettel: „{N3} … und morgen wieder {N3}.“ Wer schreibt diese Zettel?
                    """,
                    questions: [
                        StoryQuestion(question: "Wo liegt die Flasche?", options: ["Am Strand", "Im Haus", "Auf einem Baum"], answerIndex: 0),
                        StoryQuestion(question: "Wer springt aus dem Wasser?", options: ["Eine Katze", "Ein Fisch", "Ein Kind"], answerIndex: 1),
                    ],
                    summary: "Dr Tusk hat am Strand geheimnisvolle Zettel mit den Wörtern {N1}, {N2} und {N3} gefunden.",
                    fallbackWord: "Meer"
                )
            case .italian:
                Template(
                    title: "Dr Tusk e il biglietto misterioso",
                    story: """
                    Oggi Dr Tusk si sveglia molto presto. Sulla spiaggia c'è una bottiglia con un biglietto. \
                    Il biglietto dice solo una parola: «{N1}». Dr Tusk legge il biglietto un'altra volta. «{N1}», dice ad alta voce. \
                    Un pesce esce dall'acqua e lo guarda. «Sai che cosa vuol dire {N2}?», chiede il pesce. \
                    Dr Tusk pensa a lungo. Poi dice: «{N2} è la mia parola preferita». \
                    Il pesce ride così tanto che cade in acqua. Anche Dr Tusk ride, ma scivola su uno scoglio. \
                    Splash! Adesso sono tutti e due in acqua. \
                    Alla fine, Dr Tusk trova un altro biglietto: «{N3}… e domani, ancora {N3}». Chi scrive questi biglietti?
                    """,
                    questions: [
                        StoryQuestion(question: "Dov'è la bottiglia?", options: ["Sulla spiaggia", "In casa", "Su un albero"], answerIndex: 0),
                        StoryQuestion(question: "Chi esce dall'acqua?", options: ["Un gatto", "Un pesce", "Un bambino"], answerIndex: 1),
                    ],
                    summary: "Dr Tusk ha trovato biglietti misteriosi sulla spiaggia con le parole {N1}, {N2} e {N3}.",
                    fallbackWord: "mare"
                )
            }
        }
    }
}
