# Product architecture

## Windows

### Library and reader

The primary window uses a native sidebar and detail area. `LampLibrary` installs portable `.lamp` archives and maintains verified, derived SQLite copies for immediate chapter access and cross-translation full-text search. Search results and reading-plan assignments deep-link to an exact reader location. The reader renders module-provided inline styles, poetry layout, and installed translation-matched highlight spans without baking presentation into shared data. Dictionary lookup, translation footnotes and lexical annotations, verse-aware commentary, installed notes, personal notes, and highlight controls are presented in a native trailing inspector rather than mobile sheets or bottom panels. Plan selection, year-scoped completion, personal notes, and editable highlight spans live in a separate user-data database so portable modules remain immutable. Personal study data can round-trip through canonical JSON or `.lamp`; imports retain newer local notes and deduplicate identical highlight spans.

### Module Studio

Module Studio is a section of the Import or Create Content window, so a user can validate and build modules alongside one or more reader windows. Its pipeline is:

```text
drop JSON → detect → validate → preview → compile SQLite → integrity check → compress → save .lamp
```

The UI never constructs a module database directly; all format work is delegated to `LampModuleKit`.

### Slide Studio

Slide Studio edits versioned `.lampdeck` JSON documents stored under the library's `Presentations` directory. `LampCore` defines the semantic deck, slide, layout, content-block, theme, source-link, and validation contracts; the Mac app owns the inspector, autosave, file import/export, and indexed full-screen presenter. Geometry stays in the renderer so human and agent authors describe content roles rather than fragile coordinates.

The renderer itself lives in `LampPresentationUI`, a separate product from `LampCore` because the module CLI and the MCP server link `LampCore` headlessly and must not pull in SwiftUI. Slide Studio's editor and slide list, the full-screen presenter, the iOS deck viewer, and the iOS remote's current/next previews all draw through that one canvas, so a deck cannot look different depending on which screen shows it. Image blocks resolve `assetPath` against the library's `Presentations/Assets` directory, which Slide Studio copies chosen images into under generated names. The canvas draws a labelled placeholder when a file is missing, so a deck that has outrun its images still presents. Images have no deletion ledger: they union-merge newest-wins and are collected by reachability, on the Mac when a deck is deleted and on iOS after every pull, because a deletion record could otherwise race a deck that still needs the file.

Decks sync between Macs, and out to iPhone and iPad, as individual files under `Workspaces/Presentations` in the portable backup, with deletions recorded in `deleted-decks.json`. `LampPresentationDeckPortableLayout` fixes those paths and `LampPresentationDeckPortablePull` the merge decision, both in `LampCore`, so the Mac's read-write sync and the read-only iOS mirror resolve the same winner. iOS never publishes a deck.

Decks may link to a devotional without being embedded in it, allowing several audience-specific presentations to accompany the same writing. A bundled `build-lamp-deck` workspace skill writes `presentation.lampdeck`; the devotional workspace validates and imports changed artifacts while preserving the MCP server's read-only library boundary.

Writing comes in from Markdown through `LampWritingImport` in `LampCore`: a folder or file is read into files, `planWritingImport` says what each would become (create, update, unchanged, conflict or rejected, with errors, warnings and what was tidied) without writing, and `applyWritingImport` writes the items the person chooses, refusing any whose library copy changed after the plan. A file without a front matter `id` takes one derived from its path within the chosen folder, so importing again updates rather than copies. Plan, apply and undo run against a `LampWritingImportStore` — `LampLibrary` here, the phone's own database there — so both apps decide alike. Pictures and recordings a file links to are copied into its writing's media; a `.lampdeck` beside a file becomes its writing's deck, a row of its own; links between files of one import become `lampbible://writing/<id>`. Applying returns an undo record, which the Mac keeps for its last ten imports under Application Support's `WritingImportUndo`; undoing leaves anything changed since. `lamp-mcp --plan-writing-import` prints the same report from a shell. The Import or Create Content window shows the plan in a review sheet. Agents use the bundled `import-lamp-writing` skill and three MCP tools: `plan_writing_import` checks a bundle, and `import_writings` copies the files' text into a request under Application Support's `WritingImports`, and their pictures and decks into a folder beside it, which Lamp shows in the same review sheet, behind the AI switch; nothing an agent sends is imported until the person ticks it, and `writing_import_status` reads back what they chose.

