import Foundation
import LampCore
import Testing
@testable import LampBibleMacSupport

/// The form behind the New Reading Plan sheet: what it makes of what was
/// typed, and what it makes of what a model asked for.
///
/// Core does the arithmetic and has its own tests for it. What is checked here
/// is the part a sheet would otherwise hide: that the words on screen become
/// the request they look like.
struct ReadingPlanFormTests {
    private let calendar = LampPlanCalendar.calendar

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    // MARK: - Reading what was typed

    @Test func passagesAreSeparatedByLinesCommasAndSemicolons() {
        #expect(
            LampReadingPlanForm.passages(in: "Matthew–John\nPsalms 1–41, Proverbs; NT")
                == ["Matthew–John", "Psalms 1–41", "Proverbs", "NT"]
        )
    }

    @Test func blankLinesAndStraySpacesAreNotPassages() {
        #expect(LampReadingPlanForm.passages(in: "  \n\n Romans 8 \n,;\n") == ["Romans 8"])
        #expect(LampReadingPlanForm.passages(in: "").isEmpty)
    }

    /// A reference with a colon in it survives the splitting, which is the
    /// whole reason the separators are what they are.
    @Test func averseRangeIsOnePassage() {
        #expect(
            LampReadingPlanForm.passages(in: "Matthew 5:1–7:29") == ["Matthew 5:1–7:29"]
        )
    }

    // MARK: - What the form asks for

    @Test func therequestCarriesTheFormAsItReads() {
        let form = LampReadingPlanForm(
            name: "  The Gospels in a Month  ",
            planDescription: " Matthew to John ",
            tracks: [
                .init(passages: "Matthew–John"),
                .init(passages: "Proverbs", chaptersPerDay: 1),
            ],
            length: .days,
            readingDays: 30,
            start: date(2026, 11, 1),
            restDays: [.saturday, .sunday]
        )

        let request = form.agentRequest()

        #expect(request.name == "The Gospels in a Month")
        #expect(request.description == "Matthew to John")
        #expect(request.tracks.count == 2)
        // Nil, not zero: core reads nil as "spread this over the plan's days".
        #expect(request.tracks[0].chaptersPerDay == nil)
        #expect(request.tracks[1].chaptersPerDay == 1)
        #expect(request.readingDays == 30)
        #expect(request.startDate == "2026-11-01")
        #expect(request.restDays == ["saturday", "sunday"])
    }

    /// A plan whose length is its pace gives core no number of days, which is
    /// what tells core to read until the paced tracks are through.
    @Test func apacedPlanAsksForNoNumberOfDays() throws {
        var form = LampReadingPlanForm(tracks: [.init(passages: "John", chaptersPerDay: 1)])
        form.name = "John a Chapter a Day"
        form.length = .pace

        #expect(form.agentRequest().readingDays == nil)
        #expect(try form.draft().plan.duration == 21, "John has 21 chapters")
    }

    @Test func thegospelsOverThirtyDaysAreLaidOutOnTheirDates() throws {
        var form = LampReadingPlanForm(tracks: [.init(passages: "Matthew–John")])
        form.name = "The Gospels in a Month"
        form.readingDays = 30
        form.start = date(2026, 11, 1)

        let draft = try form.draft()

        #expect(draft.plan.duration == 30)
        #expect(draft.days.count == 30)
        #expect(draft.days[0].date == calendar.startOfDay(for: date(2026, 11, 1)))
        #expect(draft.days[0].number == LampPlanCalendar.dayNumber(for: date(2026, 11, 1)))
        #expect(draft.days[0].readings.first?.startReference == 40_001_001, "Matthew 1:1")
        #expect(draft.days.allSatisfy { !$0.readings.isEmpty })
    }

    /// A hyphen as well as an en dash, because the MCP tools tell an agent to
    /// write "Matthew-John" and someone typing into the sheet will do the same.
    @Test func ahyphenReadsAsARangeOfBooks() throws {
        var form = LampReadingPlanForm(tracks: [.init(passages: "Matthew-John")])
        form.name = "Hyphenated"
        form.readingDays = 10

        #expect(try form.draft().days.count == 10)
    }

    @Test func daysOffAreSteppedOverRatherThanCountedIn() throws {
        var form = LampReadingPlanForm(tracks: [.init(passages: "John")])
        form.name = "Weekdays Only"
        form.readingDays = 10
        form.start = date(2026, 11, 1)
        form.restDays = [.saturday, .sunday]

        let draft = try form.draft()

        #expect(draft.days.count == 10, "still ten readings")
        let weekdays = draft.days.map { calendar.component(.weekday, from: $0.date) }
        #expect(
            !weekdays.contains(LampWeekday.saturday.calendarWeekday),
            "nothing to read on a Saturday"
        )
        #expect(!weekdays.contains(LampWeekday.sunday.calendarWeekday))
    }

    /// Core's refusals are shown as they are, so the sheet never has to word
    /// one. These are the three a form can produce.
    @Test func whatCannotBeLaidOutSaysWhyInCoresWords() {
        var form = LampReadingPlanForm(tracks: [.init(passages: "Matthew–John")])
        form.readingDays = 30
        #expect(throws: LampReadingPlanError.noName) { try form.draft() }

        form.name = "Something"
        form.tracks = [.init(passages: "The Gospel of Thomas")]
        #expect(throws: LampReadingPlanError.unknownPassage("The Gospel of Thomas")) {
            try form.draft()
        }

        form.tracks = [.init(passages: "John")]
        form.length = .pace
        #expect(throws: LampReadingPlanError.noLength, "nothing sets a pace") {
            try form.draft()
        }
    }

    @Test func ablankFormIsNotAWrongOne() {
        #expect(LampReadingPlanForm().isBlank)
        #expect(LampReadingPlanForm(name: "Named").isBlank == false)
        #expect(LampReadingPlanForm(tracks: [.init(passages: "John")]).isBlank == false)
    }

    // MARK: - Filling the form in from what was asked for

    @Test func theformIsFilledInFromWhatAnAgentAskedFor() throws {
        let asked = LampAgentReadingPlanRequest(
            name: "The New Testament with a Psalm a Day",
            description: "Matthew to Revelation, and a psalm beside it.",
            tracks: [
                .init(passages: ["NT"]),
                .init(passages: ["Psalms"], chaptersPerDay: 1),
            ],
            readingDays: 90,
            startDate: "2026-11-01",
            restDays: ["weekends"]
        )

        let form = LampReadingPlanForm.filled(from: asked)

        #expect(form.name == "The New Testament with a Psalm a Day")
        #expect(form.tracks.count == 2)
        #expect(form.tracks[0].passages == "NT")
        #expect(form.tracks[0].chaptersPerDay == 0, "spread, as the form says it")
        #expect(form.tracks[1].chaptersPerDay == 1)
        #expect(form.length == .days)
        #expect(form.readingDays == 90)
        #expect(form.start == calendar.startOfDay(for: date(2026, 11, 1)))
        // Core knows that "weekends" is two days. Nothing here does.
        #expect(form.restDays == [.saturday, .sunday])
        #expect(try form.draft().days.count == 90)
    }

    @Test func noLengthAskedForMeansTheFormShowsAPace() {
        let asked = LampAgentReadingPlanRequest(
            name: "John a Chapter a Day",
            tracks: [.init(passages: ["John"], chaptersPerDay: 1)]
        )

        #expect(LampReadingPlanForm.filled(from: asked).length == .pace)
    }

    /// A passage the model got wrong must not take the rest of its answer with
    /// it: the form opens with everything it asked for, and the preview beside
    /// it says what is wrong.
    @Test func apassageNobodyCanReadStillLeavesTheAnswerOnScreen() {
        let asked = LampAgentReadingPlanRequest(
            name: "The Gospel of Thomas in a Week",
            tracks: [.init(passages: ["The Gospel of Thomas"])],
            readingDays: 7,
            startDate: "2026-11-01",
            restDays: ["weekends"]
        )

        let form = LampReadingPlanForm.filled(from: asked)

        #expect(form.name == "The Gospel of Thomas in a Week")
        #expect(form.tracks[0].passages == "The Gospel of Thomas")
        #expect(form.readingDays == 7)
        #expect(form.start == calendar.startOfDay(for: date(2026, 11, 1)))
        #expect(form.restDays == [.saturday, .sunday])
        #expect(throws: LampReadingPlanError.unknownPassage("The Gospel of Thomas")) {
            try form.draft()
        }
    }

    @Test func atrackPerPassageIsNeverAnEmptyForm() {
        let asked = LampAgentReadingPlanRequest(name: "Nothing", tracks: [])

        #expect(LampReadingPlanForm.filled(from: asked).tracks.count == 1)
    }

    @Test func thedateIsWrittenAsCoreTakesOne() {
        #expect(LampReadingPlanForm.dateText(date(2026, 1, 9)) == "2026-01-09")
    }

    @Test func thedaysOfTheWeekReadInWeekOrder() {
        #expect(LampWeekday.inWeekOrder.first == .sunday)
        #expect(LampWeekday.inWeekOrder.last == .saturday)
        #expect(LampWeekday.wednesday.shortTitle == "Wed")
        #expect(LampWeekday.wednesday.title == "Wednesday")
    }
}

