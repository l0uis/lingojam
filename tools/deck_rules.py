"""Rule-based deck retagging, applied at build time to every seed word.

Why rules and not the LLM tagger: the original deck tags came from
`generate_vocab.py`, whose prompt filed "weather and nature" under `traveling`
(a leftover from an older taxonomy where `nature_weather` had been merged into
`traveling`). Re-running that tagger over ~26k words needs an API key the build
environment doesn't have, so the 2026-07-29 taxonomy change is applied as
reproducible rules instead.

Rules match on the ENGLISH gloss, which every language's seed carries, so one
rule set retags all four. Lemma-level overrides handle the cases where the
gloss is ambiguous ("fly" the insect vs. "fly" the verb).

`retag()` is the only entry point. It returns the full replacement slug list
for a word — including `common`, which every word keeps so "All Words" stays
complete. It is deliberately allowed to REMOVE tags: that's the whole point of
the pass, and it is why `SeedDataLoader.migrateDeckTaxonomy` had to gain an
authoritative reset (DeckSyncMigrator's normal merge only ever adds).
"""

from __future__ import annotations

import re

COMMON = "common"

# Terms matched against the English gloss, case-insensitively. Every term is
# anchored on BOTH sides (`\b(?:...)\b`) — an earlier draft anchored only the
# left, which made "cat" match "category", "app" match "apparent", "fund" match
# "fundamental" and "sea" match "seasoned". Write a stem as `foo\w*` when you
# deliberately want the suffixes.
GLOSS_TERMS: dict[str, list[str]] = {
    "animals": [
        r"animals?", r"pets?", r"birds?", r"fish", r"insects?", r"dogs?", r"pupp\w+",
        r"cats?", r"kittens?", r"sheep", r"lambs?", r"goats?", r"cows?", r"cattle",
        r"calf", r"calves", r"pigs?", r"piglets?", r"horses?", r"ponies", r"pony",
        r"donkeys?", r"mules?", r"chickens?", r"hens?", r"roosters?", r"ducks?",
        r"geese", r"goose", r"turkeys?", r"rabbits?", r"hares?", r"mouse", r"mice",
        r"rats?", r"foxe?s?", r"wol(?:f|ves)", r"bears?", r"deer", r"lions?",
        r"tigers?", r"elephants?", r"monkeys?", r"snakes?", r"lizards?", r"frogs?",
        r"toads?", r"turtles?", r"spiders?", r"flies", r"bees?", r"wasps?", r"ants?",
        r"butterfl\w+", r"mosquito\w*", r"worms?", r"owls?", r"eagles?", r"hawks?",
        r"pigeons?", r"sparrows?", r"crows?", r"seagulls?", r"whales?", r"dolphins?",
        r"sharks?", r"paws?", r"claws?", r"feathers?", r"fur", r"beaks?", r"hoo(?:f|ves)",
        r"nests?", r"herds?", r"flocks?", r"neigh\w*", r"wildlife", r"fauna",
        r"livestock", r"veterinar\w+", r"kennels?", r"stables?", r"cages?",
    ],
    "weather-and-nature": [
        r"weather", r"forecasts?", r"climate", r"rain", r"rainy", r"drizzle",
        r"snow", r"snowy", r"hail", r"sleet", r"winds?", r"windy", r"breeze",
        r"gale", r"storms?", r"stormy", r"thunder", r"lightning", r"clouds?",
        r"cloudy", r"sunny", r"sunshine", r"sunset", r"sunrise", r"dawn", r"dusk",
        r"fog", r"foggy", r"mist", r"frost", r"thaw", r"drought", r"floods?",
        r"temperature", r"seasons?", r"spring", r"summer", r"autumn", r"winter",
        r"trees?", r"leaf", r"leaves", r"branch(?:es)?", r"trunks?", r"roots?",
        r"flowers?", r"blossoms?", r"petals?", r"grass", r"plants?", r"bushes",
        r"shrubs?", r"forests?", r"woods?", r"jungle", r"meadows?", r"fields?",
        r"crops?", r"harvest", r"soil", r"mud", r"sand", r"dust", r"stones?",
        r"rocks?", r"boulders?", r"cliffs?", r"mountains?", r"hills?", r"valleys?",
        r"slopes?", r"rivers?", r"streams?", r"lakes?", r"ponds?", r"lagoons?",
        r"sea", r"ocean", r"waves?", r"tide", r"beach(?:es)?", r"shore", r"coast",
        r"coastal", r"bay", r"islands?", r"desert", r"volcano\w*", r"caves?",
        r"waterfalls?", r"dew", r"rainbow", r"earthquake", r"landscape", r"scenery",
        r"countryside", r"nature", r"flora",
    ],
    "studying": [
        r"schools?", r"schooling", r"students?", r"pupils?", r"teachers?",
        r"professors?", r"tutors?", r"classroom", r"lessons?", r"lectures?",
        r"seminars?", r"courses?", r"curriculum", r"syllabus", r"study", r"studies",
        r"studying", r"revision", r"exams?", r"examination", r"quiz", r"grades?",
        r"degrees?", r"diplomas?", r"doctorate", r"universit\w+", r"college",
        r"faculty", r"campus", r"homework", r"essays?", r"thesis", r"dissertation",
        r"notebooks?", r"pencils?", r"erasers?", r"textbooks?", r"semester",
        r"scholarship", r"enrol\w*", r"graduate", r"graduation", r"library",
        r"literacy", r"learn", r"learning", r"teach", r"teaching", r"tuition",
        r"blackboard", r"whiteboard", r"timetable", r"academic", r"lecturer",
    ],
    "phone-and-internet": [
        r"phone", r"telephone", r"mobile phone", r"smartphone", r"voicemail",
        r"ringtone", r"text message", r"app", r"apps", r"screen", r"touchscreen",
        r"internet", r"online", r"offline", r"website", r"web page", r"browser",
        r"search engine", r"e-?mail", r"inbox", r"password", r"username",
        r"log ?in", r"download", r"upload", r"streaming", r"wi-?fi", r"broadband",
        r"router", r"devices?", r"laptop", r"tablet", r"computer", r"keyboard",
        r"charger", r"battery", r"bluetooth", r"privacy", r"hackers?", r"virus",
        r"software", r"notification", r"emoji", r"selfie", r"social media",
        r"link", r"click", r"scroll", r"swipe", r"subscription", r"digital",
    ],
    "out-and-about": [
        r"party", r"parties", r"celebration", r"concerts?", r"cinema", r"films?",
        r"movies?", r"museums?", r"galler\w+", r"exhibition", r"theatres?",
        r"theaters?", r"nightclub", r"pub", r"caf[eé]", r"terrace", r"dance",
        r"dancing", r"music", r"musical", r"songs?", r"sing", r"singer",
        r"orchestra", r"choir", r"guitar", r"piano", r"drums?", r"violin",
        r"instrument", r"festivals?", r"carnival", r"parade", r"sports?",
        r"tournament", r"league", r"referee", r"stadium", r"gym", r"swim",
        r"swimming", r"jogging", r"cycling", r"hiking", r"climbing", r"skiing",
        r"surfing", r"yoga", r"hobby", r"hobbies", r"pastime", r"leisure",
        r"board game", r"puzzle", r"chess", r"photography", r"painting",
        r"drawing", r"knitting", r"gardening", r"novels?", r"magazines?",
        r"podcast", r"entertainment", r"championship", r"spectators?",
    ],
    "money": [
        r"money", r"cash", r"coins?", r"banknotes?", r"currency", r"bank",
        r"banking", r"salary", r"salaries", r"wages?", r"pay", r"payment",
        r"payslip", r"income", r"earnings", r"profit", r"cost", r"costs?",
        r"prices?", r"expensive", r"cheap", r"afford", r"affordable", r"budget",
        r"expenses?", r"spending", r"bills?", r"invoices?", r"receipts?", r"tax",
        r"taxes", r"taxation", r"vat", r"loans?", r"lend", r"borrow", r"debts?",
        r"owe", r"mortgage", r"rent", r"instal?ment", r"savings", r"deposit",
        r"withdraw", r"credit", r"debit", r"refund", r"reimburse", r"discount",
        r"bargain", r"fees?", r"surcharge", r"insurance", r"pension",
        r"inheritance", r"invest", r"investment", r"donation", r"charity",
        r"wealth", r"wealthy", r"poverty", r"bankrupt\w*", r"insolven\w+",
    ],
    "work": [
        r"jobs?", r"work", r"workers?", r"workplace", r"employ", r"employees?",
        r"employers?", r"employment", r"unemploy\w+", r"colleagues?",
        r"co-?workers?", r"boss", r"managers?", r"management", r"supervisors?",
        r"staff", r"workforce", r"careers?", r"profession", r"professional",
        r"occupation", r"trade union", r"hire", r"hiring", r"recruit\w*",
        r"interview", r"cv", r"r[eé]sum[eé]", r"freelance", r"self-employed",
        r"interns?", r"internship", r"apprentice\w*", r"shifts?", r"overtime",
        r"office", r"meetings?", r"agenda", r"deadlines?", r"promotion",
        r"resign", r"retire", r"retirement", r"redundan\w+", r"dismissal",
        r"sick leave", r"maternity", r"workload", r"company", r"firm",
        r"entrepreneur", r"startup", r"clients?", r"supplier", r"contractor",
        r"foreman", r"payroll", r"vacancy", r"vacancies",
    ],
}

