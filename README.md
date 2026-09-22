# Lamp Bible for macOS

A native macOS Bible study application and module-authoring environment.

This repository intentionally contains Mac-specific application lifecycle and UI. Shared module formats, databases, search, sync, and domain behavior belong in the sibling [`lamp-bible-core`](../lamp-bible-core) Swift package.

## Feature-complete macOS application

- Native multiwindow SwiftUI shell
- Sidebar-based library navigation
- Dedicated Module Studio window and menu command
- JSON file importer and drag-and-drop target
- Module type detection, summary statistics, and validation provided by `LampModuleKit`
- Native `.lamp` compilation for translations, dictionaries, commentaries, reading plans, devotionals, quizzes, notes, and highlights
- Save-panel export with integrity verification, checksums, and Finder reveal
- Persistent module-native library with integrity-checked `.lamp` installation
- Translation reader with native book/chapter menus and keyboard navigation
- Long-form book reader with hierarchical contents, search, rich annotations and footnotes, covers, image/audio media, bookmarks, and synced reading position and typography
- Rich translation rendering for red-letter text, supplied-word italics, divine names, variants, and poetry layout
- Full-text scripture search across all translations or a selected translation
- Search-result deep links with exact verse scrolling and focus treatment
- Native trailing study inspector with verse-aware commentary, translation notes, lexical metadata, and dictionary lookup
- Native personal-note editor with per-verse save, clear, and reader badges
- Span-compatible verse highlights with the shared iOS color palette, reader context menus, and inline rendering
- Read-only display of installed note modules and translation-matched highlight modules in the reader
- Personal study export to canonical JSON or installable `.lamp` notes/highlight modules
- Editable study-data import from canonical JSON or `.lamp`, with newer-note wins and exact-span highlight deduplication
- Dictionary search by word, lemma, transliteration, or Strong's key across installed modules
- One-click Strong's links from translation annotations into installed dictionaries
- Translator-note badges on annotated verses with direct Verse-inspector routing
- Native Today and Reading Plans screens with date navigation, plan selection, and reader deep links
- Searchable devotional library with scripture deep links
- Day- and age-specific quizzes with answer reveal and reader deep links
- The same read-only bundled translations, lexicons, commentaries, plans, and quiz module as the iOS app
- Year-scoped reading completion persisted outside portable modules
- Restored reading location, selectable scripture text, and reader typography settings
- Reader tabs restored on relaunch, including tab order, translations, chapters, focused verses, and the selected tab
- Module management with Finder access and safe removal
- One-click installation of a successful Module Studio build
- Persistent reader navigation history and unified all-module search history
- Read Aloud with system voices, adjustable rate, pause/resume, and verse follow-along
- Exact text-range highlights with styles, named sets, and reusable themes
- Verse-range Markdown notes with editable footnotes
- Personal devotional authoring, images, audio attachment/recording/playback, presentation, import, export, and sharing
- Native Slide Studio with semantic layouts, speaker notes, linked writing decks, `.lampdeck` import/export, validation, autosave, and indexed full-screen presentation
- Bonjour presentation discovery with QR-first, challenge-bound encrypted pairing and synchronized iPhone/iPad controls for current/next slide, notes, timing, navigation, and blackout
- A bundled agent skill that turns devotional workspaces into validated Slide Studio decks without writable module access
- Native devotional agent chat (powered by the Apache-2.0 SwiftyChat UI) with resumable Codex, Claude Code, and OpenCode sessions, browser sign-in, and a terminal-mode toggle
- Resizable reader chat sidebar using the same provider accounts and chat UI, with read-only module research, per-message chapter context, and separate saved conversations for each reader window
- Actual-word-count reading estimates, daily notifications, and external Bible app links
- Default, visibility, and ordering preferences for translations, dictionaries, and commentaries
- Finder document opening and `lampbible://` deep links
- Portable iCloud Drive/folder and WebDAV sync for modules, settings, notes, highlights/themes, devotionals, media, and user-authored devotional workspace files
- A menu-bar Today surface as the native Mac equivalent of the iOS widget

Personal edits are stored outside immutable modules and can be imported or exported as canonical JSON or `.lamp` modules, while every canonical module type can also be built and installed through Module Studio.

The detailed iOS-to-macOS capability matrix is in [Documentation/FeatureParity.md](Documentation/FeatureParity.md).

## Development

The package uses a local sibling dependency while both repositories are evolving:

```text
Personal Repos/
├── lamp-bible-core/
├── lamp-bible-ios/
├── lamp-bible-macos/
└── lamp-bible-modules/
```

Build and test from the command line:

```sh
swift build
swift test
```

Open `Lamp Bible.xcodeproj` in Xcode, choose the **Lamp Bible** scheme and **My Mac**, then press `⌘R`. The Xcode target builds a real macOS application bundle using `com.neus.Lamp-Bible.macOS`; `Package.swift` remains available for library-focused command-line builds and tests.

The Xcode target copies `../lamp-bible-modules/modules_db/bundled_modules.db.zlib` into the application bundle. Keep the sibling repositories in the layout above and rebuild that canonical archive from `lamp-bible-modules` when bundled content changes; both Apple apps consume the same artifact.

Install a translation with File → Install Module… (`⌘O`), import editable study data with `⌥⌘O`, navigate chapters with `⌘[` and `⌘]`, and toggle study tools with `⇧⌘I`. Clicking a verse number focuses the inspector; right-clicking a verse exposes highlight and personal-note actions.

Open Reader Chat with the speech-bubble toolbar button (`⇧⌘J`). Ask about the displayed chapter or name any other passage; each message includes the reader’s current chapter and translation. Chat can query all installed modules through read-only tools. AI & Agents settings control whether module queries and personal study content are available. Reader conversations are saved separately from Writing and resume when the sidebar reopens.
