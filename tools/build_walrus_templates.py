#!/usr/bin/env python3
"""Emit walrus_templates_{lang}_{level}.json for FR, IT, DE and EN (British).

The existing Spanish files (walrus_templates_a1.json … _c2.json) are
left in place for backward compatibility; the Swift loader picks the
language-suffixed variant when targetLanguage is set.

Walter's voice across languages:
  - Mildly grumpy; you've woken him from his nap.
  - Direct, no fluff, no saccharine "qué bonito" type reactions.
  - Curious despite himself — leans in once the user talks.
  - Dry humor scales with CEFR level (sharper sarcasm at B2+).
"""

import json
from pathlib import Path


TEMPLATES = {
    "fr": {
        "A1": {
            "openers": [
                "Ah, encore toi. Tu as étudié aujourd'hui ?",
                "Bon, dis-moi. Quels mots tu connais ?",
                "Salut. Tu pratiques le français aujourd'hui, oui ou non ?",
            ],
            "prompts": [
                "Fais-moi une phrase avec « {WORD} », vas-y.",
                "Et « {WORD} » ? Mets-le dans une phrase.",
                "Allez, une phrase avec « {WORD} ».",
                "Donne-moi un exemple avec le mot « {WORD} ».",
            ],
            "fillers": ["Ah oui.", "D'accord, d'accord.", "Mmm, raconte."],
            "closers": [
                "Bon, pas mal. Au revoir.",
                "Bon, ça suffit pour aujourd'hui. À la prochaine.",
            ],
        },
        "A2": {
            "openers": [
                "Ah, tu m'as réveillé. Bon, comment va ton français cette semaine ?",
                "Encore toi. Tu as appris quelque chose ou pas ?",
                "Bon, je t'écoute. Qu'est-ce que tu as fait aujourd'hui ?",
            ],
            "prompts": [
                "Et toi, qu'est-ce que tu penses de « {WORD} » ? Sans détour.",
                "Bon, décris-moi « {WORD} » en une phrase.",
                "Bon, utilise « {WORD} » dans une phrase. Raconte bien.",
                "Fais-moi une phrase avec « {WORD} », vas-y.",
            ],
            "fillers": ["Ah oui, continue.", "Mmm, sans blague.", "Bon, je te suis."],
            "closers": [
                "Bon, pas mal du tout. À la prochaine.",
                "Bon, ça suffit pour aujourd'hui. Au revoir.",
            ],
        },
        "B1": {
            "openers": [
                "Ah, j'allais faire ma sieste. Bon, tu as pratiqué ou je l'invente ?",
                "Tiens, encore toi. Va, lâche-le : comment s'est passée ta semaine ?",
                "Bon, puisque tu m'as réveillé, qu'est-ce que tu as appris dernièrement ?",
            ],
            "prompts": [
                "Et dis-moi, comment tu décrirais « {WORD} » à quelqu'un qui ne le connaît pas ?",
                "Bon, quelle est ton expérience avec « {WORD} » ? Sans détour.",
                "Mmm, tu penses que « {WORD} » est important dans ta vie ? Pourquoi ?",
                "Bon, raconte-moi une histoire où « {WORD} » a toute sa place.",
            ],
            "fillers": ["Ah oui, continue.", "Bon, bon, je te suis.", "Mmm, c'est intéressant ça."],
            "closers": [
                "Bon, pas mal du tout. Je te laisse, j'ai des choses à faire. À la prochaine.",
                "Bon, ça suffit pour aujourd'hui. Reviens quand tu auras quelque chose d'intéressant à dire.",
            ],
        },
        "B2": {
            "openers": [
                "Tu interromps ma sieste, encore. Va, lâche-le : comment va le français cette semaine ?",
                "Tiens, qui voilà. Puisque tu es là, qu'est-ce qui t'a fait réfléchir dernièrement ?",
                "Ah, quelle barbe. Mais puisque tu m'as appelé, dis-moi : sur quoi tu t'es donné du mal dernièrement ?",
            ],
            "prompts": [
                "Et dis-moi, quel rôle joue « {WORD} » dans ta vie ? Pas de détours.",
                "Bon, si tu devais expliquer « {WORD} » à un étranger, comment tu ferais ?",
                "Mmm, comment ta relation à « {WORD} » a-t-elle évolué avec les années ?",
                "Va, fais-moi une phrase où « {WORD} » joue un rôle décisif.",
            ],
            "fillers": ["Mmm, nuance intéressante.", "Bon, bon, je te suis.", "Ah oui, ça a de la consistance."],
            "closers": [
                "Bon, pas mal du tout, ce que tu fais. À la prochaine, je retourne à ma sieste.",
                "Bon, ça suffit pour aujourd'hui. Continue comme ça et on en parle plus longuement la prochaine fois.",
            ],
        },
        "C1": {
            "openers": [
                "Tu me prends entre deux siestes, alors allons droit au but : qu'est-ce qui t'a trotté dans la tête cette semaine ?",
                "Encore toi. Puisque tu insistes, dis-moi : quel sujet te passionne en ce moment ?",
                "Ah, quelle paresse de parler, mais bon : qu'as-tu lu, vu ou pensé dernièrement qui t'ait remué ?",
            ],
            "prompts": [
                "Et dis-moi, dans quelle mesure « {WORD} » définit une époque, ou est-ce plus universel ?",
                "Va, argumente pour et contre l'importance de « {WORD} » dans le monde moderne.",
                "Mmm, quelles nuances se perdent quand on traduit « {WORD} » dans une autre langue ?",
                "Imagine un monde sans « {WORD} ». Qu'est-ce qui nous manquerait ? Ne reste pas dans l'évidence.",
            ],
            "fillers": ["Mmm, position nuancée. Continue.", "Bon, je comprends le raisonnement.", "Ah oui, ça mène la conversation en bon terrain."],
            "closers": [
                "Bon, ça a été plus intéressant que prévu. À la prochaine.",
                "Bon, assez de philosophie pour aujourd'hui. Je retourne à ma sieste. Au revoir.",
            ],
        },
        "C2": {
            "openers": [
                "Écoute, je n'étais pas d'humeur à bavarder, mais puisque tu as appelé : quel sujet vaudrait la peine d'être disséqué aujourd'hui ?",
                "Encore. Épargnons-nous l'échauffement : quelle idée t'obsède dernièrement ?",
                "Va, surprends-moi : quel thème de fond te trotte dans la tête ?",
            ],
            "prompts": [
                "Dis-moi, quelles connotations culturelles porte le mot « {WORD} » qu'un étranger saisit rarement ?",
                "Va, articule une critique étayée du concept de « {WORD} ».",
                "Mmm, quels auteurs ou penseurs ont influencé ta vision de « {WORD} » ?",
                "Tu dirais que « {WORD} » est une construction sociale ou quelque chose d'intrinsèque à la nature humaine ? Défends-le.",
            ],
            "fillers": ["Distinction très fine. Continue.", "Bon, ça mérite une nuance supplémentaire.", "Mmm, tu mènes la chose sur un terrain fascinant."],
            "closers": [
                "Bon, tu ne m'as pas fait perdre mon temps, je l'admets. À la prochaine.",
                "Bon, c'est tout. Je retourne à ma sieste intellectuelle. Au revoir.",
            ],
        },
    },
    "it": {
        "A1": {
            "openers": [
                "Ah, di nuovo tu. Hai studiato oggi?",
                "Allora, dimmi. Che parole nuove sai?",
                "Ciao. Pratichi l'italiano oggi, sì o no?",
            ],
            "prompts": [
                "E dimmi, cosa {WORD} di solito?",
                "Ok, ti piace {WORD}? Sì o no.",
                "Una frase con {WORD}, dai.",
                "Quando è stata l'ultima volta che hai {WORD}?",
            ],
            "fillers": ["Ah-ah.", "Ok, ok.", "Mmm, dimmi di più."],
            "closers": [
                "Beh, non male. Ciao.",
                "Ok, basta per oggi. Alla prossima.",
            ],
        },
        "A2": {
            "openers": [
                "Ah, mi hai svegliato. Allora, come va il tuo italiano questa settimana?",
                "Di nuovo tu. Hai imparato qualcosa o no?",
                "Ok, ti ascolto. Cosa hai fatto oggi?",
            ],
            "prompts": [
                "E tu, cosa pensi di {WORD}? Senza giri di parole.",
                "Ok, descrivimi {WORD} in una frase.",
                "Quando di solito {WORD}? Racconta bene.",
                "Conosci qualcuno che {WORD} molto? Parla.",
            ],
            "fillers": ["Ah-ah, continua.", "Mmm, ma non mi dire.", "Ok, ti seguo."],
            "closers": [
                "Beh, non è stato male. Alla prossima.",
                "Ok, basta per oggi. Ciao.",
            ],
        },
        "B1": {
            "openers": [
                "Ah, stavo per fare la pennichella. Allora, hai praticato o me lo invento?",
                "Ma guarda, di nuovo tu. Dai, sputalo: come è andata la settimana?",
                "Beh, visto che mi hai svegliato, cosa hai imparato ultimamente?",
            ],
            "prompts": [
                "E dimmi, come descriveresti {WORD} a qualcuno che non lo conosce?",
                "Ok, che esperienza hai tu con {WORD}? Senza giri di parole.",
                "Mmm, credi che {WORD} sia importante nella tua vita? Perché?",
                "Dai, raccontami una storia in cui {WORD} è la chiave.",
            ],
            "fillers": ["Ah-ah, continua.", "Ok, ok, ti seguo.", "Mmm, questa è interessante."],
            "closers": [
                "Beh, non è male del tutto. Ti lascio, ho cose da fare. Alla prossima.",
                "Ok, basta per oggi. Torna quando hai qualcosa di interessante da raccontare.",
            ],
        },
        "B2": {
            "openers": [
                "Di nuovo a interrompermi la pennichella. Dai, sputalo: come va l'italiano questa settimana?",
                "Guarda chi si vede. Visto che sei qui, cosa ti è successo ultimamente che ti ha fatto pensare?",
                "Ah, che noia. Ma visto che mi hai chiamato, dimmi: in cosa ti sei impegnato ultimamente?",
            ],
            "prompts": [
                "E dimmi, che ruolo gioca {WORD} nella tua vita? Senza giri di parole.",
                "Ok, se dovessi spiegare {WORD} a uno straniero, come faresti?",
                "Mmm, come è cambiato il tuo rapporto con {WORD} negli anni?",
                "Dai, dammi un esempio concreto in cui {WORD} è stato cruciale per te.",
            ],
            "fillers": ["Mmm, sfumatura interessante.", "Ok, ok, ti seguo.", "Ah-ah, questa ha la sua sostanza."],
            "closers": [
                "Beh, non è affatto male quel che fai. Alla prossima, torno alla pennichella.",
                "Ok, basta per oggi. Continua così e un'altra volta parliamo di più.",
            ],
        },
        "C1": {
            "openers": [
                "Senti, mi hai beccato tra una pennichella e l'altra, quindi andiamo al sodo: cosa ti ha frullato in testa questa settimana?",
                "Di nuovo tu. Visto che insisti, dimmi: che argomento ti appassiona ora?",
                "Ah, che pigrizia parlare, ma dai: cosa hai letto, visto o pensato ultimamente che ti ha smosso?",
            ],
            "prompts": [
                "E dimmi, fino a che punto credi che {WORD} definisca un'epoca, o è qualcosa di più universale?",
                "Dai, argomenta a favore e contro l'importanza di {WORD} nel mondo moderno.",
                "Mmm, che sfumature si perdono quando si traduce {WORD} in un'altra lingua?",
                "Immagina un mondo senza {WORD}. Cosa ci mancherebbe? Non fermarti all'ovvio.",
            ],
            "fillers": ["Mmm, posizione sfumata. Continua.", "Ok, capisco il ragionamento.", "Ah-ah, porti la conversazione su un buon terreno."],
            "closers": [
                "Beh, è stato più interessante di quanto pensassi. Alla prossima.",
                "Ok, basta filosofia per oggi. Torno alla mia pennichella. Ciao.",
            ],
        },
        "C2": {
            "openers": [
                "Senti, non ero in vena di chiacchiere, ma visto che hai chiamato: che argomento varrebbe la pena sviscerare oggi?",
                "Di nuovo. Risparmiamoci entrambi il riscaldamento: che idea ti ha intrappolato ultimamente?",
                "Dai, stupiscimi: che tema di fondo ti gira in testa?",
            ],
            "prompts": [
                "Dimmi, che connotazioni culturali porta la parola {WORD} che uno straniero coglie raramente?",
                "Dai, articola una critica fondata al concetto di {WORD}.",
                "Mmm, che autori o pensatori hanno influenzato la tua visione di {WORD}?",
                "Diresti che {WORD} è una costruzione sociale o qualcosa di intrinseco alla natura umana? Difendilo.",
            ],
            "fillers": ["Distinzione finissima. Continua.", "Ok, questo merita un'altra sfumatura.", "Mmm, porti la cosa su un terreno affascinante."],
            "closers": [
                "Beh, non mi hai fatto perdere tempo, lo ammetto. Alla prossima.",
                "Ok, basta. Torno alla mia pennichella intellettuale. Ciao.",
            ],
        },
    },
    "de": {
        "A1": {
            "openers": [
                "Ach, du wieder. Hast du heute geübt?",
                "Also, sag mal. Welche Wörter kennst du?",
                "Hallo. Übst du heute Deutsch, ja oder nein?",
            ],
            "prompts": [
                "Und sag, was {WORD} du normalerweise?",
                "Okay, magst du {WORD}? Ja oder nein.",
                "Ein Satz mit {WORD}, los.",
                "Wann hast du das letzte Mal {WORD}?",
            ],
            "fillers": ["Aha.", "Okay, okay.", "Mmh, erzähl weiter."],
            "closers": [
                "Na ja, nicht schlecht. Tschüss.",
                "Okay, genug für heute. Bis zum nächsten Mal.",
            ],
        },
        "A2": {
            "openers": [
                "Ach, du hast mich geweckt. Also, wie läuft dein Deutsch diese Woche?",
                "Du schon wieder. Hast du was Neues gelernt oder nicht?",
                "Okay, ich höre. Was hast du heute gemacht?",
            ],
            "prompts": [
                "Und du, was denkst du über {WORD}? Ohne Umschweife.",
                "Okay, beschreib mir {WORD} in einem Satz.",
                "Wann {WORD} du normalerweise? Erzähl ordentlich.",
                "Kennst du jemanden, der oft {WORD}? Sprich.",
            ],
            "fillers": ["Aha, mach weiter.", "Mmh, was du nicht sagst.", "Okay, ich höre dir zu."],
            "closers": [
                "Na ja, gar nicht so schlecht. Bis zum nächsten Mal.",
                "Okay, genug für heute. Tschüss.",
            ],
        },
        "B1": {
            "openers": [
                "Ach, ich wollte gerade ein Nickerchen machen. Also, hast du geübt oder bilde ich mir das ein?",
                "Sieh an, schon wieder du. Komm, raus damit: wie war deine Woche?",
                "Na gut, da du mich schon geweckt hast — was hast du in letzter Zeit gelernt?",
            ],
            "prompts": [
                "Und sag, wie würdest du {WORD} jemandem beschreiben, der es nicht kennt?",
                "Okay, was für Erfahrungen hast du mit {WORD}? Ohne Umschweife.",
                "Mmh, glaubst du, {WORD} ist wichtig in deinem Leben? Warum?",
                "Komm, erzähl mir eine Geschichte, in der {WORD} eine Schlüsselrolle spielt.",
            ],
            "fillers": ["Aha, mach weiter.", "Okay, okay, ich folge dir.", "Mmh, das hat was."],
            "closers": [
                "Na ja, gar nicht so übel. Ich lasse dich, ich habe zu tun. Bis zum nächsten Mal.",
                "Okay, genug für heute. Komm wieder, wenn du was Interessantes zu erzählen hast.",
            ],
        },
        "B2": {
            "openers": [
                "Du unterbrichst schon wieder mein Nickerchen. Komm, raus damit: wie läuft das Deutsch diese Woche?",
                "Schau, wer da ist. Da du nun hier bist — was hat dich in letzter Zeit zum Nachdenken gebracht?",
                "Ach, was für ein Aufwand. Aber da du mich angerufen hast: woran hast du dich neulich besonders abgemüht?",
            ],
            "prompts": [
                "Und sag, welche Rolle spielt {WORD} in deinem Leben? Ohne Umschweife.",
                "Okay, wenn du {WORD} einem Ausländer erklären müsstest — wie würdest du es machen?",
                "Mmh, wie hat sich dein Verhältnis zu {WORD} über die Jahre verändert?",
                "Komm, gib mir ein konkretes Beispiel, in dem {WORD} entscheidend für dich war.",
            ],
            "fillers": ["Mmh, interessante Nuance.", "Okay, okay, ich folge dir.", "Aha, das hat Substanz."],
            "closers": [
                "Na ja, gar nicht übel, was du machst. Bis zum nächsten Mal, ich gehe wieder schlafen.",
                "Okay, genug für heute. Mach so weiter und beim nächsten Mal reden wir länger.",
            ],
        },
        "C1": {
            "openers": [
                "Du erwischst mich zwischen zwei Nickerchen, also kommen wir zur Sache: was hat dir diese Woche im Kopf gespukt?",
                "Du schon wieder. Da du darauf bestehst: welches Thema fasziniert dich gerade?",
                "Ach, wie mühsam das Reden ist, aber bitte: was hast du in letzter Zeit gelesen, gesehen oder gedacht, das dich aufgewühlt hat?",
            ],
            "prompts": [
                "Und sag, inwieweit definiert {WORD} eine Epoche oder ist es etwas Universelles?",
                "Komm, argumentiere für und gegen die Bedeutung von {WORD} in der modernen Welt.",
                "Mmh, welche Nuancen gehen verloren, wenn man {WORD} in eine andere Sprache übersetzt?",
                "Stell dir eine Welt ohne {WORD} vor. Was würde uns fehlen? Bleib nicht beim Offensichtlichen.",
            ],
            "fillers": ["Mmh, nuancierte Position. Weiter.", "Okay, ich verstehe die Argumentation.", "Aha, du führst das Gespräch in gute Bahnen."],
            "closers": [
                "Na ja, war interessanter als erwartet. Bis zum nächsten Mal.",
                "Okay, genug Philosophie für heute. Ich gehe wieder schlafen. Tschüss.",
            ],
        },
        "C2": {
            "openers": [
                "Hör mal, ich war nicht in Plauderstimmung, aber da du schon anrufst: welches Thema wäre es heute wert, auseinandergenommen zu werden?",
                "Du schon wieder. Ersparen wir uns beiden das Aufwärmen: welche Idee hält dich gerade gefangen?",
                "Komm, überrasch mich: welches Grundthema spukt dir im Kopf herum?",
            ],
            "prompts": [
                "Sag, welche kulturellen Konnotationen trägt das Wort {WORD}, die ein Ausländer selten erfasst?",
                "Komm, formuliere eine fundierte Kritik am Konzept von {WORD}.",
                "Mmh, welche Autoren oder Denker haben deine Sicht auf {WORD} geprägt?",
                "Würdest du sagen, {WORD} ist ein soziales Konstrukt oder etwas der menschlichen Natur Eigenes? Verteidige es.",
            ],
            "fillers": ["Sehr feine Unterscheidung. Weiter.", "Okay, das verdient eine weitere Nuance.", "Mmh, du führst das auf faszinierendes Terrain."],
            "closers": [
                "Na ja, du hast mir die Zeit nicht gestohlen, das gebe ich zu. Bis zum nächsten Mal.",
                "Okay, das war's. Ich gehe wieder zu meinem intellektuellen Nickerchen. Tschüss.",
            ],
        },
    },
    "en": {
        "A1": {
            "openers": [
                "Oh, it's you again. Did you study today?",
                "Right, tell me. What words do you know?",
                "Hello. Are you practising your English today, yes or no?",
            ],
            "prompts": [
                "Give me a sentence with \"{WORD}\", go on.",
                "And \"{WORD}\"? Put it in a sentence.",
                "Come on, one sentence with \"{WORD}\".",
                "Give me an example with the word \"{WORD}\".",
            ],
            "fillers": ["Oh yes.", "Right, right.", "Mm, go on."],
            "closers": [
                "Right, not bad. Bye.",
                "Right, that's enough for today. See you next time.",
            ],
        },
        "A2": {
            "openers": [
                "Oh, you woke me up. Right, how's your English this week?",
                "You again. Have you learnt anything or not?",
                "Right, I'm listening. What did you do today?",
            ],
            "prompts": [
                "And what do you think about \"{WORD}\"? Be honest.",
                "Right, describe \"{WORD}\" in one sentence.",
                "Right, use \"{WORD}\" in a sentence. Tell me properly.",
                "Give me a sentence with \"{WORD}\", go on.",
            ],
            "fillers": ["Oh yes, carry on.", "Mm, you don't say.", "Right, I'm with you."],
            "closers": [
                "Right, not bad at all. See you next time.",
                "Right, that's enough for today. Cheerio.",
            ],
        },
        "B1": {
            "openers": [
                "Ah, I was about to have my nap. Right, have you been practising or am I imagining it?",
                "Well, you again. Go on, out with it: how was your week?",
                "Hmm. You've got that look of someone who wants to chat. Go on then.",
            ],
            "prompts": [
                "What does \"{WORD}\" make you think of? Something real, not textbook stuff.",
                "Tell me about a time when \"{WORD}\" mattered to you.",
                "Would you use \"{WORD}\" with a friend or only at work? Why?",
                "Go on, convince me \"{WORD}\" is a useful word.",
            ],
            "fillers": ["Fair enough.", "Mm, and then what?", "Right, I didn't expect that."],
            "closers": [
                "Right, you've earned my nap. Bye.",
                "Not bad, I'll admit. Off you go.",
            ],
        },
        "B2": {
            "openers": [
                "You've interrupted a perfectly good nap, so this had better be interesting.",
                "Right, I'm awake now. Let's see if your English has improved or if I'm being optimistic.",
                "Ah, the keen learner returns. What's on your mind?",
            ],
            "prompts": [
                "If you had to explain \"{WORD}\" to someone who'd never heard it, how would you do it?",
                "Is \"{WORD}\" overrated? Make your case.",
                "Where did you last come across \"{WORD}\"? Set the scene.",
                "Use \"{WORD}\" in a sentence that would actually impress me.",
            ],
            "fillers": ["Interesting. Go on.", "Hmm, I'm not entirely convinced.", "Right, now we're getting somewhere."],
            "closers": [
                "Well, that wasn't a complete waste of my nap. Cheers.",
                "Right, I'll grudgingly call that progress. See you.",
            ],
        },
        "C1": {
            "openers": [
                "Ah, you. I was halfway through a rather good dream. Make it worth my while.",
                "Right, let's skip the pleasantries. What's been occupying that head of yours?",
                "You've caught me in a philosophical mood. Dangerous for you.",
            ],
            "prompts": [
                "What's the difference, in your view, between \"{WORD}\" and its nearest synonym?",
                "Would \"{WORD}\" mean the same thing to your grandparents as it does to you?",
                "Give me a sentence with \"{WORD}\" that a native speaker wouldn't raise an eyebrow at.",
                "Defend an unpopular opinion that involves \"{WORD}\".",
            ],
            "fillers": ["Hmm, a fair point, annoyingly.", "Go on, I'm almost persuaded.", "Now that's a subtle distinction."],
            "closers": [
                "Well, you've kept me awake, which is no mean feat. Cheerio.",
                "Right, I'm going back to my nap with plenty to think about. Bye.",
            ],
        },
        "C2": {
            "openers": [
                "Ah, my most persistent caller. Shall we have a proper conversation for once?",
                "You again. I was contemplating the meaning of life. You'll do instead.",
                "Right, impress me. I've had a dreadfully dull morning.",
            ],
            "prompts": [
                "Is \"{WORD}\" something we're born understanding or something we learn? Argue it.",
                "Which writers or thinkers have shaped how you see \"{WORD}\"?",
                "How would the meaning of \"{WORD}\" shift between a tabloid and a broadsheet?",
                "Make the strongest case you can against \"{WORD}\", then demolish it.",
            ],
            "fillers": ["A very fine distinction. Carry on.", "Right, that deserves another nuance.", "Hmm, you're leading us onto fascinating ground."],
            "closers": [
                "Well, you haven't wasted my time, I'll grant you that. Until next time.",
                "Right, that's it. Back to my intellectual nap. Cheerio.",
            ],
        },
    },
}


def main() -> None:
    project_root = Path(__file__).resolve().parent.parent
    out_dir = project_root / "wordrus" / "wordrus" / "Resources"
    out_dir.mkdir(parents=True, exist_ok=True)

    count = 0
    for lang_code, by_level in TEMPLATES.items():
        for level, sections in by_level.items():
            payload = {
                "level": level,
                "openers": sections["openers"],
                "prompts": sections["prompts"],
                "fillers": sections["fillers"],
                "closers": sections["closers"],
            }
            filename = f"walrus_templates_{lang_code}_{level.lower()}.json"
            (out_dir / filename).write_text(
                json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
                encoding="utf-8",
            )
            count += 1
    print(f"Wrote {count} walrus template files to {out_dir}")


if __name__ == "__main__":
    main()
