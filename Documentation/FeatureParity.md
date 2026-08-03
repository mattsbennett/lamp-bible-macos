# iOS / macOS feature parity

This matrix tracks user-facing capability rather than identical UI. Touch-only iOS interactions are represented by native macOS menus, inspectors, keyboard commands, file panels, windows, and context menus.

| Area | iOS capability | macOS equivalent | Status |
| --- | --- | --- | --- |
| Bundled library | Built-in translations, lexicons, commentaries, plans, and quiz | Consumes the same `bundled_modules.db.zlib` artifact | Complete |
| Portable modules | Install translations, dictionaries, commentaries, plans, devotionals, quizzes, notes, and highlights | Integrity-checked `.lamp` installation and management for all eight kinds | Complete |
| Reader | Formatted scripture, poetry, red letters, annotations, selectable text, font settings | Native SwiftUI reader with the same schema rendering and typography controls | Complete |
| Navigation | Book/chapter/verse navigation and history | Menus, chapter shortcuts, precise verse links, persistent back/forward history | Complete |
| Read aloud | Voice selection, rate, pause/resume, follow along | `AVSpeechSynthesizer` chapter queue with voice/rate settings and spoken-verse scrolling | Complete |
| Study tools | Commentary, lexicons, Strong’s links, footnotes, cross-references | Resizable macOS inspector with module ordering/hiding and cross-reference sorting | Complete |
| Notes | Editable verse/range notes with footnotes and import/export | Markdown note editor, verse ranges, editable footnotes, canonical JSON/`.lamp` transfer | Complete |
| Highlights | Exact spans, colors, underline styles, sets, themes, import/export | AppKit text selection, four styles, named sets/themes, canonical JSON/`.lamp` transfer | Complete |
| Search | Scripture and module search with filters/history | Unified search across all eight module kinds plus personal notes/highlights, filters, previews, and persistent history | Complete |
| Plans | Selected plans, Today, completion, dates, estimates, reminders, external apps | Today and plan views, year-scoped completion, actual word-count estimates, notifications, five external Bible targets | Complete |
| Devotionals | Browse, search, author/edit, scripture links, rich text, images, audio, recording, import/export/share | Search/filter, Markdown authoring, key scriptures, images, audio playback/recording, presentation, JSON/`.lamp` import/export and sharing | Complete |
| Quizzes | Plan/day/age-group questions and answer reveal | Module/day/age-group picker, saved age preference, reveal and scripture links | Complete |
| Module preferences | Default/hidden translations, lexicon ordering/hiding, Strong’s hints | Shared settings for default/visibility/order, hints, and canonical cross-reference order | Complete |
| Sync | Local, iCloud Drive, WebDAV, settings and editable data | Versioned portable backup over a chosen iCloud Drive/folder or authenticated WebDAV; Keychain password, merge, manual and launch sync | Complete |
| Links and files | App links and document import | `lampbible://` reader/section links plus Finder opening for `.lamp` and JSON | Complete |
| Widget | Today-reading glance and launch | Menu-bar Today window with plan assignments and reader launch | Complete (native equivalent) |
| Multiwindow | iPad/window navigation | Reader and Module Studio window groups; additional reader windows from File menu | Complete |
| Module authoring | Not an iOS feature | Drag/drop JSON inspection, validation and `.lamp` builds for every module kind | macOS addition |

## Platform-specific substitutions

- The iOS camera/image picker is a native Mac file picker; image attachments and full-size viewing remain available.
- iPad bottom/right tool-panel positioning becomes the standard resizable trailing macOS inspector.
- UIKit touch gestures, haptics, compact-size adaptations, and the WidgetKit extension are not copied literally; their user outcomes are covered by mouse/keyboard controls and the menu-bar surface.
- Realm migration and iOS database-reset diagnostics are implementation-specific to the legacy iOS store. macOS starts on the shared `LampCore` schema and therefore does not need that migration UI.

## Verification

- `lamp-bible-core`: compiler/schema/library tests cover all module kinds, search, plans, editable study data, devotionals, portable backups, media, set/theme preservation, and conflicts.
- `lamp-bible-macos`: support tests cover Studio documents, reading/search history, Unicode span conversion, read-aloud queues, external links, reading estimates/reminders, deep links, devotional media parsing, sync archives, and WebDAV requests.
- The signed Xcode application is built with the `Lamp Bible` scheme and smoke-tested by launching a real window and opening a `lampbible://read` URL.
