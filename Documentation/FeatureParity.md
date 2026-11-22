# iOS / macOS feature parity

This matrix tracks user-facing capability rather than identical UI. Touch-only iOS interactions are represented by native macOS menus, inspectors, keyboard commands, file panels, windows, and context menus.

| Area | iOS capability | macOS equivalent | Status |
| --- | --- | --- | --- |
| Bundled library | Built-in translations, lexicons, commentaries, plans, and quiz | Consumes the same `bundled_modules.db.zlib` artifact | Complete |
| Portable modules | Install translations, dictionaries, commentaries, plans, devotionals, quizzes, notes, highlights, and books | Integrity-checked `.lamp` installation and management for all nine kinds | Complete |
| Bible import | Import a USFM, OSIS, Zefania or XML Bible the user owns from Files as a translation, reviewed before it installs | The same import from Import or Create Content; both apps take their wording and the replace-or-add decision from core | Complete |
| Reader | Formatted scripture, poetry, red letters, annotations, selectable text, font settings | Native SwiftUI reader with the same schema rendering and typography controls | Complete |
| Long-form books | Hierarchical books with annotated prose, scripture links, footnotes, covers, images, and audio | Three-pane reader with nested contents/search, bookmarks, section and block resume, metadata, rich annotations, footnotes, image viewing, audio/waveforms/transcripts, navigation, and independent typography | Complete |
| Navigation | Book/chapter/verse navigation and history | Menus, chapter shortcuts, precise verse links, persistent back/forward history | Complete |
| Read aloud | Voice selection, rate, pause/resume, follow along | `AVSpeechSynthesizer` chapter queue with voice/rate settings and spoken-verse scrolling | Complete |
| Study tools | Commentary, lexicons, Strong’s links, footnotes, cross-references | Resizable macOS inspector with module defaults/visibility and cross-reference sorting | Complete |
| Notes | Verse/range notes whose existing footnotes can be edited, with import/export | Markdown note editor, verse ranges, editable footnotes, canonical JSON/`.lamp` transfer | Complete |
| Highlights | Exact spans, colors, underline styles, sets, themes, import/export | AppKit text selection, four styles, named sets/themes, canonical JSON/`.lamp` transfer | Complete |
| Search | Scripture and module search with filters/history | Unified search across all nine module kinds plus personal notes/highlights, filters, previews, and persistent history | Complete |
| Plans | Selected plans, Today, completion, dates, estimates, reminders, external apps | Today and plan views, year-scoped completion, actual word-count estimates, notifications, five external Bible targets | Complete |
| Devotionals | Browse, search, author/edit, scripture links, rich text, images, audio, recording, import/export/share | Search/filter, Markdown authoring with find and replace, key scriptures, images, audio playback/recording, presentation, JSON/`.lamp` import/export and sharing; linked Slide Studio decks with notes and agent generation | Complete |
| Review marks | Marks on what the assistant changed, in the writing and in every synced document beside it, made only on the Mac; the phone draws, clears, restores and carries them. In the writing: a ✓ per paragraph, a ↺ beside it while editing for Restore Original Wording with a Now/Original preview, and a ✓ menu holding Mark Selection/All as Reviewed and Next/Previous Change. In a document: a count per file in the Files list, a tap on a marked passage or on the caret where words were taken out opening Now/Original with Mark as Reviewed and Restore Original Wording, and a to-review menu listing every change by its words, drawn or not | Marks made and drawn in both the visual page and the Markdown editor, with Mark Selection/All as Reviewed, Restore Original Wording and Next/Previous Change, and a warning where the page cannot draw them | Complete |
| Devotional agents | Not an iOS feature | Embedded Codex CLI, Claude Code, and OpenCode workspaces, and Google Antigravity for chat alone, with live draft sync, context files, skills, revisions, provider accounts, in-chat approval of Claude Code tool calls, and policy-scoped read-only access to every module kind | macOS addition |
| Quizzes | Plan/day/age-group questions and answer reveal | Module/day/age-group picker, saved age preference, reveal and scripture links | Complete |
| Module preferences | Default/hidden translations, lexicon ordering/hiding, Strong’s hints | Type-specific defaults, per-language dictionary defaults, visibility, hints, and canonical cross-reference order | Complete |
| Sync | Local, iCloud Drive, WebDAV, settings and editable data | Versioned portable backup over a chosen iCloud Drive/folder or authenticated WebDAV; includes companion writing files, agent context, custom skills, and revisions; Keychain password, merge, manual and launch sync | Complete |
| Links and files | App links and document import | `lampbible://` reader, book/section, and library links plus Finder opening for `.lamp` and JSON | Complete |
| Widget | Today-reading glance and launch | Menu-bar Today window with plan assignments and reader launch | Complete (native equivalent) |
| Multiwindow | iPad/window navigation | Reader, book, writing and Slide Studio window groups; additional reader windows from File menu | Complete |
| Module authoring | Not an iOS feature | Drag/drop JSON inspection, validation and `.lamp` builds for every module kind | macOS addition |

