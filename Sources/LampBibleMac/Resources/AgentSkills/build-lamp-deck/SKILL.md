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
5. Validate the artifact:

   ```sh
   python3 .agents/skills/build-lamp-deck/scripts/validate_deck.py presentation.lampdeck
   ```

6. Fix every reported error. Review warnings and retain them only when the content genuinely requires the extra density.
7. Derive what Lamp can derive. For a talk, this fills in the speaker notes and gives any new slide or block a UUID:

   ```sh
   "$HELPER" --build-deck presentation.lampdeck --manuscript draft.md
   ```

   Lamp derives these notes by itself on every save; this writes the same notes into your copy of the deck, assigns any missing IDs, and reports what it could not do. It exits non-zero when an anchor is no longer in the manuscript, and names the slide — under that slide's entry in `slides`, and by number in the top-level `slidesWithProblems`. Running it twice changes nothing.
8. Look at the slides. The validator cannot see a layout, and most layout mistakes are invisible until something is drawn:

   ```sh
   HELPER=$(python3 -c "import json;print(json.load(open('.mcp.json'))['mcpServers']['lamp']['command'])")
   "$HELPER" --render-deck presentation.lampdeck --output presentation-preview      --library-root "$(python3 -c "import json;a=json.load(open('.mcp.json'))['mcpServers']['lamp']['args'];print(a[a.index('--library-root')+1])")" \
     --manuscript draft.md
   ```

   This writes one PNG per slide and prints a report. View the PNGs. Act on every `note`: a block the layout will not draw, text shrunk to fit, content running off the slide, and — when a scripture block carries a `scriptureReference` and `--library-root` is given — a quotation that does not match the installed translation. The top-level `slidesWithProblems` names the slides that have one, out of the slides this run drew. Add `--slides 3,7` to redraw just the ones you changed — remembering that a run narrowed that way can say nothing about the slides it skipped, so finish on a full run. `--overview presentation-preview/overview.jpg` tiles whatever was drawn into one numbered image, which is the way to review a run of slides together.
9. Read `presentation-import.json` to confirm Lamp took the deck. Lamp writes it each time it looks at the artifact, and amends its `speakerNotes` whenever the writing is saved — so after the writer edits the prose, this is where a broken anchor appears, with the slide named.

   When the writer has edited while you worked, `writing_changes` shows what they changed, as diffs, so you need not keep copies of `draft.md` to compare. What a slide *summarises* is not checked by anything: after a passage changes, read the slides that stood on it.

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
- Use semantic layouts and block roles. Do not invent coordinates, font sizes, animations, or unsupported fields.
- Use an `image` block only when the referenced asset exists in the workspace and provide meaningful `altText`.
- Prefer public-domain or openly licensed pictures, and keep a note of each one's source and licence beside the deck. Credit a picture that is not openly licensed on its own slide.
- A picture must show what the slide says it shows. Label a simplified illustration as simplified, and do not draw a picture of something whose real form you cannot check — say it in words instead.
- An image is not confined to the `image` layout: put one on a `scripture`, `quotation`, or `title-and-body` slide and it is laid beside the prose. Reserve the `image` layout for a slide the picture itself carries.
- To put a picture behind a whole slide, set `"placement": "background"` on its image block. Do not choose text colours or add a darkening layer: Lamp sets the words to read over the picture. Credit the picture in a `caption` block.
- Put each citation block directly after the quotation it attributes. Passages from different places are separate quotations, each with its own citation; two passages from the same place are one quotation joined with an ellipsis.
- Do not type outer quotation marks, or an ellipsis at the start or end, in a quotation or scripture block — Lamp adds them from the block's role. Do type an ellipsis where you leave words out in the middle.
- On a `two-column` slide, give each column its heading as a `subtitle` block and its source as a `citation` block, and put quoted words in a `quotation` or `scripture` block. Do not type them as extra lines of a `body` block. A headed column can carry more than one attributed passage — a writer's sentence, then the verse that answers him — each with its own citation. An unheaded column ends at its citation.
- Keep a passage together: these layouts draw every quotation and citation block they are given, so there is no need for one verse per slide or a repeated "Source: …" body line.
- For a talk, set `speakerNotesSource` to `manuscript` and give each spoken slide a `notesAnchor`. Do not paste the manuscript into `speakerNotes` yourself: Lamp derives it, and keeps deriving it when the writing is edited later.
- Do not modify `draft.md` unless the user also asked to revise the writing.
- Deliver images in an `Assets` folder beside `presentation.lampdeck`, and reference them as `Assets/name.jpg`. Lamp copies the ones the deck names into the library on import; do not write into the library yourself.
- Treat `presentation-import.json` as Lamp's to write and yours to read.
- Do not write directly into Lamp Bible's library or `.lamp/` metadata directory.

For a minimal conforming artifact, inspect [references/example.lampdeck](references/example.lampdeck).
