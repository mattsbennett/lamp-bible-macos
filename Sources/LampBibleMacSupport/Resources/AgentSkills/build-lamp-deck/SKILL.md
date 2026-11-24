---
name: build-lamp-deck
description: Build or revise an accessible Lamp Bible presentation deck from a devotional, writing draft, scripture study, or supplied source material. Use when an agent is asked to create slides, a sermon or teaching deck, presentation notes, a shorter or audience-specific deck variant, or a presentation.lampdeck artifact for Lamp Slide Studio.
---

# Build Lamp Deck

Create or revise `presentation.lampdeck` in the current devotional workspace. Treat the deck as an accompaniment to `draft.md`, not a replacement for it.

## Workflow

1. Read `DEVOTIONAL_CONTEXT.md`, `DEVOTIONAL_ID`, and the complete `draft.md`. Inspect relevant files under `context/` when present.
2. Read [references/deck-format.md](references/deck-format.md). When revising an existing `presentation.lampdeck`, preserve deck, slide, and block IDs for content that survives the revision.
3. Outline one communicative purpose per slide. Prefer a clear narrative arc over mirroring every paragraph of the writing.
4. Write the complete deck to `presentation.lampdeck`. Use UUIDs for all new IDs and link `source.id` to the exact value in `DEVOTIONAL_ID`.
5. Validate the artifact with the `validate_deck` tool, passing the deck's text as `deck`. It reports every error and warning with the field it is at, and a missing required field by name. These are the same rules Lamp applies when it imports a deck.
6. Fix every reported error. Review warnings and retain them only when the content genuinely requires the extra density.
7. Derive what Lamp can derive with the `build_deck` tool, passing the deck and — for a talk — `draft.md` as `manuscript`. It fills in the speaker notes, gives any new slide or block a UUID, and returns the filled-in deck for you to write back to `presentation.lampdeck`.

   Lamp derives these notes by itself on every save; this puts the same notes into your copy of the deck, and reports what it could not do. Its report's `resolved` is false when an anchor is no longer in the manuscript, and names the slide — under that slide's entry in `slides`, and by number in the top-level `slidesWithProblems`. Running it twice changes nothing.
8. Look at the slides with the `render_deck` tool, passing the deck and `draft.md` as `manuscript`. It returns one picture per slide with a report.

   The validator cannot see a layout, and most layout mistakes are invisible until something is drawn. View the pictures. Act on every `note`: a block the layout will not draw, text shrunk to fit, content running off the slide, and — when a scripture block carries a `scriptureReference` — a quotation that does not match the installed translation. The top-level `slidesWithProblems` names the slides that have one, out of the slides this run drew. Pass `slides` to redraw just the ones you changed — remembering that a run narrowed that way can say nothing about the slides it skipped, so finish on a full run.

9. Read `presentation-import.json` to confirm Lamp took the deck. Lamp writes it each time it looks at the artifact, and amends its `speakerNotes` whenever the writing is saved — so after the writer edits the prose, this is where a broken anchor appears, with the slide named.

   When the writer has edited while you worked, `writing_changes` shows what they changed, as diffs, so you need not keep copies of `draft.md` to compare. What a slide *summarises* is not checked by anything: after a passage changes, read the slides that stood on it.

   `studioEdits` is the same thing for the slides: what the writer has changed in Slide Studio since your last import, named slide by slide. Read it **before** you write the deck as well as after — see the authoring rules.

Lamp Bible detects a valid changed artifact and imports it into Slide Studio automatically.

## Authoring rules