## Decisions both apps hold to

### An undone restore is let go, on both apps

Where the writer undoes a restore Lamp made, both apps drop what they
were going to write down, and neither tries to notice a Redo.

The cost is real: Redo puts the restored wording back without the page
asking the host anything, so an undone-then-redone restore is recorded
nowhere, no restoration reaches the assistant, and the words it put
back that nobody has read carry no mark.

The other side is worse. A restore whose replacement is empty — a
deletion put back — is proved only negatively: it stands whenever the
assistant's words are absent, which an unrelated edit eventually makes
true. Held across that, the next save records a restoration the writer
never made.

Keeping it safely means knowing whether a Redo brought *this restore*
back. The iOS session built that signal and took it through four codex
rounds; each round found new losses, and the fourth found a false
record — paste the restore's words after an unrelated redo, and the
save records a restore that never happened. The conclusion was that no
signal built from the page's text and history depth can work: text
cannot tell a Redo from typing or pasting the same words, and every
such signal races with a settle; and the same writing can be open in
two pages at once, each with its own history, so even a correct signal
from one page does not say what another can still redo. A sound version would have the page
track the restore through its own history, and even that cannot mark a
restore that only deletes — the dangerous case to begin with.

The work is kept, unpushed, on the iOS branch `held-redo` (42ef0cf).
**Read it before building anything in this direction.** The Mac built
a host half to the same rules and removed it again (396dfbe) rather
than leave inert machinery for someone to wire up.

Core still classifies such a passage as `dormant` from
`RestorePlan.settlement`, and `SyncMerge.lean` proves no passage of a
restore is ever dropped from the classification. That is a true
description of what a save proves; it does not ask either app to keep
anything, and neither does.

### What both apps were verified to do, 2026-11-22

Checked with the iOS session at the close of this work, each point
against the code rather than by assertion:

- **Placement is core's on both.** The phone's prose goes through
  `LampWritingReviewMarkdown.drawable` (`WritingFilesSheet.swift`), and
  `numbered`, `passing`, `clearingBlockSyntax`, `isMarker`, `unmarked`
  and `markers` all forward to core. The Mac's page is the phone's
  built bundle, spliced with only the Mac's own style line changed, so
  the two cannot drift on what the page does.
- **A clear or restore by range reaches block syntax and stops**, at
  all four sites on the phone and both on the Mac.
- **An undone restore is let go.** The phone binds only `settlement`'s
  `record` and `waiting`; `dormant` is never read. The Mac does the
  same and has no redo-signal host.
- **iOS `origin/main` builds and tests green against core 13dcafd**
  (569 tests), which removed `takingInDelimiters`,
  `takingInSyntaxAndDelimiters` and their helpers.