Opening the full-screen presenter starts a session-scoped Bonjour service and offers a QR code plus a readable 16-character manual code. Bonjour reveals only the presenter service. Each TCP connection receives a fresh public challenge; pairing proof, deck state, notes, and commands use length-prefixed ChaCha20-Poly1305 frames derived from the 80-bit session code. The presenter withholds deck state until the encrypted proof contains that connection's challenge, preventing a captured pairing frame from authorizing a new connection. It then broadcasts the current/next semantic slides, speaker notes, elapsed time, navigation availability, and blackout state. Remote commands are applied to the same indexed presenter state as keyboard and pointer controls. `LampCore` owns the versioned messages, pairing material, and authenticated framing contract; the macOS and iOS apps own their respective Network.framework lifecycles.

### Devotional agents and module access

The devotional editor can launch Codex CLI, Claude Code, or OpenCode in an embedded terminal. Each devotional gets an isolated workspace containing the synchronized draft, user-supplied context files, selected workspace skills, and provider-local MCP configuration. Agent-authored Markdown and text artifacts beside `draft.md` appear as live editor tabs, and the tab bar shows only once a writing has companion files; users create validated companion Markdown files from the editor's Workspace menu, and Lamp autosaves edits while detecting external changes before overwriting them. Every Markdown tab has per-file history for saved edits, agent changes, conflict resolutions, and restores; legacy unscoped records belong to `draft.md`. Context files are content-addressed by SHA-256 and represented in workspaces by read-only hard links, so byte-identical files share one library-local object while retaining their workspace filenames and folder layout. Custom skills live once in the library-wide `AgentSkills` catalog and can be enabled in any workspace; Lamp materializes the selected provider copies from a per-workspace manifest and migrates older workspace-owned skills without discarding name conflicts. Folder and WebDAV sync stage companion documents, user context, the shared skill catalog, workspace skill selections, and revision history in a portable `Workspaces` tree; imported context is consolidated into the local object store. The canonical devotional record carries the main prose, while generated instructions, bundled or provider-materialized skills, the context object store, MCP/provider configuration, sync markers, and credentials remain machine-local and are regenerated when needed.

Module access follows a narrow read-only boundary:

```text
provider CLI → stdio MCP → lamp-mcp → LampAgentLibrary → LampLibrary
```

`LampAgentLibrary` is the transport-independent semantic API. It exposes bounded operations for scripture, dictionaries, commentary, long-form books, devotionals, plans, quizzes, notes, and highlights without exposing database tables or writable library methods. The bundled `lamp-mcp` helper adapts those operations to MCP and is embedded in `Contents/Helpers` by the Xcode app target. Codex, Claude Code, and OpenCode receive generated project-local configuration pointing to that exact helper.

The settings policy controls whether agents may query modules, whether they see only enabled or all installed modules, and whether personal content is included. Personal content is off by default. The helper reloads the policy before every tool call so revoking access applies to provider processes that are already running.

## Repository boundaries

- `lamp-bible-macos`: SwiftUI/AppKit views, commands, windows, drag and drop, file panels, and Mac lifecycle.
- `lamp-bible-core`: reusable Swift models, GRDB databases, compiler/importer, search, and sync protocols.
- `lamp-bible-modules` (private): canonical JSON Schemas, authoring sources, Python pipelines, and generated module fixtures.
- `lamp-bible-ios`: UIKit/SwiftUI views and iOS lifecycle.

## Dependency policy

Local path dependencies are for coordinated development only. Once `lamp-bible-core` has its first stable API, both apps should pin the same tagged Git release. Core changes that affect `.lamp` output require compatibility fixtures from `lamp-bible-modules` and importer tests in both applications.