/// Plans another app asked Lamp to add, left in Application Support for Lamp
/// to install.
///
/// The helper is its own process and must not install into the library Lamp
/// has open, so everything about this is the hand-over: where it is written,
/// that it reads back, and that it is forgotten once used.
struct ReadingPlanAdditionTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("lamp-plan-addition-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func addition(_ id: String, askedAt: Date = Date()) -> LampReadingPlanAdditions.Addition {
        LampReadingPlanAdditions.Addition(
            id: id,
            request: LampAgentReadingPlanRequest(
                name: "The Gospels in a Month",
                tracks: [.init(passages: ["Matthew-John"])],
                readingDays: 30,
                startDate: "2026-11-01"
            ),
            askedAt: askedAt
        )
    }

    /// Beside the descriptor, outside the library. A request left in the
    /// library would travel to the user's server and down to their phone as a
    /// side effect of where it was put.
    @Test func itgoesBesideTheDescriptorAndNotIntoTheLibrary() {
        let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support")

        #expect(
            LampReadingPlanAdditions.url(inApplicationSupport: support, id: "plan-1").path
                == "/Users/someone/Library/Application Support/Lamp Bible"
                + "/ReadingPlanAdditions/plan-1.json"
        )
    }

    @Test func awrittenRequestReadsBackAsItself() throws {
        let support = try scratch()
        defer { try? FileManager.default.removeItem(at: support) }

        try LampReadingPlanAdditions.write(addition("plan-1"), inApplicationSupport: support)

        let waiting = LampReadingPlanAdditions.pending(inApplicationSupport: support)
        #expect(waiting.count == 1)
        #expect(waiting.first?.id == "plan-1")
        #expect(waiting.first?.request.startDate == "2026-11-01")
        #expect(waiting.first?.request.tracks.first?.passages == ["Matthew-John"])
    }

    @Test func theyAreInstalledInTheOrderTheyWereAskedFor() throws {
        let support = try scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let now = Date()

        try LampReadingPlanAdditions.write(
            addition("plan-later", askedAt: now), inApplicationSupport: support
        )
        try LampReadingPlanAdditions.write(
            addition("plan-earlier", askedAt: now.addingTimeInterval(-600)),
            inApplicationSupport: support
        )

        #expect(
            LampReadingPlanAdditions.pending(inApplicationSupport: support).map(\.id)
                == ["plan-earlier", "plan-later"]
        )
    }

    @Test func oneThatHasBeenInstalledIsForgotten() throws {
        let support = try scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        try LampReadingPlanAdditions.write(addition("plan-1"), inApplicationSupport: support)

        LampReadingPlanAdditions.forget(id: "plan-1", inApplicationSupport: support)

        #expect(LampReadingPlanAdditions.pending(inApplicationSupport: support).isEmpty)
    }

    @Test func nothingWaitingIsNotAnError() throws {
        let support = try scratch()
        defer { try? FileManager.default.removeItem(at: support) }

        #expect(LampReadingPlanAdditions.pending(inApplicationSupport: support).isEmpty)
        LampReadingPlanAdditions.forget(id: "plan-1", inApplicationSupport: support)
    }

    /// The identifier becomes a file name here and a module ID in the library,
    /// so it is checked rather than cleaned: a request whose identifier had to
    /// be rewritten is not the request that was made.
    @Test func anidentifierThatCouldLeaveTheFolderIsRefused() throws {
        let support = try scratch()
        defer { try? FileManager.default.removeItem(at: support) }

        #expect(LampReadingPlanAdditions.isUsableIdentifier("plan-00000000-0000-0000"))
        #expect(LampReadingPlanAdditions.isUsableIdentifier("../../escape") == false)
        #expect(LampReadingPlanAdditions.isUsableIdentifier("") == false)
        #expect(LampReadingPlanAdditions.isUsableIdentifier("plan 1") == false)
        #expect(throws: LampReadingPlanAdditions.AdditionError.unusableIdentifier("../escape")) {
            try LampReadingPlanAdditions.write(
                addition("../escape"), inApplicationSupport: support
            )
        }
    }

    @Test func rubbishIsLeftAloneRatherThanTakenForARequest() throws {
        let support = try scratch()
        defer { try? FileManager.default.removeItem(at: support) }
        let directory = LampReadingPlanAdditions.directoryURL(inApplicationSupport: support)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rubbish = directory.appendingPathComponent("plan-broken.json")
        try Data("{ not json".utf8).write(to: rubbish)
        try LampReadingPlanAdditions.write(addition("plan-1"), inApplicationSupport: support)

        #expect(LampReadingPlanAdditions.pending(inApplicationSupport: support).map(\.id) == ["plan-1"])
        #expect(
            FileManager.default.fileExists(atPath: rubbish.path),
            "deleting what we could not read is deleting we don't know what"
        )
    }

    // MARK: - Telling the reader

    @Test func thereaderIsToldWhatTurnedUpInTheirLibrary() throws {
        let one = try #require(LampReadingPlanAdditions.summary(added: ["The Gospels"], refused: []))
        #expect(one.contains("The Gospels"))
        #expect(one.contains("another app"))
        #expect(one.contains("Today"))

        let several = try #require(
            LampReadingPlanAdditions.summary(added: ["The Gospels", "Proverbs"], refused: [])
        )
        #expect(several.contains("2 reading plans"))
        #expect(several.contains("Proverbs"))

        let refused = try #require(
            LampReadingPlanAdditions.summary(added: [], refused: ["‘Thomas’ is not a passage."])
        )
        #expect(refused.contains("‘Thomas’ is not a passage."))

        #expect(LampReadingPlanAdditions.summary(added: [], refused: []) == nil)
    }
}

