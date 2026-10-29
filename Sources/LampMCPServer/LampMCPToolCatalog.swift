import MCP

public enum LampMCPToolCatalog {
    /// The read-only library tools, which every session has.
    public static let tools: [Tool] = [
        tool(
            "list_modules",
            "List the Lamp Bible modules and personal library sources available to this agent.",
            properties: [
                "kinds": arrayOfStrings("Optional module kinds to include."),
            ]
        ),
        tool(
            "search_library",
            "Search across permitted translations, dictionaries, commentaries, books, devotionals, plans, quizzes, notes, and highlights.",
            properties: [
                "query": string("Words or phrase to find."),
                "kinds": arrayOfStrings("Optional module kinds to search."),
                "module_ids": arrayOfStrings("Optional module IDs to search."),
                "limit": integer("Maximum results; Lamp applies its configured upper bound."),
            ],
            required: ["query"]
        ),
        tool(
            "read_passage",
            "Read clean scripture text for a human Bible reference, including ranges that cross chapters.",
            properties: [
                "reference": string("Reference such as John 1:1-3 or John 1:1-2:3."),
                "translation_ids": arrayOfStrings("Optional translation IDs. If omitted, Lamp returns up to three permitted translations."),
                "include_headings": boolean("Include section headings. Defaults to true."),
                "include_annotations": boolean("Include lexical and scripture annotations. Defaults to false."),
            ],
            required: ["reference"]
        ),
        tool(
            "read_commentary",
            "Read commentary units that overlap a scripture reference or range.",
            properties: [
                "reference": string("Human Bible reference."),
                "module_ids": arrayOfStrings("Optional commentary module IDs."),
                "limit": integer("Maximum commentary units."),
            ],
            required: ["reference"]
        ),
        tool(
            "search_dictionary",
            "Search permitted Bible dictionaries and lexicons by word, lemma, transliteration, or definition.",
            properties: [
                "query": string("Word or phrase to find."),
                "module_ids": arrayOfStrings("Optional dictionary module IDs."),
                "limit": integer("Maximum dictionary entries."),
            ],
            required: ["query"]
        ),
        tool(
            "lookup_dictionary_keys",
            "Look up exact Strong's or lexicon keys such as G3056 or H7225.",
            properties: [
                "keys": arrayOfStrings("One or more exact dictionary keys."),
                "module_ids": arrayOfStrings("Optional dictionary module IDs."),
            ],
            required: ["keys"]
        ),
        tool(
            "list_reading_plans",
            "List permitted Lamp reading plans.",
            properties: [:]
        ),
        tool(
            "read_plan_day",
            "Read the scripture ranges assigned to one day of a reading plan.",
            properties: [
                "module_id": string("Reading-plan module ID."),
                "day": integer("One-based plan day."),
            ],
            required: ["module_id", "day"]
        ),
        tool(
            "list_books",
            "List permitted long-form book modules and their publication metadata.",
            properties: [:]
        ),
        tool(
            "list_book_sections",
            "Read the ordered table of contents for one long-form book module.",
            properties: [
                "module_id": string("Book module ID."),
            ],
            required: ["module_id"]
        ),
        tool(
            "read_book_section",
            "Read the complete plain text and scripture links for one long-form book section.",
            properties: [
                "module_id": string("Book module ID."),
                "section_id": string("Section ID returned by search_library or list_book_sections."),
            ],
            required: ["module_id", "section_id"]
        ),
        tool(
            "read_devotional",
            "Read a complete devotional returned by search_library.",
            properties: [
                "module_id": string("Devotional module ID."),
                "devotional_id": string("Devotional entry ID."),
            ],
            required: ["module_id", "devotional_id"]
        ),
        tool(
            "list_quiz_modules",
            "List permitted quiz modules, optionally for one reading plan.",
            properties: [
                "plan_id": string("Optional reading-plan ID."),
            ]
        ),
        tool(
            "read_quiz_questions",
            "Read quiz questions by module and day, optionally narrowed to a passage or age group.",
            properties: [
                "module_id": string("Quiz module ID."),
                "day": integer("One-based quiz day."),
                "reference": string("Optional Bible reference matching the quiz reading."),
                "age_group": string("Optional age-group ID."),
            ],
            required: ["module_id", "day"]
        ),
        tool(
            "read_study_material",
            "Read annotations, footnotes, notes, and highlights for one verse in one translation.",
            properties: [
                "reference": string("A single verse such as John 1:1."),
                "translation_id": string("Translation module ID."),
            ],
            required: ["reference", "translation_id"]
        ),
    ]

