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

### Devotional agents and module access

The devotional editor can launch Codex CLI, Claude Code, or OpenCode in an embedded terminal. Each devotional gets an isolated workspace containing the synchronized draft, user-supplied context files, workspace skills, and provider-local MCP configuration.

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