GLOSS_RULES = {
    slug: r"\b(?:" + "|".join(terms) + r")\b"
    for slug, terms in GLOSS_TERMS.items()
}

# Glosses are comma-separated sense lists, so a SECONDARY sense can trigger a
# match the word doesn't deserve. Two defences, both language-independent
# because the gloss is English in all four seeds:
#
#  1. Parentheticals are stripped before matching — "(body or music)" and
#     "(hotel room or music)" are clarifications about the word, not senses of
#     it, and were pulling `órgano`/`suite` into Out & About.
#  2. This exclusion list vetoes a deck when the gloss matches a known
#     false-friend phrase.
GLOSS_EXCLUDE: dict[str, list[str]] = {
    "animals": [r"puppet", r"to bear\b", r"bear in mind"],
    "weather-and-nature": [r"to soil", r"flux", r"zone, field", r"field of study"],
    "studying": [r"of course", r"course of action", r"main course"],
    "phone-and-internet": [r"weighing device", r"mechanism", r"pill", r"pile, stack"],
    "out-and-about": [r"party member", r"political party", r"activist"],
    "work": [r"left-luggage office", r"term of office", r"hard work", r"box office",
             r"post office"],
    "money": [],
}

_EXCLUDE = {
    slug: re.compile("|".join(pats), re.I) if pats else None
    for slug, pats in GLOSS_EXCLUDE.items()
}
_PARENTHETICAL = re.compile(r"\([^)]*\)")

