import Foundation
import LampCore

/// What the New Reading Plan sheet collects, and the request it makes.
///
/// Here rather than in the sheet because this is the part with rules in it:
/// how a line of typed passages is read, which of the two ways a plan's length
/// can be decided, and how a form is filled in from what an agent or the
/// on-device model asked for. A view can only be checked by looking at it.
///
/// None of the arithmetic is here. The form says what to read and how fast, in
/// the same words `LampAgentReadingPlanRequest` takes, and core lays out the
/// days — so a plan made in this sheet, by a tool, or from a description is
/// laid out once and the same way.
public struct LampReadingPlanForm: Equatable, Sendable {
    /// One of the things read side by side: every reading day has a portion
    /// of each track.
    public struct Track: Identifiable, Equatable, Sendable {
        public var id: UUID
        /// Passages as people write them — "Matthew–John", "Psalms 1–41",
        /// "NT", "Romans 8" — separated by new lines, commas or semicolons.
        public var passages: String
        /// Whole chapters a day, starting over when the passages are read, so
        /// a short track such as Proverbs can run beside a long one. Zero
        /// spreads the passages over the plan's days instead.
        public var chaptersPerDay: Int

        public init(id: UUID = UUID(), passages: String = "", chaptersPerDay: Int = 0) {
            self.id = id
            self.passages = passages
            self.chaptersPerDay = chaptersPerDay
        }

        /// The passages one at a time, in the order they were typed.
        public var passageList: [String] {
            LampReadingPlanForm.passages(in: passages)
        }
    }

