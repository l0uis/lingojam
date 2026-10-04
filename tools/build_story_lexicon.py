"""Build the per-language story lexicons used by Walter's daily story.

Writes `wordrus/wordrus/Resources/story_lexicon_{code}.json` for es/fr/de/it:

    {
      "version": 1,
      "language": "de",
      "frequency": ["sein", "haben", ...],      # seed lemmas, most frequent first; rank = index + 1
      "functionWords": ["der", "die", ...],     # always allowed in a story
      "aliases": {"koennen": ["können"], ...},  # extra lemma candidates for a surface form or tagger lemma
      "inflectionSuffixes": [["en", ""], ...],  # noun/adjective endings → base form (tried when nothing else matches)
      "verbEndings": {"ar": [...], ...},        # verb ending classes for stem matching without a tagger lemma
      "stemAlternations": [["e", "ie"], ...],   # last-vowel stem changes (querer → quier-)
      "stemFinalAlternations": [["c", "qu"]],   # stem-final spelling changes (buscar → busqu-é)
      "cliticSuffixes": [...],                  # es/it: dámelo, comprarlo, andiamocene
      "separablePrefixes": [...],               # de: "steht … auf" → aufstehen
      "compoundLinkers": [...]                  # de: Bahnhof+s+uhr
    }

Consumers:
  - `StoryVocabularyChecker.swift` (frequency is not needed there; everything else is).
  - Coverage stats and known-word selection for story prompts (frequency).

Everything here is stdlib-only and deterministic: the inputs are the shipped
seed JSON (so run the matching `build_*.py` first) and the frequency lists
already vendored in tools/ (`doozan_frequency.csv`, `hermitdave_*_50k.txt`).

## Frequency rank

Spanish uses doozan, which is already lemmatised. FR/DE/IT use hermitdave, which
counts word *forms* (est / suis / était separately), so a lemma's score is the
count of the lemma itself plus the counts of the forms a small regular paradigm
generates for it (plurals, feminine, regular verb endings), plus any alias
forms. Generated forms that are themselves seed lemmas or function words are
never credited, so "vent" can't inflate "venir". It's a ranking proxy, not a
linguistic analysis: good enough to weight coverage stats and pick frequent
known words, nothing more.

## Aliases

Apple's NLTagger lemmatiser (what the app uses) has systematic quirks. These
were found by tagging every seed example sentence on-device and listing
content tokens whose lemma missed the seed (e.g. puede → "podar", kannst →
"koennen", étaient → "étayer", sento → "sentare"). Aliases only ever ADD
candidates — the checker accepts a token if any candidate is allowed — so an
alias like podar → poder can't break a story that really means "podar".

They also carry the irregular forms of each language's most frequent verbs
(IRREGULAR_FORMS). NLTagger has no lemma model for Spanish on the iOS
simulator and Italian assets may be missing on device; without a lemma, regular
forms are matched by stem + VERB_ENDINGS and irregular ones only via aliases.

Re-run after any seed rebuild:

    python3 tools/build_story_lexicon.py           # all four languages
    python3 tools/build_story_lexicon.py --report  # also list frequent forms the lexicon can't explain
"""

from __future__ import annotations

import argparse
import csv
import json
import re
import sys
import unicodedata
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parent
RESOURCES_DIR = TOOLS_DIR.parent / "wordrus" / "wordrus" / "Resources"

SEED_FILES = {
    "es": "spanish_top1000.json",
    "fr": "french_top1000.json",
    "de": "german_top1000.json",
    "it": "italian_top1000.json",
}


def _words(text: str) -> list[str]:
    return text.split()


# --- Function words ---------------------------------------------------------
# Closed-class items a story may always use: articles, pronouns, possessives,
# demonstratives, prepositions (incl. contractions), conjunctions, auxiliaries
# and modals, negation, a handful of grammatical adverbs/quantifiers the seeds
# deliberately leave out (muy / pas / nicht / non), and cardinal numbers.
# Lowercase surface forms; elided forms keep their apostrophe.

