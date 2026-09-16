import Foundation

/// Which side of life a task belongs to. The panel shows one space at a time —
/// each has its own Mon→Sun week, its own long-term list and its own tallies —
/// so work never crowds an evening's list and vice versa.
///
/// Raw values are the words themselves, so the persisted JSON reads plainly.
enum Space: String, Codable, CaseIterable, Identifiable {
    case personal
    case work

    var id: String { rawValue }

    /// Label for the space picker, e.g. "Personal".
    var name: String { rawValue.capitalized }

    /// The space the panel opens in on a fresh install. Personal, because an
    /// empty list reads as a clean start where a list already holding a task
    /// nobody wrote reads as leftover data from someone else.
    static let `default`: Space = .personal

    /// What data written *before* the split decodes as. Deliberately a constant
    /// of its own rather than a reference to `default`: changing which space is
    /// the default must never re-file an existing list.
    static let legacy: Space = .personal

    /// The one space the daily "Plan the day" task is seeded into. Planning is a
    /// work ritual here; the personal list doesn't want a chore added to it every
    /// morning.
    static let planning: Space = .work

}

/// A list a task can be filed under: one of the seven days, or the long-term
/// list for anything that isn't for this week at all.
///
/// Raw values are ISO weekday numbers (Mon = 1, Sun = 7) so the persisted JSON
/// stays readable and sorts Mon→Sun naturally; `longTerm` takes 8, one past the
/// week, so it sorts last everywhere the raw value orders things: the flat
/// array's grouping, the panel's sections, the day picker.
enum Bucket: Int, Codable, CaseIterable, Identifiable {
    case monday = 1, tuesday, wednesday, thursday, friday, saturday, sunday
    case longTerm = 8

    var id: Int { rawValue }

    /// Header label, e.g. "Monday".
    var name: String {
        switch self {
        case .monday: "Monday"
        case .tuesday: "Tuesday"
        case .wednesday: "Wednesday"
        case .thursday: "Thursday"
        case .friday: "Friday"
        case .saturday: "Saturday"
        case .sunday: "Sunday"
        case .longTerm: "Long-term"
        }
    }

    /// Label for the day picker. One or two letters, not the "Mon" of before:
    /// the eighth segment pushed three-letter labels past the panel's width, and
    /// widening the panel for the picker alone is the wrong trade.
    var shortName: String {
        switch self {
        case .monday: "M"
        case .tuesday: "Tu"
        case .wednesday: "W"
        case .thursday: "Th"
        case .friday: "F"
        case .saturday: "Sa"
        case .sunday: "Su"
        case .longTerm: "L"
        }
    }

    /// The seven days on their own — the picker's segments, where long-term is
    /// its own button rather than an eighth segment.
    static var week: [Bucket] { allCases.filter { $0 != .longTerm } }


    /// How to say "on Monday" / "in the long-term list" in a tooltip.
    var place: String { self == .longTerm ? "in the long-term list" : "on \(name)" }

    /// The day new tasks land on — simply today, now that every day has a
    /// bucket. Never `longTerm`: nothing goes there unless it's aimed there.
    static var current: Bucket {
        // Calendar's `.weekday` is 1 = Sunday … 7 = Saturday; ISO puts Sunday last.
        let weekday = Calendar.current.component(.weekday, from: Date())
        return Bucket(rawValue: weekday == 1 ? 7 : weekday - 1) ?? .monday
    }
}

/// The area a task belongs to — which part of the week's work it is, as opposed
/// to `Priority`'s how-much-it-matters. Areas are the user's own words, not a
/// fixed set: they are typed as a leading `#token` when a task is captured
/// (`#sales call the bank`), and an area exists simply because a task uses it.
/// So a new area next week costs nothing, and there is no list to maintain.
///
/// A `String?` on the task rather than an enum, for exactly that reason. This
/// type is only the rules around it: how a token is pulled off a line, what
/// counts as a name, and which colour a name gets.
enum Area {
    /// Longest an area name may be. A cap rather than a validation error: the
    /// capsule has to fit on the row, and an "area" longer than this is a task.
    static let maxLength = 24