/// The sentence the preview puts under a plan's name: what it reads, how
/// fast, on which days, between which dates.
///
/// Pinned word for word because the phone shows the same sentence from its
/// own copy of the rules (lamp-bible-ios `d005406`,
/// `NewPlanForm.readingWeek` / `trackSummaries`). The wording is the whole
/// point of it: the phone's model answered "the gospels in a month, weekdays
/// only" with a chapter a day on Saturdays, and no screen said so until the
/// plan had been added. Two apps wording it differently would make the next
/// such report hard to place.
struct ReadingPlanSummaryTests {
    private let calendar = LampPlanCalendar.calendar

    private func form(restDays: Set<LampWeekday>) -> LampReadingPlanForm {
        LampReadingPlanForm(restDays: restDays)
    }

    // MARK: - The days of the week

    @Test func noDaysOffReadsAsEveryDay() {
        #expect(form(restDays: []).readingWeek == "every day")
    }

    @Test func mondayToFridayReadsAsWeekdays() {
        #expect(form(restDays: [.saturday, .sunday]).readingWeek == "on weekdays")
    }

    @Test func saturdayAndSundayReadAsWeekends() {
        #expect(
            form(restDays: [.monday, .tuesday, .wednesday, .thursday, .friday]).readingWeek
                == "on weekends"
        )
    }

    /// The case the phone's bug produced. "Only" is not said, on either app.
    @Test func asingleReadingDayIsNamedOnItsOwn() {
        #expect(
            form(restDays: [.sunday, .monday, .tuesday, .wednesday, .thursday, .friday])
                .readingWeek == "on Saturdays"
        )
    }

    /// Sunday first, in `LampWeekday.allCases` order, not the order the rest
    /// days happen to be in.
    @Test func severalDaysAreListedSundayFirst() {
        #expect(
            form(restDays: [.sunday]).readingWeek
                == "on Mondays, Tuesdays, Wednesdays, Thursdays, Fridays, and Saturdays"
        )
    }

    // MARK: - What each track reads

    @Test func anunpacedTrackIsSpreadOverThePlan() {
        let form = LampReadingPlanForm(tracks: [.init(passages: "Matthew–John")])
        #expect(form.trackSummaries == ["Matthew–John, spread over the plan"])
    }

    @Test func apaceOfOneIsAChapterADay() {
        let form = LampReadingPlanForm(tracks: [.init(passages: "Proverbs", chaptersPerDay: 1)])
        #expect(form.trackSummaries == ["Proverbs, a chapter a day"])
    }

    @Test func afasterPaceCountsItsChapters() {
        let form = LampReadingPlanForm(tracks: [.init(passages: "Psalms", chaptersPerDay: 3)])
        #expect(form.trackSummaries == ["Psalms, 3 chapters a day"])
    }

    /// Every track is named, in the order they were typed.
    @Test func atrackWithNothingToReadSaysNothing() {
        let form = LampReadingPlanForm(
            tracks: [
                .init(passages: "Matthew–John"),
                .init(passages: "   "),
                .init(passages: "Proverbs", chaptersPerDay: 1),
            ]
        )
        #expect(
            form.trackSummaries == [
                "Matthew–John, spread over the plan",
                "Proverbs, a chapter a day",
            ]
        )
    }

    // MARK: - The whole sentence

    @Test func thesummaryNamesTheTracksThenTheLengthAndDates() throws {
        var form = LampReadingPlanForm(tracks: [.init(passages: "Matthew–John")])
        form.name = "The Gospels"
        form.readingDays = 20
        form.start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        form.restDays = [.saturday, .sunday]

        let draft = try form.draft()
        let first = draft.days.first!.date.formatted(date: .abbreviated, time: .omitted)
        let last = draft.days.last!.date.formatted(date: .abbreviated, time: .omitted)

        #expect(
            form.summary(of: draft) == """
                Matthew–John, spread over the plan.
                20 days of reading, on weekdays, \(first) to \(last).
                """
        )
    }

    /// Both tracks, each on its own line, before the length line.
    @Test func everyTrackGetsALineOfItsOwn() throws {
        var form = LampReadingPlanForm(
            tracks: [
                .init(passages: "Matthew–John"),
                .init(passages: "Proverbs", chaptersPerDay: 1),
            ]
        )
        form.name = "Two Tracks"
        form.readingDays = 7

        let lines = form.summary(of: try form.draft()).split(separator: "\n")

        #expect(lines.count == 3)
        #expect(lines[0] == "Matthew–John, spread over the plan.")
        #expect(lines[1] == "Proverbs, a chapter a day.")
        #expect(lines[2].hasPrefix("7 days of reading, every day, "))
    }
}