FUNCTION_WORDS: dict[str, list[str]] = {
    "es": _words("""
        el la los las lo un una unos unas al del
        yo tú tu usted él ella ello nosotros nosotras vosotros vosotras ellos ellas ustedes
        me te se nos os le les mí ti sí conmigo contigo consigo
        mi mis tus su sus nuestro nuestra nuestros nuestras vuestro vuestra vuestros vuestras
        mío mía míos mías tuyo tuya tuyos tuyas suyo suya suyos suyas
        este esta estos estas esto ese esa esos esas eso aquel aquella aquellos aquellas aquello
        que qué quien quién quienes quiénes cual cuál cuales cuáles cuyo cuya cuyos cuyas
        donde dónde adonde adónde cuando cuándo como cómo cuanto cuánto cuanta cuánta cuantos cuántos cuantas cuántas
        algo alguien nada nadie alguno alguna algunos algunas algún ninguno ninguna ningún
        otro otra otros otras todo toda todos todas mucho mucha muchos muchas poco poca pocos pocas
        mismo misma mismos mismas tanto tanta tantos tantas cada varios varias demás
        ése ésa éste ésta aquél tal tales cualquier cualquiera
        a ante bajo con contra de desde durante en entre hacia hasta mediante para por según sin sobre tras
        y e o u ni pero sino si porque aunque pues mientras
        no muy más menos también tampoco ya
        haber ser estar usted ustedes
        cero uno dos tres cuatro cinco seis siete ocho nueve diez once doce trece catorce quince
        dieciséis diecisiete dieciocho diecinueve veinte treinta cuarenta cincuenta sesenta setenta
        ochenta noventa cien ciento mil
    """),
    "fr": _words("""
        le la les l' un une des du au aux de d'
        je j' tu il elle on nous vous ils elles me m' te t' se s' lui leur eux moi toi soi y en
        ce c' ça cela ceci
        mon ma mes ton ta tes son sa ses notre nos votre vos leurs
        mien mienne miens miennes tien tienne tiens tiennes sien sienne siens siennes
        cet cette ces celui celle ceux celles
        qui que qu' quoi dont où lequel laquelle lesquels lesquelles auquel duquel quel quelle quels quelles
        quelque quelques quelqu'un quelqu' chaque tout toute tous toutes autre autres même mêmes
        rien personne aucun aucune plusieurs certains certaines
        à après avant avec chez contre dans depuis derrière devant entre par pendant pour sans selon
        sous sur vers jusque jusqu' près
        et ou mais donc or ni car si comme quand lorsque lorsqu' puisque puisqu' parce
        ne n' pas plus jamais très aussi non oui t
        être avoir
        zéro deux trois quatre cinq six sept huit neuf dix onze douze treize quatorze quinze seize
        vingt trente quarante cinquante soixante cent mille
    """),
    "de": _words("""
        der die das den dem des ein eine einen einem einer eines
        kein keine keinen keinem keiner keines
        am im ins ans aufs beim vom zum zur fürs ums übers unterm hinterm vorm
        ich du er sie es wir ihr mich dich sich uns euch mir dir ihm ihn ihnen man
        dieser diese dieses diesen diesem jener jene jenes jenen jenem
        welcher welche welches welchen welchem
        wer wen wem wessen was wo wohin woher wann wie warum
        alle alles allen aller jeder jede jedes jeden jedem etwas nichts jemand niemand
        viel viele vielen wenig wenige
        an auf aus bei bis durch für gegen hinter in mit nach neben ohne seit über um unter von vor
        während wegen zu zwischen
        und oder aber denn sondern doch dass ob wenn als weil obwohl damit bevor nachdem
        nicht nein ja sehr auch noch schon nur
        sein haben werden 's s
        null eins zwei drei vier fünf sechs sieben acht neun zehn elf zwölf zwanzig dreißig
        vierzig fünfzig hundert tausend
    """) + [
        # Possessive determiners: every stem × every case ending.
        stem + ending
        for stem in ("mein", "dein", "sein", "ihr", "unser", "eur", "euer")
        for ending in ("", "e", "en", "em", "er", "es")
    ],
    "it": _words("""
        il lo la l' i gli le un uno una un'
        del dello della dell' dei degli delle al allo alla all' ai agli alle
        dal dallo dalla dall' dai dagli dalle nel nello nella nell' nei negli nelle
        sul sullo sulla sull' sui sugli sulle col coi
        io tu lui lei egli ella noi voi loro esso essa essi esse
        mi ti si ci vi li ne me te se ce ve sé m' t' s' c' v' n' d'
        mio mia miei mie tuo tua tuoi tue suo sua suoi sue nostro nostra nostri nostre
        vostro vostra vostri vostre
        questo questa questi queste quello quella quelli quelle quel quei quegli quell'
        che chi cui quale quali dove quando come quanto quanta quanti quante perché
        qualcosa qualcuno niente nulla nessuno nessuna ogni ognuno nessun qual alcun alcuno alcuna
        anch' quand' dov' com' cos' quest' tutt' senz' vent' trent'
        tutto tutta tutti tutte altro altra altri altre stesso stessa stessi stesse
        molto molta molti molte poco poca pochi poche tanto tanta tanti tante
        di a ad da in con su per tra fra senza verso sopra sotto dopo prima durante
        e ed o od ma se anche però quindi mentre né
        non no sì più meno già
        essere avere
        zero uno due tre quattro cinque sei sette otto nove dieci undici dodici tredici quattordici
        quindici sedici diciassette diciotto diciannove venti trenta quaranta cinquanta cento mille
    """),
}


# --- Aliases ----------------------------------------------------------------
# key: a lowercase surface form OR a (wrong) NLTagger lemma; value: lemmas to
# also try. Contractions map to their parts. Keep entries evidence-based (see
# module docstring) — a quirk list; irregular verb forms live in IRREGULAR_FORMS.

