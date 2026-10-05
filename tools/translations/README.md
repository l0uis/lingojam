# Parked interface translations

Wordrus ships with an English-only interface and App Store listing for now
(decided 2026-10-05). The Spanish, French, Italian and German translations
were complete and QA'd (every onboarding screen, tab, Settings and the
paywall), so they're kept here instead of deleted.

Each `<lang>.json` holds that language's translations for all three catalogs
(app `Localizable.xcstrings`, widget `Localizable.xcstrings`,
`InfoPlist.xcstrings`) in the format `tools/string_catalog.py import` reads.

## Turning a language back on

1. `python3 tools/string_catalog.py import --lang es tools/translations/es.json`
2. Add the region back to `knownRegions` in `wordrus.xcodeproj/project.pbxproj`.
3. Build, then `python3 tools/string_catalog.py sync --derived-data wordrus/build/dd`
   and `python3 tools/string_catalog.py export --lang es` to find strings added
   since parking; translate and `import` them.
4. Check every screen with `TEST_RUNNER_TOUR_LANGUAGES=es` and
   `wordrusUITests/LocalizationTourTests` (see that file for the command).

To also offer British English as a target to es/fr/it/de speakers (the
"I speak" pickers), set `FeatureFlags.offersEnglishTarget = true` — the
English seed is already bundled. The two are independent but belong together:
a Spanish speaker learning English should get a Spanish interface.
