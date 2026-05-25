#!/usr/bin/env python3
"""Generate spanish_top1000.json from a hand-curated dictionary.

This script is a build-time tool — it is NOT bundled in the app. It produces
`lingojam/Resources/spanish_top1000.json` which the app reads on first launch.

The curated entries below were authored manually with reference to the
hermitdave/FrequencyWords Spanish list (top frequencies in OpenSubtitles).
Each entry contains:
  - rank: position in our curated ordering (roughly frequency-ordered)
  - lemma: the Spanish word in its dictionary form
  - partOfSpeech: a short tag (noun, verb, adjective, ...)
  - definitions.en: a concise English gloss suitable for a flashcard "back"
  - example.es: a short Spanish sentence using the word
  - example.translations.en: English translation of the example

The list focuses on CONTENT WORDS (verbs, nouns, adjectives, meaningful
adverbs) rather than pure grammatical particles. Function words like
articles, prepositions, and conjunctions are not great flashcard material
— learners acquire those through reading and example sentences.

To extend toward 1000 words: append new entries to ENTRIES (in roughly
frequency or pedagogical order) and re-run this script.

Attribution: frequency rankings are inspired by
https://github.com/hermitdave/FrequencyWords (MIT). Example sentences and
translations were authored from scratch for this project.
"""

import json
from pathlib import Path
from vocab_pipeline import DEFAULT_DECKS, normalize_slugs