ALIASES: dict[str, dict[str, list[str]]] = {
    "es": {
        # Contractions
        "del": ["de", "el"], "al": ["a", "el"],
        # Clitic-fused forms NLTagger leaves unlemmatised
        "vámonos": ["ir"], "vamos": ["ir"],
        # Wrong tagger lemmas (form → tagger lemma → intended lemma)
        "podar": ["poder"], "salar": ["salir"], "comerse": ["comer"],
        "profundar": ["profundo"], "aficionar": ["aficionado"],
        "clienta": ["cliente"], "pece": ["pez"], "peces": ["pez"],
        # Forms the tagger returns unchanged (noun homographs or apocope)
        "busca": ["buscar"], "mira": ["mirar"], "cuesta": ["costar"],
        "tomé": ["tomar"], "leo": ["leer"], "sale": ["salir"],
        "gran": ["grande"], "grandes": ["grande"], "buen": ["bueno"],
        "primer": ["primero"], "primera": ["primero"], "tercer": ["tercero"],
        "mal": ["malo"], "algún": ["alguno"], "ningún": ["ninguno"],
        # Irregular auxiliaries — frequency credit for haber/ser/estar/ir
        "hay": ["haber"], "he": ["haber"], "ha": ["haber"], "han": ["haber"],
        "es": ["ser"], "soy": ["ser"], "son": ["ser"], "era": ["ser"], "fue": ["ser", "ir"],
        "está": ["estar"], "estoy": ["estar"], "están": ["estar"],
        "voy": ["ir"], "va": ["ir"], "van": ["ir"],
    },
    "fr": {
        # Contractions
        "au": ["à", "le"], "aux": ["à", "les"], "du": ["de", "le"], "des": ["de", "les"],
        "jusqu'à": ["jusque", "à"],
        # Wrong tagger lemmas
        "étayer": ["être"], "sommer": ["être"], "ouvrer": ["ouvrir"],
        "s'éteindre": ["éteindre"], "s'éviter": ["éviter"],
        "réputer": ["réputé"], "fatiguer": ["fatigué"],
        # Forms the tagger returns unchanged
        "est": ["être"], "tourne": ["tourner"],
        "coule": ["couler"], "tape": ["taper"],
        # Irregular feminines / plurals the suffix rules can't reach
        "belle": ["beau"], "belles": ["beau"], "bel": ["beau"], "vieille": ["vieux"], "vieilles": ["vieux"],
        "folle": ["fou"], "fausse": ["faux"], "fausses": ["faux"], "fraîche": ["frais"],
        "blanche": ["blanc"], "blanches": ["blanc"], "sèche": ["sec"], "mesdames": ["madame"],
        # Irregular auxiliaries / very frequent verbs — frequency credit
        "suis": ["être"], "es": ["être"], "sont": ["être"], "était": ["être"],
        "étaient": ["être"], "été": ["être"], "sommes": ["être"], "êtes": ["être"],
        "ai": ["avoir"], "as": ["avoir"], "a": ["avoir"], "avons": ["avoir"],
        "avez": ["avoir"], "ont": ["avoir"], "avait": ["avoir"], "eu": ["avoir"],
        "vais": ["aller"], "vas": ["aller"], "va": ["aller"], "vont": ["aller"],
        "fait": ["faire"], "fais": ["faire"], "font": ["faire"],
        "peux": ["pouvoir"], "peut": ["pouvoir"], "peuvent": ["pouvoir"], "pu": ["pouvoir"],
        "veux": ["vouloir"], "veut": ["vouloir"], "veulent": ["vouloir"],
        "dois": ["devoir"], "doit": ["devoir"], "dû": ["devoir"],
        "sais": ["savoir"], "sait": ["savoir"], "su": ["savoir"],
        "dit": ["dire"], "dis": ["dire"], "vu": ["voir"], "vois": ["voir"], "voit": ["voir"],
        "viens": ["venir"], "vient": ["venir"], "venu": ["venir"],
        "étais": ["être"], "sera": ["être"], "serait": ["être"], "soit": ["être"], "sois": ["être"],
        "avais": ["avoir"], "aurais": ["avoir"], "aurait": ["avoir"],
        "voulais": ["vouloir"], "voulez": ["vouloir"], "savez": ["savoir"], "savais": ["savoir"],
        "pouvez": ["pouvoir"], "devrais": ["devoir"], "devrait": ["devoir"],
        "faut": ["falloir"], "connais": ["connaître"], "compris": ["comprendre"], "dirait": ["dire"],
        "bonne": ["bon"], "première": ["premier"], "dernière": ["dernier"], "yeux": ["œil"],
    },
    "de": {
        # Contractions
        "am": ["an", "der"], "im": ["in", "der"], "ins": ["in", "das"],
        "ans": ["an", "das"], "beim": ["bei", "der"], "vom": ["von", "der"],
        "zum": ["zu", "der"], "zur": ["zu", "die"],
        # Wrong tagger lemmas (umlaut transliteration is handled by the
        # checker's folding, so koennen/muessen need no entry)
        "kosen": ["kosten"], "zeihen": ["ziehen"], "dachen": ["denken"],
        "hangen": ["hängen"], "wart": ["warten"], "brachen": ["brechen"],
        "riefen": ["rufen"], "schwären": ["schwören"], "lade": ["Laden"],
        "nah": ["nächste"], "nächsten": ["nächste", "nah"],
        # Forms the tagger returns unchanged
        "hast": ["haben"], "mach": ["machen"], "schau": ["schauen"],
        "stelle": ["Stelle", "stellen"], "gerne": ["gern"],
        # Umlauted comparative/superlative stems (declension is stripped first)
        "größt": ["groß"], "größer": ["groß"], "ältest": ["alt"], "älter": ["alt"],
        "best": ["gut"], "besser": ["gut"], "höchst": ["hoch"], "höher": ["hoch"],
        "jüngst": ["jung"], "jünger": ["jung"], "längst": ["lang"], "länger": ["lang"],
        "kürzest": ["kurz"], "kürzer": ["kurz"], "wärmst": ["warm"], "wärmer": ["warm"],
        "kältest": ["kalt"], "kälter": ["kalt"], "stärkst": ["stark"], "stärker": ["stark"],
        "schwächst": ["schwach"], "schwächer": ["schwach"], "meist": ["viel"], "mehr": ["viel"],
        "liebst": ["gern"], "lieber": ["gern"], "nächst": ["nah"],
        # Irregular auxiliaries / modals — frequency credit
        "bin": ["sein"], "bist": ["sein"], "ist": ["sein"], "sind": ["sein"], "seid": ["sein"],
        "war": ["sein"], "waren": ["sein"], "gewesen": ["sein"],
        "habe": ["haben"], "hat": ["haben"], "habt": ["haben"], "hatte": ["haben"], "gehabt": ["haben"],
        "wird": ["werden"], "wirst": ["werden"], "wurde": ["werden"], "geworden": ["werden"],
        "kann": ["können"], "kannst": ["können"], "konnte": ["können"],
        "muss": ["müssen"], "musst": ["müssen"], "musste": ["müssen"],
        "darf": ["dürfen"], "will": ["wollen"], "willst": ["wollen"], "wollte": ["wollen"],
        "soll": ["sollen"], "sollte": ["sollen"], "mag": ["mögen"], "möchte": ["mögen"],
        "weiß": ["wissen"], "weißt": ["wissen"], "wusste": ["wissen"],
        "geht": ["gehen"], "ging": ["gehen"], "gegangen": ["gehen"],
        "geh": ["gehen"], "hab": ["haben"], "hätte": ["haben"], "hatten": ["haben"],
        "sei": ["sein"], "warst": ["sein"], "komm": ["kommen"], "kam": ["kommen"],
        "gibt": ["geben"], "gab": ["geben"], "gib": ["geben"], "tut": ["tun"], "getan": ["tun"],
        "lass": ["lassen"], "sieht": ["sehen"], "siehst": ["sehen"], "sieh": ["sehen"],
        "gesehen": ["sehen"], "sag": ["sagen"], "hör": ["hören"], "gefunden": ["finden"],
        "dachte": ["denken"], "männer": ["Mann"],
    },
    "it": {
        # Contractions not covered by the elision split
        "col": ["con", "il"], "coi": ["con", "i"],
        # Wrong tagger lemmas
        "sentare": ["sentire"], "piova": ["piovere"], "riempiere": ["riempire"],
        "regale": ["regalo"], "complicare": ["complicato"], "colorare": ["colorato"],
        "domina": ["dominare"], "matura": ["maturo"],
        # Forms the tagger returns unchanged
        "costa": ["costare"], "compro": ["comprare"], "cerco": ["cercare"],
        "fa": ["fare"], "era": ["essere"], "anni": ["anno"], "po": ["poco"], "po'": ["poco"],
        "buon": ["buono"], "gran": ["grande"], "bel": ["bello"], "mal": ["male"],
        "miglior": ["migliore"], "maggior": ["maggiore"], "uomini": ["uomo"], "signor": ["signore"],
        # Truncated infinitives before clitics (dirti, darmi, starci)
        "dir": ["dire"], "dar": ["dare"], "star": ["stare"], "esser": ["essere"],
        "andiamocene": ["andare"],
        # Imperative + doubled clitic (da' + mmelo)
        "dammi": ["dare"], "dammelo": ["dare"], "dimmi": ["dire"], "fammi": ["fare"],
        # Irregular auxiliaries / very frequent verbs — frequency credit
        "è": ["essere"], "sono": ["essere"], "sei": ["essere"], "siamo": ["essere"],
        "siete": ["essere"], "erano": ["essere"], "stato": ["essere"], "stata": ["essere"],
        "ho": ["avere"], "hai": ["avere"], "ha": ["avere"], "abbiamo": ["avere"],
        "avete": ["avere"], "hanno": ["avere"], "aveva": ["avere"],
        "vado": ["andare"], "vai": ["andare"], "va": ["andare"], "vanno": ["andare"],
        "faccio": ["fare"], "fai": ["fare"], "fanno": ["fare"], "fatto": ["fare"],
        "posso": ["potere"], "puoi": ["potere"], "può": ["potere"],
        "voglio": ["volere"], "vuoi": ["volere"], "vuole": ["volere"],
        "devo": ["dovere"], "devi": ["dovere"], "deve": ["dovere"],
        "so": ["sapere"], "sai": ["sapere"], "sa": ["sapere"],
        "detto": ["dire"], "dice": ["dire"], "visto": ["vedere"], "vedo": ["vedere"],
        "sta": ["stare"], "sto": ["stare"], "stai": ["stare"], "stiamo": ["stare"],
        "stanno": ["stare"], "stavo": ["stare"],
        "sia": ["essere"], "sarà": ["essere"], "ero": ["essere"], "sarebbe": ["essere"],
        "avevo": ["avere"], "avuto": ["avere"], "aver": ["avere"], "avrei": ["avere"], "avrebbe": ["avere"],
        "dobbiamo": ["dovere"], "dovrei": ["dovere"], "dovrebbe": ["dovere"],
        "possiamo": ["potere"], "potrebbe": ["potere"], "vorrei": ["volere"],
        "vieni": ["venire"], "dici": ["dire"], "dico": ["dire"],
        "facendo": ["fare"], "facciamo": ["fare"], "far": ["fare"],
    },
}


