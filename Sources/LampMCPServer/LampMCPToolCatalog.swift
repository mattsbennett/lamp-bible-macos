import MCP

public enum LampMCPToolCatalog {
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
