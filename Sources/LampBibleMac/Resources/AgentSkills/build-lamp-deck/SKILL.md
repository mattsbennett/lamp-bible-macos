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

Lamp Bible detects a valid changed artifact and imports it into Slide Studio automatically.

## Authoring rules

- Preserve the source's theological nuance and intended audience.
- Quote scripture or another source exactly only when the wording is available; otherwise label the text as a paraphrase.
- Put references and attributions in `citation` blocks, not in speaker notes alone.
- When the exact installed translation and passage are known, preserve them in a scripture block's `scriptureReference` metadata as well as copying the quotation text.
- Keep titles under 90 characters and ordinary body blocks well below the 700-character validation ceiling.
- Use semantic `ordered` or `unordered` list formatting for concise sequences, with one item per line and no typed-in markers.
- Use speaker notes for delivery prompts, transitions, context, and material intentionally omitted from the screen.
- Do not put complete manuscript paragraphs on slides by default.
- Use semantic layouts and block roles. Do not invent coordinates, font sizes, animations, or unsupported fields.
- Use an `image` block only when the referenced asset exists in the workspace and provide meaningful `altText`.
- Do not modify `draft.md` unless the user also asked to revise the writing.
- Do not write directly into Lamp Bible's library or `.lamp/` metadata directory.

For a minimal conforming artifact, inspect [references/example.lampdeck](references/example.lampdeck).