# --- Morphology hints for the checker --------------------------------------
# inflectionSuffixes: tried on noun/adjective tokens (surface and tagger lemma)
# only when no other candidate is allowed. Longest suffix first.

INFLECTION_SUFFIXES: dict[str, list[list[str]]] = {
    "es": [
        ["oras", "or"], ["ora", "or"], ["olas", "ol"], ["ola", "ol"], ["esas", "es"], ["esa", "es"],
        ["onas", "on"], ["ona", "on"], ["ces", "z"], ["as", "o"], ["os", "o"], ["es", ""], ["a", "o"], ["s", ""],
    ],
    "fr": [
        ["euses", "eux"], ["euse", "eux"], ["ives", "if"], ["ive", "if"],
        ["elles", "el"], ["elle", "el"], ["ennes", "en"], ["enne", "en"],
        ["ères", "er"], ["ère", "er"], ["eaux", "eau"], ["aux", "al"],
        ["illes", "il"], ["ille", "il"], ["lles", "l"], ["lle", "l"], ["ves", "f"], ["ve", "f"],
        ["ces", "x"], ["ce", "x"], ["sses", "s"], ["sse", "s"], ["gues", "g"], ["gue", "g"],
        ["es", ""], ["e", ""], ["s", ""], ["x", ""],
    ],
    "it": [
        ["chi", "co"], ["ghi", "go"], ["che", "ca"], ["ghe", "ga"], ["che", "co"], ["ghe", "go"],
        ["a", "o"], ["i", "o"], ["i", "io"], ["i", "e"], ["i", "a"], ["e", "o"], ["e", "a"],
    ],
    "de": [
        # Superlative / comparative + declension (schnellsten, wichtigere)
        ["esten", ""], ["estes", ""], ["ester", ""], ["estem", ""], ["este", ""],
        ["sten", ""], ["stes", ""], ["ster", ""], ["stem", ""], ["ste", ""],
        ["eren", ""], ["eres", ""], ["erer", ""], ["erem", ""], ["ere", ""],
        ["nen", ""], ["ern", ""], ["en", ""], ["em", ""], ["er", ""], ["er", "e"], ["es", ""],
        ["n", ""], ["e", ""], ["s", ""],
    ],
}

CLITIC_SUFFIXES: dict[str, list[str]] = {
    "es": _words("melo mela melos melas telo tela telos telas selo sela selos selas noslo nosla me te se nos os lo la los las le les"),
    "it": _words("glielo gliela glieli gliele gliene mene tene sene cene vene melo mela telo tela celo cela velo vela mi ti si ci vi lo la li le gli ne"),
}

SEPARABLE_PREFIXES_DE = _words("""
    ab an auf aus bei ein fest fort her heraus herein herum herunter hin hinaus hinein hinauf
    hinunter los mit nach um vor voraus vorbei weg weiter wieder zu zurück zusammen
    dabei dazu entgegen fern frei statt teil
""")

COMPOUND_LINKERS_DE = ["ens", "es", "en", "er", "ns", "s", "n", "e"]


# Verb ending classes, used when NLTagger has no lemma model for the language
# (the iOS simulator has none for Spanish, and Italian assets may be missing on
# device): a token matches a known verb if it is the verb's stem plus one of
# its class endings. Endings are accent-free because the checker folds accents
# (es/fr/it) — German endings never contain umlauts. "" is the bare stem
# (German imperative "komm"); the infinitive ending itself is included.