    /// Reads the history of the writing this workspace holds.
    ///
    /// Offered only to a session that was given a workspace: there is nothing
    /// to report on without one, and a tool that always answers "no workspace"
    /// is worse than no tool.
    public static let workspaceTools: [Tool] = [
        tool(
            "writing_changes",
            """
            Read what has changed in this workspace's writing, as unified diffs, \
            newest last. Each change says when it happened and whether it came \
            from the editor (the writer) or from an agent. Use this to tell the \
            writer's edits from your own before moving a slide's notes anchor.
            """,
            properties: [
                "since": string(
                    "A change ID from an earlier call, or an ISO 8601 time. "
                        + "Omitted, the most recent changes are returned."
                ),
                "document_path": string(
                    "Which document's history to read, relative to the workspace. "
                        + "Defaults to draft.md, the writing itself."
                ),
                "limit": integer("Maximum changes to return. Defaults to 20."),
                "context": integer(
                    "Unchanged lines to show either side of a change. Defaults to 3."
                ),
            ]
        ),
    ]

    /// Checking, deriving and drawing a deck.
    ///
    /// Offered to every session, workspace or not. The skill that used these
    /// reached them through a shell — a `python3` validator and two flags on
    /// this helper — which an app with no working folder cannot do, and which
    /// was already failing on any Mac without the developer tools installed,
    /// since macOS does not ship `python3`. The deck goes in as text and the
    /// answer comes back as values, so the work is the same wherever it runs.
    public static let deckTools: [Tool] = [
        tool(
            "validate_deck",
            """
            Check a Lamp deck against the rules Lamp applies when it imports \
            one, and return every error and warning with the path it is at. \
            Fix every error; keep a warning only where the content genuinely \
            needs it. This is the same check as the skill's validate_deck.py, \
            and needs no Python.
            """,
            properties: [
                "deck": string("The deck's complete JSON."),
            ],
            required: ["deck"]
        ),
        tool(
            "build_deck",
            """
            Derive what a deck can derive and return the filled-in deck with a \
            report: speaker notes taken from the manuscript for each slide's \
            notesAnchor, and identifiers for anything newly added. Running it \
            twice changes nothing. The report's `resolved` is false when an \
            anchor is no longer in the manuscript, and names the slide.
            """,
            properties: [
                "deck": string("The deck's complete JSON."),
                "manuscript": string(
                    "The writing the talk is given from, as Markdown. Needed "
                        + "for a deck whose speakerNotesSource is manuscript."
                ),
            ],
            required: ["deck"]
        ),
        tool(
            "render_deck",
            """
            Draw the deck's slides and return the pictures with a report. A \
            format check cannot see a layout: a block that will not draw, text \
            shrunk to fit, content running off the slide, and a quotation that \
            does not match the installed translation are all invisible until \
            something is drawn. Look at the pictures, and act on every note.
            """,
            properties: [
                "deck": string("The deck's complete JSON."),
                "manuscript": string("Optional manuscript, for checking a slide's notes anchor."),
                "slides": arrayOfStrings(
                    "Optional slide numbers to draw, such as [\"3\", \"7\"]. A run "
                        + "narrowed this way says nothing about the slides it skipped, "
                        + "so finish on a full run."
                ),
                "width": integer("Pixel width of each slide. Defaults to 1600."),
            ],
            required: ["deck"]
        ),
    ]

    /// Everything a session with a workspace is offered.
    public static func tools(workspace: Bool) -> [Tool] {
        let base = tools + deckTools
        return workspace ? base + workspaceTools : base
    }

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: Value],
        required: [String] = []
    ) -> Tool {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map(Value.string))
        }
        return Tool(
            name: name,
            description: description,
            inputSchema: .object(schema),
            annotations: .init(
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false
            )
        )
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func arrayOfStrings(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "description": .string(description),
            "items": .object(["type": .string("string")]),
        ])
    }
}
