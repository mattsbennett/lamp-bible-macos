# Product architecture

## Windows

### Library and reader

The primary window uses a native sidebar and detail area. `LampLibrary` installs portable `.lamp` archives and maintains verified, derived SQLite copies for immediate chapter access and cross-translation full-text search. Search results and reading-plan assignments deep-link to an exact reader location. The reader renders module-provided inline styles, poetry layout, and installed translation-matched highlight spans without baking presentation into shared data. Dictionary lookup, translation footnotes and lexical annotations, verse-aware commentary, installed notes, personal notes, and highlight controls are presented in a native trailing inspector rather than mobile sheets or bottom panels. Plan selection, year-scoped completion, personal notes, and editable highlight spans live in a separate user-data database so portable modules remain immutable. Personal study data can round-trip through canonical JSON or `.lamp`; imports retain newer local notes and deduplicate identical highlight spans.

### Module Studio

Module Studio is a separate window so a user can validate and build modules alongside one or more reader windows. Its pipeline is:

```text
drop JSON → detect → validate → preview → compile SQLite → integrity check → compress → save .lamp
```

The UI never constructs a module database directly; all format work is delegated to `LampModuleKit`.

### Slide Studio

Slide Studio edits versioned `.lampdeck` JSON documents stored under the library's `Presentations` directory. `LampCore` defines the semantic deck, slide, layout, content-block, theme, source-link, and validation contracts; the Mac app owns the canvas, inspector, autosave, file import/export, and indexed full-screen presenter. Geometry stays in the renderer so human and agent authors describe content roles rather than fragile coordinates.

Decks may link to a devotional without being embedded in it, allowing several audience-specific presentations to accompany the same writing. A bundled `build-lamp-deck` workspace skill writes `presentation.lampdeck`; the devotional workspace validates and imports changed artifacts while preserving the MCP server's read-only library boundary.

Opening the full-screen presenter starts a session-scoped Bonjour service and offers a QR code plus a readable 16-character manual code. Bonjour reveals only the presenter service. Each TCP connection receives a fresh public challenge; pairing proof, deck state, notes, and commands use length-prefixed ChaCha20-Poly1305 frames derived from the 80-bit session code. The presenter withholds deck state until the encrypted proof contains that connection's challenge, preventing a captured pairing frame from authorizing a new connection. It then broadcasts the current/next semantic slides, speaker notes, elapsed time, navigation availability, and blackout state. Remote commands are applied to the same indexed presenter state as keyboard and pointer controls. `LampCore` owns the versioned messages, pairing material, and authenticated framing contract; the macOS and iOS apps own their respective Network.framework lifecycles.

### Devotional agents and module access

The devotional editor can launch Codex CLI, Claude Code, or OpenCode in an embedded terminal. Each devotional gets an isolated workspace containing the synchronized draft, user-supplied context files, selected workspace skills, and provider-local MCP configuration. Agent-authored Markdown and text artifacts beside `draft.md` appear as live editor tabs; users can create validated companion Markdown files from the tab bar, and Lamp autosaves edits while detecting external changes before overwriting them. Every Markdown tab has per-file history for saved edits, agent changes, conflict resolutions, and restores; legacy unscoped records belong to `draft.md`. Context files are content-addressed by SHA-256 and represented in workspaces by read-only hard links, so byte-identical files share one library-local object while retaining their workspace filenames and folder layout. Custom skills live once in the library-wide `AgentSkills` catalog and can be enabled in any workspace; Lamp materializes the selected provider copies from a per-workspace manifest and migrates older workspace-owned skills without discarding name conflicts. Folder and WebDAV sync stage companion documents, user context, the shared skill catalog, workspace skill selections, and revision history in a portable `Workspaces` tree; imported context is consolidated into the local object store. The canonical devotional record carries the main prose, while generated instructions, bundled or provider-materialized skills, the context object store, MCP/provider configuration, sync markers, and credentials remain machine-local and are regenerated when needed.

Module access follows a narrow read-only boundary:

```text
provider CLI → stdio MCP → lamp-mcp → LampAgentLibrary → LampLibrary
```

`LampAgentLibrary` is the transport-independent semantic API. It exposes bounded operations for scripture, dictionaries, commentary, long-form books, devotionals, plans, quizzes, notes, and highlights without exposing database tables or writable library methods. The bundled `lamp-mcp` helper adapts those operations to MCP and is embedded in `Contents/Helpers` by the Xcode app target. Codex, Claude Code, and OpenCode receive generated project-local configuration pointing to that exact helper.

The settings policy controls whether agents may query modules, whether they see only enabled or all installed modules, and whether personal content is included. Personal content is off by default. The helper reloads the policy before every tool call so revoking access applies to provider processes that are already running.

## Repository boundaries

- `lamp-bible-macos`: SwiftUI/AppKit views, commands, windows, drag and drop, file panels, and Mac lifecycle.
- `lamp-bible-core`: reusable Swift models, GRDB databases, compiler/importer, search, and sync protocols.
- `lamp-bible-modules`: canonical JSON Schemas, authoring sources, Python pipelines, and generated module fixtures.
- `lamp-bible-ios`: UIKit/SwiftUI views and iOS lifecycle.

## Dependency policy

Local path dependencies are for coordinated development only. Once `lamp-bible-core` has its first stable API, both apps should pin the same tagged Git release. Core changes that affect `.lamp` output require compatibility fixtures from `lamp-bible-modules` and importer tests in both applications.