VERB_ENDINGS: dict[str, dict[str, list[str]]] = {
    "es": {
        "ar": _words("""ar o as a amos ais an aba abas abamos abais aban e aste aron are aras ara aremos
            areis aran aria arias ariamos ariais arian es emos eis en aramos arais ase ases ando ado ada ados adas ad"""),
        "er": _words("""er o es e emos eis en ia ias iamos iais ian i iste io imos isteis ieron ere eras era
            eremos ereis eran eria erias eriamos eriais erian a as amos ais an iera ieras ieramos ierais ieran
            iese iendo ido ida idos idas ed"""),
        "ir": _words("""ir o es e imos is en ia ias iamos iais ian i iste io isteis ieron ire iras ira iremos
            ireis iran iria irias iriamos iriais irian a as amos ais an iera ieras ieran iendo ido ida idos idas id"""),
    },
    "it": {
        # Truncated infinitives (ar/er/ir) appear before clitics: comprar|lo.
        "are": _words("""are ar o i a iamo ate ano avo avi ava avamo avate avano ai asti ammo aste arono ero erai
            era eremo erete eranno erei eresti erebbe eremmo ereste erebbero iate ino assi asse assimo assero
            ando ato ata ati"""),
        "ere": _words("""ere er o i e iamo ete ono evo evi eva evamo evate evano ei esti emmo este erono ero erai
            era eremo erete eranno erei eresti erebbe a iate ano essi esse endo uto uta uti ute"""),
        "ire": _words("""ire ir o i e iamo ite ono ivo ivi iva ivamo ivate ivano ii isti immo iste irono iro irai
            ira iremo irete iranno irei iresti irebbe a ano isco isci isce iscono isca iscano endo ito ita iti"""),
    },
    "fr": {
        "er": _words("""er e es ent ons ez ais ait ions iez aient ai as a ames ates erent erai eras era erons
            erez eront erais erait erions eriez eraient asse ant ee ees eons eais eait eaient eant"""),
        "ir": _words("""ir is it issons issez issent issais issait issions issiez issaient irai iras ira irons
            irez iront irais irait isse issant i ie ies s t ons ez ent ais ait ions iez aient ant"""),
        "re": _words("""re s t ons ez ent ais ait ions iez aient is it rai ras ra rons rez ront rais rait u ue
            us ues ant"""),
    },
    "de": {
        "en": _words("en e st est t et te test ten tet tete ete eten etest etet"),
        "n": _words("n e st t te test ten tet"),
    },
}
# Bare stems are real forms: German imperative "komm", French 3sg "il attend",
# "il sent" (stem-final t dropped via STEM_FINAL_ALTERNATIONS: sen|s, sen|t).
VERB_ENDINGS["de"]["en"].append("")
VERB_ENDINGS["fr"]["re"].append("")
VERB_ENDINGS["fr"]["ir"].append("")

# Vowel alternations applied to the LAST vowel of a verb stem (querer → quier-,
# poder → pued-, pedir → pid-, dormir → durm-; German sehen → sieh-, fahren →
# fähr- ≡ faehr-), and spelling changes applied to the stem's final letters
# (buscar → busqu-é, pagar → pagu-é, empezar → empec-é, coger → coj-o;
# cercare → cerch-i; appeler → appell-e).

STEM_ALTERNATIONS: dict[str, list[list[str]]] = {
    "es": [["e", "ie"], ["e", "i"], ["o", "ue"], ["o", "u"], ["u", "ue"]],
    "it": [["o", "uo"], ["e", "ie"]],
    "fr": [["e", "ie"], ["o", "eu"]],
    "de": [["a", "ae"], ["e", "ie"], ["e", "i"], ["au", "aeu"], ["o", "oe"]],
}

STEM_FINAL_ALTERNATIONS: dict[str, list[list[str]]] = {
    "es": [["c", "qu"], ["g", "gu"], ["z", "c"], ["g", "j"], ["gu", "g"], ["c", "zc"], ["u", "uy"]],
    "it": [["c", "ch"], ["g", "gh"], ["sc", "sch"], ["i", ""]],
    "fr": [["l", "ll"], ["t", "tt"], ["y", "i"], ["t", ""], ["m", ""], ["v", ""]],
    "de": [["el", "l"], ["er", "r"]],
}

# Irregular forms of the most frequent verbs: lemma → forms. Folded into the
# aliases (form → lemma). With lemma assets these are redundant; without them
# they're the only way "dijo" can mean decir.