# Lemma-level overrides, keyed by language code then lemma. `add` forces a deck
# on; `drop` forces one off. These exist for glosses that are genuinely
# ambiguous in English and would otherwise be mis-sorted by the regexes above.
OVERRIDES: dict[str, dict[str, dict[str, set[str]]]] = {
    "es": {
        "mosca":   {"add": {"animals"}},
        "coco":    {"drop": {"animals", "weather-and-nature"}},
        "golfo":   {"drop": {"animals"}},
        "sirena":  {"drop": {"animals"}},
        "pez":     {"add": {"animals"}},
        "pescado": {"drop": {"animals"}, "addx": {"food-and-drink"}},
        "hoja":    {"add": {"weather-and-nature"}},
        "tiempo":  {"drop": {"weather-and-nature"}},
    },
    "de": {
        "Fliege":  {"add": {"animals"}},
        "Blatt":   {"add": {"weather-and-nature"}},
        "Wetter":  {"add": {"weather-and-nature"}},
        "Zeit":    {"drop": {"weather-and-nature"}},
    },
    "fr": {
        "mouche":  {"add": {"animals"}},
        "feuille": {"add": {"weather-and-nature"}},
        "temps":   {"drop": {"weather-and-nature"}},
        "poisson": {"add": {"animals"}},
    },
    "it": {
        "mosca":   {"add": {"animals"}},
        "foglia":  {"add": {"weather-and-nature"}},
        "tempo":   {"drop": {"weather-and-nature"}},
        "pesce":   {"add": {"animals"}},
    },
}

# Decks whose membership this pass computes from scratch. A word's existing tag
# for one of these is discarded and recomputed, which is how `traveling` sheds
# its nature/animal residue and how `work-and-money` splits in two.
RECOMPUTED = set(GLOSS_RULES)

# `traveling` keeps its hand-authored membership EXCEPT where the word turns
# out to be nature or an animal — that residue is what the old taxonomy merged
# in and what this pass is undoing.
TRAVELING_YIELDS_TO = {"weather-and-nature", "animals"}

# The pre-split slug. Words carrying it get `work`/`money` recomputed from the
# gloss, and fall back to `work` when neither matches.
#
# The fallback is deliberate. Dropping the tag instead de-bloats the deck
# nicely (~1,000 words down to ~200) but is destructive: it also discards
# hand-curated tags the rules can't re-derive — `periodo de prueba`,
# `funcionario`, `suministros`, `plazo de entrega` all lost their tag in
# testing. Splitting is worth doing on its own (Money becomes a focused,
# accurate deck); pruning what remains in Work needs real judgment per word,
# i.e. the LLM tagger, not a gloss regex.
LEGACY_WORK_MONEY = "work-and-money"
LEGACY_WORK_MONEY_FALLBACK = "work"

_COMPILED = {slug: re.compile(pat, re.I) for slug, pat in GLOSS_RULES.items()}


def retag(language_code: str, lemma: str, gloss: str, slugs: list[str]) -> list[str]:
    """Return the replacement slug list for one word (always includes `common`)."""
    kept = {
        s for s in slugs
        if s != COMMON and s not in RECOMPUTED and s != LEGACY_WORK_MONEY
    }

    probe = _PARENTHETICAL.sub(" ", gloss)
    matched = {
        slug for slug, rx in _COMPILED.items()
        if rx.search(probe)
        and not (_EXCLUDE[slug] and _EXCLUDE[slug].search(probe))
    }

    ov = OVERRIDES.get(language_code, {}).get(lemma, {})
    matched |= ov.get("add", set())
    matched -= ov.get("drop", set())
    kept |= ov.get("addx", set())

    if matched & TRAVELING_YIELDS_TO:
        kept.discard("traveling")

    if LEGACY_WORK_MONEY in slugs and not (matched & {"work", "money"}):
        matched.add(LEGACY_WORK_MONEY_FALLBACK)

    result = kept | matched
    return [COMMON] + sorted(result)
