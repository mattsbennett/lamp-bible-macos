# Lamp Bible for macOS

A native macOS Bible study application and module-authoring environment.

This repository intentionally contains Mac-specific application lifecycle and UI. Shared module formats, databases, search, sync, and domain behavior belong in the sibling [`lamp-bible-core`](../lamp-bible-core) Swift package.

## Current slice

- Native multiwindow SwiftUI shell
- Sidebar-based library navigation
- Dedicated Module Studio window and menu command
- JSON file importer and drag-and-drop target
- Module type detection, summary statistics, and validation provided by `LampModuleKit`
- Native `.lamp` compilation for translations, dictionaries, commentaries, reading plans, notes, and highlights
- Save-panel export with integrity verification, checksums, and Finder reveal
- Persistent module-native library with integrity-checked `.lamp` installation
- Translation reader with native book/chapter menus and keyboard navigation
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
- Year-scoped reading completion persisted outside portable modules
- Restored reading location, selectable scripture text, and reader typography settings
- Module management with Finder access and safe removal
- One-click installation of a successful Module Studio build

Personal edits are stored outside immutable modules and can be imported or exported as canonical JSON or `.lamp` modules, while canonical notes and highlight JSON can also be built and installed through Module Studio. Quizzes and devotionals will be added incrementally.

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

Install a translation with File → Install Module… (`⌘O`), import editable study data with `⌥⌘O`, navigate chapters with `⌘[` and `⌘]`, and toggle study tools with `⇧⌘I`. Clicking a verse number focuses the inspector; right-clicking a verse exposes highlight and personal-note actions.