- **The phone's marks were seen drawn**, on an iOS 27.2 simulator
  rather than only in tests (2026-11-22). `WritingFileView` with
  `showsMarks: true`, against a record written through
  `LibrarySyncPass.reviewStore`, on a document carrying a code span, a
  table, bold delimiters, an escaped backtick and a fenced block — the
  same mix the Mac was checked against. Three passages were marked, at
  exactly the assistant's insertions and nowhere else: the table, the
  fence, the code span and the escaped backtick were left alone.
  Clearing one passage by range removed that passage's highlight only:
  three marked, two left.

  The shot of that run shows a count pill of 5, then 4, which is an
  artefact of the harness and not the app: it wrote to the real store
  under a fixed writing id without clearing it first, so a second run
  marked the same change on top of the record the first had left
  behind. The extra marks land under the existing highlights, so the
  pill rose while three passages still showed. A reused harness should
  take a fresh id or remove the record first. Found by the iOS session
  from the two runs' logs, after this was first written down here as
  the pill counting points, which was a guess.

  Seen on the way: the phone's side-file reader **breaks a paragraph at
  a soft-wrapped source newline**, where the editor joins it. This is
  the block-level divergence class recorded below, caught on screen
  rather than by reading.

**The parser, as adopted (iOS a56bf48 on core 573a593):** the phone's
`WritingDocumentText` reads code blocks and tables through
`LampMarkdownModel`, and its own scanners for them — `isDelimiterRow`,
the alignment-row match, the table rescan — are gone. The Mac reaches
the same model through `drawable`, the block readers and the clear's
reach, and its editor page is the phone's built bundle, so neither app
can drift from the other on what the page does.

`NoteMarkdownRenderer` on the phone is **not on the model**: its
inline reading is Foundation's `AttributedString(markdown:)`, which is
cmark, and its blocks are read line by line, which matches the notes
editor's line-break setting.

That was first written down here as deliberate and settled. A review
on 2026-11-22 found it is neither, and the reason is worth keeping:
the line-by-line split is **one markdown-it option** (`breaks: true`,
which both note editors set), not a second grammar. Four hand-written
block grammars stand in for it across the two apps —
`NoteMarkdown.Block`, `DevotionalProseParser`,
`DevotionalMarkdownParser`, and the phone's side-file cutter — and the
reader that does *not* honour the option is the Mac's, not the phone's:
`DevotionalProseParser` joins consecutive lines with a space
(`ReaderSupport.swift:1298`, pinned by `wrappedLinesStayInOneParagraph`),
and the Mac reading card draws notes through it
(`StudyInspectorView.swift:839`). So a Mac note typed as three plain
lines is read back as one joined line, where its own editor
(`lineBreaks: true`, `StudyInspectorView.swift:1345`) and the phone
both show three.

Every divergence a writer actually meets is block-level in this way —
line breaks, quote lines joining, lists renumbering from 1, nesting
drawn two levels deep. The inline layer is already shared, all three
native readers using Foundation's parser. Nothing is decided here
about unifying them; what is decided is that "the phone renders
differently" was the wrong way round.

Equally deliberate in core: `keepingEscapes` stays a single regex,
being exactly the spec's rule; and `movingMarksOutOfLinks` stays
by hand after a rewrite onto the model was found — by running both
against the same inputs — to drag a marker out of a link's *label* and
to miss an autolink's address, where for `<url>` the address is the
content rather than what follows it. Both failures are tests, so a
future rewrite has a net the regexes already pass.

The phone and iPad in use run iOS a2dec6e on core 0605966; for review
marks that behaves as 13dcafd does, so no reinstall was needed.

### Core reads Markdown with a CommonMark parser

Decided by the owner on 2026-11-22, after six rounds of review found
six ways a hand-written reader disagreed with the writer's editor
about what the Markdown means. Core depends on swift-markdown (Apple's
wrapper over cmark-gfm), pinned exact as GRDB is.

`LampMarkdownModel` parses a text once and reports UTF-16 ranges for
blocks and their kinds, and for each inline span both its delimiter
ranges and its content. Two things it does that are easy to get wrong
and are tested on their own:

- **The conversion.** swift-markdown reports a line and a *UTF-8
  column*; `NSRange` counts UTF-16. A Hebrew letter is two UTF-16
  units and two UTF-8 bytes, an emoji two and four, and `"\r\n"` is a
  single Swift `Character`. Lines are split and mapped by Unicode
  scalar for exactly these reasons.
- **Matching the editor, not the spec.** The page reads Markdown with
  markdown-it. Where cmark-gfm differs, core follows the page: a lone
  `~` is literal (markdown-it needs `~~`), DocC block directives are
  off, and a bare URL is not a link because the page has `linkify`
  off.

**What is on the parser:** what counts as code, how much of a line is
its opening block syntax, which emphasis a clear may reach, and —
through `readsTheSame` — whether a review marker standing in a line
changes how that line reads.

**What is still by hand, deliberately:** `keepingEscapes`, one regex
that is exactly the spec's rule; and `movingMarksOutOfLinks`, whose
rewrite onto the model broke a marker inside a link's label and an
autolink's address, and was reverted. Both have tests a rewrite must
pass.

A review marker is a private-use scalar, which to cmark is an ordinary
character — so it can create or destroy a delimiter. Anything asking
what Markdown *means* must therefore parse the unmarked text, and
anything asking whether a marker is safe where it stands must parse
both and compare their shapes. Comparing renderings does not work: a
delimiter run a marker split writes back the same characters as real
emphasis once the markers come off.

### A clear reaches block syntax, never emphasis

Where the assistant's change *is* the emphasis — `red dog` becoming
`**red dog**` — what it changed is the two runs of `**`, and the marks
sit on them. A clear of the words does not cover the runs, so marks on
them stay behind as a sliver. A second clear, or a caret clear on the
sliver, removes it. That tidy-up click is the accepted cost, decided by
the owner on 2026-11-21.

Reaching for them cost more. Six rounds of the iOS session's codex
found six ways a hand-written pairing takes in a delimiter belonging to
a word the writer never selected, which partly clears that word's mark
and leaves its change unrestorable: a run that merely matches rather
than pairs, a literal run inside a code span, an escaped run, a caret,
a list bullet pairing with a word's opener, and a nested emphasis.
Still ahead were flanking runs, the rule of three, `_` inside words,
links, autolinks, HTML, and `~~` against `~`.

The rule behind all of them is CommonMark's delimiter-run algorithm —
flanking runs and the emphasis-processing pass with its delimiter
stack — which is what the editor page follows through markdown-it, and
so what decides what the writer sees as bold. Matching it means a
cmark-backed parser in core, or a faithful port tested against the
spec's own emphasis examples. Both were considered and declined: the
sliver is cheaper than either.

**So a clear reaches a line's block syntax and stops.** Do not add
emphasis back by hand; a seventh attempt would be the seventh case
narrower than the problem.

## Platform-specific substitutions

- The iOS camera/image picker is a native Mac file picker; image attachments and full-size viewing remain available.
- iPad bottom/right tool-panel positioning becomes the standard resizable trailing macOS inspector.
- UIKit touch gestures, haptics, compact-size adaptations, and the WidgetKit extension are not copied literally; their user outcomes are covered by mouse/keyboard controls and the menu-bar surface.
- Realm migration and iOS database-reset diagnostics are implementation-specific to the legacy iOS store. macOS starts on the shared `LampCore` schema and therefore does not need that migration UI.

## Verification

- `lamp-bible-core`: compiler/schema/library tests cover all module kinds, search, plans, editable study data, devotionals, portable backups, media, set/theme preservation, and conflicts.
- `lamp-bible-macos`: support tests cover Studio documents, reading/search history, Unicode span conversion, read-aloud queues, external links, reading estimates/reminders, deep links, devotional and book media/content parsing, finding text in writing, per-book reading state, workspace merges, sync archives, and WebDAV requests.
- The signed Xcode application is built with the `Lamp Bible` scheme and smoke-tested by launching a real window and opening a `lampbible://read` URL.