IRREGULAR_FORMS: dict[str, dict[str, str]] = {
    "es": {
        "ser": "soy eres es somos sois son era eras éramos eran fui fuiste fue fuimos fueron sea seas sean sido siendo sería fuera fueras fueran",
        "estar": "estoy estás está estamos están estuve estuvo estuvieron esté estado estuvimos estuviera",
        "haber": "he has ha hemos han había habían hubo habrá haya hay hayamos hayan hubiera",
        "ir": "voy vas va vamos vais van iba ibas íbamos iban fui fue fueron vaya vayas yendo ido fuimos",
        "tener": "tengo tienes tiene tenemos tienen tuve tuvo tuvieron tenga tendrá tendría tuvimos tuviera tuvieras tendré tendrás tendremos ten",
        "hacer": "hago haces hace hacemos hacen hice hizo hicieron haga hecho hará haría haz hicimos haré harás",
        "decir": "digo dices dice decimos dicen dije dijo dijeron diga dicho dirá diría di dijimos diré dirás",
        "poder": "puedo puedes puede pueden pude pudo pudieron pueda podrá podría podré podremos",
        "querer": "quiero quieres quiere quieren quise quiso quisieron quiera querrá querría querré",
        "saber": "sé sabes sabe sabemos saben supe supo supieron sepa sabrá sabría sabré",
        "venir": "vengo vienes viene venimos vienen vine vino vinieron venga vendrá ven vinimos vendré",
        "poner": "pongo pones pone ponemos ponen puse puso pusieron ponga puesto pondrá pon pusimos pondré",
        "salir": "salgo sale salimos salen salga saldrá sal saldré",
        "ver": "veo ves ve vemos ven vi vio vieron vea visto",
        "dar": "doy das da damos dan di dio dieron dé dado dimos dieran",
        "traer": "traigo trae traen traje trajo trajeron traiga",
        "oír": "oigo oyes oye oímos oyen oyó oyeron oiga",
        "caer": "caigo cae cayó cayeron",
        "leer": "leyó leyeron leyendo",
        "dormir": "duermo duerme durmió durmieron",
        "morir": "muero muere murió muerto",
        "volver": "vuelvo vuelve vuelto",
        "escribir": "escrito",
        "abrir": "abierto",
        "romper": "roto",
        "conocer": "conozco conozca",
        "pedir": "pido pide pidió pidieron",
        "seguir": "sigo sigue siguió sigamos siga",
        "conducir": "conduzco condujo",
        "creer": "creyó creyeron creyendo",
    },
    "it": {
        "essere": "sono sei è siamo siete era eri eravamo erano fui fu furono sarò sarà sarebbe sia siano stato stata stati state fossi fosse fossimo foste fossero sii siate sarai saremo sarete saranno sarei saresti",
        "avere": "ho hai ha abbiamo avete hanno avevo aveva avevano ebbi ebbe ebbero avrò avrà avrebbe abbia avuto avrai avremo avrei avresti avremmo",
        "andare": "vado vai va andiamo andate vanno andrò andrà vada vadano andrai andremo andrete andranno andrei andresti andrebbe",
        "fare": "faccio fai fa facciamo fate fanno facevo faceva feci fece fecero farò farà faccia fatto facendo",
        "dire": "dico dici dice diciamo dite dicono dicevo diceva dissi disse dissero dirò dirà dica detto dicendo",
        "venire": "vengo vieni viene veniamo venite vengono venni venne vennero verrò verrà venga venuto verrai verremo verrei",
        "volere": "voglio vuoi vuole vogliamo volete vogliono volli volle vorrò vorrei vorrebbe voglia vorrai vorremo vorresti",
        "potere": "posso puoi può possiamo potete possono potrò potrei potrebbe possa potrai potrà potremo potresti potrebbero",
        "dovere": "devo devi deve dobbiamo dovete devono dovrò dovrei dovrebbe debba dovrai dovrà dovremo dovresti dovrebbero",
        "sapere": "so sai sa sappiamo sapete sanno seppi seppe saprò saprei sappia saprai sapremo",
        "stare": "sto stai sta stiamo state stanno stetti stette starò stia",
        "dare": "do dai dà diamo date danno diedi diede dette darò dia dato",
        "bere": "bevo bevi beve beviamo bevono bevevo bevve bevuto",
        "uscire": "esco esci esce usciamo escono esca",
        "rimanere": "rimango rimane rimangono rimase rimasto",
        "tenere": "tengo tieni tiene tengono tenne terrò terrà terrei tenuto",
        "vedere": "vidi vide videro visto vedrò vedrà vedrai vedrei",
        "prendere": "presi prese presero preso",
        "mettere": "misi mise misero messo",
        "scrivere": "scrissi scrisse scritto",
        "leggere": "lessi lesse letto",
        "aprire": "aperto",
        "chiudere": "chiusi chiuse chiuso",
        "correre": "corsi corse corso",
        "vivere": "vissi visse vissuto",
        "scendere": "scesi scese sceso",
        "nascere": "nacqui nacque nato",
        "morire": "muoio muore morì morto",
        "piacere": "piace piacciono piacque piaciuto",
        "rispondere": "risposi rispose risposto",
        "chiedere": "chiesi chiese chiesto",
        "perdere": "perso",
        "decidere": "decisi decise deciso",
        "ridere": "risi rise riso",
        "vincere": "vinsi vinse vinto",
        "cadere": "caddi cadde",
        "conoscere": "conobbi conobbe conosciuto",
        "giungere": "giunsi giunse giunto",
        "risolvere": "risolsi risolse risolto",
        "porre": "pongo pone pongono posi pose posto",
    },
    "fr": {
        "être": "suis es est sommes êtes sont étais était étions étaient fus fut serai sera serons seront serais serait sois soit soient été étant",
        "avoir": "ai as a avons avez ont avais avait avions aviez avaient eus eut aurai aura aurons auront aurais aurait aie ait aient eu ayant",
        "aller": "vais vas va allons allez vont irai ira iront irais irait aille",
        "faire": "fais fait faisons faites font faisais faisait fis fit ferai fera ferons feront ferais ferait fasse faisant",
        "dire": "dis dit disons dites disent disais disait dirai dira",
        "pouvoir": "peux peut pouvons pouvez peuvent pouvais pouvait pus put pourrai pourra pourrais pourrait puisse pu",
        "vouloir": "veux veut voulons voulez veulent voulais voulait voulus voulut voudrai voudra voudrais voudrait veuille voulu",
        "devoir": "dois doit devons devez doivent devais devait dus dut devrai devra devrais devrait doive dû",
        "savoir": "sais sait savons savez savent savais savait sus sut saurai saura saurais saurait sache su",
        "venir": "viens vient venons venez viennent venais venait vins vint viendrai viendra vienne venu",
        "tenir": "tiens tient tenons tiennent tint tiendra tenu",
        "voir": "vois voit voyons voyez voient voyais voyait vis vit verrai verra verrais verrait voie vu",
        "prendre": "prends prend prenons prenez prennent prenais prenait pris prit prendrai prendra prenne",
        "mettre": "mets met mettons mettez mettent mis mit mettrai",
        "boire": "bois boit buvons buvez boivent buvait but bu",
        "lire": "lis lit lisons lisent lisait lut lu",
        "écrire": "écris écrit écrivons écrivent écrivait",
        "connaître": "connais connaît connaissons connaissent connaissait connut connu",
        "croire": "crois croit croyons croient croyait crut cru croyaient croyais",
        "partir": "pars part partons partent partait parti partie",
        "sortir": "sors sort sortons sortent sortait sorti sortie",
        "dormir": "dors dort dorment dormait dormi",
        "courir": "cours court courent courait couru",
        "ouvrir": "ouvre ouvrent ouvert ouverte",
        "mourir": "meurt meurent mort morte",
        "naître": "naît né née",
        "recevoir": "reçois reçoit reçu",
        "falloir": "faut fallait faudra faudrait fallu",
        "pleuvoir": "pleut pleuvait plu",
        "vivre": "vis vit vivons vivent vivait vécu",
        "rire": "ris rit rient riait ri",
        "suivre": "suit suivent suivait suivi",
        "valoir": "vaut vaux valait valu",
        "éteindre": "éteins éteint éteignent éteignait",
        "joindre": "joins joint joignent joignez",
        "paraître": "parais paraît paraissent paraisse paru",
        "plaire": "plaît plu",
        "couvrir": "couvre couvrent couvert",
        "offrir": "offre offrent offert",
        "battre": "bats bat",
        "asseoir": "assieds assied asseyez assoient assis",
    },
    "de": {
        "sein": "bin bist ist sind seid war warst waren wart gewesen sei wäre wären",
        "haben": "habe hast hat habt hatte hattest hatten gehabt hätte hätten hab",
        "werden": "wirst wird wurde wurdest wurden geworden würde würden",
        "können": "kann kannst konnte konnten gekonnt könnte konntest",
        "müssen": "muss musst musste mussten gemusst müsste",
        "dürfen": "darf darfst durfte durften dürfte",
        "wollen": "will willst wollte wollten gewollt",
        "sollen": "soll sollst sollte sollten",
        "mögen": "mag magst mochte mochten möchte möchtest möchten",
        "wissen": "weiß weißt wusste wussten gewusst",
        "gehen": "ging gingen gegangen",
        "kommen": "kam kamen gekommen",
        "sehen": "sieht siehst sah sahen gesehen sieh",
        "geben": "gibt gibst gab gaben gegeben gib",
        "nehmen": "nimmt nimmst nahm nahmen genommen nimm",
        "essen": "isst aß aßen gegessen iss",
        "trinken": "trank tranken getrunken",
        "fahren": "fährt fährst fuhr fuhren gefahren",
        "laufen": "läuft läufst lief liefen gelaufen",
        "lesen": "liest las lasen gelesen lies",
        "sprechen": "spricht sprichst sprach sprachen gesprochen sprich",
        "finden": "fand fanden gefunden",
        "stehen": "stand standen gestanden",
        "liegen": "lag lagen gelegen",
        "sitzen": "saß saßen gesessen",
        "schlafen": "schläft schlief schliefen geschlafen",
        "bleiben": "blieb blieben geblieben",
        "schreiben": "schrieb schrieben geschrieben",
        "denken": "dachte dachten gedacht",
        "bringen": "brachte brachten gebracht",
        "tun": "tue tust tut tat taten getan",
        "lassen": "lässt ließ ließen gelassen",
        "helfen": "hilft hilfst half halfen geholfen",
        "treffen": "trifft traf trafen getroffen",
        "fallen": "fällt fiel fielen gefallen",
        "halten": "hält hielt hielten gehalten",
        "tragen": "trägt trug trugen getragen",
        "fliegen": "flog flogen geflogen",
        "ziehen": "zog zogen gezogen",
        "rufen": "rief riefen gerufen",
        "schwimmen": "schwamm schwammen geschwommen",
        "singen": "sang sangen gesungen",
        "beginnen": "begann begannen begonnen",
        "vergessen": "vergisst vergaß",
        "verlieren": "verlor verloren",
        "werfen": "wirft warf geworfen",
        "wachsen": "wächst wuchs gewachsen",
        "waschen": "wäscht wusch gewaschen",
        "sterben": "stirbt starb gestorben",
        "gewinnen": "gewann gewonnen",
        "kennen": "kannte gekannt",
        "nennen": "nannte genannt",
        "rennen": "rannte gerannt",
        "treten": "tritt trat traten getreten",
        "lügen": "log logen gelogen",
        "schneiden": "schnitt schnitten geschnitten",
        "schlagen": "schlägt schlug schlugen geschlagen",
        "fangen": "fängt fing fingen gefangen",
        "scheinen": "schien schienen geschienen",
        "bitten": "bat baten gebeten",
    },
}