    /// How many hues areas are drawn from — see `paletteIndex`. The view's
    /// palette must hold exactly this many colours.
    ///
    /// Widened from ten once twelve areas were in use: ten was picked when the
    /// aim was "eight to ten clearly distinct", and a real week outgrew it.
    /// Slots 0-9 keep their original colours, because an area's hue is stored
    /// as an *index* — moving them would repaint every tagged row.
    static let paletteCount = 16

    /// Splits a captured line into its area and the task text: a **leading**
    /// `#token` is the area and comes off the text, anything else is text.
    ///
    /// Leading, and starting with a letter: a task reading "fix issue #42" — or
    /// one that just happens to contain a `#` — has to stay a task, and only the
    /// very start of a line is unambiguous.
    ///
    /// A line that is *nothing but* a tag keeps its text and gets no area:
    /// "#sales" on its own is far more likely to be a slip than a request for
    /// an empty task, and keeping the text loses nothing.
    static func parse(_ raw: String) -> (area: String?, text: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return (nil, trimmed) }
        let body = trimmed.dropFirst()
        let token = body.prefix { !$0.isWhitespace }
        let rest = body.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let area = normalize(String(token)), !rest.isEmpty else { return (nil, trimmed) }
        return (area, rest)
    }

    /// An area name reduced to its identity: lower-cased, stripped of anything
    /// that isn't a letter, digit, `-` or `_`, and capped. `nil` for anything
    /// that doesn't then start with a letter, which is what keeps `#42` from
    /// becoming an area.
    ///
    /// Lower-cased so `#Sales` and `#sales` are one area rather than two that
    /// look alike — the name is the identity here, there being no id to key on.
    static func normalize(_ raw: String) -> String? {
        let cleaned = String(raw.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }.map(Character.init))
        guard let first = cleaned.first, first.isLetter else { return nil }
        return String(cleaned.prefix(maxLength))
    }

    /// Which hue of the palette an area gets — derived from the name, so an
    /// area keeps its colour without anything being stored about it and no two
    /// areas have to be assigned by hand.
    ///
    /// A hash written out here rather than `hashValue`: Swift seeds that per
    /// process, so the whole panel would change colour on every launch.
    ///
    /// FNV-1a accumulates the bytes, and then the result goes through
    /// MurmurHash3's finalizer before being reduced. That second step is not
    /// decoration: FNV-1a's *low* bits barely avalanche — its last operation is
    /// a multiply, whose low bits depend on almost nothing — so reducing it with
    /// `%` straight away clusters badly — in testing, three of four hyphenated
    /// area names landed on the same hue out of eight. The finalizer's
    /// shift-multiply-shift rounds spread the entropy across the whole word, so
    /// the low bits are as good as the high ones.
    ///
    /// This is the **fallback and the tie-breaker**, not how an area normally
    /// gets its colour. Hashing alone gives permanence but not distinctness —
    /// four areas over ten hues collide about half the time (they did: "admin"
    /// and "sales" both landed on pink) — so a first sighting is *assigned* a
    /// hue by `assignHue(for:taken:)` and that assignment is persisted. This is
    /// what answers for an area that has somehow never been assigned one.
    static func paletteIndex(_ name: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash = hash &* 0xc4ce_b9fe_1a85_ec53
        hash ^= hash >> 33
        return Int(hash % UInt64(paletteCount))
    }

    /// The hue to give an area being seen for the first time: whichever is
    /// **least used** by the areas already assigned one, with the name's own
    /// hash breaking the tie so the choice is deterministic rather than
    /// dependent on dictionary order.
    ///
    /// This is what gets both halves of what a colour has to do here. Assigning
    /// by least-used means the first ten areas each get a hue of their own, and
    /// persisting the answer (see `TaskStore.hue(of:)`) means it never changes
    /// again — so a new area next week cannot repaint the ones already learned,
    /// which assigning colours by position in the current set would.
    ///
    /// `taken` is the whole existing map, areas no longer in use included: their
    /// hues stay reserved, so an area that comes back comes back the same colour.
    static func assignHue(for name: String, taken: [String: Int]) -> Int {
        var counts = [Int](repeating: 0, count: paletteCount)
        for hue in taken.values where counts.indices.contains(hue) {
            counts[hue] += 1
        }
        let fewest = counts.min() ?? 0
        let candidates = counts.indices.filter { counts[$0] == fewest }
        return candidates[paletteIndex(name) % candidates.count]
    }

    /// Moves as few areas as possible so that no two share a hue while a hue
    /// sits unused. Returns the map unchanged when there is nothing to gain.
    ///
    /// This is what lets the palette be *widened* later without hand-editing
    /// `areas.json`. Assignment is otherwise permanent, deliberately — but a
    /// pair that had to share a hue because the palette was full is a
    /// compromise the app made, not a choice the user made, so it is worth
    /// undoing the moment there is room. Nothing else moves.
    ///
    /// Deterministic and **idempotent**, which is what makes it safe to run on
    /// every load: hues are visited in ascending order, the alphabetically
    /// first holder of a shared hue keeps it, and the rest take the lowest free
    /// hues in turn. Once no hue is free — or none is shared — it is a no-op, so
    /// an area's colour cannot drift from one launch to the next. And since the
    /// map is never pruned, hues only ever come free by the palette growing.
    static func rebalanced(_ taken: [String: Int]) -> [String: Int] {
        var map = taken
        var holders: [Int: [String]] = [:]
        for (name, hue) in map where (0..<paletteCount).contains(hue) {
            holders[hue, default: []].append(name)
        }
        var free = (0..<paletteCount).filter { holders[$0] == nil }
        guard !free.isEmpty else { return map }
        for hue in holders.keys.sorted() {
            guard let names = holders[hue], names.count > 1 else { continue }
            for name in names.sorted().dropFirst() {
                guard !free.isEmpty else { return map }
                map[name] = free.removeFirst()
            }
        }
        return map
    }
}

