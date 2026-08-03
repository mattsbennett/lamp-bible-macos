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

## Repository boundaries

- `lamp-bible-macos`: SwiftUI/AppKit views, commands, windows, drag and drop, file panels, and Mac lifecycle.
- `lamp-bible-core`: reusable Swift models, GRDB databases, compiler/importer, search, and sync protocols.
- `lamp-bible-modules`: canonical JSON Schemas, authoring sources, Python pipelines, and generated module fixtures.
- `lamp-bible-ios`: UIKit/SwiftUI views and iOS lifecycle.

## Dependency policy

Local path dependencies are for coordinated development only. Once `lamp-bible-core` has its first stable API, both apps should pin the same tagged Git release. Core changes that affect `.lamp` output require compatibility fixtures from `lamp-bible-modules` and importer tests in both applications.