def merged_aliases(lang: str) -> dict[str, list[str]]:
    """Quirk aliases + irregular verb forms, form → sorted unique lemmas."""
    merged: dict[str, list[str]] = {k: list(v) for k, v in ALIASES[lang].items()}
    for lemma, forms in IRREGULAR_FORMS[lang].items():
        for form in forms.split():
            targets = merged.setdefault(form, [])
            if lemma not in targets:
                targets.append(lemma)
    return {k: merged[k] for k in sorted(merged)}


def fold(s: str, lang: str) -> str:
    """Mirror of StoryVocabularyChecker.fold: lowercase; de transliterates
    umlauts/ß, es/fr/it strip accents (es keeps ñ)."""
    lower = unicodedata.normalize("NFC", s).lower().replace("’", "'")
    if lang == "de":
        return lower.replace("ä", "ae").replace("ö", "oe").replace("ü", "ue").replace("ß", "ss")
    out = []
    previous = ""
    for ch in unicodedata.normalize("NFD", lower):
        if unicodedata.combining(ch):
            if lang == "es" and ch == "̃" and previous == "n":
                out.append(ch)
            continue
        out.append(ch)
        previous = ch
    return unicodedata.normalize("NFC", "".join(out))


# --- Frequency --------------------------------------------------------------

REFLEXIVE_PREFIXES = ("se ", "s'", "sich ")


def base_lemma(lang: str, lemma: str) -> str:
    """Strip reflexive markers so levantarse / se lever / sich freuen / alzarsi
    score as their base verb. Mirrors StoryVocabularyChecker.variants(of:)."""
    lower = lemma.lower()
    for prefix in REFLEXIVE_PREFIXES:
        if lower.startswith(prefix):
            return lower[len(prefix):]
    if lang == "es" and lower.endswith("se") and lower[-4:-2] in ("ar", "er", "ir"):
        return lower[:-2]
    if lang == "it" and lower.endswith("rsi"):
        return lower[:-3] + "re"
    return lower


def verb_class(lang: str, lemma: str) -> str | None:
    """Longest matching ending class (Italian "are" before French-style "re")."""
    for ending in sorted(VERB_ENDINGS[lang], key=len, reverse=True):
        if lemma.endswith(ending) and len(lemma) > len(ending) + 1:
            return ending
    return None


def regular_forms(lang: str, lemma: str, pos: str) -> set[str]:
    """A small regular paradigm for a lemma, folded. Over-generation is fine:
    forms that are other seed lemmas or function words are discarded upstream."""
    w = fold(lemma, lang)
    forms: set[str] = set()
    if pos.startswith("verb"):
        cls = verb_class(lang, w)
        if cls:
            stem = w[: -len(cls)]
            if len(stem) >= 2:
                forms |= {stem + e for e in VERB_ENDINGS[lang][cls] if e}
                if lang == "de":
                    forms.add("ge" + stem + "t")
    elif pos.startswith("noun") or pos.startswith("adjective"):
        if lang == "fr":
            forms |= {w + "s", w + "x", w + "e", w + "es"}
        elif lang == "it" and len(w) > 2 and w[-1] in "oae":
            stem = w[:-1]
            forms |= {stem + e for e in ("o", "a", "i", "e")}
        elif lang == "de":
            forms |= {w + e for e in ("e", "en", "n", "er", "s", "es", "em", "nen")}
    forms.discard(w)
    return forms