/// Where a task sits in the Eisenhower matrix — the two questions (is it
/// urgent? is it important?) collapsed into four quadrants, each shown as a
/// single character in the row's badge column.
///
/// Untagged is deliberately *not* a case: `TaskItem.priority` is optional, so a
/// task carries no quadrant until one is chosen. Most tasks never need one, and
/// a list nobody has triaged should look exactly as quiet as it did before the
/// matrix existed.
///
/// Raw values are words, not the glyphs, so the JSON reads plainly and the
/// stored shape survives a change of symbol.
enum Priority: String, Codable, CaseIterable, Identifiable {
    /// Urgent *and* important — do it now.
    case now
    /// Important but not urgent — give it a day of its own.
    case schedule
    /// Urgent but not important — hand it on.
    case delegate
    /// Neither — it shouldn't really be on the list.
    case drop

    var id: String { rawValue }

    /// The badge glyph. One character each, so the badge column is the same
    /// width whichever quadrant a row is in — the task text lines up down the
    /// whole panel.
    var symbol: String {
        switch self {
        case .now: "!"
        case .schedule: "↑"
        case .delegate: "→"
        case .drop: "·"
        }
    }

    /// What the quadrant tells you to *do* — how the menu item reads.
    var action: String {
        switch self {
        case .now: "Do now"
        case .schedule: "Schedule"
        case .delegate: "Delegate"
        case .drop: "Drop"
        }
    }

    /// The quadrant itself, for the badge's tooltip: the two axes spelled out,
    /// since the glyph alone can't say which half of each it means.
    var axes: String {
        switch self {
        case .now: "urgent & important"
        case .schedule: "important, not urgent"
        case .delegate: "urgent, not important"
        case .drop: "neither urgent nor important"
        }
    }

    /// The quadrant a click on the badge moves to, `nil` past the last one — so
    /// one control walks all five states (! → ↑ → → → · → untagged) and a
    /// mis-tagged row can be cleared without opening a menu.
    var next: Priority? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index + 1 < all.count else { return nil }
        return all[index + 1]
    }

    /// Where an untagged row starts when its badge is clicked.
    static let first: Priority = .now

    /// Where this quadrant sits when a day's rows are ordered — see `Ordering`.
    ///
    /// Note the gap at 3: that is where *untriaged* tasks go, above `drop`. A
    /// `·` is work you have decided against, so it has to sink below work you
    /// simply haven't looked at yet — otherwise tagging something `·` would
    /// promote it above everything real, which is the opposite of what the tag
    /// means.
    var rank: Int {
        switch self {
        case .now: 0
        case .schedule: 1
        case .delegate: 2
        case .drop: 4
        }
    }

    /// The rank of a task with no quadrant at all.
    static let untriagedRank = 3

    /// How many bands a day is split into, `nil` included.
    static let rankCount = 5

    /// The band a task's quadrant puts it in, untagged included.
    static func rank(_ priority: Priority?) -> Int {
        priority?.rank ?? untriagedRank
    }
}