# (lemma, part_of_speech, english_gloss, spanish_example, english_translation)
ENTRIES = [
    # Essential verbs — the absolute foundation of Spanish
    ("ser", "verb", "to be (essential quality)", "Yo soy estudiante.", "I am a student."),
    ("estar", "verb", "to be (state/location)", "Estoy cansado.", "I am tired."),
    ("tener", "verb", "to have", "Tengo hambre.", "I'm hungry."),
    ("haber", "verb", "there is/are; to have (aux.)", "Hay un problema.", "There is a problem."),
    ("hacer", "verb", "to do, to make", "¿Qué haces?", "What are you doing?"),
    ("ir", "verb", "to go", "Voy al mercado.", "I'm going to the market."),
    ("decir", "verb", "to say, to tell", "Dime la verdad.", "Tell me the truth."),
    ("ver", "verb", "to see, to watch", "Quiero ver la película.", "I want to watch the movie."),
    ("querer", "verb", "to want; to love", "Quiero un café.", "I want a coffee."),
    ("poder", "verb", "to be able, can", "No puedo ir hoy.", "I can't go today."),
    ("saber", "verb", "to know (a fact)", "No sé qué decir.", "I don't know what to say."),
    ("dar", "verb", "to give", "Te doy un regalo.", "I'll give you a gift."),
    ("hablar", "verb", "to speak, to talk", "Hablo dos idiomas.", "I speak two languages."),
    ("llegar", "verb", "to arrive", "Llego mañana.", "I arrive tomorrow."),
    ("pasar", "verb", "to pass, to happen", "¿Qué pasa?", "What's happening?"),
    ("deber", "verb", "must, should", "Debo trabajar.", "I have to work."),
    ("poner", "verb", "to put, to place", "Pon el libro en la mesa.", "Put the book on the table."),
    ("parecer", "verb", "to seem, to appear", "Parece fácil.", "It seems easy."),
    ("quedar", "verb", "to stay, to remain", "Me quedo en casa.", "I'm staying home."),
    ("creer", "verb", "to believe, to think", "Creo que sí.", "I think so."),
    ("dejar", "verb", "to leave, to let", "Déjame en paz.", "Leave me alone."),
    ("seguir", "verb", "to follow, to continue", "Sigue por la calle.", "Continue down the street."),
    ("encontrar", "verb", "to find", "No encuentro mis llaves.", "I can't find my keys."),
    ("llamar", "verb", "to call; to be named", "Me llamo Carlos.", "My name is Carlos."),
    ("venir", "verb", "to come", "Ven aquí.", "Come here."),
    ("pensar", "verb", "to think", "¿En qué piensas?", "What are you thinking about?"),
    ("salir", "verb", "to leave, to go out", "Salgo a las ocho.", "I leave at eight."),
    ("volver", "verb", "to return, to come back", "Vuelvo en una hora.", "I'll be back in an hour."),
    ("tomar", "verb", "to take, to drink", "Tomo café por la mañana.", "I drink coffee in the morning."),
    ("conocer", "verb", "to know (a person/place)", "Conozco a tu hermana.", "I know your sister."),
    ("vivir", "verb", "to live", "Vivo en Madrid.", "I live in Madrid."),
    ("sentir", "verb", "to feel; to be sorry", "Lo siento mucho.", "I'm very sorry."),
    ("mirar", "verb", "to look at, to watch", "Mira el cielo.", "Look at the sky."),
    ("contar", "verb", "to count, to tell", "Cuéntame un cuento.", "Tell me a story."),
    ("empezar", "verb", "to begin, to start", "La clase empieza ahora.", "Class starts now."),
    ("esperar", "verb", "to wait; to hope", "Te espero en casa.", "I'll wait for you at home."),
    ("buscar", "verb", "to look for, to search", "Busco mi teléfono.", "I'm looking for my phone."),
    ("entrar", "verb", "to enter, to come in", "Entra, por favor.", "Come in, please."),
    ("trabajar", "verb", "to work", "Trabajo en una oficina.", "I work in an office."),
    ("escuchar", "verb", "to listen", "Escucho música cada día.", "I listen to music every day."),
    ("recordar", "verb", "to remember", "Recuerdo aquel día.", "I remember that day."),
    ("terminar", "verb", "to finish, to end", "Termino el trabajo.", "I'll finish the work."),
    ("comer", "verb", "to eat", "Vamos a comer.", "Let's eat."),
    ("beber", "verb", "to drink", "Bebo agua todos los días.", "I drink water every day."),
    ("dormir", "verb", "to sleep", "Duermo ocho horas.", "I sleep eight hours."),
    ("leer", "verb", "to read", "Leo todas las noches.", "I read every night."),
    ("escribir", "verb", "to write", "Escribo una carta.", "I'm writing a letter."),
    ("aprender", "verb", "to learn", "Quiero aprender español.", "I want to learn Spanish."),
    ("enseñar", "verb", "to teach, to show", "Mi madre me enseña a cocinar.", "My mother teaches me to cook."),
    ("estudiar", "verb", "to study", "Estudio para el examen.", "I'm studying for the exam."),
    ("jugar", "verb", "to play", "Los niños juegan en el parque.", "The children play in the park."),
    ("correr", "verb", "to run", "Corro cada mañana.", "I run every morning."),
    ("caminar", "verb", "to walk", "Caminamos por la playa.", "We walk along the beach."),
    ("viajar", "verb", "to travel", "Me gusta viajar.", "I like to travel."),
    ("pagar", "verb", "to pay", "Pago con tarjeta.", "I'll pay with a card."),
    ("comprar", "verb", "to buy", "Compro pan en la tienda.", "I buy bread at the shop."),
    ("vender", "verb", "to sell", "Venden frutas en el mercado.", "They sell fruit at the market."),
    ("abrir", "verb", "to open", "Abre la ventana.", "Open the window."),
    ("cerrar", "verb", "to close", "Cierra la puerta.", "Close the door."),
    ("cambiar", "verb", "to change", "Quiero cambiar de trabajo.", "I want to change jobs."),
    ("ayudar", "verb", "to help", "¿Puedes ayudarme?", "Can you help me?"),
    ("gustar", "verb", "to please, to like", "Me gusta el café.", "I like coffee."),
    ("amar", "verb", "to love", "Amo a mi familia.", "I love my family."),
    ("necesitar", "verb", "to need", "Necesito ayuda.", "I need help."),
    ("usar", "verb", "to use", "Uso el teléfono cada día.", "I use the phone every day."),
    ("cantar", "verb", "to sing", "Cantamos en la fiesta.", "We sing at the party."),
    ("bailar", "verb", "to dance", "Bailo salsa los sábados.", "I dance salsa on Saturdays."),
    ("cocinar", "verb", "to cook", "Mi padre cocina muy bien.", "My father cooks very well."),
    ("conducir", "verb", "to drive", "Conduzco al trabajo.", "I drive to work."),
    ("ganar", "verb", "to win, to earn", "Ganamos el partido.", "We won the game."),
    ("perder", "verb", "to lose", "Perdí mis llaves.", "I lost my keys."),

    # Core people/family nouns
    ("hombre", "noun (masc.)", "man", "Aquel hombre es alto.", "That man is tall."),
    ("mujer", "noun (fem.)", "woman, wife", "Esa mujer es mi tía.", "That woman is my aunt."),
    ("niño", "noun (masc.)", "boy, child", "El niño juega con el perro.", "The boy plays with the dog."),
    ("niña", "noun (fem.)", "girl", "La niña tiene cinco años.", "The girl is five years old."),
    ("hijo", "noun (masc.)", "son, child", "Mi hijo estudia mucho.", "My son studies a lot."),
    ("hija", "noun (fem.)", "daughter", "Mi hija toca la guitarra.", "My daughter plays guitar."),
    ("padre", "noun (masc.)", "father", "Mi padre es médico.", "My father is a doctor."),
    ("madre", "noun (fem.)", "mother", "Mi madre cocina bien.", "My mother cooks well."),
    ("hermano", "noun (masc.)", "brother", "Mi hermano vive en París.", "My brother lives in Paris."),
    ("hermana", "noun (fem.)", "sister", "Mi hermana es profesora.", "My sister is a teacher."),
    ("abuelo", "noun (masc.)", "grandfather", "Mi abuelo cuenta historias.", "My grandfather tells stories."),
    ("abuela", "noun (fem.)", "grandmother", "Mi abuela hace pasteles.", "My grandmother makes cakes."),
    ("amigo", "noun (masc.)", "friend (male)", "Mi mejor amigo se llama Luis.", "My best friend's name is Luis."),
    ("amiga", "noun (fem.)", "friend (female)", "Mi amiga llega esta noche.", "My friend arrives tonight."),
    ("familia", "noun (fem.)", "family", "Mi familia es grande.", "My family is big."),
    ("gente", "noun (fem.)", "people", "Hay mucha gente aquí.", "There are a lot of people here."),
    ("persona", "noun (fem.)", "person", "Es una buena persona.", "He is a good person."),

    # Time nouns
    ("día", "noun (masc.)", "day", "Buenos días.", "Good morning."),
    ("noche", "noun (fem.)", "night", "Buenas noches.", "Good night."),
    ("mañana", "noun (fem.)/adverb", "morning; tomorrow", "Hasta mañana.", "See you tomorrow."),
    ("tarde", "noun (fem.)/adverb", "afternoon; late", "Buenas tardes.", "Good afternoon."),
    ("semana", "noun (fem.)", "week", "Nos vemos la próxima semana.", "See you next week."),
    ("mes", "noun (masc.)", "month", "Este mes es mayo.", "This month is May."),
    ("año", "noun (masc.)", "year", "Tengo veinte años.", "I am twenty years old."),
    ("hora", "noun (fem.)", "hour, time", "¿Qué hora es?", "What time is it?"),
    ("minuto", "noun (masc.)", "minute", "Espera un minuto.", "Wait a minute."),
    ("momento", "noun (masc.)", "moment", "Un momento, por favor.", "One moment, please."),
    ("tiempo", "noun (masc.)", "time; weather", "No tengo tiempo.", "I don't have time."),
    ("vez", "noun (fem.)", "time, occasion", "Por primera vez.", "For the first time."),

    # Place nouns
    ("casa", "noun (fem.)", "house, home", "Voy a casa.", "I'm going home."),
    ("calle", "noun (fem.)", "street", "Vivo en esta calle.", "I live on this street."),
    ("ciudad", "noun (fem.)", "city", "Madrid es una gran ciudad.", "Madrid is a great city."),
    ("país", "noun (masc.)", "country", "Visito otro país.", "I'm visiting another country."),
    ("mundo", "noun (masc.)", "world", "Es el mejor del mundo.", "He's the best in the world."),
    ("lugar", "noun (masc.)", "place", "Este lugar es bonito.", "This place is pretty."),
    ("escuela", "noun (fem.)", "school", "Voy a la escuela.", "I'm going to school."),
    ("trabajo", "noun (masc.)", "work, job", "Mi trabajo es difícil.", "My job is hard."),
    ("oficina", "noun (fem.)", "office", "La oficina está cerrada.", "The office is closed."),
    ("tienda", "noun (fem.)", "shop, store", "Voy a la tienda.", "I'm going to the shop."),
    ("mercado", "noun (masc.)", "market", "El mercado abre a las ocho.", "The market opens at eight."),
    ("restaurante", "noun (masc.)", "restaurant", "Cenamos en un restaurante.", "We have dinner at a restaurant."),
    ("hospital", "noun (masc.)", "hospital", "Trabaja en el hospital.", "She works at the hospital."),
    ("aeropuerto", "noun (masc.)", "airport", "Te recojo en el aeropuerto.", "I'll pick you up at the airport."),
    ("estación", "noun (fem.)", "station", "La estación está cerca.", "The station is nearby."),
    ("parque", "noun (masc.)", "park", "Caminamos en el parque.", "We walk in the park."),
    ("playa", "noun (fem.)", "beach", "Vamos a la playa.", "Let's go to the beach."),
    ("montaña", "noun (fem.)", "mountain", "La montaña es alta.", "The mountain is high."),
    ("río", "noun (masc.)", "river", "El río pasa por la ciudad.", "The river runs through the city."),
    ("mar", "noun (masc./fem.)", "sea", "El mar está tranquilo.", "The sea is calm."),

    # Home
    ("puerta", "noun (fem.)", "door", "Cierra la puerta.", "Close the door."),
    ("ventana", "noun (fem.)", "window", "Abre la ventana.", "Open the window."),
    ("mesa", "noun (fem.)", "table", "La cena está en la mesa.", "Dinner is on the table."),
    ("silla", "noun (fem.)", "chair", "Siéntate en la silla.", "Sit on the chair."),
    ("cama", "noun (fem.)", "bed", "Voy a la cama temprano.", "I'm going to bed early."),
    ("baño", "noun (masc.)", "bathroom", "¿Dónde está el baño?", "Where is the bathroom?"),
    ("cocina", "noun (fem.)", "kitchen", "La cocina huele bien.", "The kitchen smells good."),
    ("habitación", "noun (fem.)", "room", "Mi habitación es pequeña.", "My room is small."),

    # Food & drink
    ("agua", "noun (fem.)", "water", "Quiero un vaso de agua.", "I want a glass of water."),
    ("café", "noun (masc.)", "coffee", "Quiero un café con leche.", "I want a coffee with milk."),
    ("té", "noun (masc.)", "tea", "Prefiero el té verde.", "I prefer green tea."),
    ("leche", "noun (fem.)", "milk", "Compro leche en la tienda.", "I'm buying milk at the store."),
    ("pan", "noun (masc.)", "bread", "Me gusta el pan caliente.", "I like warm bread."),
    ("comida", "noun (fem.)", "food, meal", "La comida está lista.", "The food is ready."),
    ("desayuno", "noun (masc.)", "breakfast", "El desayuno es a las siete.", "Breakfast is at seven."),
    ("almuerzo", "noun (masc.)", "lunch", "El almuerzo dura una hora.", "Lunch lasts an hour."),
    ("cena", "noun (fem.)", "dinner", "La cena está deliciosa.", "Dinner is delicious."),
    ("fruta", "noun (fem.)", "fruit", "La fruta es saludable.", "Fruit is healthy."),
    ("carne", "noun (fem.)", "meat", "No como carne.", "I don't eat meat."),
    ("pescado", "noun (masc.)", "fish (food)", "El pescado está fresco.", "The fish is fresh."),
    ("verdura", "noun (fem.)", "vegetable", "Como verduras cada día.", "I eat vegetables every day."),
    ("queso", "noun (masc.)", "cheese", "Me encanta el queso.", "I love cheese."),
    ("huevo", "noun (masc.)", "egg", "Quiero dos huevos.", "I'd like two eggs."),
    ("azúcar", "noun (masc./fem.)", "sugar", "Sin azúcar, por favor.", "No sugar, please."),
    ("sal", "noun (fem.)", "salt", "Pásame la sal.", "Pass me the salt."),
    ("manzana", "noun (fem.)", "apple", "Como una manzana al día.", "I eat an apple a day."),
    ("naranja", "noun (fem.)", "orange", "El zumo de naranja es rico.", "Orange juice is delicious."),
    ("vino", "noun (masc.)", "wine", "Pedimos vino tinto.", "We ordered red wine."),
    ("cerveza", "noun (fem.)", "beer", "Tomamos una cerveza fría.", "We had a cold beer."),

    # Things & objects
    ("libro", "noun (masc.)", "book", "Leo un libro interesante.", "I'm reading an interesting book."),
    ("coche", "noun (masc.)", "car", "Mi coche es rojo.", "My car is red."),
    ("dinero", "noun (masc.)", "money", "No tengo dinero.", "I don't have money."),
    ("teléfono", "noun (masc.)", "telephone", "¿Cuál es tu teléfono?", "What's your phone number?"),
    ("ordenador", "noun (masc.)", "computer", "Trabajo con mi ordenador.", "I work with my computer."),
    ("llave", "noun (fem.)", "key", "Olvidé mis llaves.", "I forgot my keys."),
    ("bolso", "noun (masc.)", "bag, handbag", "Mi bolso es nuevo.", "My bag is new."),
    ("reloj", "noun (masc.)", "clock, watch", "Mi reloj está roto.", "My watch is broken."),
    ("cámara", "noun (fem.)", "camera", "La cámara es cara.", "The camera is expensive."),
    ("dinero", "noun (masc.)", "money", "El dinero no es todo.", "Money isn't everything."),

    # Clothing
    ("ropa", "noun (fem.)", "clothes", "La ropa está sucia.", "The clothes are dirty."),
    ("camisa", "noun (fem.)", "shirt", "Llevo una camisa blanca.", "I'm wearing a white shirt."),
    ("pantalón", "noun (masc.)", "trousers, pants", "Estos pantalones son nuevos.", "These pants are new."),
    ("zapato", "noun (masc.)", "shoe", "Mis zapatos están sucios.", "My shoes are dirty."),
    ("vestido", "noun (masc.)", "dress", "El vestido es bonito.", "The dress is pretty."),
    ("sombrero", "noun (masc.)", "hat", "Llevo un sombrero rojo.", "I'm wearing a red hat."),

    # Body parts
    ("cabeza", "noun (fem.)", "head", "Me duele la cabeza.", "My head hurts."),
    ("cara", "noun (fem.)", "face", "Tiene una cara amable.", "He has a kind face."),
    ("ojo", "noun (masc.)", "eye", "Tiene ojos azules.", "She has blue eyes."),
    ("nariz", "noun (fem.)", "nose", "Le sangra la nariz.", "His nose is bleeding."),
    ("boca", "noun (fem.)", "mouth", "Abre la boca.", "Open your mouth."),
    ("oreja", "noun (fem.)", "ear", "Le duele la oreja.", "His ear hurts."),
    ("pelo", "noun (masc.)", "hair", "Tiene el pelo largo.", "She has long hair."),
    ("mano", "noun (fem.)", "hand", "Dame la mano.", "Give me your hand."),
    ("pie", "noun (masc.)", "foot", "Me duele el pie.", "My foot hurts."),
    ("brazo", "noun (masc.)", "arm", "Se rompió el brazo.", "He broke his arm."),
    ("pierna", "noun (fem.)", "leg", "Tengo las piernas cansadas.", "My legs are tired."),
    ("corazón", "noun (masc.)", "heart", "Te quiero con todo mi corazón.", "I love you with all my heart."),

    # Nature
    ("sol", "noun (masc.)", "sun", "Hoy brilla el sol.", "The sun is shining today."),
    ("luna", "noun (fem.)", "moon", "La luna está llena.", "The moon is full."),
    ("cielo", "noun (masc.)", "sky", "El cielo está azul.", "The sky is blue."),
    ("estrella", "noun (fem.)", "star", "Las estrellas brillan.", "The stars are shining."),
    ("nube", "noun (fem.)", "cloud", "Hay muchas nubes hoy.", "There are many clouds today."),
    ("lluvia", "noun (fem.)", "rain", "La lluvia es fuerte.", "The rain is heavy."),
    ("nieve", "noun (fem.)", "snow", "Me encanta la nieve.", "I love the snow."),
    ("viento", "noun (masc.)", "wind", "Hace mucho viento hoy.", "It's very windy today."),
    ("fuego", "noun (masc.)", "fire", "El fuego está caliente.", "The fire is hot."),
    ("tierra", "noun (fem.)", "earth, ground, land", "La tierra es nuestro hogar.", "The earth is our home."),
    ("aire", "noun (masc.)", "air", "El aire es fresco.", "The air is fresh."),
    ("flor", "noun (fem.)", "flower", "Te regalo una flor.", "I'll give you a flower."),
    ("árbol", "noun (masc.)", "tree", "El árbol da sombra.", "The tree gives shade."),
    ("hoja", "noun (fem.)", "leaf; sheet", "La hoja cae del árbol.", "The leaf falls from the tree."),

    # Animals
    ("perro", "noun (masc.)", "dog", "Mi perro se llama Max.", "My dog is named Max."),
    ("gato", "noun (masc.)", "cat", "El gato duerme en el sofá.", "The cat sleeps on the sofa."),
    ("caballo", "noun (masc.)", "horse", "El caballo corre rápido.", "The horse runs fast."),
    ("pájaro", "noun (masc.)", "bird", "El pájaro canta por la mañana.", "The bird sings in the morning."),
    ("pez", "noun (masc.)", "fish (animal)", "El pez nada en el río.", "The fish swims in the river."),
    ("vaca", "noun (fem.)", "cow", "La vaca da leche.", "The cow gives milk."),

    # Abstract / common nouns
    ("vida", "noun (fem.)", "life", "Así es la vida.", "That's life."),
    ("amor", "noun (masc.)", "love", "El amor es paciente.", "Love is patient."),
    ("paz", "noun (fem.)", "peace", "Buscamos la paz.", "We seek peace."),
    ("verdad", "noun (fem.)", "truth", "Dime la verdad.", "Tell me the truth."),
    ("mentira", "noun (fem.)", "lie", "No me digas mentiras.", "Don't lie to me."),
    ("idea", "noun (fem.)", "idea", "Tengo una buena idea.", "I have a good idea."),
    ("problema", "noun (masc.)", "problem", "No hay problema.", "No problem."),
    ("pregunta", "noun (fem.)", "question", "Tengo una pregunta.", "I have a question."),
    ("respuesta", "noun (fem.)", "answer", "No sé la respuesta.", "I don't know the answer."),
    ("historia", "noun (fem.)", "story, history", "Es una historia larga.", "It's a long story."),
    ("nombre", "noun (masc.)", "name", "¿Cuál es tu nombre?", "What's your name?"),
    ("número", "noun (masc.)", "number", "Dame tu número.", "Give me your number."),
    ("palabra", "noun (fem.)", "word", "No entiendo esta palabra.", "I don't understand this word."),
    ("voz", "noun (fem.)", "voice", "Tienes una voz bonita.", "You have a beautiful voice."),
    ("color", "noun (masc.)", "color", "¿Cuál es tu color favorito?", "What's your favorite color?"),
    ("música", "noun (fem.)", "music", "Me encanta la música.", "I love music."),
    ("película", "noun (fem.)", "movie", "Vimos una película anoche.", "We watched a movie last night."),
    ("fiesta", "noun (fem.)", "party", "La fiesta es el sábado.", "The party is on Saturday."),
    ("camino", "noun (masc.)", "road, way, path", "Sé el camino a tu casa.", "I know the way to your house."),
    ("luz", "noun (fem.)", "light", "Apaga la luz.", "Turn off the light."),
    ("parte", "noun (fem.)", "part", "Es parte del trabajo.", "It's part of the job."),
    ("cosa", "noun (fem.)", "thing", "Hay muchas cosas que hacer.", "There are many things to do."),

    # Core adjectives — descriptive
    ("bueno", "adjective", "good", "Es un buen amigo.", "He's a good friend."),
    ("malo", "adjective", "bad", "El tiempo está malo.", "The weather is bad."),
    ("grande", "adjective", "big, large, great", "Es una casa grande.", "It's a big house."),
    ("pequeño", "adjective", "small", "Tengo un perro pequeño.", "I have a small dog."),
    ("nuevo", "adjective", "new", "Tengo un coche nuevo.", "I have a new car."),
    ("viejo", "adjective", "old", "Mi coche es viejo.", "My car is old."),
    ("joven", "adjective", "young", "Es muy joven todavía.", "He's still very young."),
    ("alto", "adjective", "tall, high", "Mi hermano es alto.", "My brother is tall."),
    ("bajo", "adjective", "short, low", "El techo es bajo.", "The ceiling is low."),
    ("largo", "adjective", "long", "El camino es largo.", "The road is long."),
    ("corto", "adjective", "short (length)", "Lleva el pelo corto.", "She wears her hair short."),
    ("ancho", "adjective", "wide", "La calle es ancha.", "The street is wide."),
    ("gordo", "adjective", "fat", "El gato está gordo.", "The cat is fat."),
    ("delgado", "adjective", "thin, slim", "Es alto y delgado.", "He's tall and thin."),
    ("fuerte", "adjective", "strong", "El café está fuerte.", "The coffee is strong."),
    ("débil", "adjective", "weak", "Me siento débil hoy.", "I feel weak today."),
    ("rápido", "adjective", "fast", "El tren es rápido.", "The train is fast."),
    ("lento", "adjective", "slow", "Camina muy lento.", "He walks very slowly."),
    ("fácil", "adjective", "easy", "Es muy fácil.", "It's very easy."),
    ("difícil", "adjective", "difficult, hard", "El examen fue difícil.", "The exam was hard."),
    ("importante", "adjective", "important", "Es una decisión importante.", "It's an important decision."),
    ("posible", "adjective", "possible", "Todo es posible.", "Everything is possible."),
    ("claro", "adjective", "clear, bright", "Está muy claro.", "It's very clear."),
    ("oscuro", "adjective", "dark", "El cuarto está oscuro.", "The room is dark."),
    ("caliente", "adjective", "hot", "El café está caliente.", "The coffee is hot."),
    ("frío", "adjective", "cold", "Hace mucho frío.", "It's very cold."),
    ("feliz", "adjective", "happy", "Soy feliz contigo.", "I'm happy with you."),
    ("triste", "adjective", "sad", "Estoy triste hoy.", "I'm sad today."),
    ("contento", "adjective", "glad, pleased", "Estoy contento con el resultado.", "I'm glad with the result."),
    ("enojado", "adjective", "angry", "Mi padre está enojado.", "My father is angry."),
    ("cansado", "adjective", "tired", "Estoy muy cansado.", "I'm very tired."),
    ("enfermo", "adjective", "sick", "Hoy estoy enfermo.", "I'm sick today."),
    ("limpio", "adjective", "clean", "La cocina está limpia.", "The kitchen is clean."),
    ("sucio", "adjective", "dirty", "Mis zapatos están sucios.", "My shoes are dirty."),
    ("rico", "adjective", "rich; tasty", "La sopa está rica.", "The soup is tasty."),
    ("pobre", "adjective", "poor", "Es una familia pobre.", "It's a poor family."),
    ("hermoso", "adjective", "beautiful", "Qué día tan hermoso.", "What a beautiful day."),
    ("bonito", "adjective", "pretty, nice", "Tienes un coche bonito.", "You have a nice car."),
    ("feo", "adjective", "ugly", "El sombrero es feo.", "The hat is ugly."),
    ("lleno", "adjective", "full", "El vaso está lleno.", "The glass is full."),
    ("vacío", "adjective", "empty", "La botella está vacía.", "The bottle is empty."),

    # Colors
    ("rojo", "adjective", "red", "El coche es rojo.", "The car is red."),
    ("azul", "adjective", "blue", "El cielo es azul.", "The sky is blue."),
    ("verde", "adjective", "green", "La hierba es verde.", "The grass is green."),
    ("amarillo", "adjective", "yellow", "El sol es amarillo.", "The sun is yellow."),
    ("blanco", "adjective", "white", "Llevo una camisa blanca.", "I'm wearing a white shirt."),
    ("negro", "adjective", "black", "Me gusta el café negro.", "I like black coffee."),
    ("gris", "adjective", "gray", "El cielo está gris.", "The sky is gray."),

    # Numbers
    ("uno", "number", "one", "Quiero uno, por favor.", "I want one, please."),
    ("dos", "number", "two", "Tengo dos hermanos.", "I have two brothers."),
    ("tres", "number", "three", "Son las tres en punto.", "It's three o'clock."),
    ("cuatro", "number", "four", "Tengo cuatro gatos.", "I have four cats."),
    ("cinco", "number", "five", "Cinco minutos más.", "Five more minutes."),
    ("seis", "number", "six", "Compré seis manzanas.", "I bought six apples."),
    ("siete", "number", "seven", "Trabajo siete horas.", "I work seven hours."),
    ("ocho", "number", "eight", "El bebé tiene ocho meses.", "The baby is eight months old."),
    ("nueve", "number", "nine", "Llamo a las nueve.", "I'll call at nine."),
    ("diez", "number", "ten", "Hay diez sillas.", "There are ten chairs."),
    ("cien", "number", "one hundred", "Hay cien personas aquí.", "There are a hundred people here."),
    ("mil", "number", "one thousand", "Cuesta mil pesos.", "It costs a thousand pesos."),

    # Useful adverbs (with real meaning, not particles)
    ("hoy", "adverb", "today", "Hoy es lunes.", "Today is Monday."),
    ("ayer", "adverb", "yesterday", "Ayer fui al cine.", "Yesterday I went to the cinema."),
    ("siempre", "adverb", "always", "Siempre llego tarde.", "I always arrive late."),
    ("nunca", "adverb", "never", "Nunca digo mentiras.", "I never lie."),
    ("bien", "adverb", "well", "Hablas bien español.", "You speak Spanish well."),
    ("mal", "adverb", "badly", "Me siento mal hoy.", "I feel bad today."),
    ("cerca", "adverb", "near, close", "Vivo cerca del parque.", "I live near the park."),
    ("lejos", "adverb", "far", "La playa está lejos.", "The beach is far."),
    ("arriba", "adverb", "up, above", "El gato está arriba.", "The cat is upstairs."),
    ("abajo", "adverb", "down, below", "Mira abajo.", "Look down."),
    ("dentro", "adverb", "inside", "Te espero dentro.", "I'll wait for you inside."),
    ("fuera", "adverb", "outside", "Los niños juegan fuera.", "The kids are playing outside."),
    ("temprano", "adverb", "early", "Me levanto temprano.", "I get up early."),
    ("rápidamente", "adverb", "quickly", "Habla rápidamente.", "He speaks quickly."),

    # Essentials & interjections
    ("hola", "interjection", "hello", "Hola, ¿cómo estás?", "Hello, how are you?"),
    ("adiós", "interjection", "goodbye", "Adiós, hasta luego.", "Goodbye, see you later."),
    ("gracias", "interjection", "thank you", "Muchas gracias.", "Thank you very much."),
    ("favor", "noun (masc.)", "favor", "Por favor, ayúdame.", "Please, help me."),
    ("perdón", "interjection/noun", "sorry, pardon", "Perdón por llegar tarde.", "Sorry for being late."),
    ("salud", "noun (fem.)", "health; cheers!", "¡Salud!", "Cheers!"),

    # Question words (essential for conversation)
    ("qué", "pronoun", "what", "¿Qué quieres comer?", "What do you want to eat?"),
    ("quién", "pronoun", "who", "¿Quién es esa persona?", "Who is that person?"),
    ("dónde", "adverb", "where", "¿Dónde vives?", "Where do you live?"),
    ("cuándo", "adverb", "when", "¿Cuándo llegas?", "When do you arrive?"),
    ("cómo", "adverb", "how", "¿Cómo estás hoy?", "How are you today?"),
    ("cuánto", "adverb/adjective", "how much", "¿Cuánto cuesta?", "How much does it cost?"),
    ("cuál", "pronoun", "which", "¿Cuál prefieres?", "Which one do you prefer?"),
    ("por qué", "phrase", "why", "¿Por qué dices eso?", "Why do you say that?"),

    # More everyday verbs — communication, social
    ("preguntar", "verb", "to ask", "Te quiero preguntar algo.", "I want to ask you something."),
    ("responder", "verb", "to answer, to reply", "No respondió a mi mensaje.", "He didn't reply to my message."),
    ("contestar", "verb", "to answer", "Contesta el teléfono.", "Answer the phone."),
    ("explicar", "verb", "to explain", "Explícame la regla.", "Explain the rule to me."),
    ("repetir", "verb", "to repeat", "¿Puedes repetir, por favor?", "Can you repeat, please?"),
    ("traducir", "verb", "to translate", "Traduzco del español al inglés.", "I translate from Spanish to English."),
    ("invitar", "verb", "to invite", "Te invito a cenar.", "I'm inviting you to dinner."),
    ("visitar", "verb", "to visit", "Vamos a visitar a la abuela.", "We're going to visit grandma."),
    ("conocerse", "verb", "to meet (each other)", "Nos conocimos en la universidad.", "We met at university."),
    ("encontrarse", "verb", "to meet up", "Nos encontramos en el café.", "We're meeting at the cafe."),
    ("despedirse", "verb", "to say goodbye", "Se despidió con un abrazo.", "She said goodbye with a hug."),
    ("agradecer", "verb", "to thank", "Te agradezco la ayuda.", "I thank you for your help."),
    ("disculpar", "verb", "to forgive, to excuse", "Disculpe, ¿qué hora es?", "Excuse me, what time is it?"),
    ("felicitar", "verb", "to congratulate", "Te felicito por tu trabajo.", "I congratulate you on your work."),

    # Daily routine verbs
    ("levantarse", "verb", "to get up", "Me levanto a las siete.", "I get up at seven."),
    ("acostarse", "verb", "to go to bed", "Me acuesto a las once.", "I go to bed at eleven."),
    ("despertarse", "verb", "to wake up", "Me despierto temprano.", "I wake up early."),
    ("ducharse", "verb", "to shower", "Me ducho cada mañana.", "I shower every morning."),
    ("bañarse", "verb", "to bathe", "El bebé se baña por la noche.", "The baby bathes at night."),
    ("vestirse", "verb", "to get dressed", "Me visto rápidamente.", "I get dressed quickly."),
    ("peinarse", "verb", "to comb one's hair", "Me peino antes de salir.", "I comb my hair before going out."),
    ("cepillarse", "verb", "to brush", "Me cepillo los dientes.", "I brush my teeth."),
    ("descansar", "verb", "to rest", "Necesito descansar un poco.", "I need to rest a bit."),
    ("sentarse", "verb", "to sit down", "Siéntate, por favor.", "Sit down, please."),
    ("ponerse", "verb", "to put on (clothes)", "Me pongo el abrigo.", "I'm putting on my coat."),
    ("quitarse", "verb", "to take off (clothes)", "Quítate los zapatos.", "Take off your shoes."),
    ("limpiar", "verb", "to clean", "Limpio la casa los sábados.", "I clean the house on Saturdays."),
    ("lavar", "verb", "to wash", "Lavo los platos después de comer.", "I wash the dishes after eating."),
    ("planchar", "verb", "to iron", "Plancho la camisa para mañana.", "I'm ironing the shirt for tomorrow."),

    # Movement verbs
    ("mover", "verb", "to move", "Mueve la silla, por favor.", "Move the chair, please."),
    ("subir", "verb", "to go up, to climb", "Subo las escaleras.", "I'm going up the stairs."),
    ("bajar", "verb", "to go down", "Baja la voz, por favor.", "Lower your voice, please."),
    ("saltar", "verb", "to jump", "Los niños saltan en la cama.", "The kids are jumping on the bed."),
    ("nadar", "verb", "to swim", "Nado en la piscina los domingos.", "I swim in the pool on Sundays."),
    ("volar", "verb", "to fly", "El avión vuela alto.", "The plane flies high."),
    ("conducir", "verb", "to drive", "Conduzco al trabajo cada día.", "I drive to work every day."),
    ("montar", "verb", "to ride", "Me gusta montar en bicicleta.", "I like to ride a bike."),
    ("traer", "verb", "to bring", "Trae el libro, por favor.", "Bring the book, please."),
    ("llevar", "verb", "to take, to carry", "Llevo a mi hijo a la escuela.", "I take my son to school."),
    ("enviar", "verb", "to send", "Te envío un correo.", "I'll send you an email."),
    ("recibir", "verb", "to receive", "Recibí tu regalo, gracias.", "I received your gift, thank you."),
    ("regalar", "verb", "to give as a gift", "Le regalo flores a mi madre.", "I give flowers to my mother."),
    ("prestar", "verb", "to lend", "¿Me prestas un bolígrafo?", "Can you lend me a pen?"),
    ("devolver", "verb", "to return (something)", "Te devuelvo el libro mañana.", "I'll return the book tomorrow."),

    # Emotions and feelings (verbs)
    ("alegrarse", "verb", "to be happy, to rejoice", "Me alegro de verte.", "I'm happy to see you."),
    ("enojarse", "verb", "to get angry", "Se enoja fácilmente.", "He gets angry easily."),
    ("preocuparse", "verb", "to worry", "No te preocupes.", "Don't worry."),
    ("sorprenderse", "verb", "to be surprised", "Me sorprendí mucho.", "I was very surprised."),
    ("aburrirse", "verb", "to get bored", "Los niños se aburren en casa.", "The kids get bored at home."),
    ("divertirse", "verb", "to have fun", "Nos divertimos mucho anoche.", "We had a lot of fun last night."),
    ("asustar", "verb", "to scare, to frighten", "El ruido me asustó.", "The noise scared me."),
    ("odiar", "verb", "to hate", "Odio levantarme temprano.", "I hate getting up early."),

    # Life events
    ("nacer", "verb", "to be born", "Nací en Madrid.", "I was born in Madrid."),
    ("morir", "verb", "to die", "Su abuelo murió el año pasado.", "His grandfather died last year."),
    ("crecer", "verb", "to grow", "Los niños crecen rápido.", "Children grow fast."),
    ("casarse", "verb", "to get married", "Mi hermana se casa en junio.", "My sister is getting married in June."),

    # Days of the week
    ("lunes", "noun (masc.)", "Monday", "El lunes empieza la semana.", "Monday is when the week begins."),
    ("martes", "noun (masc.)", "Tuesday", "Tengo clase el martes.", "I have class on Tuesday."),
    ("miércoles", "noun (masc.)", "Wednesday", "El miércoles voy al gimnasio.", "On Wednesday I go to the gym."),
    ("jueves", "noun (masc.)", "Thursday", "Nos vemos el jueves.", "See you on Thursday."),
    ("viernes", "noun (masc.)", "Friday", "Por fin es viernes.", "Finally it's Friday."),
    ("sábado", "noun (masc.)", "Saturday", "El sábado vamos al cine.", "On Saturday we're going to the movies."),
    ("domingo", "noun (masc.)", "Sunday", "El domingo descanso.", "On Sunday I rest."),

    # Months of the year
    ("enero", "noun (masc.)", "January", "Mi cumpleaños es en enero.", "My birthday is in January."),
    ("febrero", "noun (masc.)", "February", "Febrero es el mes más corto.", "February is the shortest month."),
    ("marzo", "noun (masc.)", "March", "En marzo empieza la primavera.", "Spring starts in March."),
    ("abril", "noun (masc.)", "April", "Llueve mucho en abril.", "It rains a lot in April."),
    ("mayo", "noun (masc.)", "May", "En mayo viajamos a España.", "In May we travel to Spain."),
    ("junio", "noun (masc.)", "June", "Junio es un mes caluroso.", "June is a hot month."),
    ("julio", "noun (masc.)", "July", "En julio hay vacaciones.", "In July there are holidays."),
    ("agosto", "noun (masc.)", "August", "Agosto es caluroso aquí.", "August is hot here."),
    ("septiembre", "noun (masc.)", "September", "Las clases empiezan en septiembre.", "Classes start in September."),
    ("octubre", "noun (masc.)", "October", "En octubre cambian las hojas.", "In October the leaves change."),
    ("noviembre", "noun (masc.)", "November", "Noviembre es frío.", "November is cold."),
    ("diciembre", "noun (masc.)", "December", "En diciembre celebramos la Navidad.", "In December we celebrate Christmas."),

    # Seasons
    ("primavera", "noun (fem.)", "spring", "Me encanta la primavera.", "I love spring."),
    ("verano", "noun (masc.)", "summer", "En verano vamos a la playa.", "In summer we go to the beach."),
    ("otoño", "noun (masc.)", "fall, autumn", "El otoño tiene colores bonitos.", "Fall has beautiful colors."),
    ("invierno", "noun (masc.)", "winter", "En invierno nieva mucho.", "In winter it snows a lot."),

    # Numbers 11-30 and tens
    ("once", "number", "eleven", "Tengo once años.", "I'm eleven years old."),
    ("doce", "number", "twelve", "Hay doce meses.", "There are twelve months."),
    ("trece", "number", "thirteen", "Mi hermana tiene trece años.", "My sister is thirteen."),
    ("catorce", "number", "fourteen", "Catorce de febrero.", "February fourteenth."),
    ("quince", "number", "fifteen", "Llegó hace quince minutos.", "He arrived fifteen minutes ago."),
    ("dieciséis", "number", "sixteen", "Cumplí dieciséis años.", "I turned sixteen."),
    ("veinte", "number", "twenty", "Cuesta veinte euros.", "It costs twenty euros."),
    ("treinta", "number", "thirty", "Tengo treinta años.", "I'm thirty years old."),
    ("cuarenta", "number", "forty", "Trabajo cuarenta horas a la semana.", "I work forty hours a week."),
    ("cincuenta", "number", "fifty", "Mi padre tiene cincuenta años.", "My father is fifty."),
    ("sesenta", "number", "sixty", "El edificio tiene sesenta pisos.", "The building has sixty floors."),
    ("setenta", "number", "seventy", "Mi abuela cumple setenta.", "My grandmother is turning seventy."),
    ("ochenta", "number", "eighty", "Vivió ochenta años.", "She lived eighty years."),
    ("noventa", "number", "ninety", "Hay noventa estudiantes.", "There are ninety students."),

    # Transport
    ("tren", "noun (masc.)", "train", "El tren sale a las ocho.", "The train leaves at eight."),
    ("avión", "noun (masc.)", "airplane", "El avión despega ahora.", "The plane is taking off now."),
    ("autobús", "noun (masc.)", "bus", "Tomo el autobús al trabajo.", "I take the bus to work."),
    ("metro", "noun (masc.)", "subway, metro", "El metro es rápido.", "The subway is fast."),
    ("taxi", "noun (masc.)", "taxi", "Llamamos a un taxi.", "We called a taxi."),
    ("bicicleta", "noun (fem.)", "bicycle", "Voy en bicicleta a la escuela.", "I ride my bike to school."),
    ("motocicleta", "noun (fem.)", "motorcycle", "Tiene una motocicleta nueva.", "He has a new motorcycle."),
    ("barco", "noun (masc.)", "boat, ship", "El barco zarpa al mediodía.", "The ship sails at noon."),
    ("billete", "noun (masc.)", "ticket", "Compré un billete de tren.", "I bought a train ticket."),
    ("viaje", "noun (masc.)", "trip, journey", "Buen viaje.", "Have a good trip."),
    ("maleta", "noun (fem.)", "suitcase", "Hago la maleta esta noche.", "I'll pack the suitcase tonight."),
    ("pasaporte", "noun (masc.)", "passport", "Mi pasaporte expira pronto.", "My passport expires soon."),

    # Technology
    ("internet", "noun (masc.)", "internet", "No hay internet en el café.", "There's no internet at the cafe."),
    ("ordenador", "noun (masc.)", "computer", "Mi ordenador está roto.", "My computer is broken."),
    ("móvil", "noun (masc.)", "mobile phone", "Olvidé el móvil en casa.", "I forgot my phone at home."),
    ("pantalla", "noun (fem.)", "screen", "La pantalla está sucia.", "The screen is dirty."),
    ("contraseña", "noun (fem.)", "password", "He olvidado la contraseña.", "I've forgotten the password."),
    ("correo", "noun (masc.)", "mail; email", "Te escribí un correo.", "I wrote you an email."),
    ("mensaje", "noun (masc.)", "message", "Recibí tu mensaje.", "I got your message."),
    ("aplicación", "noun (fem.)", "app, application", "Descargué una aplicación nueva.", "I downloaded a new app."),
    ("vídeo", "noun (masc.)", "video", "Vimos un vídeo divertido.", "We watched a funny video."),
    ("foto", "noun (fem.)", "photo", "Sácame una foto.", "Take a photo of me."),

    # Professions / jobs
    ("profesor", "noun (masc.)", "teacher (male)", "Mi profesor es muy bueno.", "My teacher is very good."),
    ("profesora", "noun (fem.)", "teacher (female)", "La profesora es amable.", "The teacher is kind."),
    ("médico", "noun (masc.)", "doctor (male)", "Voy al médico mañana.", "I'm going to the doctor tomorrow."),
    ("doctora", "noun (fem.)", "doctor (female)", "La doctora me dio medicina.", "The doctor gave me medicine."),
    ("enfermero", "noun (masc.)", "nurse (male)", "El enfermero es muy paciente.", "The nurse is very patient."),
    ("abogado", "noun (masc.)", "lawyer", "Necesito hablar con mi abogado.", "I need to talk to my lawyer."),
    ("ingeniero", "noun (masc.)", "engineer", "Mi padre es ingeniero.", "My father is an engineer."),
    ("policía", "noun (masc./fem.)", "police officer", "Llamamos a la policía.", "We called the police."),
    ("bombero", "noun (masc.)", "firefighter", "Los bomberos llegaron rápido.", "The firefighters arrived quickly."),
    ("cocinero", "noun (masc.)", "cook, chef", "El cocinero prepara la cena.", "The chef is preparing dinner."),
    ("camarero", "noun (masc.)", "waiter", "El camarero trae la cuenta.", "The waiter is bringing the bill."),
    ("conductor", "noun (masc.)", "driver", "El conductor es muy amable.", "The driver is very kind."),
    ("estudiante", "noun (masc./fem.)", "student", "Soy estudiante de medicina.", "I'm a medical student."),
    ("jefe", "noun (masc.)", "boss", "Mi jefe es exigente.", "My boss is demanding."),
    ("artista", "noun (masc./fem.)", "artist", "Es una artista talentosa.", "She's a talented artist."),
    ("escritor", "noun (masc.)", "writer", "Mi escritor favorito es García Márquez.", "My favorite writer is García Márquez."),
    ("músico", "noun (masc.)", "musician", "Es músico profesional.", "He's a professional musician."),

    # School / education
    ("clase", "noun (fem.)", "class", "La clase empieza ahora.", "Class is starting now."),
    ("examen", "noun (masc.)", "exam, test", "Estudio para el examen.", "I'm studying for the exam."),
    ("tarea", "noun (fem.)", "homework, task", "Tengo mucha tarea hoy.", "I have a lot of homework today."),
    ("universidad", "noun (fem.)", "university", "Estudio en la universidad.", "I study at the university."),
    ("biblioteca", "noun (fem.)", "library", "Voy a la biblioteca a estudiar.", "I'm going to the library to study."),
    ("lección", "noun (fem.)", "lesson", "La lección de hoy es difícil.", "Today's lesson is hard."),
    ("estudio", "noun (masc.)", "study", "Mi estudio favorito es la historia.", "My favorite subject is history."),
    ("idioma", "noun (masc.)", "language", "Aprendo un idioma nuevo.", "I'm learning a new language."),
    ("inglés", "noun (masc.)", "English", "Mi inglés es bueno.", "My English is good."),
    ("español", "noun (masc.)", "Spanish", "Aprendo español cada día.", "I learn Spanish every day."),
    ("francés", "noun (masc.)", "French", "Hablo un poco de francés.", "I speak a little French."),

    # Weather (more)
    ("clima", "noun (masc.)", "climate, weather", "El clima aquí es agradable.", "The climate here is pleasant."),
    ("temperatura", "noun (fem.)", "temperature", "La temperatura es alta.", "The temperature is high."),
    ("calor", "noun (masc.)", "heat", "Hace mucho calor hoy.", "It's very hot today."),
    ("tormenta", "noun (fem.)", "storm", "Viene una tormenta.", "A storm is coming."),
    ("niebla", "noun (fem.)", "fog, mist", "Hay mucha niebla esta mañana.", "There's a lot of fog this morning."),
    ("hielo", "noun (masc.)", "ice", "La calle está cubierta de hielo.", "The street is covered with ice."),
    ("relámpago", "noun (masc.)", "lightning", "El relámpago iluminó el cielo.", "Lightning lit up the sky."),
    ("trueno", "noun (masc.)", "thunder", "Escucho los truenos.", "I hear the thunder."),

    # Geography / nature
    ("norte", "noun (masc.)", "north", "Vivimos en el norte del país.", "We live in the north of the country."),
    ("sur", "noun (masc.)", "south", "El sur es más caluroso.", "The south is hotter."),
    ("este", "noun (masc.)", "east", "El sol sale por el este.", "The sun rises in the east."),
    ("oeste", "noun (masc.)", "west", "El sol se pone por el oeste.", "The sun sets in the west."),
    ("isla", "noun (fem.)", "island", "Mallorca es una isla bonita.", "Mallorca is a beautiful island."),
    ("lago", "noun (masc.)", "lake", "El lago está tranquilo.", "The lake is calm."),
    ("océano", "noun (masc.)", "ocean", "El océano es enorme.", "The ocean is huge."),
    ("bosque", "noun (masc.)", "forest", "Caminamos por el bosque.", "We walked through the forest."),
    ("desierto", "noun (masc.)", "desert", "El desierto es muy seco.", "The desert is very dry."),

    # Health / medical
    ("salud", "noun (fem.)", "health", "La salud es lo más importante.", "Health is the most important thing."),
    ("dolor", "noun (masc.)", "pain", "Tengo un dolor de cabeza.", "I have a headache."),
    ("fiebre", "noun (fem.)", "fever", "El niño tiene fiebre.", "The child has a fever."),
    ("gripe", "noun (fem.)", "flu", "Tengo gripe esta semana.", "I have the flu this week."),
    ("medicina", "noun (fem.)", "medicine", "Tomo medicina para el dolor.", "I take medicine for the pain."),
    ("farmacia", "noun (fem.)", "pharmacy", "Voy a la farmacia.", "I'm going to the pharmacy."),
    ("dentista", "noun (masc./fem.)", "dentist", "Voy al dentista cada seis meses.", "I go to the dentist every six months."),
    ("herida", "noun (fem.)", "wound, injury", "La herida ya está mejor.", "The wound is better now."),

    # Shopping / money
    ("precio", "noun (masc.)", "price", "El precio es razonable.", "The price is reasonable."),
    ("descuento", "noun (masc.)", "discount", "Hay un descuento del veinte por ciento.", "There's a twenty percent discount."),
    ("oferta", "noun (fem.)", "offer, sale", "Hay una oferta en la tienda.", "There's a sale at the store."),
    ("recibo", "noun (masc.)", "receipt", "Guarda el recibo, por favor.", "Keep the receipt, please."),
    ("tarjeta", "noun (fem.)", "card", "Pago con tarjeta.", "I'll pay with a card."),
    ("efectivo", "noun (masc.)", "cash", "Solo aceptan efectivo.", "They only accept cash."),
    ("cambio", "noun (masc.)", "change (money)", "Necesito cambio para el bus.", "I need change for the bus."),
    ("cuenta", "noun (fem.)", "bill; account", "La cuenta, por favor.", "The bill, please."),

    # Sports & hobbies
    ("deporte", "noun (masc.)", "sport", "Hago deporte todos los días.", "I do sports every day."),
    ("fútbol", "noun (masc.)", "soccer, football", "Me gusta el fútbol.", "I like soccer."),
    ("baloncesto", "noun (masc.)", "basketball", "Juego al baloncesto los sábados.", "I play basketball on Saturdays."),
    ("tenis", "noun (masc.)", "tennis", "Tomo clases de tenis.", "I take tennis lessons."),
    ("natación", "noun (fem.)", "swimming", "La natación es buen ejercicio.", "Swimming is good exercise."),
    ("gimnasio", "noun (masc.)", "gym", "Voy al gimnasio tres veces por semana.", "I go to the gym three times a week."),
    ("equipo", "noun (masc.)", "team", "Mi equipo ganó el partido.", "My team won the match."),
    ("partido", "noun (masc.)", "match, game", "El partido empieza a las ocho.", "The match starts at eight."),

    # Entertainment
    ("teatro", "noun (masc.)", "theater", "Fuimos al teatro anoche.", "We went to the theater last night."),
    ("concierto", "noun (masc.)", "concert", "El concierto fue increíble.", "The concert was incredible."),
    ("museo", "noun (masc.)", "museum", "Visitamos el museo el domingo.", "We visited the museum on Sunday."),
    ("juego", "noun (masc.)", "game", "Es un juego divertido.", "It's a fun game."),
    ("libro", "noun (masc.)", "book (duplicate; kept earlier)", "Leo un libro nuevo.", "I'm reading a new book."),
    ("vacaciones", "noun (fem. pl.)", "vacation, holidays", "Me voy de vacaciones.", "I'm going on vacation."),
    ("regalo", "noun (masc.)", "gift", "Te traigo un regalo.", "I'm bringing you a gift."),

    # More personality / opinion adjectives
    ("amable", "adjective", "kind", "Eres muy amable.", "You're very kind."),
    ("simpático", "adjective", "nice, friendly", "Tu hermano es simpático.", "Your brother is nice."),
    ("antipático", "adjective", "unfriendly, unpleasant", "El vendedor es antipático.", "The salesperson is unpleasant."),
    ("generoso", "adjective", "generous", "Es una persona generosa.", "She's a generous person."),
    ("egoísta", "adjective", "selfish", "No seas egoísta.", "Don't be selfish."),
    ("paciente", "adjective", "patient", "El profesor es muy paciente.", "The teacher is very patient."),
    ("impaciente", "adjective", "impatient", "Soy un poco impaciente.", "I'm a bit impatient."),
    ("valiente", "adjective", "brave", "Es muy valiente.", "He's very brave."),
    ("tímido", "adjective", "shy", "Mi hija es tímida.", "My daughter is shy."),
    ("divertido", "adjective", "fun, funny", "La fiesta fue muy divertida.", "The party was very fun."),
    ("aburrido", "adjective", "boring", "Esta película es aburrida.", "This movie is boring."),
    ("interesante", "adjective", "interesting", "El libro es muy interesante.", "The book is very interesting."),
    ("inteligente", "adjective", "intelligent", "Es un niño inteligente.", "He's an intelligent child."),
    ("tonto", "adjective", "silly, dumb", "No seas tonto.", "Don't be silly."),
    ("loco", "adjective", "crazy", "¡Estás loco!", "You're crazy!"),
    ("tranquilo", "adjective", "calm, quiet", "Estaba muy tranquilo en el lago.", "It was very calm at the lake."),
    ("nervioso", "adjective", "nervous", "Estoy nervioso antes del examen.", "I'm nervous before the exam."),

    # Quality adjectives
    ("barato", "adjective", "cheap", "Este restaurante es barato.", "This restaurant is cheap."),
    ("caro", "adjective", "expensive", "Ese coche es muy caro.", "That car is very expensive."),
    ("gratis", "adjective/adverb", "free (of charge)", "La entrada es gratis.", "Admission is free."),
    ("peligroso", "adjective", "dangerous", "Este barrio es peligroso.", "This neighborhood is dangerous."),
    ("seguro", "adjective", "safe; sure", "Estás seguro aquí.", "You're safe here."),
    ("útil", "adjective", "useful", "Este libro es muy útil.", "This book is very useful."),
    ("inútil", "adjective", "useless", "Es inútil discutir.", "It's useless to argue."),
    ("verdadero", "adjective", "true, real", "Esta es una historia verdadera.", "This is a true story."),
    ("falso", "adjective", "false, fake", "Es una noticia falsa.", "It's fake news."),
    ("famoso", "adjective", "famous", "Es un actor famoso.", "He's a famous actor."),
    ("popular", "adjective", "popular", "Este restaurante es popular.", "This restaurant is popular."),
    ("delicioso", "adjective", "delicious", "La comida está deliciosa.", "The food is delicious."),

    # More common nouns
    ("error", "noun (masc.)", "mistake, error", "Cometí un error.", "I made a mistake."),
    ("ejemplo", "noun (masc.)", "example", "Te doy un ejemplo.", "I'll give you an example."),
    ("forma", "noun (fem.)", "form, shape, way", "Hay otra forma de hacerlo.", "There's another way to do it."),
    ("manera", "noun (fem.)", "way, manner", "De ninguna manera.", "No way."),
    ("razón", "noun (fem.)", "reason; right", "Tienes razón.", "You're right."),
    ("opinión", "noun (fem.)", "opinion", "En mi opinión, es bueno.", "In my opinion, it's good."),
    ("decisión", "noun (fem.)", "decision", "Tomé una decisión.", "I made a decision."),
    ("plan", "noun (masc.)", "plan", "¿Cuál es tu plan?", "What's your plan?"),
    ("sueño", "noun (masc.)", "dream; sleep", "Tengo un sueño.", "I have a dream."),
    ("miedo", "noun (masc.)", "fear", "Tengo miedo de los perros.", "I'm afraid of dogs."),
    ("suerte", "noun (fem.)", "luck", "¡Buena suerte!", "Good luck!"),
    ("ayuda", "noun (fem.)", "help", "Necesito tu ayuda.", "I need your help."),
    ("noticia", "noun (fem.)", "news", "Tengo una buena noticia.", "I have good news."),
    ("regla", "noun (fem.)", "rule", "Hay que seguir las reglas.", "You have to follow the rules."),
    ("información", "noun (fem.)", "information", "Necesito más información.", "I need more information."),
    ("trabajo", "noun (masc.)", "job, work (duplicate)", "Es mi nuevo trabajo.", "It's my new job."),
    ("razón", "noun (fem.)", "reason (duplicate)", "No hay razón para llorar.", "There's no reason to cry."),

    # Useful phrases / connectors
    ("buenos días", "phrase", "good morning", "Buenos días, ¿cómo está?", "Good morning, how are you?"),
    ("buenas tardes", "phrase", "good afternoon", "Buenas tardes, profesor.", "Good afternoon, professor."),
    ("buenas noches", "phrase", "good evening, good night", "Buenas noches, que duermas bien.", "Good night, sleep well."),
    ("hasta luego", "phrase", "see you later", "Hasta luego, amigo.", "See you later, friend."),
    ("hasta mañana", "phrase", "see you tomorrow", "Hasta mañana en clase.", "See you tomorrow in class."),
    ("mucho gusto", "phrase", "nice to meet you", "Mucho gusto en conocerte.", "Nice to meet you."),
    ("de nada", "phrase", "you're welcome", "—Gracias. —De nada.", "—Thanks. —You're welcome."),
    ("por supuesto", "phrase", "of course", "Por supuesto que sí.", "Of course."),
    ("claro", "adverb", "of course; clearly", "Claro, te entiendo.", "Of course, I understand."),
    ("tal vez", "phrase", "maybe", "Tal vez vaya a la fiesta.", "Maybe I'll go to the party."),
    ("quizás", "adverb", "perhaps, maybe", "Quizás mañana.", "Perhaps tomorrow."),
    ("sin", "preposition", "without", "Café sin azúcar, por favor.", "Coffee without sugar, please."),
    ("según", "preposition", "according to", "Según mi madre, es verdad.", "According to my mother, it's true."),
]