    /// What decides how long the plan is. Core takes either, and the form has
    /// to ask which, because the two mean different things: a number of days
    /// spreads the reading to fit, a pace lets the reading decide the days.
    public enum Length: String, CaseIterable, Identifiable, Sendable {
        /// A set number of reading days. An unpaced track is spread over them.
        case days
        /// However long the paced tracks take to be read once through.
        case pace

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .days: "Over a number of days"
            case .pace: "Until it has been read once"
            }
        }
    }

    public var name: String
    /// Named so as not to shadow `description`; it is the plan's own
    /// description, the sentence shown under its name.
    public var planDescription: String
    public var tracks: [Track]
    public var length: Length
    /// How many days have a reading, when `length` is `.days`.
    public var readingDays: Int
    public var start: Date
    public var restDays: Set<LampWeekday>

    public init(
        name: String = "",
        planDescription: String = "",
        tracks: [Track] = [Track()],
        length: Length = .days,
        readingDays: Int = 30,
        start: Date = Date(),
        restDays: Set<LampWeekday> = []
    ) {
        self.name = name
        self.planDescription = planDescription
        self.tracks = tracks
        self.length = length
        self.readingDays = readingDays
        self.start = start
        self.restDays = restDays
    }

    /// Nothing has been asked for yet: no name and nothing to read.
    ///
    /// The difference between a form nobody has filled in and one that is
    /// wrong. Both fail to lay out, and only one of them is worth saying so
    /// about.
    public var isBlank: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && tracks.allSatisfy { $0.passageList.isEmpty }
    }

    /// Passages as typed, read as a list.
    ///
    /// New lines, commas and semicolons all separate, because people type all
    /// three and a passage Lamp can read never contains one: its ranges are
    /// dashes and its verses colons.
    public static func passages(in text: String) -> [String] {
        text
            .split(whereSeparator: { $0.isNewline || $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What the plan asks for, in the words core takes from a form, a tool and
    /// the on-device model alike.
    ///
    /// A track reading no chapters a day is one to spread, which core says
    /// with nil rather than zero.
    public func agentRequest() -> LampAgentReadingPlanRequest {
        LampAgentReadingPlanRequest(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            description: planDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            tracks: tracks.map {
                .init(
                    passages: $0.passageList,
                    chaptersPerDay: $0.chaptersPerDay > 0 ? $0.chaptersPerDay : nil
                )
            },
            readingDays: length == .days ? readingDays : nil,
            startDate: Self.dateText(start),
            restDays: restDays.map(\.rawValue).sorted()
        )
    }

    /// The plan laid out on its dates, or the reason it cannot be.
    ///
    /// Every refusal is a `LampReadingPlanError`, whose messages core writes
    /// to be shown as they are, so the sheet never has to word one itself.
    public func draft(
        id: String = UUID().uuidString,
        today: Date = Date(),
        calendar: Calendar = LampPlanCalendar.calendar
    ) throws -> LampReadingPlanDraft {
        try agentRequest()
            .request(today: today, calendar: calendar)
            .draft(id: id, calendar: calendar)
    }

    /// The form filled in from what an agent or the on-device model asked for,
    /// for the reader to look over and change before anything is added.
    ///
    /// Everything that can be filled in is, even when the whole request will
    /// not convert: a passage the model got wrong should leave the rest of its
    /// answer on screen to be corrected, not an empty form.
    public static func filled(
        from request: LampAgentReadingPlanRequest,
        today: Date = Date(),
        calendar: Calendar = LampPlanCalendar.calendar
    ) -> LampReadingPlanForm {
        let when = Self.when(request, today: today, calendar: calendar)
        return LampReadingPlanForm(
            name: request.name,
            planDescription: request.description ?? "",
            tracks: request.tracks.isEmpty
                ? [Track()]
                : request.tracks.map {
                    Track(
                        passages: $0.passages.joined(separator: "\n"),
                        chaptersPerDay: $0.chaptersPerDay ?? 0
                    )
                },
            length: request.readingDays == nil ? .pace : .days,
            readingDays: request.readingDays ?? 30,
            start: when.start,
            restDays: when.restDays
        )
    }

    /// The start date and rest days as core reads them.
    ///
    /// Core's own conversion rather than a second parser here: "weekends"
    /// means two days, and one place should know that. It is asked of a copy
    /// whose passages are known-good, so a passage the model got wrong does
    /// not also cost the date it got right. A date core cannot read becomes
    /// today, which the form then shows and the reader can correct.
    private static func when(
        _ request: LampAgentReadingPlanRequest,
        today: Date,
        calendar: Calendar
    ) -> (start: Date, restDays: Set<LampWeekday>) {
        var readable = request
        readable.tracks = [.init(passages: ["Genesis"])]
        guard let converted = try? readable.request(today: today, calendar: calendar) else {
            return (calendar.startOfDay(for: today), [])
        }
        return (converted.start, converted.restDays)
    }

    /// Year-month-day, as core takes a start date.
    public static func dateText(_ date: Date, calendar: Calendar = LampPlanCalendar.calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

extension LampWeekday {
    /// The day's name as a form lists it.
    public var title: String {
        rawValue.capitalized
    }

    /// The first three letters, for a row of seven.
    public var shortTitle: String {
        String(rawValue.prefix(3)).capitalized
    }

    /// Sunday first, as a week is shown.
    public static var inWeekOrder: [LampWeekday] {
        allCases.sorted { $0.calendarWeekday < $1.calendarWeekday }
    }
}

/// A reading plan another app has asked Lamp to add, left where Lamp will find
/// it.
///
/// `add_reading_plan` runs in `lamp-mcp`, which is its own process, and Lamp
/// has the library open. Rather than have two processes install a module into
/// one library, the helper writes down what was asked for and Lamp installs
/// it: when it next reads its library, or when a plans view is opened.
///
/// Beside the descriptor in Application Support, deliberately outside the
/// library, for the reason a writing's note is: the library syncs, and a
/// request left in it would travel to the user's server and down to their
/// phone as a side effect of where it was put.
public enum LampReadingPlanAdditions {
    public static let directoryName = "ReadingPlanAdditions"

    public struct Addition: Codable, Equatable, Identifiable, Sendable {
        /// The identifier the plan will be installed under, chosen when the
        /// plan was asked for so the tool could name it in its reply.
        public let id: String
        /// What was asked for, its start date filled in. Lamp lays the plan
        /// out when it installs it, which may be hours later, and a plan asked
        /// for "today" must start on the day it was asked for rather than the
        /// day Lamp next opened.
        public let request: LampAgentReadingPlanRequest
        public let askedAt: Date

        public init(id: String, request: LampAgentReadingPlanRequest, askedAt: Date = Date()) {
            self.id = id
            self.request = request
            self.askedAt = askedAt
        }
    }

    public enum AdditionError: Error, LocalizedError, Equatable {
        case unusableIdentifier(String)

        public var errorDescription: String? {
            switch self {
            case .unusableIdentifier(let id):
                "‘\(id)’ cannot be a plan's identifier: use letters, digits, dashes and underscores."
            }
        }
    }

    public static func directoryURL(inApplicationSupport root: URL) -> URL {
        LampAgentDescriptorStore.directoryURL(inApplicationSupport: root)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    public static func url(inApplicationSupport root: URL, id: String) -> URL {
        directoryURL(inApplicationSupport: root).appendingPathComponent("\(id).json")
    }

    /// An identifier that is safe both as a file name here and as a module ID
    /// in the library. Checked rather than cleaned: a request whose identifier
    /// had to be rewritten is not the request that was made.
    public static func isUsableIdentifier(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_")
        }
    }

    @discardableResult
    public static func write(
        _ addition: Addition,
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard isUsableIdentifier(addition.id) else {
            throw AdditionError.unusableIdentifier(addition.id)
        }
        let destination = url(inApplicationSupport: root, id: addition.id)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(addition).write(to: destination, options: .atomic)
        return destination
    }

    /// The plans waiting to be added, oldest first, so they are installed in
    /// the order they were asked for.
    ///
    /// A file that cannot be read is left alone rather than deleted: it is a
    /// few hundred bytes, and throwing away something we could not read is
    /// throwing away we don't know what.
    public static func pending(
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) -> [Addition] {
        let directory = directoryURL(inApplicationSupport: root)
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return names
            .filter { $0.hasSuffix(".json") }
            .compactMap { name in
                guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else {
                    return nil
                }
                return try? decoder.decode(Addition.self, from: data)
            }
            .sorted { $0.askedAt < $1.askedAt }
    }

    public static func forget(
        id: String,
        inApplicationSupport root: URL,
        fileManager: FileManager = .default
    ) {
        guard isUsableIdentifier(id) else { return }
        try? fileManager.removeItem(at: url(inApplicationSupport: root, id: id))
    }

    /// What to tell the reader about the plans another app asked for, or nil
    /// when there is nothing to say.
    ///
    /// A plan appearing in the library on its own is the kind of thing someone
    /// should be told about, even though they asked for it in another app: the
    /// asking happened somewhere else, and Lamp is where the plan turns up.
    public static func summary(added: [String], refused: [String]) -> String? {
        var sentences: [String] = []
        if added.count == 1 {
            sentences.append(
                "Added the reading plan \u{201C}\(added[0])\u{201D}, asked for in another app, "
                    + "and included it in Today."
            )
        } else if added.count > 1 {
            sentences.append(
                "Added \(added.count) reading plans asked for in other apps, and included "
                    + "them in Today: \(added.joined(separator: ", "))."
            )
        }
        sentences.append(contentsOf: refused.map {
            "A reading plan asked for in another app could not be made. \($0)"
        })
        return sentences.isEmpty ? nil : sentences.joined(separator: " ")
    }
}