/// How the flat task array is ordered. One pure function over an array, so the
/// rule can be exercised without a `TaskStore` — and therefore without touching
/// the real Application Support files.
///
/// `TaskStore.tasks` is one flat array kept in this order at all times, which is
/// what lets the panel render a day as a contiguous slice and lets array order
/// *be* the user's order inside a band.
enum Ordering {
    /// The sort key inside one day of one space: the seeded "Plan the day" row
    /// first, then the four Eisenhower bands with untriaged tasks between
    /// `delegate` and `drop`.
    ///
    /// Planning is pinned above the bands rather than sorted by its (absent)
    /// quadrant: it is the app's own row, put at the top of today deliberately,
    /// and it would otherwise sink under every `!` the morning produced.
    static func rank(_ task: TaskItem) -> Int {
        task.kind == .planning ? 0 : 1 + Priority.rank(task.priority)
    }

    /// How many bands there are, planning included.
    static let rankCount = 1 + Priority.rankCount

    /// The array regrouped: spaces in `Space.allCases` order, days Mon→Sun (then
    /// long-term) inside each, priority bands inside each day, and **areas
    /// inside each band** — so two `!` tasks in the same area sit next to each
    /// other rather than either side of an `!` from somewhere else.
    ///
    /// **Stable at every level** — a filter per group, not `sort`, which isn't —
    /// so the user's own order survives inside a (band, area) group. That is
    /// what keeps drag-to-reorder meaningful next to an automatic sort: dragging
    /// inside a group arranges it, and dragging across bands retags the row (see
    /// `TaskStore.move(_:before:)`) so it stays where it was put.
    ///
    /// A list with nothing tagged is one band holding one area, so adopting the
    /// sort reorders such a list not at all.
    static func regrouped(_ tasks: [TaskItem]) -> [TaskItem] {
        Space.allCases.flatMap { space in
            Bucket.allCases.flatMap { day in
                (0..<rankCount).flatMap { band in
                    byArea(tasks.filter {
                        $0.space == space && $0.day == day && rank($0) == band
                    })
                }
            }
        }
    }

    /// One band's rows with each area's tasks brought together, the areas
    /// themselves in **order of first appearance**.
    ///
    /// First appearance rather than alphabetical, and rather than by the hue
    /// they were assigned, because it is the order that moves the fewest rows:
    /// the group stays where the user already had its first task, and joining a
    /// second task to it is the only thing that moves. Alphabetical would
    /// reshuffle a band the user had arranged by hand — and would move a whole
    /// group the day an area is renamed.
    ///
    /// Untagged rows are a group like any other here, placed by first
    /// appearance rather than sunk to the end. Unlike `·`, having no area says
    /// nothing about whether the work matters, so there is no reason to demote
    /// it.
    private static func byArea(_ band: [TaskItem]) -> [TaskItem] {
        var order: [String?] = []
        for task in band where !order.contains(task.area) {
            order.append(task.area)
        }
        return order.flatMap { area in band.filter { $0.area == area } }
    }
}

/// What kind of task a row is. `planning` is the "Plan the day" task the app
/// seeds each morning: it gets its own colour and a shorter timer box.
enum TaskKind: String, Codable {
    case normal
    case planning

    /// How long this kind of task's focus timer runs.
    var timerDuration: TimeInterval {
        switch self {
        case .normal: 20 * 60
        case .planning: 10 * 60
        }
    }
}