- Preserve the source's theological nuance and intended audience.
- Quote scripture or another source exactly only when the wording is available; otherwise label the text as a paraphrase. A `scriptureReference` names whole verses, so to show part of a verse, copy its words exactly, leave the reference off, and name the passage in the citation. Keep "paraphrase" for words that are not the translation's.
- Check a quotation against its source for who it describes and what its author meant, not only for wording. A verse about one group of people, or a sentence its author goes on to reject, misleads a listener even when every word is right.
- A verse can hold half a quotation. Excerpting a verse that opens a speech closing later, or closes one opened earlier, leaves a quotation mark with no partner: start after the mark, or include the verse that closes it.
- Put references and attributions in `citation` blocks, not in speaker notes alone.
- When the exact installed translation and passage are known, preserve them in a scripture block's `scriptureReference` metadata as well as copying the quotation text.
- Keep titles under 90 characters and ordinary body blocks well below the 700-character validation ceiling.
- Use semantic `ordered` or `unordered` list formatting for concise sequences, with one item per line and no typed-in markers.
- Use speaker notes for delivery prompts, transitions, context, and material intentionally omitted from the screen.
- Do not put complete manuscript paragraphs on slides by default.
- Use semantic layouts and block roles. Do not invent coordinates, font sizes, or unsupported fields. An animation is a video you make with the `render_animation` tool, never a field of the deck.
- Choose one of Lamp's themes from the format reference, and take any highlights from its palette. A `headingTypeface` apart from the body (a serif title over sans text, or the reverse) gives a deck character; keep to two faces. Give a slide its own `backgroundColor` only to set it apart, such as a section break.
- A deck's motion is a slide's `reveal` and `revealsEmphasis`, the deck's `transition`, a picture's `drift` or `video`, and animations made into video; see "Presenting" and "Images" in the format reference. Reveal a slide only where the order of its parts matters to the talk, such as a passage read a verse at a time or a list built point by point. Most slides should arrive whole.
- Use an `image` block only when the referenced asset exists in the workspace and provide meaningful `altText`.
- Prefer public-domain or openly licensed pictures, and keep a note of each one's source and licence beside the deck. Credit a picture that is not openly licensed on its own slide.
- A picture must show what the slide says it shows. Label a simplified illustration as simplified, and do not draw a picture of something whose real form you cannot check — say it in words instead.
- An image is not confined to the `image` layout: put one on a `scripture`, `quotation`, or `title-and-body` slide and it is laid beside the prose. Reserve the `image` layout for a slide the picture itself carries.
- To put a picture behind a whole slide, set `"placement": "background"` on its image block. Do not choose text colours or add a darkening layer: Lamp sets the words to read over the picture. Credit the picture in a `caption` block. Give a cropped background a `focus` on its subject, and consider one `tint` (`duotone` or `muted`) across a deck's pictures so they read as one set; see the format reference. A picture that stays up a while can take `"motion": "drift"`, a slow 3% closing-in while presenting; use it sparingly. A picture can also name a short silent `video` to loop while presenting, keeping its `assetPath` as the still, or a `clip` to play with its sound when the talk reaches it (a file in Assets, or a YouTube or Vimeo address); see the format reference.
- For a moment a still picture cannot carry — a model turning to show its shape, light moving across a scene, a route traced, a structure assembling — make an animation: write a three.js page in `Assets`, render it with `render_animation`, look at the frames it returns, and put the video and still it writes on an image block, behind a slide or beside the words. It is one-off, not a deck style. See "An animation" in the format reference.
- An epigraph belongs on the title slide, not on a slide of its own that the talk opens by reading: a `title` slide draws `scripture` and `quotation` blocks, each with its `citation`, in small type under the heading, where they can be read while the slide waits on screen.
- Put each citation block directly after the quotation it attributes. Passages from different places are separate quotations, each with its own citation; two passages from the same place are one quotation joined with an ellipsis.
- Do not type outer quotation marks, or an ellipsis at the start or end, in a quotation or scripture block — Lamp adds them from the block's role. Do type an ellipsis where you leave words out in the middle.
- To draw key words bold and in colour, list them in the block's `emphasis`, copied exactly from its `text`; never mark them up inside the text. A key detail takes the accent colour. To set ideas or people apart, name a colour for each in the theme's `highlights` and give its name in the entry. Fix every emphasis warning: the deck still imports, but those words are drawn plain.
- A `title` slide can take `"variant": "statement"` for one phrase set large, or `"variant": "word"` for a Hebrew or Greek word with its transliteration and gloss, taken from `analyze_strongs`. A column slide holds up to four columns, and `"variant": "comparison"` marks where translations of one passage differ.
- For a sequence of events, use a `body` block with `"figure": "timeline"`, one `date — event` per line, at most 8. For a longer one, up to 40, add `"zoom": {"span": 4}`: the slide shows the whole timeline, then each click moves in and along a few events, then back out to the whole with the stretch explored marked; `from` and `through` (counted from 1) explore only part of it. For a passage's chiastic or parallel structure, use `"figure": "chiasm"` or `"parallel"`, one member per line, naming each member's verse. These figures draw a reading the writer has made, so present them as the talk's reading, not as something the text states.
- For where things happened, use a `body` block with `"figure": "map"`, one place per line as OpenBible.info names it (look names up with the `find_place` tool), and `"map": {"route": true}` for a journey. Name the one place meant where OpenBible numbers places that share a name (`Antioch 1`, `Antioch 2`). A site OpenBible.info is unsure of is drawn as uncertain and the validator says so: say so in the talk too, or leave it off. Never invent a location.
- On a `two-column` slide, give each column its heading as a `subtitle` block and its source as a `citation` block, and put quoted words in a `quotation` or `scripture` block. Do not type them as extra lines of a `body` block. A headed column can carry more than one attributed passage — a writer's sentence, then the verse that answers him — each with its own citation. An unheaded column ends at its citation.
- Keep a passage together: these layouts draw every quotation and citation block they are given, so there is no need for one verse per slide or a repeated "Source: …" body line.
- For a talk, set `speakerNotesSource` to `manuscript` and give each spoken slide a `notesAnchor`. Do not paste the manuscript into `speakerNotes` yourself: Lamp derives it, and keeps deriving it when the writing is edited later.
- Do not modify `draft.md` unless the user also asked to revise the writing.
- Deliver images in an `Assets` folder beside `presentation.lampdeck`, and reference them as `Assets/name.jpg`. Lamp copies the ones the deck names into the library on import; do not write into the library yourself.
- Treat `presentation-import.json` as Lamp's to write and yours to read.
- **Read `presentation-import.json` before you write `presentation.lampdeck`, not only after.** Slide Studio saves into the library and never touches your file, so the writer's editing is invisible in the workspace. If `studioEdits` is there, rewriting the whole artifact discards every slide it names at the next import. Rewrite only the slides it does not name, or say what it shows and ask.
- Do not write directly into Lamp Bible's library or `.lamp/` metadata directory.

For a minimal conforming artifact, inspect [references/example.lampdeck](references/example.lampdeck).