# Decks group words into themed study sets. Every word in ENTRIES is
# implicitly part of "common" (the frequency list). Topic decks below can
# either tag existing ENTRIES lemmas with an extra deck membership, or add
# brand-new words that don't appear in ENTRIES.
# Visible deck taxonomy — re-exported from vocab_pipeline so the Spanish
# standalone builder stays in sync with the shared FR/IT/DE pipeline.
DECKS = DEFAULT_DECKS

# Each topic deck lists:
#   - lemmas: existing ENTRIES words to tag with this deck
#   - new_entries: extra words (not in ENTRIES) to add with only this deck
TOPIC_DECKS = {
    "travel": {
        "lemmas": [
            "viajar", "viaje", "llegar", "salir", "ciudad", "país", "aeropuerto",
            "estación", "playa", "montaña", "tren", "avión", "billete", "maleta",
            "pasaporte", "calle", "camino", "lejos", "cerca", "vacaciones",
            "autobús", "metro", "taxi", "coche", "bicicleta", "barco",
        ],
        "new_entries": [
            ("hotel", "noun (masc.)", "hotel", "Reservé un hotel cerca del centro.", "I booked a hotel near downtown."),
            ("vuelo", "noun (masc.)", "flight", "Mi vuelo sale a las nueve.", "My flight leaves at nine."),
            ("equipaje", "noun (masc.)", "luggage", "Perdí mi equipaje.", "I lost my luggage."),
            ("reserva", "noun (fem.)", "reservation, booking", "Tengo una reserva a las ocho.", "I have a reservation at eight."),
            ("turista", "noun", "tourist", "Hay muchos turistas en agosto.", "There are many tourists in August."),
            ("aduana", "noun (fem.)", "customs", "Pasé por la aduana sin problemas.", "I went through customs without trouble."),
            ("embarque", "noun (masc.)", "boarding", "La puerta de embarque es la 12.", "The boarding gate is 12."),
            ("alojamiento", "noun (masc.)", "accommodation", "Buscamos alojamiento barato.", "We're looking for cheap accommodation."),
            ("itinerario", "noun (masc.)", "itinerary", "Te envío el itinerario.", "I'll send you the itinerary."),
            ("frontera", "noun (fem.)", "border", "Cruzamos la frontera al mediodía.", "We crossed the border at noon."),
            ("mapa", "noun (masc.)", "map", "Necesito un mapa de la ciudad.", "I need a map of the city."),
            ("carretera", "noun (fem.)", "road, highway", "La carretera está cerrada.", "The road is closed."),
            ("puente", "noun (masc.)", "bridge", "Cruzamos el puente al atardecer.", "We crossed the bridge at sunset."),
            ("puerto", "noun (masc.)", "port, harbour", "El barco llega al puerto mañana.", "The boat arrives at the port tomorrow."),
            ("parada", "noun (fem.)", "stop (bus, etc.)", "La próxima parada es la mía.", "The next stop is mine."),
            ("salida", "noun (fem.)", "exit; departure", "La salida está por allí.", "The exit is over there."),
            ("entrada", "noun (fem.)", "entrance; ticket", "Compré dos entradas para el museo.", "I bought two tickets for the museum."),
            ("destino", "noun (masc.)", "destination", "Mi destino final es Buenos Aires.", "My final destination is Buenos Aires."),
            ("visita", "noun (fem.)", "visit", "La visita guiada empieza a las diez.", "The guided tour starts at ten."),
            ("excursión", "noun (fem.)", "excursion, day trip", "Hicimos una excursión al lago.", "We took a day trip to the lake."),
            ("recuerdo", "noun (masc.)", "souvenir", "Compré un recuerdo en el aeropuerto.", "I bought a souvenir at the airport."),
            ("guía", "noun", "guide", "El guía nos explicó la historia.", "The guide explained the history to us."),
            ("retraso", "noun (masc.)", "delay", "Hubo un retraso de dos horas.", "There was a two-hour delay."),
            ("estancia", "noun (fem.)", "stay", "Espero que disfruten su estancia.", "I hope you enjoy your stay."),
            ("brújula", "noun (fem.)", "compass", "La brújula apunta al norte.", "The compass points north."),
            ("mochila", "noun (fem.)", "backpack", "Llevo lo esencial en mi mochila.", "I carry the essentials in my backpack."),
        ],
    },
    "food": {
        "lemmas": [
            "comer", "beber", "cocinar", "café", "agua", "pan", "carne", "fruta",
            "verdura", "queso", "leche", "vino", "cerveza", "azúcar", "sal",
            "desayuno", "almuerzo", "cena", "restaurante", "cuenta",
            "pescado", "huevo", "manzana", "naranja",
        ],
        "new_entries": [
            ("camarero", "noun (masc.)", "waiter", "El camarero trajo la cuenta.", "The waiter brought the bill."),
            ("propina", "noun (fem.)", "tip", "Dejé una buena propina.", "I left a good tip."),
            ("plato", "noun (masc.)", "plate, dish", "Probé un plato típico.", "I tried a traditional dish."),
            ("postre", "noun (masc.)", "dessert", "¿Quieres postre?", "Would you like dessert?"),
            ("receta", "noun (fem.)", "recipe", "Mi abuela me dio la receta.", "My grandmother gave me the recipe."),
            ("sabroso", "adjective", "tasty", "La sopa estaba muy sabrosa.", "The soup was very tasty."),
            ("picante", "adjective", "spicy", "No me gusta la comida picante.", "I don't like spicy food."),
            ("menú", "noun (masc.)", "menu", "¿Me trae el menú, por favor?", "Could you bring me the menu, please?"),
            ("arroz", "noun (masc.)", "rice", "Comemos arroz con frecuencia.", "We eat rice often."),
            ("pollo", "noun (masc.)", "chicken", "Pedí pollo asado.", "I ordered roast chicken."),
            ("tomate", "noun (masc.)", "tomato", "La ensalada lleva tomate.", "The salad has tomato in it."),
            ("cebolla", "noun (fem.)", "onion", "La cebolla me hace llorar.", "Onion makes me cry."),
            ("ajo", "noun (masc.)", "garlic", "Añade un poco de ajo.", "Add a bit of garlic."),
            ("aceite", "noun (masc.)", "oil", "Usamos aceite de oliva.", "We use olive oil."),
            ("mantequilla", "noun (fem.)", "butter", "Untó pan con mantequilla.", "He spread butter on the bread."),
            ("galleta", "noun (fem.)", "biscuit, cookie", "¿Quieres una galleta?", "Want a cookie?"),
            ("chocolate", "noun (masc.)", "chocolate", "Me encanta el chocolate negro.", "I love dark chocolate."),
            ("pastel", "noun (masc.)", "cake, pastry", "Compré un pastel de cumpleaños.", "I bought a birthday cake."),
            ("sopa", "noun (fem.)", "soup", "La sopa está caliente.", "The soup is hot."),
            ("ensalada", "noun (fem.)", "salad", "Pediré la ensalada mixta.", "I'll have the mixed salad."),
            ("bocadillo", "noun (masc.)", "sandwich (Spain)", "Me hice un bocadillo de queso.", "I made myself a cheese sandwich."),
            ("hambre", "noun (fem.)", "hunger", "Tengo mucha hambre.", "I'm very hungry."),
            ("sed", "noun (fem.)", "thirst", "Tengo sed.", "I'm thirsty."),
            ("plátano", "noun (masc.)", "banana", "Como un plátano al día.", "I eat a banana a day."),
            ("zumo", "noun (masc.)", "juice", "Pidió un zumo de naranja.", "She ordered an orange juice."),
            ("cuchara", "noun (fem.)", "spoon", "Necesito otra cuchara.", "I need another spoon."),
            ("tenedor", "noun (masc.)", "fork", "El tenedor está sucio.", "The fork is dirty."),
            ("cuchillo", "noun (masc.)", "knife", "Pásame el cuchillo, por favor.", "Pass me the knife, please."),
            ("vaso", "noun (masc.)", "glass (drinking)", "Un vaso de agua, por favor.", "A glass of water, please."),
            ("taza", "noun (fem.)", "cup, mug", "Bebo el café en mi taza favorita.", "I drink coffee in my favorite mug."),
        ],
    },
    "work": {
        "lemmas": [
            "trabajar", "trabajo", "oficina", "jefe",
            "correo", "teléfono", "ordenador",
        ],
        "new_entries": [
            ("colega", "noun", "colleague", "Mi colega me ayudó con el informe.", "My colleague helped me with the report."),
            ("informe", "noun (masc.)", "report", "Entrego el informe el viernes.", "I'll hand in the report on Friday."),
            ("plazo", "noun (masc.)", "deadline", "El plazo es la próxima semana.", "The deadline is next week."),
            ("contrato", "noun (masc.)", "contract", "Firmé el contrato esta mañana.", "I signed the contract this morning."),
            ("entrevista", "noun (fem.)", "interview", "Tengo una entrevista el martes.", "I have an interview on Tuesday."),
            ("currículum", "noun (masc.)", "CV, résumé", "Actualicé mi currículum.", "I updated my CV."),
            ("ascenso", "noun (masc.)", "promotion", "Espero un ascenso este año.", "I'm hoping for a promotion this year."),
            ("empresa", "noun (fem.)", "company, firm", "Trabajo en una empresa pequeña.", "I work at a small company."),
            ("reunión", "noun (fem.)", "meeting", "La reunión es a las diez.", "The meeting is at ten."),
            ("proyecto", "noun (masc.)", "project", "Terminé el proyecto a tiempo.", "I finished the project on time."),
            ("horario", "noun (masc.)", "schedule, hours", "Mi horario es flexible.", "My schedule is flexible."),
            ("salario", "noun (masc.)", "salary", "Negocié un mejor salario.", "I negotiated a better salary."),
            ("cliente", "noun", "client, customer", "Atiendo al cliente en español.", "I serve the client in Spanish."),
            ("gerente", "noun", "manager", "El gerente está en una reunión.", "The manager is in a meeting."),
            ("director", "noun (masc.)", "director", "El director llega a las nueve.", "The director arrives at nine."),
            ("presidente", "noun", "president", "La presidente dio un discurso.", "The president gave a speech."),
            ("empleado", "noun (masc.)", "employee", "Somos cien empleados.", "We are a hundred employees."),
            ("escritorio", "noun (masc.)", "desk", "Dejé las llaves en el escritorio.", "I left the keys on the desk."),
            ("portátil", "noun (masc.)", "laptop", "Olvidé mi portátil en casa.", "I forgot my laptop at home."),
            ("llamada", "noun (fem.)", "call", "Tengo una llamada importante.", "I have an important call."),
            ("documento", "noun (masc.)", "document", "Firma el documento, por favor.", "Sign the document, please."),
            ("factura", "noun (fem.)", "invoice", "Pagué la factura ayer.", "I paid the invoice yesterday."),
            ("presupuesto", "noun (masc.)", "budget", "El presupuesto es limitado.", "The budget is limited."),
            ("venta", "noun (fem.)", "sale", "Cerramos la venta esta tarde.", "We're closing the sale this afternoon."),
            ("equipo", "noun (masc.)", "team", "Trabajo bien en equipo.", "I work well in a team."),
            ("tarea", "noun (fem.)", "task", "Tengo varias tareas pendientes.", "I have several pending tasks."),
            ("reunir", "verb", "to gather, meet up", "Nos reunimos cada lunes.", "We meet every Monday."),
            ("despedir", "verb", "to fire; to see off", "Lo despidieron sin avisar.", "They fired him without notice."),
            ("contratar", "verb", "to hire", "Vamos a contratar a tres personas.", "We're going to hire three people."),
            ("ascender", "verb", "to be promoted; to rise", "La ascendieron a directora.", "She was promoted to director."),
        ],
    },
    "family": {
        "lemmas": [
            "madre", "padre", "hijo", "hija", "hermano", "hermana", "abuelo",
            "abuela", "amigo", "amiga", "familia", "niño", "niña", "hombre",
            "mujer", "persona", "gente",
        ],
        "new_entries": [
            ("tío", "noun (masc.)", "uncle", "Mi tío vive en Madrid.", "My uncle lives in Madrid."),
            ("tía", "noun (fem.)", "aunt", "Mi tía es enfermera.", "My aunt is a nurse."),
            ("primo", "noun (masc.)", "cousin (m.)", "Mi primo tiene mi edad.", "My cousin is my age."),
            ("prima", "noun (fem.)", "cousin (f.)", "Mi prima estudia derecho.", "My cousin is studying law."),
            ("esposo", "noun (masc.)", "husband", "Mi esposo cocina los domingos.", "My husband cooks on Sundays."),
            ("esposa", "noun (fem.)", "wife", "Mi esposa trabaja desde casa.", "My wife works from home."),
            ("novio", "noun (masc.)", "boyfriend; groom", "Conocí a su novio anoche.", "I met her boyfriend last night."),
            ("novia", "noun (fem.)", "girlfriend; bride", "Su novia es muy simpática.", "His girlfriend is very nice."),
            ("bebé", "noun", "baby", "El bebé duerme toda la noche.", "The baby sleeps all night."),
            ("vecino", "noun (masc.)", "neighbour", "Mi vecino es muy amable.", "My neighbour is very kind."),
            ("chico", "noun (masc.)", "boy, guy", "Aquel chico es mi hermano.", "That guy is my brother."),
            ("chica", "noun (fem.)", "girl", "La chica del café me saludó.", "The girl from the café greeted me."),
            ("sobrino", "noun (masc.)", "nephew", "Mi sobrino cumple ocho años.", "My nephew is turning eight."),
            ("sobrina", "noun (fem.)", "niece", "Mi sobrina toca el piano.", "My niece plays the piano."),
            ("suegro", "noun (masc.)", "father-in-law", "Mi suegro es jubilado.", "My father-in-law is retired."),
            ("suegra", "noun (fem.)", "mother-in-law", "Cenamos con mi suegra.", "We're having dinner with my mother-in-law."),
            ("pareja", "noun (fem.)", "partner; couple", "Mi pareja y yo vivimos juntos.", "My partner and I live together."),
            ("amistad", "noun (fem.)", "friendship", "Nuestra amistad es muy fuerte.", "Our friendship is very strong."),
            ("ahijado", "noun (masc.)", "godchild", "Soy padrino de mi ahijado.", "I'm my godchild's godfather."),
            ("padrino", "noun (masc.)", "godfather", "Mi padrino me regaló un libro.", "My godfather gave me a book."),
            ("madrina", "noun (fem.)", "godmother", "Mi madrina vive en el campo.", "My godmother lives in the countryside."),
            ("gemelo", "noun (masc.)", "twin", "Mi hermano es mi gemelo.", "My brother is my twin."),
            ("adulto", "noun (masc.)", "adult", "Solo adultos pueden entrar.", "Only adults may enter."),
            ("adolescente", "noun", "teenager", "Mi hijo ya es adolescente.", "My son is a teenager now."),
            ("anciano", "noun (masc.)", "elderly person", "Ayudé a un anciano a cruzar.", "I helped an elderly man cross."),
        ],
    },
    "home": {
        "lemmas": [
            "casa", "puerta", "ventana", "mesa", "silla", "cama", "cocina",
            "baño", "llave", "luz",
        ],
        "new_entries": [
            ("dormitorio", "noun (masc.)", "bedroom", "Mi dormitorio es pequeño pero acogedor.", "My bedroom is small but cozy."),
            ("salón", "noun (masc.)", "living room", "Vemos la tele en el salón.", "We watch TV in the living room."),
            ("sala", "noun (fem.)", "room; living room", "La sala está vacía.", "The room is empty."),
            ("pared", "noun (fem.)", "wall", "Colgué un cuadro en la pared.", "I hung a picture on the wall."),
            ("techo", "noun (masc.)", "ceiling, roof", "El techo es muy alto.", "The ceiling is very high."),
            ("suelo", "noun (masc.)", "floor", "El suelo es de madera.", "The floor is wooden."),
            ("escalera", "noun (fem.)", "stairs; ladder", "Subimos por la escalera.", "We went up the stairs."),
            ("jardín", "noun (masc.)", "garden", "El jardín está lleno de flores.", "The garden is full of flowers."),
            ("garaje", "noun (masc.)", "garage", "El coche está en el garaje.", "The car is in the garage."),
            ("lámpara", "noun (fem.)", "lamp", "Enciende la lámpara, por favor.", "Turn on the lamp, please."),
            ("espejo", "noun (masc.)", "mirror", "El espejo está sucio.", "The mirror is dirty."),
            ("cortina", "noun (fem.)", "curtain", "Cierra las cortinas.", "Close the curtains."),
            ("cuadro", "noun (masc.)", "painting, picture", "Compramos un cuadro en el mercado.", "We bought a painting at the market."),
            ("armario", "noun (masc.)", "wardrobe, cupboard", "Guarda la ropa en el armario.", "Put the clothes in the wardrobe."),
            ("sofá", "noun (masc.)", "sofa, couch", "Me dormí en el sofá.", "I fell asleep on the couch."),
            ("televisión", "noun (fem.)", "television", "Apaga la televisión, por favor.", "Turn off the TV, please."),
            ("piso", "noun (masc.)", "flat, apartment; floor", "Vivo en un piso compartido.", "I live in a shared flat."),
            ("apartamento", "noun (masc.)", "apartment", "Alquilamos un apartamento pequeño.", "We rented a small apartment."),
            ("alfombra", "noun (fem.)", "rug, carpet", "La alfombra es muy suave.", "The rug is very soft."),
            ("almohada", "noun (fem.)", "pillow", "Esta almohada es muy dura.", "This pillow is too firm."),
            ("manta", "noun (fem.)", "blanket", "Hace frío, pásame la manta.", "It's cold, hand me the blanket."),
            ("nevera", "noun (fem.)", "fridge", "La nevera está casi vacía.", "The fridge is almost empty."),
            ("lavavajillas", "noun (masc.)", "dishwasher", "Mete los platos al lavavajillas.", "Put the plates in the dishwasher."),
            ("ducha", "noun (fem.)", "shower", "Voy a darme una ducha.", "I'm going to take a shower."),
            ("balcón", "noun (masc.)", "balcony", "Tomamos café en el balcón.", "We had coffee on the balcony."),
            ("timbre", "noun (masc.)", "doorbell", "Sonó el timbre dos veces.", "The doorbell rang twice."),
            ("vecindario", "noun (masc.)", "neighbourhood", "Mi vecindario es tranquilo.", "My neighbourhood is quiet."),
        ],
    },
    "body_health": {
        "lemmas": [
            "cabeza", "cara", "ojo", "nariz", "boca", "oreja", "mano", "pie",
            "pierna", "brazo", "corazón", "pelo", "médico", "hospital",
            "enfermo", "dolor", "medicina", "farmacia", "salud",
        ],
        "new_entries": [
            ("diente", "noun (masc.)", "tooth", "Me duele un diente.", "I have a toothache."),
            ("dedo", "noun (masc.)", "finger; toe", "Me corté el dedo.", "I cut my finger."),
            ("espalda", "noun (fem.)", "back (body)", "Me duele la espalda.", "My back hurts."),
            ("estómago", "noun (masc.)", "stomach", "Tengo dolor de estómago.", "I have a stomachache."),
            ("sangre", "noun (fem.)", "blood", "Me sale sangre del dedo.", "My finger is bleeding."),
            ("piel", "noun (fem.)", "skin", "Tiene la piel muy clara.", "She has very fair skin."),
            ("cuerpo", "noun (masc.)", "body", "El cuerpo humano es complejo.", "The human body is complex."),
            ("hueso", "noun (masc.)", "bone", "Se rompió un hueso al caer.", "He broke a bone when he fell."),
            ("rodilla", "noun (fem.)", "knee", "Me lastimé la rodilla corriendo.", "I hurt my knee running."),
            ("codo", "noun (masc.)", "elbow", "Apoyó el codo en la mesa.", "He rested his elbow on the table."),
            ("hombro", "noun (masc.)", "shoulder", "Me duele el hombro derecho.", "My right shoulder hurts."),
            ("cuello", "noun (masc.)", "neck", "Tengo el cuello tieso.", "My neck is stiff."),
            ("garganta", "noun (fem.)", "throat", "Me duele la garganta.", "My throat hurts."),
            ("pulmón", "noun (masc.)", "lung", "El humo daña los pulmones.", "Smoke damages the lungs."),
            ("cerebro", "noun (masc.)", "brain", "El cerebro nunca descansa.", "The brain never rests."),
            ("enfermedad", "noun (fem.)", "illness", "Es una enfermedad común.", "It's a common illness."),
            ("síntoma", "noun (masc.)", "symptom", "Tengo varios síntomas raros.", "I have several strange symptoms."),
            ("fiebre", "noun (fem.)", "fever", "Tengo fiebre desde anoche.", "I've had a fever since last night."),
            ("tos", "noun (fem.)", "cough", "Tengo una tos muy fuerte.", "I have a really bad cough."),
            ("resfriado", "noun (masc.)", "cold (illness)", "Estoy con un resfriado.", "I have a cold."),
            ("receta", "noun (fem.)", "prescription", "El médico me dio una receta.", "The doctor gave me a prescription."),
            ("pastilla", "noun (fem.)", "pill, tablet", "Tomo una pastilla por la mañana.", "I take a pill in the morning."),
            ("cita", "noun (fem.)", "appointment", "Tengo cita con el dentista.", "I have a dentist appointment."),
            ("ambulancia", "noun (fem.)", "ambulance", "Llamaron a una ambulancia.", "They called an ambulance."),
            ("vacuna", "noun (fem.)", "vaccine", "Me puse la vacuna ayer.", "I got the vaccine yesterday."),
            ("herido", "adjective", "injured", "Hay dos personas heridas.", "There are two people injured."),
        ],
    },
    "time_numbers": {
        "lemmas": [
            "día", "semana", "mes", "año", "hora", "minuto", "mañana", "tarde",
            "noche", "hoy", "ayer", "siempre", "nunca", "temprano",
            "lunes", "martes", "miércoles", "jueves", "viernes", "sábado",
            "domingo", "enero", "febrero", "marzo", "abril", "mayo", "junio",
            "julio", "agosto", "uno", "dos", "tres", "cuatro", "cinco", "seis",
            "siete", "ocho", "nueve", "diez", "veinte", "cien", "mil",
        ],
        "new_entries": [
            ("segundo", "noun (masc.)", "second (time)", "Espera un segundo.", "Wait a second."),
            ("septiembre", "noun (masc.)", "September", "En septiembre empieza el curso.", "School starts in September."),
            ("octubre", "noun (masc.)", "October", "En octubre llegan las lluvias.", "The rains arrive in October."),
            ("noviembre", "noun (masc.)", "November", "Noviembre suele ser frío.", "November tends to be cold."),
            ("diciembre", "noun (masc.)", "December", "En diciembre celebramos las fiestas.", "We celebrate the holidays in December."),
            ("once", "number", "eleven", "Tengo once años.", "I'm eleven years old."),
            ("doce", "number", "twelve", "La reunión es a las doce.", "The meeting is at twelve."),
            ("trece", "number", "thirteen", "Hay trece personas en la sala.", "There are thirteen people in the room."),
            ("catorce", "number", "fourteen", "Mi sobrina tiene catorce años.", "My niece is fourteen."),
            ("quince", "number", "fifteen", "Llegó hace quince minutos.", "He arrived fifteen minutes ago."),
            ("treinta", "number", "thirty", "Tengo treinta años.", "I'm thirty years old."),
            ("cuarenta", "number", "forty", "Hay cuarenta personas inscritas.", "There are forty people signed up."),
            ("cincuenta", "number", "fifty", "El billete cuesta cincuenta euros.", "The ticket costs fifty euros."),
            ("primero", "ordinal", "first", "Soy el primero de la fila.", "I'm first in line."),
            ("último", "adjective", "last", "Este es el último capítulo.", "This is the last chapter."),
            ("antes", "adverb", "before", "Llámame antes de salir.", "Call me before you leave."),
            ("después", "adverb", "after, afterwards", "Te veo después de la clase.", "I'll see you after class."),
            ("luego", "adverb", "later; then", "Hablamos luego.", "We'll talk later."),
            ("pronto", "adverb", "soon; early", "Te respondo pronto.", "I'll reply soon."),
            ("tarde", "adverb", "late", "Llegué tarde a la reunión.", "I arrived late to the meeting."),
            ("siglo", "noun (masc.)", "century", "Vivimos en el siglo veintiuno.", "We live in the twenty-first century."),
            ("medianoche", "noun (fem.)", "midnight", "Llegamos a medianoche.", "We arrived at midnight."),
            ("mediodía", "noun (masc.)", "noon, midday", "Comemos al mediodía.", "We eat at noon."),
            ("amanecer", "noun (masc.)", "dawn, sunrise", "Salimos al amanecer.", "We left at sunrise."),
            ("anochecer", "noun (masc.)", "dusk, nightfall", "Volvimos al anochecer.", "We came back at nightfall."),
            ("hace", "phrase", "ago (time)", "Llegué hace una hora.", "I arrived an hour ago."),
            ("dentro", "phrase", "in (time); inside", "Vuelvo dentro de un momento.", "I'll be back in a moment."),
        ],
    },
    "money_shopping": {
        "lemmas": [
            "dinero", "precio", "caro", "barato", "comprar", "vender", "pagar",
            "tienda", "mercado", "billete", "tarjeta", "cambio", "cuenta",
        ],
        "new_entries": [
            ("banco", "noun (masc.)", "bank", "Voy al banco esta mañana.", "I'm going to the bank this morning."),
            ("moneda", "noun (fem.)", "coin; currency", "Cambié unas monedas en el aeropuerto.", "I exchanged some coins at the airport."),
            ("efectivo", "noun (masc.)", "cash", "Prefiero pagar en efectivo.", "I prefer to pay in cash."),
            ("descuento", "noun (masc.)", "discount", "Me hicieron un descuento del diez por ciento.", "They gave me a ten percent discount."),
            ("oferta", "noun (fem.)", "offer, deal", "Aprovecha la oferta de hoy.", "Take advantage of today's offer."),
            ("rebaja", "noun (fem.)", "sale (price reduction)", "Las rebajas empiezan mañana.", "The sales start tomorrow."),
            ("recibo", "noun (masc.)", "receipt", "Guarda el recibo, por favor.", "Keep the receipt, please."),
            ("ahorrar", "verb", "to save (money)", "Estoy ahorrando para un viaje.", "I'm saving up for a trip."),
            ("gastar", "verb", "to spend", "Gasté demasiado este mes.", "I spent too much this month."),
            ("deuda", "noun (fem.)", "debt", "No tengo deudas.", "I have no debts."),
            ("hipoteca", "noun (fem.)", "mortgage", "La hipoteca es una carga.", "The mortgage is a burden."),
            ("alquiler", "noun (masc.)", "rent", "El alquiler sube cada año.", "The rent goes up every year."),
            ("propietario", "noun (masc.)", "owner, landlord", "El propietario vive arriba.", "The landlord lives upstairs."),
            ("regalo", "noun (masc.)", "gift", "Le compré un regalo a mi madre.", "I bought my mother a gift."),
            ("supermercado", "noun (masc.)", "supermarket", "El supermercado cierra a las diez.", "The supermarket closes at ten."),
            ("escaparate", "noun (masc.)", "shop window", "Vi un vestido en el escaparate.", "I saw a dress in the shop window."),
            ("cajero", "noun (masc.)", "cashier; ATM", "El cajero más cercano está aquí.", "The closest ATM is here."),
            ("probador", "noun (masc.)", "fitting room", "¿Dónde está el probador?", "Where is the fitting room?"),
            ("talla", "noun (fem.)", "size (clothing)", "¿Tienes esta camisa en otra talla?", "Do you have this shirt in another size?"),
            ("gratis", "adjective", "free (no cost)", "El envío es gratis.", "Shipping is free."),
        ],
    },
    "feelings": {
        "lemmas": [
            "amor", "feliz", "triste", "contento", "enojado", "tranquilo",
            "nervioso", "miedo", "sentir", "gustar", "odiar", "amar",
        ],
        "new_entries": [
            ("enfadado", "adjective", "angry (Spain)", "Está enfadado conmigo.", "He's angry at me."),
            ("preocupado", "adjective", "worried", "Estoy preocupado por ti.", "I'm worried about you."),
            ("sorpresa", "noun (fem.)", "surprise", "¡Qué sorpresa verte aquí!", "What a surprise to see you here!"),
            ("alegría", "noun (fem.)", "joy", "Sentí una gran alegría.", "I felt great joy."),
            ("risa", "noun (fem.)", "laughter, a laugh", "Su risa es contagiosa.", "Her laughter is contagious."),
            ("llorar", "verb", "to cry", "No llores, todo está bien.", "Don't cry, everything is fine."),
            ("reír", "verb", "to laugh", "Nos hizo reír toda la noche.", "He made us laugh all night."),
            ("aburrido", "adjective", "bored; boring", "Estoy aburrido en casa.", "I'm bored at home."),
            ("cansado", "adjective", "tired", "Estoy muy cansado hoy.", "I'm very tired today."),
            ("emocionado", "adjective", "excited", "Estoy emocionado por el viaje.", "I'm excited about the trip."),
            ("orgulloso", "adjective", "proud", "Estoy orgulloso de ti.", "I'm proud of you."),
            ("celoso", "adjective", "jealous", "No seas celoso.", "Don't be jealous."),
            ("tímido", "adjective", "shy", "Soy un poco tímido al principio.", "I'm a bit shy at first."),
            ("valiente", "adjective", "brave", "Eres muy valiente.", "You're very brave."),
            ("amable", "adjective", "kind, friendly", "Qué amable eres.", "How kind of you."),
            ("simpático", "adjective", "nice, friendly", "Es muy simpático con todos.", "He's very nice to everyone."),
            ("antipático", "adjective", "unfriendly, unpleasant", "Ese camarero es antipático.", "That waiter is unpleasant."),
            ("estrés", "noun (masc.)", "stress", "Tengo mucho estrés en el trabajo.", "I have a lot of stress at work."),
            ("ansiedad", "noun (fem.)", "anxiety", "La ansiedad no me deja dormir.", "Anxiety doesn't let me sleep."),
            ("vergüenza", "noun (fem.)", "shame, embarrassment", "Me da vergüenza decirlo.", "I'm embarrassed to say it."),
            ("esperanza", "noun (fem.)", "hope", "Nunca pierdo la esperanza.", "I never lose hope."),
            ("confianza", "noun (fem.)", "trust, confidence", "Tengo plena confianza en ti.", "I have full confidence in you."),
            ("sonreír", "verb", "to smile", "Sonríe para la foto.", "Smile for the photo."),
        ],
    },
    "nature_weather": {
        "lemmas": [
            "sol", "luna", "estrella", "cielo", "nube", "lluvia", "viento",
            "nieve", "frío", "calor", "agua", "mar", "río", "lago", "bosque",
            "árbol", "flor", "perro", "gato", "pájaro", "pez", "tierra", "fuego",
        ],
        "new_entries": [
            ("planta", "noun (fem.)", "plant", "Riego las plantas cada mañana.", "I water the plants every morning."),
            ("animal", "noun (masc.)", "animal", "Es un animal muy curioso.", "It's a very curious animal."),
            ("rama", "noun (fem.)", "branch", "El pájaro saltó a otra rama.", "The bird hopped to another branch."),
            ("hoja", "noun (fem.)", "leaf; sheet of paper", "Las hojas caen en otoño.", "The leaves fall in autumn."),
            ("hierba", "noun (fem.)", "grass; herb", "La hierba está mojada.", "The grass is wet."),
            ("piedra", "noun (fem.)", "stone, rock", "Recogí una piedra del río.", "I picked up a stone from the river."),
            ("arena", "noun (fem.)", "sand", "Caminamos por la arena.", "We walked on the sand."),
            ("isla", "noun (fem.)", "island", "Pasamos el verano en una isla.", "We spent the summer on an island."),
            ("desierto", "noun (masc.)", "desert", "El desierto se ve infinito.", "The desert looks endless."),
            ("colina", "noun (fem.)", "hill", "Subimos a la colina al amanecer.", "We climbed the hill at dawn."),
            ("valle", "noun (masc.)", "valley", "El valle está cubierto de niebla.", "The valley is covered in fog."),
            ("niebla", "noun (fem.)", "fog, mist", "Hay mucha niebla esta mañana.", "There's heavy fog this morning."),
            ("tormenta", "noun (fem.)", "storm", "Viene una tormenta fuerte.", "A strong storm is coming."),
            ("trueno", "noun (masc.)", "thunder", "Escuché un trueno a lo lejos.", "I heard thunder in the distance."),
            ("relámpago", "noun (masc.)", "lightning", "Un relámpago iluminó el cielo.", "A flash of lightning lit up the sky."),
            ("arcoíris", "noun (masc.)", "rainbow", "Salió un arcoíris después de la lluvia.", "A rainbow came out after the rain."),
            ("hielo", "noun (masc.)", "ice", "El lago está cubierto de hielo.", "The lake is covered in ice."),
            ("clima", "noun (masc.)", "climate, weather", "El clima de aquí es suave.", "The climate here is mild."),
            ("estación", "noun (fem.)", "season", "Mi estación favorita es el otoño.", "My favorite season is autumn."),
            ("primavera", "noun (fem.)", "spring", "En primavera todo florece.", "In spring everything blooms."),
            ("verano", "noun (masc.)", "summer", "El verano fue muy caluroso.", "The summer was very hot."),
            ("otoño", "noun (masc.)", "autumn, fall", "En otoño llueve mucho.", "It rains a lot in autumn."),
            ("invierno", "noun (masc.)", "winter", "El invierno aquí es duro.", "Winter here is harsh."),
            ("vaca", "noun (fem.)", "cow", "Vimos vacas en el campo.", "We saw cows in the field."),
            ("caballo", "noun (masc.)", "horse", "Aprendí a montar a caballo.", "I learned to ride a horse."),
            ("oveja", "noun (fem.)", "sheep", "Las ovejas pastan en la colina.", "The sheep graze on the hill."),
            ("ratón", "noun (masc.)", "mouse", "Un ratón corrió por la cocina.", "A mouse ran across the kitchen."),
            ("mariposa", "noun (fem.)", "butterfly", "Una mariposa se posó en mi mano.", "A butterfly landed on my hand."),
            ("abeja", "noun (fem.)", "bee", "Una abeja me picó en el brazo.", "A bee stung me on the arm."),
        ],
    },
}