/// A single to-do item. Named `TaskItem` (not `Task`) to avoid colliding with
/// Swift concurrency's `Task`.
struct TaskItem: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var day: Bucket
    var space: Space
    var kind: TaskKind
    /// Which Eisenhower quadrant this task is in, or `nil` for the untriaged
    /// majority. Optional rather than a fifth case, so an untagged task encodes
    /// no key at all and every task saved before the matrix stays untagged.
    var priority: Priority?
    /// Which area of the week's work this is — the user's own word, or `nil`.
    /// See `Area`: free-form on purpose, so next week's areas need no code
    /// change. Optional for the same reason `priority` is — an untagged task
    /// encodes no key, so nothing saved before areas existed needs migrating.
    var area: String?

    init(
        id: UUID = UUID(),
        text: String,
        day: Bucket = .current,
        space: Space = .default,
        kind: TaskKind = .normal,
        priority: Priority? = nil,
        area: String? = nil
    ) {
        self.id = id
        self.text = text
        self.day = day
        self.space = space
        self.kind = kind
        self.priority = priority
        self.area = area
    }

    /// Tasks saved before the week split have no `day`; they load onto the
    /// current day, which is where the panel opens, so an existing list stays
    /// in sight and can be spread across the week by dragging.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        text = try container.decode(String.self, forKey: .text)
        day = try container.decodeIfPresent(Bucket.self, forKey: .day) ?? .current
        // Tasks saved before the personal/work split are all personal ones.
        space = try container.decodeIfPresent(Space.self, forKey: .space) ?? .legacy
        // Tasks saved before the planning task existed are all ordinary ones.
        kind = try container.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .normal
        // No quadrant is the resting state, so a file written before the matrix
        // needs no migration: every task simply loads untagged.
        priority = try container.decodeIfPresent(Priority.self, forKey: .priority)
        area = try container.decodeIfPresent(String.self, forKey: .area)
    }
}

/// One task that has been ticked off — the registry behind the day headings'
/// green ✓ tally. The tally is a count; this is the list it counts.
///
/// A record of what *was*, so it is a snapshot rather than a reference: the task
/// it came from no longer exists, and its text/day/space are the ones it had
/// when it was completed.
struct CompletedTask: Identifiable, Codable, Equatable {
    /// The completed task's own id, which is what an undo looks the record up by.
    let id: UUID
    var text: String
    var day: Bucket
    var space: Space
    /// The quadrant it was in when it was ticked off — part of the snapshot, so
    /// the record says what the row said. Optional, like the task's own, which
    /// is also how entries archived before the matrix decode.
    var priority: Priority?
    /// The area it was filed under, same snapshot, same optionality.
    var area: String?
    var completedAt: Date

    init(_ task: TaskItem, at completedAt: Date = Date()) {
        self.id = task.id
        self.text = task.text
        self.day = task.day
        self.space = task.space
        self.priority = task.priority
        self.area = task.area
        self.completedAt = completedAt
    }
}

/// How a typed query is matched against a task. A pure `enum` of rules, in the
/// model rather than the store, so it can be exercised without a `TaskStore` —
/// and therefore without touching the real Application Support files.
enum Search {
    /// A query broken into the terms that must *all* be found. Whitespace
    /// separated, folded the same way the haystack is.
    ///
    /// An AND of terms rather than one literal substring: a week's tasks are
    /// deliberately specific sentences, so "bank call" should find "call the
    /// bank about the invoice". Word *order* is the thing nobody remembers.
    static func terms(_ query: String) -> [String] {
        query.split(whereSeparator: \.isWhitespace).map { fold(String($0)) }
    }

    /// Case- and diacritic-insensitive, so "résumé" is found by typing
    /// "resume" and "Bank" by typing "bank".
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Whether a task answers the query. The **area counts as part of the
    /// haystack**: `#sales` comes off the text when the task is captured, so a
    /// search for "sales" would otherwise miss every task filed under it — the
    /// one place the tag would read as having hidden something.
    ///
    /// The quadrant is deliberately not searchable: `!` is a glyph, not a word,
    /// and typing one would match a band rather than a task.
    static func matches(text: String, area: String?, terms: [String]) -> Bool {
        guard !terms.isEmpty else { return false }
        let haystack = fold(area.map { "#\($0) \(text)" } ?? text)
        return terms.allSatisfy(haystack.contains)
    }

    static func matches(_ task: TaskItem, terms: [String]) -> Bool {
        matches(text: task.text, area: task.area, terms: terms)
    }
}
