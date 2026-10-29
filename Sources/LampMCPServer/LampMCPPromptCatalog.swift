import MCP

/// Lamp's skills, offered as MCP prompts.
///
/// A skill is a folder of Markdown that an agent in a workspace reads off
/// disk. An app like Claude Desktop has no workspace to read, so the same
/// instructions are served over the protocol instead, and a client lists them
/// for the user to pick.
///
/// The steps differ from the workspace skill's in one way, deliberately: they
/// name the `validate_deck`, `build_deck` and `render_deck` tools where the
/// skill shells out to `python3` and the helper's own flags. The authoring
/// rules are the skill's own, because they are about decks and not about how
/// the work is reached.
public enum LampMCPPromptCatalog {
    public static let prompts: [Prompt] = [
        Prompt(
            name: "build-lamp-deck",
            title: "Build a Lamp deck",
            description: """
            Build or revise an accessible Lamp Bible presentation deck from a \
            devotional, writing draft, scripture study, or supplied source \
            material. Use when asked to create slides, a sermon or teaching \
            deck, presentation notes, or a shorter audience-specific variant.
            """,
            arguments: [
                Prompt.Argument(
                    name: "source",
                    description:
                        "The writing or study the deck is built from. Paste the prose itself.",
                    required: false
                ),
                Prompt.Argument(
                    name: "deck",
                    description:
                        "An existing deck's JSON, when revising rather than starting one.",
                    required: false
                ),
            ]
        ),
    ]

    public static func prompt(named name: String) -> Prompt? {
        prompts.first { $0.name == name }
    }

    /// The instructions for a prompt, with whatever the caller supplied.
    public static func messages(
        for name: String,
        arguments: [String: String]?
    ) -> [Prompt.Message]? {
        guard name == "build-lamp-deck" else { return nil }
        var text = buildDeckInstructions
        if let source = arguments?["source"], !source.isEmpty {
            text += "\n\n## The writing this deck is built from\n\n\(source)"
        }
        if let deck = arguments?["deck"], !deck.isEmpty {
            text += """

            ## The deck being revised

            Preserve the deck, slide and block identifiers of everything that \
            survives the revision.

            \(deck)
            """
        }
        return [.user(.text(text: text))]
    }

    /// Mirrors `Resources/AgentSkills/build-lamp-deck/SKILL.md`, with its shell
    /// steps replaced by the tools that do the same work.
    ///
    /// The rules are quoted rather than summarised. A deck built against a
    /// shortened version of them is a deck that imports with warnings nobody
    /// asked for, and the ones about quotation are about misleading a listener,
    /// which is not a detail to compress.
    static let buildDeckInstructions = """
    # Build a Lamp deck

    Produce a complete Lamp deck as JSON. Treat the deck as an accompaniment to \
    the writing, not a replacement for it.

    ## Workflow

    1. Read the source material in full before outlining anything.
    2. Outline one communicative purpose per slide. Prefer a clear narrative arc \
       over mirroring every paragraph of the writing.
    3. Write the complete deck. Use UUIDs for all new identifiers. When revising, \
       preserve the identifiers of content that survives.
    4. Call `validate_deck` with the deck. Fix every error. Review warnings and \
       keep them only where the content genuinely requires the extra density.
    5. Call `build_deck` with the deck, and the manuscript when the deck's \
       `speakerNotesSource` is `manuscript`. It fills in the speaker notes from \
       the manuscript and gives anything new an identifier, and returns the \
       filled-in deck. Running it twice changes nothing. When its report says \
       `resolved` is false, a slide's `notesAnchor` is no longer in the \
       manuscript: it names the slide, and the anchor has to be corrected.
    6. Call `render_deck` and look at the pictures. A format check cannot see a \
       layout, and most layout faults are invisible until something is drawn: a \
       block that will not draw, text shrunk to fit, content running off the \
       slide, a quotation that does not match the installed translation. Act on \
       every `note`. `slidesWithProblems` names the slides that have one, out of \
       the slides the run drew — so a run narrowed with `slides` says nothing \
       about the ones it skipped, and the last run should be a full one.
    7. Hand back the finished deck as JSON.

    ## Authoring rules

    - Preserve the source's theological nuance and intended audience.
    - Quote scripture or another source exactly only when the wording is \
      available; otherwise label the text as a paraphrase. A `scriptureReference` \
      names whole verses, so to show part of a verse, copy its words exactly, \
      leave the reference off, and name the passage in the citation. Keep \
      "paraphrase" for words that are not the translation's.
    - Check a quotation against its source for who it describes and what its \
      author meant, not only for wording. A verse about one group of people, or \
      a sentence its author goes on to reject, misleads a listener even when \
      every word is right.
    - A verse can hold half a quotation. Excerpting a verse that opens a speech \
      closing later, or closes one opened earlier, leaves a quotation mark with \
      no partner: start after the mark, or include the verse that closes it.
    - Put references and attributions in `citation` blocks, not in speaker notes \
      alone, and put each citation directly after the quotation it attributes. \
      Passages from different places are separate quotations, each with its own \
      citation; two passages from the same place are one quotation joined with \
      an ellipsis.
    - Keep titles under 90 characters and ordinary body blocks well below the \
      700-character validation ceiling.
    - Use semantic `ordered` or `unordered` list formatting for concise \
      sequences, with one item per line and no typed-in markers.
    - Use speaker notes for delivery prompts, transitions, context, and material \
      intentionally omitted from the screen. Do not put complete manuscript \
      paragraphs on slides by default.
    - Use semantic layouts and block roles. Do not invent coordinates, font \
      sizes, animations, or unsupported fields.
    - Use an `image` block only when the referenced asset exists beside the deck, \
      and give it meaningful `altText`. Prefer public-domain or openly licensed \
      pictures and keep a note of each one's source and licence. A picture must \
      show what the slide says it shows: label a simplified illustration as \
      simplified, and do not describe a picture of something whose real form you \
      cannot check — say it in words instead.
    - To put a picture behind a whole slide, set `"placement": "background"` on \
      its image block. Do not choose text colours or add a darkening layer: Lamp \
      sets the words to read over the picture. Credit the picture in a `caption` \
      block.
    - An epigraph belongs on the title slide, not on a slide of its own that the \
      talk opens by reading: a `title` slide draws `scripture` and `quotation` \
      blocks, each with its citation, in small type under the heading.
    - Do not type outer quotation marks, or an ellipsis at the start or end, in a \
      quotation or scripture block — Lamp adds them from the block's role. Do \
      type an ellipsis where you leave words out in the middle.
    - To draw key words bold and in colour, list them in the block's `emphasis`, \
      copied exactly from its `text`; never mark them up inside the text. A key \
      detail takes the accent colour. To set ideas or people apart, name a colour \
      for each in the theme's `highlights` and give its name in the entry. Fix \
      every emphasis warning: the deck still imports, but those words are drawn \
      plain.
    - On a `two-column` slide, give each column its heading as a `subtitle` block \
      and its source as a `citation` block, and put quoted words in a `quotation` \
      or `scripture` block rather than as extra lines of a `body` block. A headed \
      column can carry more than one attributed passage, each with its own \
      citation.
    - Keep a passage together: these layouts draw every quotation and citation \
      block they are given, so there is no need for one verse per slide or a \
      repeated "Source: …" body line.
    - For a talk, set `speakerNotesSource` to `manuscript` and give each spoken \
      slide a `notesAnchor`. Do not paste the manuscript into `speakerNotes` \
      yourself: Lamp derives it, and keeps deriving it when the writing is \
      edited later.
    """
}