def slugify(text: str, idx: int) -> str:
    return f"es-{idx:04d}"


def cefr_for_rank(rank: int) -> str:
    """Map a frequency rank in the hand-curated ENTRIES list to a CEFR level.

    Bands follow the standard frequency-to-proficiency calibration used in
    Spanish-as-foreign-language pedagogy: top-of-list words are A1 essentials,
    then A2 everyday vocab, then B1+ for the long tail.
    """
    if rank <= 150:
        return "A1"
    if rank <= 350:
        return "A2"
    return "B1"


def main() -> None:
    project_root = Path(__file__).resolve().parent.parent
    output_path = project_root / "lingojam" / "lingojam" / "Resources" / "spanish_top1000.json"
    output_path.parent.mkdir(parents=True, exist_ok=True)

    # Collect all entries with their deck memberships. Main ENTRIES → "common".
    # Topic decks can tag existing lemmas and add new ones.
    word_index: dict[str, dict] = {}
    order: list[str] = []

    def add_entry(lemma, pos, gloss, example_es, example_en, deck, cefr_level=None):
        if lemma in word_index:
            if deck not in word_index[lemma]["decks"]:
                word_index[lemma]["decks"].append(deck)
            # Fill in cefrLevel if it wasn't set on first add (e.g., topic deck
            # tagged it before a generated entry provided the level).
            if cefr_level and not word_index[lemma].get("cefrLevel"):
                word_index[lemma]["cefrLevel"] = cefr_level
            return
        word_index[lemma] = {
            "lemma": lemma,
            "partOfSpeech": pos,
            "gloss": gloss,
            "example_es": example_es,
            "example_en": example_en,
            "decks": [deck],
            "cefrLevel": cefr_level,
        }
        order.append(lemma)

    for rank, (lemma, pos, gloss, example_es, example_en) in enumerate(ENTRIES, start=1):
        add_entry(lemma, pos, gloss, example_es, example_en, "common", cefr_for_rank(rank))

    for deck_slug, deck_data in TOPIC_DECKS.items():
        for lemma in deck_data.get("lemmas", []):
            if lemma in word_index:
                if deck_slug not in word_index[lemma]["decks"]:
                    word_index[lemma]["decks"].append(deck_slug)
            else:
                print(f"Warning: topic '{deck_slug}' references unknown lemma '{lemma}'")
        for lemma, pos, gloss, example_es, example_en in deck_data.get("new_entries", []):
            # Topic-deck new_entries don't have a meaningful frequency rank —
            # leave cefrLevel unset until an LLM backfill pass provides one.
            add_entry(lemma, pos, gloss, example_es, example_en, deck_slug)

    # Merge LLM-generated and curated-batch entries, if any. Files matching
    # generated_entries*.json are read in sorted order; each entry brings its
    # own deck slugs and CEFR level.
    import glob
    tools_dir = Path(__file__).resolve().parent
    generated_paths = sorted(glob.glob(str(tools_dir / "generated_entries*.json")))
    all_generated_entries: list[dict] = []
    for path_str in generated_paths:
        gen_data = json.loads(Path(path_str).read_text(encoding="utf-8"))
        all_generated_entries.extend(gen_data.get("entries", []))
    if all_generated_entries:
        n_added = n_merged = 0
        for entry in all_generated_entries:
            lemma = entry["lemma"]
            explicit_slugs = entry.get("decks")
            if lemma in word_index:
                # Only add deck membership if explicitly specified — a minimal
                # backfill entry like {"lemma": "...", "cefrLevel": "..."} must
                # not silently add "common" to a topic-only word.
                if explicit_slugs:
                    for slug in explicit_slugs:
                        if slug not in word_index[lemma]["decks"]:
                            word_index[lemma]["decks"].append(slug)
                if entry.get("cefrLevel") and not word_index[lemma].get("cefrLevel"):
                    word_index[lemma]["cefrLevel"] = entry["cefrLevel"]
                n_merged += 1
            else:
                word_index[lemma] = {
                    "lemma": lemma,
                    "partOfSpeech": entry["partOfSpeech"],
                    "gloss": entry["gloss"],
                    "example_es": entry["exampleSpanish"],
                    "example_en": entry["exampleEnglish"],
                    "decks": list(explicit_slugs or ["common"]),
                    "cefrLevel": entry.get("cefrLevel"),
                }
                order.append(lemma)
                n_added += 1
        if n_added or n_merged:
            names = ", ".join(Path(p).name for p in generated_paths)
            print(f"Merged {n_added} new + {n_merged} existing entries from {names}")

    valid_slugs = {d["slug"] for d in DECKS} | {"common"}

    words = []
    for rank, lemma in enumerate(order, start=1):
        e = word_index[lemma]
        # Apply legacy remap (travel→traveling, food→food-and-drink, …) and
        # drop slugs that aren't part of the current published taxonomy.
        normalized = normalize_slugs(e["decks"])
        final_slugs = [s for s in normalized if s in valid_slugs]
        if not final_slugs:
            final_slugs = ["common"]
        entry = {
            "id": slugify(lemma, rank),
            "rank": rank,
            "lemma": lemma,
            "partOfSpeech": e["partOfSpeech"],
            "definitions": {"en": e["gloss"]},
            "example": {
                "es": e["example_es"],
                "translations": {"en": e["example_en"]},
            },
            "decks": final_slugs,
        }
        if e.get("cefrLevel"):
            entry["cefrLevel"] = e["cefrLevel"]
        words.append(entry)

    payload = {
        "version": 4,
        "language": "es",
        "decks": DECKS,
        "words": words,
    }

    output_path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Wrote {len(words)} words and {len(DECKS)} decks to {output_path}")


if __name__ == "__main__":
    main()