def load_doozan_counts() -> dict[str, int]:
    counts: dict[str, int] = {}
    with (TOOLS_DIR / "doozan_frequency.csv").open(encoding="utf-8") as fh:
        for row in csv.DictReader(fh):
            lemma = (row.get("spanish") or "").strip().lower()
            try:
                count = int(row["count"])
            except (KeyError, ValueError):
                continue
            if lemma:
                counts[lemma] = counts.get(lemma, 0) + count
    return counts


def load_hermitdave_counts(lang: str) -> dict[str, int]:
    counts: dict[str, int] = {}
    with (TOOLS_DIR / f"hermitdave_{lang}_50k.txt").open(encoding="utf-8") as fh:
        for line in fh:
            parts = line.split()
            if len(parts) >= 2 and parts[1].isdigit():
                form = parts[0].lower()
                counts[form] = counts.get(form, 0) + int(parts[1])
    return counts


def frequency_order(lang: str, seed_words: list[dict], function_words: set[str]) -> list[str]:
    """Seed lemmas sorted by estimated corpus frequency (desc). Lemmas with no
    evidence keep their relative seed order at the tail."""
    counts = load_doozan_counts() if lang == "es" else load_hermitdave_counts(lang)
    folded_function = {fold(w, lang) for w in function_words}
    protected = {fold(w["lemma"], lang) for w in seed_words} | folded_function

    # Lemmas and alias forms are looked up exactly (dé ≠ de, maïs ≠ mais);
    # generated paradigm forms are accent-free, so they use folded counts.
    folded_counts: dict[str, int] = {}
    for form, count in counts.items():
        key = fold(form, lang)
        folded_counts[key] = folded_counts.get(key, 0) + count

    def direct(form: str) -> int:
        return counts.get(form.lower(), 0)

    scores: dict[str, int] = {}
    for word in seed_words:
        lemma = word["lemma"]
        base = base_lemma(lang, lemma)
        parts = [p for p in re.split(r"[ ']", base) if p]
        if len(parts) > 1:
            # Multiword phrase: as frequent as its rarest content part.
            content = [p for p in parts if fold(p, lang) not in folded_function] or parts
            score = min(direct(p) for p in content)
        else:
            score = direct(base)
            # doozan is already lemmatised; hermitdave counts forms.
            if lang != "es":
                for form in regular_forms(lang, base, word["partOfSpeech"]):
                    if form not in protected:
                        score += folded_counts.get(form, 0)
        scores[lemma] = score

    # Alias forms (irregular verbs etc.) credit their target lemmas.
    if lang != "es":
        by_folded = {fold(w["lemma"], lang): w["lemma"] for w in seed_words}
        for form, targets in merged_aliases(lang).items():
            for target in targets:
                lemma = by_folded.get(fold(target, lang))
                if lemma is not None and fold(form, lang) not in protected:
                    scores[lemma] += direct(form)

    seed_order = {w["lemma"]: (w["rank"], i) for i, w in enumerate(seed_words)}
    return sorted(scores, key=lambda l: (-scores[l], seed_order[l]))


def report_unexplained(lang: str, seed_words: list[dict], function_words: set[str], top: int = 400) -> None:
    """Print frequent corpus forms that are neither seed lemmas, function words,
    aliases nor a regular form of a seed lemma — candidates for curation."""
    counts = load_doozan_counts() if lang == "es" else load_hermitdave_counts(lang)
    explained = {fold(w, lang) for w in function_words} | {fold(f, lang) for f in merged_aliases(lang)}
    for w in seed_words:
        explained.add(fold(w["lemma"], lang))
        explained.add(fold(base_lemma(lang, w["lemma"]), lang))
        explained |= regular_forms(lang, base_lemma(lang, w["lemma"]), w["partOfSpeech"])
    frequent = sorted(counts, key=lambda f: -counts[f])[:top]
    missing = [f for f in frequent if fold(f, lang) not in explained]
    print(f"  {len(missing)} of the top {top} forms unexplained: {' '.join(missing[:60])}")


# --- Output -----------------------------------------------------------------

def build(lang: str, report: bool = False) -> None:
    seed = json.loads((RESOURCES_DIR / SEED_FILES[lang]).read_text(encoding="utf-8"))
    seed_words = seed["words"]

    function_words = sorted(set(FUNCTION_WORDS[lang]))
    payload: dict = {
        "version": 1,
        "language": lang,
        "frequency": frequency_order(lang, seed_words, set(function_words)),
        "functionWords": function_words,
        "aliases": merged_aliases(lang),
        "inflectionSuffixes": INFLECTION_SUFFIXES[lang],
        "verbEndings": VERB_ENDINGS[lang],
        "stemAlternations": STEM_ALTERNATIONS[lang],
        "stemFinalAlternations": STEM_FINAL_ALTERNATIONS[lang],
    }
    if lang in CLITIC_SUFFIXES:
        # Longest first so "selo" wins over "lo".
        payload["cliticSuffixes"] = sorted(CLITIC_SUFFIXES[lang], key=lambda s: (-len(s), s))
    if lang == "de":
        payload["separablePrefixes"] = sorted(SEPARABLE_PREFIXES_DE, key=lambda s: (-len(s), s))
        payload["compoundLinkers"] = COMPOUND_LINKERS_DE

    out = RESOURCES_DIR / f"story_lexicon_{lang}.json"
    out.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(
        f"Wrote {out.name}: {len(payload['frequency'])} ranked lemmas, "
        f"{len(function_words)} function words, {len(payload['aliases'])} aliases "
        f"({out.stat().st_size // 1024} KB)"
    )
    print(f"  top 25: {' '.join(payload['frequency'][:25])}")
    if report:
        report_unexplained(lang, seed_words, set(function_words))


def main(argv: list[str]) -> None:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("languages", nargs="*", help="es fr de it (default: all)")
    parser.add_argument("--report", action="store_true", help="list frequent forms the lexicon can't explain")
    args = parser.parse_args(argv)
    for lang in args.languages or list(SEED_FILES):
        if lang not in SEED_FILES:
            parser.error(f"unknown language {lang!r}; choose from {', '.join(SEED_FILES)}")
        build(lang, report=args.report)


if __name__ == "__main__":
    main(sys.argv[1:])
