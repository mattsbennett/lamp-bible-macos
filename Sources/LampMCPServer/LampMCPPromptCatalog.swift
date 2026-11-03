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
        Prompt(
            name: "sola-scriptura",
            title: "Audit writing against scripture alone",
            description: """
            Tell what scripture establishes from what is inferred from it or \
            brought to it. Use when asked whether a claim, reading or teaching is \
            actually in the text, what a passage does and does not establish, or \
            whether something can be held from scripture alone — and when asked \
            to go through a whole exhortation, sermon, study, talk, devotional or \
            article for proof-text drift, inherited framing, smuggled background, \
            or inference presented as statement.
            """,
            arguments: [
                Prompt.Argument(
                    name: "writing",
                    description: "The piece to audit. Paste the prose itself.",
                    required: false
                ),
                Prompt.Argument(
                    name: "claim",
                    description:
                        "One sentence or claim to adjudicate, instead of auditing a whole piece.",
                    required: false
                ),
            ]
        ),
        Prompt(
            name: "original-languages",
            title: "Read the Hebrew or Greek",
            description: """
            Read the Hebrew or Greek behind an English verse, word by word, and \
            show where a translation reflects a translator's decision rather than \
            the text. Use when asked what a word means in the original, what a \
            verb's tense or stem is, why translations differ at a verse, whether \
            a rendering is fair, or for a word study.
            """,
            arguments: [
                Prompt.Argument(
                    name: "passage",
                    description: "The reference to read, such as Romans 8:3.",
                    required: false
                ),
                Prompt.Argument(
                    name: "question",
                    description: "What is being asked of the passage or the word.",
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
        switch name {
        case "build-lamp-deck": return deckMessages(arguments: arguments)
        case "sola-scriptura": return auditMessages(arguments: arguments)
        case "original-languages": return languageMessages(arguments: arguments)
        default: return nil
        }
    }

    private static func languageMessages(arguments: [String: String]?) -> [Prompt.Message] {
        var text = originalLanguagesInstructions
        if let passage = arguments?["passage"], !passage.isEmpty {
            text += "\n\n## The passage\n\n\(passage)"
        }
        if let question = arguments?["question"], !question.isEmpty {
            text += "\n\n## What is being asked\n\n\(question)"
        }
        return [.user(.text(text: text))]
    }

    private static func auditMessages(arguments: [String: String]?) -> [Prompt.Message] {
        var text = solaScripturaInstructions
        if let claim = arguments?["claim"], !claim.isEmpty {
            text += """

            ## The claim to adjudicate

            Do not inventory a whole piece. Work this one claim, and answer in a \
            paragraph with the text quoted.

            \(claim)
            """
        }
        if let writing = arguments?["writing"], !writing.isEmpty {
            text += "\n\n## The writing to audit\n\n\(writing)"
        }
        return [.user(.text(text: text))]
    }

    private static func deckMessages(arguments: [String: String]?) -> [Prompt.Message] {
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

    /// Mirrors `Resources/AgentSkills/original-languages/SKILL.md`, condensed.
    ///
    /// What it keeps is the part a client cannot work without: which modules
    /// exist, the two calls that do the work, the order to do them in, and the
    /// limits. What it leaves out is the catalogue of word-study fallacies and
    /// the worked example — which make an answer better and are not what makes
    /// one possible.
    static let originalLanguagesInstructions = """
    # Reading the original

    Two jobs, and the honest answer to a great many questions is the second.

    **Read the text**: what the Hebrew or Greek says at a passage, word by word, \
    each with its dictionary form and its parsing. **Show where the English is a \
    decision**: where the translations differ, what each chose, and whether the \
    difference is a translator's judgement or a difference in the text.

    Both are answers to a question about a passage and both end the same way — \
    the evidence, then what of it is a reading — so there is no second output \
    shape to choose between and no audit mode to pick. Given a whole piece of \
    writing instead of a question, the method is the same and only longer: find \
    the claims that rest on the Hebrew or Greek, work each as a question, report \
    per claim quoting the writing's sentence and then the evidence, and rank by \
    what the piece rests on.

    What this does not do is say what a passage means. It reports the form of the \
    words and the range of their senses; a sense in place is chosen by the \
    sentence, not by a lexicon. Where a question needs that judgement, give the \
    evidence and say whose judgement the rest is.

    ## What is there

    Call `list_modules` first. Only these come with Lamp: `TAHOT`, the Hebrew Old \
    Testament in the Leningrad text; `TAGNT`, the Greek New Testament in the \
    Nestlé-Aland text; the Strong's-tagged English translations `KJVs`, `BSBs`, \
    `ASVs`, `WEBs` and `YLT`; and the lexicons `bdb`, `strongs_hebrew`, \
    `strongs_greek` and `dodson_greek`. Anything else listed is the reader's own, \
    and a reader may have none of it. Name what answered.

    ## The two calls that do the work

    `read_passage` with `translation_ids: ["TAGNT"]` or `["TAHOT"]` and \
    `include_annotations: true` returns the original text and, per word, its \
    Strong's key, dictionary form, morphology code and that code read out — \
    `σαρκός G4561 σάρξ Noun · Genitive · Singular · Feminine`. Name more \
    translations in the same call to see the renderings beside the original.

    `analyze_strongs` with a `key` reports, for every translation that tags the \
    word, how its translators rendered it and how often. That turns "this \
    translation is interpretive here" into a count: σάρξ is "flesh" in 136 of \
    ASV's 136 occurrences and in 84 of the Berean's 127. `TAGNT`'s own row lists \
    Greek forms rather than renderings, there being nothing to render, so it is \
    the control for how often the word occurs at all.

    Also: `lookup_dictionary_keys` for a word's range, quoted and named; \
    `search_library` with `strongs_key` for every verse tagged with a key; \
    `read_study_material` for a translation's own notes on a verse.

    ## The order to work in

    1. Read the passage in the original before any lexicon. The sentence decides \
       a sense, and a word study begun at the lexicon tends to end there.
    2. Read it in every translation the library has. Where they agree there is \
       usually nothing to explain.
    3. For a word that matters, take its parsing from the passage and its range \
       from a lexicon, named.
    4. Where the translations differ, measure it, and ask whether this \
       translation is doing here what it does everywhere.
    5. Report the evidence — the text, the modules, the counts — and then say \
       plainly which part is a reading rather than a datum.

    ## Four kinds of difference

    A **different text** (rule this out first: a word absent from `TAGNT` is \
    absent because the critical text omits it). A **different sense within the \
    range**, which is the commonest and the least worth dramatising. A \
    **different reading of the grammar**, which the parsing cannot settle. An \
    **interpretive rendering**, often admitted in the translation's own notes.

    ## What a parsing settles

    The form: whether a verb is perfect or participle, whether a noun is plural. \
    Not the meaning. A tense is not a timeline, a Hebrew stem is not a \
    definition, a construct chain or a genitive is a grammatical bond and not a \
    claim, and a grammatical gender is not about people.

    Hebrew verbs carry a **stem** — Qal, Niphal, Piel, Hiphil and the rest — \
    which shapes the action as simple, passive, intensive or causative and is \
    worth reporting when it is the point. Nouns carry a **state**, of which \
    construct is the one to watch. A word of several morphemes is written with \
    `/`, and the parsing given is the content morpheme's, because that is the \
    word the key belongs to.

    ## What is not here, and must not be implied

    No running text but those two, so variants, Qere readings and \
    Textus-Receptus-only words are not available. No textual apparatus: you \
    cannot say which manuscripts read what. No syntax beyond the word — nothing \
    marks clauses or dependencies, and word order may be described but a claim \
    about what it does is a reading. No Hebrew morphology in `KJVs`, which tags \
    with CrossWire's numeric codes that Lamp does not read. Renderings are \
    translators' choices and not a word's range. And Strong's glosses are an \
    index of how the KJV rendered words, not a lexicon: read `bdb` or \
    `dodson_greek` for range.

    Where a question needs something on that list, say so. A plausible answer \
    assembled without the evidence is the one thing this is meant to prevent.
    """

    /// Mirrors `Resources/AgentSkills/sola-scriptura/SKILL.md`, condensed.
    ///
    /// The skill is a folder: a procedure and five reference files an agent
    /// opens as it needs them. A client calling a prompt gets one message and
    /// no folder, so this carries the parts an audit cannot be run without —
    /// the one authority, the verdicts, the load axis, the report contract, and
    /// the rules that stop it flagging figures of speech. What it leaves out is
    /// the catalogue of failure patterns and the worked example, which make an
    /// audit better and are not what makes it possible.
    ///
    /// `SolaScripturaPromptTests` holds the two to the same verdicts and loads,
    /// so neither can be renamed without the other.
    static let solaScripturaInstructions = """
    # Sola scriptura

    Check whether a claim stands on scripture, with the text in front of you. \
    You are not anyone's doctrinal opponent and not their editor. Everything you \
    report is about evidence: *this is not established by the text you cite*. \
    Never *this is wrong*.

    Two jobs, and what you are given decides which; neither is the default. \
    **Adjudicate** when the question is about a claim, a sentence or a passage: \
    work that claim alone and answer in a paragraph or two with the text quoted, \
    with no tables and no inventory of something nobody gave you. Most questions \
    take this shape. **Audit** when you are given a piece of writing to go \
    through: work the whole of what follows and report to the contract at the \
    end. The rules below serve both.

    ## The one authority

    Measure claims against the text of scripture and nothing else. Not against \
    a creed, a confession or a statement of faith; not against any commentary, \
    lexicon or book in the library, including the ones the writer's own \
    community wrote; not against what the writer has held before; not against \
    scholarly consensus.

    A claim that agrees with the writer's tradition is not thereby established. \
    A claim that cuts against it is not thereby refuted. The whole value of \
    this audit is that it will tell the writer when something they believe is \
    not in the text they cite, and nothing else they have will do that. So flag \
    the comfortable claims too — those are the findings worth having.

    Where a community has a rule about *wording* — which terms its writing uses \
    for a doctrine — that is a separate gate. Note an intersection in a clause \
    and keep the two apart.

    ## Nothing is answered from memory

    Verse wording, who said what, what a word covers, whether a phrase occurs \
    anywhere: look all of it up, every time, including the verses you are sure \
    of. Your recall of scripture is good enough to be dangerous and not good \
    enough to audit with.

    Call `list_modules` first, because what you can check depends on what this \
    reader has. Only these come with Lamp: translations `KJVs`, `BSBs`, `ASVs`, \
    `WEBs` and `YLT`, all carrying Strong's numbers; the cross-reference \
    indexes `tske` and `crossrefs`; and the lexicons `bdb`, `strongs_hebrew`, \
    `strongs_greek` and `dodson_greek`. Everything else listed is the reader's \
    own. Read passages with `read_passage`, naming **every** translation you \
    mean to compare, since it returns three by default and that is how a claim \
    resting on one wording stays hidden.

    A cross-reference index is human work: it finds candidate texts and \
    establishes nothing. A lexicon is evidence about a word, never about a \
    claim. A commentary or book can never carry a claim, so do not open one to \
    find out what a passage means — having read a commentator first, you will \
    measure the writer against that reading and call a different one \
    unsupported. Open one only when the writing uses it, to check that the \
    source says what the writing says it does, or to trace where an \
    unattributed framing came from.

    ## Verdict and load

    Each claim gets both. The verdict says what it rests on:

    - **Stated** — scripture asserts it and the quoted text carries it. Report \
      only when the writing cites it to the wrong place.
    - **Entailed** — follows from stated texts by an argument writable in a line \
      or two, adding no premise from outside scripture.
    - **Inferred** — the text permits it, and permits something else. Report \
      when the writing gives no sign a reading was chosen. The remedy is almost \
      always to mark it, not to drop it.
    - **Imported** — a premise comes from outside scripture: a creed, a \
      commentator, a lexicon, received practice, consensus, background, or an \
      idea so common it feels scriptural. Always report.
    - **Unsupported** — no text establishes it and none is offered.
    - **Contrary** — the cited or governing text tells against it. Report first, \
      quote the text, and do not argue the doctrine.

    To tell entailed from inferred, write the argument out as premises and look \
    for the premise you added. If every premise is a text you can quote it is \
    entailed; if one is something you know rather than read, that premise is \
    the finding, and naming it is the most useful sentence you will write.

    The load says how much falls over without it: **load-bearing** (the \
    conclusion, or a step it needs), **supporting** (strengthens a point that \
    survives without it), **decorative** (colour, illustration, an aside). \
    Judge it from the chain of claims, not from how emphatic the sentence is — \
    writers state load-bearing premises quietly and decorations with force.

    ## What not to flag

    Scripture's own words, however much has been built on them — the finding \
    would be a gloss adding a mechanism the words do not state, never the \
    words. Pastoral application in the writer's own voice. Figures of speech \
    and rhetorical questions. Hedged inference, which the writer has already \
    marked. A named source, whose naming remedies the dependence — though not \
    whether the source says that. Literary observation that is checkable in the \
    text. Quoting one translation, as against a claim that depends on one. A \
    community's wording rule. Prose quality. Whether the doctrine is true.

    One finding per problem: if the same drift appears eight times, write it \
    once and list the rest in a line. And if every remedy you reach for is a \
    hedge, the audit is a bad one — writing that hedges everything asserts \
    nothing.

    ## How to work

    1. Read the whole piece once. Write its thesis in a sentence, then the \
       chain of claims carrying it. You cannot judge what a claim holds up \
       until you can see the chain.
    2. Inventory the claims doing doctrinal or factual work — not every \
       sentence.
    3. Verify every citation. Look each reference up verbatim, then ask the \
       only question that matters: does this text carry the weight the claim \
       puts on it? Proof-text drift is the commonest finding by a wide margin.
    4. For each uncited load-bearing claim, find the text it would need. \
       Cross-reference the passage, search for the phrase, and look up what you \
       find. If nothing carries it, that is the finding.
    5. Adjudicate each as verdict × load.
    6. Try to defeat each finding before reporting it. Is there another text \
       that carries the claim — did you check it? Did the writer already mark \
       it as an inference? Run this evenly: it is where an audit goes soft, \
       because a claim the writing takes for granted feels defended when it is \
       only familiar. A finding survives on whether a text carries it, and on \
       nothing about how settled it sounds or whose position it is.
    7. Report.

    ## Answering one question

    For an adjudication the report contract is the wrong shape, being built for \
    a pass over many claims. Say which verdict the claim takes and why, quote \
    the text you consulted and name its module, and give the remedy if there is \
    one. Where scripture permits the reading and permits another, say so: it is \
    a real answer and often the most useful, because it tells the reader the \
    question is not settled by the text. Where the claim is established, say so \
    plainly and point at what establishes it — a reader who only ever hears what \
    fails will not trust the answer when something holds. The evidence rule \
    stands: an adjudication with no text quoted is an opinion, whatever its \
    verdict.

    ## Reporting an audit

    Rank by load, not by how wrong something is. Every load-bearing finding \
    gets an entry; supporting ones when they change what a reader would \
    conclude; decorative ones a single closing list, one line each.

    **No finding without a quotation.** If you cannot show the text that fails \
    to carry the claim, you have a suspicion rather than a finding, and it \
    stays out.

    Each entry carries four things and stops: the sentence from the writing, \
    quoted; the text consulted, quoted verbatim and named with its module; the \
    gap in a sentence, being what the claim needs that the text does not give; \
    and the smallest remedy that makes it honest — cite the text that does \
    carry it, mark it as inference, or drop the load.

    Open with how many claims were inventoried and which modules answered, and \
    a sentence on the piece's thesis. Close with what the pass did not do: what \
    you could not check, which claims rest on a text no available module \
    carried, and what a second pass should look at. That section is part of the \
    finding, not a disclaimer — an audit that hides its own gaps is the thing \
    this one was written to catch.
    """

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
