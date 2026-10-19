import Foundation

/// A unified diff between two versions of a document.
///
/// An agent is told that `draft.md` changed on disk, but not what changed —
/// so to tell the writer's edits from its own before moving a slide's anchor it
/// kept private copies of the draft and compared them itself. Lamp already has
/// the revisions; this is how they are handed over.
public enum LampUnifiedDiff {
    /// Lines either side of a change, so a hunk can be read in context.
    public static let defaultContext = 3

    /// Past this many changed lines the diff stops being worth computing
    /// exactly: the answer is "this was rewritten", and a line-by-line edit
    /// script of a whole rewritten document is neither cheap nor useful.
    static let exactLimit = 4_000

    /// A unified diff of `before` into `after`, or an empty string when they
    /// are the same.
    public static func diff(
        before: String,
        after: String,
        beforeLabel: String = "before",
        afterLabel: String = "after",
        context: Int = defaultContext
    ) -> String {
        guard before != after else { return "" }
        let hunks = hunks(
            before: lines(of: before),
            after: lines(of: after),
            context: max(context, 0)
        )
        guard !hunks.isEmpty else { return "" }
        return (["--- \(beforeLabel)", "+++ \(afterLabel)"] + hunks).joined(separator: "\n")
    }

    /// Splits into lines without inventing a trailing empty one, so a document
    /// that ends in a newline does not read as having a blank last line.
    static func lines(of text: String) -> [String] {
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    // MARK: - Hunks

    private enum Edit {
        case same(String)
        case removed(String)
        case added(String)
    }

    private static func hunks(
        before: [String],
        after: [String],
        context: Int
    ) -> [String] {
        let script = editScript(before: before, after: after)
        var hunks: [String] = []
        var body: [String] = []
        var beforeStart = 0
        var afterStart = 0
        var beforeCount = 0
        var afterCount = 0
        var beforeLine = 1
        var afterLine = 1
        /// Unchanged lines held back: they become the context after a change,
        /// or are dropped if no further change follows.
        var trailing: [(String, Int, Int)] = []

        func flush() {
            guard !body.isEmpty else { return }
            hunks.append(
                "@@ -\(beforeStart),\(beforeCount) +\(afterStart),\(afterCount) @@\n"
                    + body.joined(separator: "\n")
            )
            body = []
            beforeCount = 0
            afterCount = 0
        }

        for edit in script {
            switch edit {
            case .same(let line):
                if body.isEmpty {
                    // Before any change: remember the last `context` lines.
                    trailing.append((line, beforeLine, afterLine))
                    if trailing.count > context { trailing.removeFirst() }
                } else {
                    trailing.append((line, beforeLine, afterLine))
                    if trailing.count > context * 2 {
                        // Enough unchanged lines to close this hunk: keep
                        // `context` of them and start again at the next change.
                        for (held, _, _) in trailing.prefix(context) {
                            body.append(" \(held)")
                            beforeCount += 1
                            afterCount += 1
                        }
                        trailing.removeFirst(context)
                        flush()
                        trailing = Array(trailing.suffix(context))
                    }
                }
                beforeLine += 1
                afterLine += 1
            case .removed(let line), .added(let line):
                if body.isEmpty {
                    beforeStart = max(trailing.first?.1 ?? beforeLine, 1)
                    afterStart = max(trailing.first?.2 ?? afterLine, 1)
                }
                for (held, _, _) in trailing {
                    body.append(" \(held)")
                    beforeCount += 1
                    afterCount += 1
                }
                trailing = []
                if case .removed = edit {
                    body.append("-\(line)")
                    beforeCount += 1
                    beforeLine += 1
                } else {
                    body.append("+\(line)")
                    afterCount += 1
                    afterLine += 1
                }
            }
        }
        if !body.isEmpty {
            for (held, _, _) in trailing.prefix(context) {
                body.append(" \(held)")
                beforeCount += 1
                afterCount += 1
            }
            flush()
        }
        return hunks
    }

    // MARK: - Edit script

    /// Turns `before` into `after` as a run of kept, removed and added lines.
    ///
    /// The ends are trimmed first, because an edit is nearly always local: a
    /// changed sentence in a long talk leaves a handful of lines to compare
    /// rather than thousands. Only what is left is matched line by line.
    private static func editScript(before: [String], after: [String]) -> [Edit] {
        var prefix = 0
        while prefix < before.count, prefix < after.count, before[prefix] == after[prefix] {
            prefix += 1
        }
        var suffix = 0
        while suffix < before.count - prefix,
              suffix < after.count - prefix,
              before[before.count - 1 - suffix] == after[after.count - 1 - suffix] {
            suffix += 1
        }

        let middleBefore = Array(before[prefix..<(before.count - suffix)])
        let middleAfter = Array(after[prefix..<(after.count - suffix)])
        var script = before[..<prefix].map(Edit.same)
        script += middle(before: middleBefore, after: middleAfter)
        script += before[(before.count - suffix)...].map(Edit.same)
        return script
    }

    private static func middle(before: [String], after: [String]) -> [Edit] {
        if before.isEmpty { return after.map(Edit.added) }
        if after.isEmpty { return before.map(Edit.removed) }
        // A whole document replaced reads as a replacement; matching its lines
        // against each other would cost a table of millions of cells to say so.
        guard before.count * after.count <= exactLimit * exactLimit / 16,
              before.count + after.count <= exactLimit
        else {
            return before.map(Edit.removed) + after.map(Edit.added)
        }

        // Longest common subsequence, by length table.
        var lengths = [[Int]](
            repeating: [Int](repeating: 0, count: after.count + 1),
            count: before.count + 1
        )
        for row in stride(from: before.count - 1, through: 0, by: -1) {
            for column in stride(from: after.count - 1, through: 0, by: -1) {
                lengths[row][column] = before[row] == after[column]
                    ? lengths[row + 1][column + 1] + 1
                    : max(lengths[row + 1][column], lengths[row][column + 1])
            }
        }

        var script: [Edit] = []
        var row = 0
        var column = 0
        while row < before.count, column < after.count {
            if before[row] == after[column] {
                script.append(.same(before[row]))
                row += 1
                column += 1
            } else if lengths[row + 1][column] >= lengths[row][column + 1] {
                script.append(.removed(before[row]))
                row += 1
            } else {
                script.append(.added(after[column]))
                column += 1
            }
        }
        script += before[row...].map(Edit.removed)
        script += after[column...].map(Edit.added)
        return script
    }
}
