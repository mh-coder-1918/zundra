import Foundation

/// The single source of truth for tasks. Owns the list, the add/complete/undo
/// operations, and persistence to a JSON file in Application Support.
///
/// Tasks live in one flat array that is always kept grouped by space, then
/// Mon→Sun, then by Eisenhower band (see `Ordering`), so the per-day slices the
/// UI renders are contiguous and array order *is* the user's order within a
/// band. Every mutation ends by putting the array back in that order —
/// `regroup()` — except the two that run repeatedly mid-drag, which leave it to
/// `commitOrder()` on the drop.
///
/// Undo is single-level: completing a task remembers exactly one task, so
/// `undoLastCompletion()` restores the most recently completed one. Completing
/// another task before undoing replaces what undo would bring back.
///
/// Completing a task also bumps a per-day tally (`completedCount(on:)`) that the
/// day headings show. The tallies are counts only — no completed task is kept —
/// and they cover the current week, resetting when a new one starts.
@MainActor
final class TaskStore: ObservableObject {
    /// Where the space on show is remembered. `UserDefaults` rather than a file
    /// of its own: it's which view was last open, not task data.
    fileprivate static let spaceKey = "space"

    @Published private(set) var tasks: [TaskItem] = []
    /// The space the panel is showing, and the one new tasks land in. Persisted
    /// so the panel opens where it was left; `@Published` because every section
    /// of the panel is a view of this one space.
    ///
    /// Restored *here*, in the default-value expression, rather than assigned in
    /// `init`: an assignment in `init` runs `didSet` (the object is fully
    /// initialized by then), which would seed a planning task and `save()` an
    /// empty list over `tasks.json` before `load()` had read it. A default-value
    /// expression runs during initialization, so no observer fires.
    @Published var space: Space =
        Space(rawValue: UserDefaults.standard.string(forKey: TaskStore.spaceKey) ?? "")
        ?? .default
    {
        didSet {
            guard space != oldValue else { return }
            UserDefaults.standard.set(space.rawValue, forKey: Self.spaceKey)
            // The space you have just switched to gets its planning task the
            // first time you look at it today — see `seedPlanningTask()`.
            seedPlanningTask()
        }
    }

    private let saveURL: URL
    private let doneURL: URL
    private let planURL: URL
    private let archiveURL: URL
    private let areaURL: URL
    /// The calendar day each space's "Plan the day" task was last seeded on
    /// ("2026-08-23"), so it appears once per day per space and stays gone once
    /// it's ticked off.
    private var plannedDay: [Space: String] = [:]
    /// What the undo bar is offering to take back. A completion and a deletion
    /// are one task deep and share the bar, but they are not the same act and
    /// must not claim to be: "Task completed" over a row the user deleted is a
    /// lie about the ✓ tally.
    enum Undoable { case completed, deleted }
    @Published private(set) var pendingUndoKind: Undoable?
    private var pendingUndo: (task: TaskItem, index: Int, kind: Undoable)?
    /// Completions per day, and the week they belong to. Read through
    /// `completedCount(on:)`, which ignores them once the week has rolled over.
    /// Not `@Published` on purpose: every change to a tally goes with a change to
    /// `tasks`, which is what republishes the day headings.
    private var done: [Space: [Bucket: Int]] = [:]
    private var doneWeek: String = ""
    /// Every task ever ticked off, oldest first — the registry the tallies count.
    /// Unlike `done` this is not stamped with a week and never reset: the counts
    /// are a scoreboard for the current week, this is the record. Kept out of
    /// `tasks.json` so that file keeps its bare-array-of-open-tasks shape, and
    /// `@Published` because the panel lists it when a tally is clicked.
    @Published private(set) var archive: [CompletedTask] = []
    /// Which hue each area is drawn in, by name — assigned the first time an
    /// area is seen and then never changed, which is the only way a colour can
    /// be both distinct from its neighbours' and permanent. Persisted in
    /// `areas.json`; see `Area.assignHue(for:taken:)`.
    ///
    /// Never pruned. An area whose last task is ticked off keeps its hue
    /// reserved, so re-using the name later brings the same colour back — and a
    /// row under an open ✓ tally still knows the colour it had.
    @Published private(set) var areaHues: [String: Int] = [:]
    /// The deferred re-sort a priority click asks for — see `scheduleRegroup()`.
    private var pendingRegroup: Task<Void, Never>?

    init() {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Zundra", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.saveURL = dir.appendingPathComponent("tasks.json")
        self.doneURL = dir.appendingPathComponent("completed.json")
        self.planURL = dir.appendingPathComponent("planning.json")
        self.archiveURL = dir.appendingPathComponent("archive.json")
        self.areaURL = dir.appendingPathComponent("areas.json")
        loadAreaHues()
        load()
        loadArchive()
        loadDone()
        loadPlanned()
        seedPlanningTask()
    }

    /// The tasks filed under `day` in the space on show, in the user's order.
    func tasks(on day: Bucket) -> [TaskItem] {
        tasks(on: day, in: space)
    }

    /// The tasks filed under `day` in a named space, for the callers that need
    /// a space other than the one on screen.
    func tasks(on day: Bucket, in space: Space) -> [TaskItem] {
        tasks.filter { $0.day == day && $0.space == space }
    }

    /// Everything in the space on show — what the panel's "no tasks" state asks.
    var visibleTasks: [TaskItem] {
        tasks.filter { $0.space == space }
    }

    /// The open tasks in `space` that answer `query`, in the order they already
    /// sit in — so results read as a slice of the list rather than a ranking of
    /// their own. Empty for an empty query: search is a filter over the list,
    /// and "no query" means the whole list, which is what the panel shows
    /// anyway.
    ///
    /// Open tasks only. The archive is a record of what was done, and folding
    /// it in would answer a different question ("did I do this?") every time
    /// the user asks this one ("where did I put this?").
    func search(_ query: String) -> [TaskItem] {
        search(query, in: space)
    }

    func search(_ query: String, in space: Space) -> [TaskItem] {
        let terms = Search.terms(query)
        guard !terms.isEmpty else { return [] }
        return tasks.filter { $0.space == space && Search.matches($0, terms: terms) }
    }

    /// How many matches a space holds — what the panel needs to say that what
    /// is being looked for is in the *other* space, which is the one place a
    /// search can't see and the likeliest place a lost task is hiding.
    func searchCount(_ query: String, in space: Space) -> Int {
        search(query, in: space).count
    }

    /// How many of `day`'s tasks have been completed this week. Zero once the
    /// week has rolled over — the stale tallies are dropped by the next
    /// completion rather than here, so reading stays free of side effects.
    func completedCount(on day: Bucket) -> Int {
        doneWeek == Self.currentWeek ? done[space]?[day] ?? 0 : 0
    }

    /// The tasks counted by `completedCount(on:)` — what the day heading reveals
    /// when its ✓ tally is clicked. This week's, in the space on show, most
    /// recently ticked off first. The archive itself keeps everything; the panel
    /// shows the week, to match the number that opens it.
    func completedTasks(on day: Bucket) -> [CompletedTask] {
        guard doneWeek == Self.currentWeek else { return [] }
        return archive
            .filter { $0.day == day && $0.space == space && Self.week(of: $0.completedAt) == doneWeek }
            .reversed()
            .map { $0 }
    }

    /// Completions across the whole week, for deciding whether the tally is
    /// worth showing at all.
    var completedThisWeek: Int {
        Bucket.allCases.reduce(0) { $0 + completedCount(on: $1) }
    }

    /// Puts today's "Plan the day" task at the top of today's list — once per
    /// calendar day. Completing it (or deleting it) doesn't bring it back: the
    /// day it was seeded on is remembered, so the next one is tomorrow's.
    /// Every day, weekends included — now that Saturday and Sunday have buckets
    /// of their own, they get planned like any other day.
    /// Seeded into `Space.planning` only — planning the day is a work ritual
    /// here, so the personal list isn't handed a chore every morning. Still
    /// lazy: it appears the first time that space is opened today, so coming to
    /// work in the afternoon plans the afternoon rather than presenting a stale
    /// morning.
    func seedPlanningTask() {
        let today = Self.currentDay
        guard space == Space.planning, plannedDay[space] != today else { return }
        plannedDay[space] = today
        savePlanned()
        let day = Bucket.current
        tasks.insert(
            TaskItem(text: "Plan the day", day: day, space: space, kind: .planning),
            at: startIndex(of: day)
        )
        // Belt and braces: the insert puts it at the top of today, and its
        // rank-0 band keeps it there through every later regroup.
        regroup()
        save()
    }

    /// Adds a task to the end of `day`. Blank / whitespace-only input is ignored.
    /// `priority` is what the capture row's quadrant picker is set to — `nil`
    /// for an untriaged task, which is where a freshly opened panel starts.
    func add(_ text: String, on day: Bucket, priority: Priority? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        add(trimmed, on: day, in: space, priority: priority)
    }

    /// Adds a task to the end of `day` in a named space, which needn't be the
    /// space on show.
    ///
    /// A leading `#area` token is pulled off the text and becomes the task's
    /// area (see `Area.parse`). Done *here* rather than at the capture field, so
    /// `#admin file the receipts` means the same thing however the task arrives.
    func add(_ text: String, on day: Bucket, in space: Space, priority: Priority? = nil) {
        let (area, body) = Area.parse(text)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tasks.insert(
            TaskItem(text: trimmed, day: day, space: space, priority: priority, area: area),
            at: endIndex(of: day, in: space)
        )
        // At the end of the day, then into its band — a tagged capture lands
        // with its own kind rather than at the bottom of the day.
        regroup()
        assignHues()
        save()
    }

    /// Edits an existing task's text. Blank / whitespace-only input is ignored
    /// (the old text is kept). No-op if the id is unknown and nothing changed.
    ///
    /// A leading `#area` retags the row, exactly as it does at capture — so an
    /// area can be corrected by typing, not only from the menu. Its *absence*
    /// changes nothing: ordinary edits to a tagged task keep the area, and
    /// clearing one is the menu's job.
    func update(_ id: UUID, text: String) {
        let (area, body) = Area.parse(text)
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = tasks.firstIndex(where: { $0.id == id })
        else { return }
        let newArea = area ?? tasks[index].area
        // Checked together: a `#token` that only retags — leaving the text as
        // it was — is still a change worth saving.
        guard tasks[index].text != trimmed || tasks[index].area != newArea else { return }
        tasks[index].text = trimmed
        tasks[index].area = newArea
        assignHues()
        save()
    }

    /// Tags a task with an Eisenhower quadrant, or clears the tag (`nil`).
    ///
    /// The quadrant is metadata beside the text, like the order and the
    /// `TaskKind`, so tagging one changes nothing about what the task *says*.
    ///
    /// The badge and the tag change at once; the *row* only moves once the
    /// clicking stops — see `scheduleRegroup()`.
    func setPriority(_ id: UUID, to priority: Priority?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].priority != priority
        else { return }
        tasks[index].priority = priority
        scheduleRegroup()
        save()
    }

    /// Files a task under an area, or clears it (`nil`) — the row menu's way in,
    /// for retagging without retyping. The name is normalized, so picking one
    /// from the menu and typing it can't produce two areas that look alike.
    ///
    /// Like `setPriority`, this changes metadata beside the text rather than
    /// what the task says.
    func setArea(_ id: UUID, to area: String?) {
        let name = area.flatMap(Area.normalize)
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].area != name
        else { return }
        tasks[index].area = name
        // Only ever a no-op here in practice — the menu offers areas that
        // already exist — but it costs nothing and keeps the invariant local.
        assignHues()
        save()
    }

    /// The areas in use in the space on show, alphabetically — what the row menu
    /// offers. Derived from the tasks rather than stored: an area exists exactly
    /// as long as something is filed under it, so nothing has to be cleaned up
    /// when the last task in an area is ticked off.
    var areas: [String] {
        Set(tasks.filter { $0.space == space }.compactMap(\.area)).sorted()
    }

    /// Live-reorders the dragged task to sit where `target` currently is,
    /// adopting `target`'s day if the drag crossed into another one. Called
    /// repeatedly as a drag hovers over rows, so it does NOT persist — call
    /// `commitOrder()` once the drop lands to write the final order to disk.
    func move(_ draggedID: UUID, before target: TaskItem) {
        guard draggedID != target.id,
              let from = tasks.firstIndex(where: { $0.id == draggedID }),
              let to = tasks.firstIndex(where: { $0.id == target.id })
        else { return }
        tasks[from].day = target.day
        // A drag can only reach rows of the space on show, so adopting the
        // target's space is a no-op in practice — stated anyway so the array
        // stays grouped by space whatever calls this.
        tasks[from].space = target.space
        // …and the target's quadrant, which is how a task crosses *bands*, for
        // the same reason adopting the day is how it crosses days. With the
        // sort on, the alternative is a row that snaps back to where it was the
        // moment it is dropped; adopting instead makes dragging a task up among
        // the `!`s mean what it looks like it means. The planning row is
        // unaffected in practice — its own band is above all four.
        tasks[from].priority = target.priority
        // The area is deliberately NOT adopted, though rows are grouped by it
        // inside a band. The asymmetry is the point: a quadrant is a judgement,
        // and dragging a task up among the urgent ones *is* the user making it,
        // whereas an area is a fact about which work this is — set by typing
        // `#name`, and not something a mis-aimed drag should silently rewrite.
        // So a row dropped among another area's tasks returns to its own group,
        // which its capsule colour makes self-explanatory rather than puzzling.
        tasks.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
    }

    /// Files the dragged task at the end of `day` — how a task is dropped onto a
    /// day header, or onto a day that has no rows to aim at yet.
    func move(_ draggedID: UUID, toEndOf day: Bucket) {
        guard let from = tasks.firstIndex(where: { $0.id == draggedID }) else { return }
        var item = tasks[from]
        guard item.day != day || from != endIndex(of: day, in: item.space) - 1 else { return }
        // Pull the task out before computing the destination, so `endIndex` can't
        // land on the task's own slot when it's the first one filed under `day`.
        tasks.remove(at: from)
        item.day = day
        tasks.insert(item, at: endIndex(of: day, in: item.space))
    }

    /// Refiles a task under another bucket, at the end of it — the context
    /// menu's "Move to Long-term" / "Move to Today", for a day that turned out
    /// to hold too much, or for a long-term task being picked up.
    ///
    /// The drag has `move(_:toEndOf:)` for the same job, but that one runs
    /// mid-drag and leaves persistence to the drop; a menu choice is finished
    /// the moment it's made, so this saves and syncs like `move(_:to:)` does.
    func move(_ id: UUID, to day: Bucket) {
        guard let task = tasks.first(where: { $0.id == id }), task.day != day else { return }
        move(id, toEndOf: day)
        regroup()
        save()
    }

    /// Moves a task to the other space, keeping the day it was filed under: a
    /// Thursday errand that turns out to be work is still a Thursday errand.
    /// Filed at the end of that day, since the two spaces have orders of their
    /// own and there is no position in the target to inherit.
    ///
    /// This is the *only* way a task crosses spaces — a drag can't, since it can
    /// only reach rows of the space on show — so unlike `move(_:before:)` it
    /// persists immediately rather than waiting for a drop to commit.
    func move(_ id: UUID, to space: Space) {
        guard let from = tasks.firstIndex(where: { $0.id == id }),
              tasks[from].space != space
        else { return }
        var item = tasks.remove(at: from)
        item.space = space
        tasks.insert(item, at: endIndex(of: item.day, in: space))
        regroup()
        save()
    }

    /// Persists the current order after a reorder drag completes — and settles
    /// the list into its bands, which the drag itself deliberately doesn't do.
    /// A drag that crossed bands has retagged the row, so it stays where it was
    /// dropped rather than springing back.
    func commitOrder() {
        regroup()
        save()
    }

    /// Removes a task, credits it to its day's tally, and remembers it for a
    /// possible undo.
    func complete(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        let completed = tasks[index]
        pendingUndo = (completed, index, .completed)
        pendingUndoKind = .completed
        tasks.remove(at: index)
        // Credit the day the task was filed under, so the tally matches the rows
        // that disappeared from that heading.
        if doneWeek != Self.currentWeek {
            doneWeek = Self.currentWeek
            done = [:]
        }
        done[completed.space, default: [:]][completed.day, default: 0] += 1
        archive.append(CompletedTask(completed))
        save()
        saveDone()
        saveArchive()
    }

    /// Removes a task without crediting it to anything.
    ///
    /// Deliberately *not* `complete()`. Ticking off a task captured by mistake
    /// inflates that day's ✓ tally and files a snapshot in the registry, which
    /// quietly corrupts the one number the panel asks you to trust — and the
    /// registry is a record, so the row cannot be taken back out of it later.
    /// A deleted task was never a task: it leaves no tally, no archive entry and
    /// no trace beyond the undo bar.
    ///
    /// It lives in the row's right-click menu rather than beside the complete
    /// circle, for the same reason the priority badge keeps its distance: a
    /// second small target next to the one control that removes a row is the
    /// mis-click the undo bar exists for, and that bar reaches only the *last*
    /// act.
    func delete(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        pendingUndo = (tasks[index], index, .deleted)
        pendingUndoKind = .deleted
        tasks.remove(at: index)
        save()
    }

    /// Restores the most recently completed *or deleted* task to its original
    /// position — and, if it was completed, takes its day's tally back down.
    func undoLast() {
        guard let pending = pendingUndo else { return }
        let index = min(pending.index, tasks.count)
        tasks.insert(pending.task, at: index)
        // Back where it was, then back into its band — the remembered index can
        // be stale (anything may have moved since), and a restored row must not
        // be the one thing sitting outside the order.
        regroup()
        pendingUndo = nil
        pendingUndoKind = nil
        // A deletion credited nothing and archived nothing, so there is nothing
        // to give back — putting the row back is the whole of the undo.
        guard pending.kind == .completed else {
            save()
            return
        }
        if let count = done[pending.task.space]?[pending.task.day], doneWeek == Self.currentWeek {
            done[pending.task.space]?[pending.task.day] = max(0, count - 1)
        }
        // Undoing a completion un-writes its registry entry too: the task is
        // back on the list, so it was never done. The last one wins, since a
        // task can be completed, restored and completed again.
        if let entry = archive.lastIndex(where: { $0.id == pending.task.id }) {
            archive.remove(at: entry)
        }
        save()
        saveDone()
        saveArchive()
    }

    /// Discards the pending undo (called when the undo window expires).
    func clearUndo() {
        pendingUndo = nil
        pendingUndoKind = nil
    }

    /// The hue an area is drawn in. A **pure read**: it never assigns, because
    /// this is called from the panel's body and mutating published state during
    /// a render is how SwiftUI gets into a loop. Assignment happens in
    /// `assignHues()`, off the back of the mutations that can introduce an area.
    ///
    /// The hash stands in for an area with no assignment on record — a
    /// hand-edited `tasks.json`, or an archive entry from before `areas.json`
    /// existed — so a colour is always available.
    func hue(of area: String) -> Int {
        areaHues[area] ?? Area.paletteIndex(area)
    }

    /// Gives a hue to every area in use that hasn't got one, and writes the map
    /// out if anything was added. Called after each mutation that can introduce
    /// an area, and once at load — which is what migrates a list whose areas
    /// predate the map.
    private func assignHues() {
        let before = areaHues
        // Sorted, so a batch arriving at once (a load, or an inbox drain) is
        // assigned in a fixed order rather than a dictionary's.
        for name in Set(tasks.compactMap(\.area)).sorted() where areaHues[name] == nil {
            areaHues[name] = Area.assignHue(for: name, taken: areaHues)
        }
        // Then undo any hue-sharing the palette's old size forced, if there is
        // now room — see `Area.rebalanced`. Idempotent, so running it on every
        // mutation costs nothing and no colour drifts between launches.
        areaHues = Area.rebalanced(areaHues)
        if areaHues != before { saveAreaHues() }
    }

    private func loadAreaHues() {
        guard let data = contents(of: areaURL) else { return }
        guard let stored = try? JSONDecoder().decode([String: Int].self, from: data) else {
            quarantine(areaURL)
            return
        }
        areaHues = stored
    }

    private func saveAreaHues() {
        guard let data = try? JSONEncoder().encode(areaHues) else { return }
        write(data, to: areaURL)
    }

    /// Puts the array back in order — spaces, then days, then priority bands —
    /// after a mutation that could have disturbed it. Stable, so the user's own
    /// order inside a band is untouched (see `Ordering.regrouped`).
    ///
    /// Called by every mutation *except* `move(_:before:)` and
    /// `move(_:toEndOf:)`, which fire repeatedly while a drag hovers: sorting
    /// there would make the rows jump out from under the cursor. Those leave it
    /// to `commitOrder()`, so the list settles into its bands once on the drop.
    private func regroup() {
        pendingRegroup?.cancel()
        pendingRegroup = nil
        tasks = Ordering.regrouped(tasks)
    }

    /// How long a priority click holds the row still before the list re-sorts.
    /// Long enough to cycle a badge through a couple of quadrants — each click
    /// starts the wait again — and short enough that the row is seen moving to
    /// where the tag just put it.
    private static let regroupDelay: Duration = .seconds(3)

    /// Re-sorts the list a moment from now rather than this instant, so a row
    /// whose badge is being clicked stays under the pointer.
    ///
    /// Cycling a quadrant takes up to four clicks on one small target, and
    /// sorting on each of them slid the row out from under the cursor between
    /// them — the same reason the drag leaves sorting to the drop. Every click
    /// restarts the wait, so the row settles into its band once, when the
    /// triaging of it is done. Only the *order* waits: the tag, the badge's
    /// colour and the file on disk all change on the click.
    ///
    /// The array stays grouped by space and day throughout — a quadrant can't
    /// change either — so the insert indices, which is what the invariant is
    /// actually for, are as good mid-wait as after. Any other mutation
    /// meanwhile calls `regroup()`, which cancels the wait by doing its job.
    private func scheduleRegroup() {
        pendingRegroup?.cancel()
        pendingRegroup = Task { [weak self] in
            try? await Task.sleep(for: Self.regroupDelay)
            guard !Task.isCancelled, let self else { return }
            self.regroup()
            // The order is part of the file, and only `regroup()` knows it has
            // just changed — the click's own `save()` wrote the tag.
            self.save()
        }
    }

    /// One past the last task of `day` in `space`, keeping the flat array
    /// grouped by space and then Mon→Sun. A band-mate is not looked for: the
    /// `regroup()` that follows every insert files the task in its own band.
    private func endIndex(of day: Bucket, in space: Space) -> Int {
        if let last = tasks.lastIndex(where: { $0.day == day && $0.space == space }) {
            return last + 1
        }
        // Nothing on that day yet — sit ahead of the first task that sorts after
        // it, which may be a later day of this space or the whole of the next.
        if let next = tasks.firstIndex(where: { Self.sorts(after: day, in: space, $0) }) {
            return next
        }
        return tasks.count
    }

    /// The index of `day`'s first task in the space on show — where the planning
    /// task goes.
    private func startIndex(of day: Bucket) -> Int {
        tasks.firstIndex {
            ($0.space == space && $0.day.rawValue >= day.rawValue)
                || Self.sorts(after: day, in: space, $0)
        } ?? tasks.count
    }

    /// Whether `task` belongs after (`day`, `space`) in the array's grouping:
    /// spaces in `Space.allCases` order, days Mon→Sun inside each.
    private static func sorts(after day: Bucket, in space: Space, _ task: TaskItem) -> Bool {
        guard let left = Space.allCases.firstIndex(of: space),
              let right = Space.allCases.firstIndex(of: task.space)
        else { return false }
        if right != left { return right > left }
        return task.day.rawValue > day.rawValue
    }

    /// Today as "2026-08-23", for stamping the planning task's seed day.
    private static var currentDay: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    /// The seed days on disk: one per space, e.g. `{"seeded": {"personal":
    /// "2026-08-23"}}`. The pre-split shape was a bare string; it decodes as the
    /// personal space's day, so the split doesn't seed a second planning task
    /// into a day that already has one.
    private struct StoredPlanning: Codable {
        var seeded: [String: String]

        init(seeded: [String: String]) { self.seeded = seeded }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let bySpace = try? container.decode([String: [String: String]].self),
               let seeded = bySpace["seeded"] {
                self.seeded = seeded
            } else if let flat = try? container.decode([String: String].self),
                      let day = flat["seeded"] {
                self.seeded = [Space.legacy.rawValue: day]
            } else {
                self.seeded = [:]
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(["seeded": seeded])
        }
    }

    private func loadPlanned() {
        guard let data = contents(of: planURL) else { return }
        guard let stored = try? JSONDecoder().decode(StoredPlanning.self, from: data) else {
            quarantine(planURL)
            return
        }
        plannedDay = Dictionary(uniqueKeysWithValues: stored.seeded.compactMap { name, day in
            Space(rawValue: name).map { ($0, day) }
        })
    }

    private func savePlanned() {
        let stored = StoredPlanning(
            seeded: Dictionary(uniqueKeysWithValues: plannedDay.map { ($0.key.rawValue, $0.value) })
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        write(data, to: planURL)
    }




    // MARK: - Data files

    /// A data file that was on disk but could not be read, and what became of it.
    struct Recovery: Identifiable {
        var id: String { file }
        /// The file that wouldn't decode — `tasks.json`, say.
        let file: String
        /// What its contents were renamed to, or `nil` if even that failed.
        let backup: String?
    }

    /// Files found unreadable that could not be moved aside. Nothing is written
    /// to these for the rest of the session: an unreadable file is not an empty
    /// one, and overwriting it is exactly how a whole list disappears.
    private var sealed: Set<String> = []

    /// Unreadable data files found at launch, for the panel to report. Empty in
    /// every ordinary session, which is why it must not be silent when it isn't.
    @Published private(set) var recoveries: [Recovery] = []

    func dismissRecoveries() { recoveries = [] }

    /// The bytes of one of the app's data files, or `nil` when there are none
    /// to be had.
    ///
    /// The distinction this draws is the whole point. A file that is *absent*
    /// is a fresh install and means nothing; a file that is present but
    /// unusable is a disaster in progress. Both used to return the same `nil`,
    /// and the very next `save()` wrote straight over the second one — one
    /// corrupt byte, and the entire list was gone without a word. An unusable
    /// file is now moved aside before anything can overwrite it, and if it
    /// cannot even be moved, its name is sealed and nothing writes there again
    /// this session.
    private func contents(of url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else {
            quarantine(url)
            return nil
        }
        return data
    }

    /// Moves a file that won't decode out of the way, under a name that says
    /// what it is and when it happened. Called by `contents(of:)` when the bytes
    /// can't be read, and by each loader when they can be read but don't decode.
    private func quarantine(_ url: URL) {
        let name = url.lastPathComponent
        guard !recoveries.contains(where: { $0.file == name }) else { return }
        let stamp = Self.backupStamp.string(from: Date())
        let base = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(base)-unreadable-\(stamp).json")
        if (try? FileManager.default.moveItem(at: url, to: backup)) != nil {
            recoveries.append(Recovery(file: name, backup: backup.lastPathComponent))
        } else {
            sealed.insert(name)
            recoveries.append(Recovery(file: name, backup: nil))
        }
    }

    private static let backupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter
    }()

    /// Writes one of the app's data files — unless it is sealed, in which case
    /// the copy on disk is the only one left and stays untouched.
    private func write(_ data: Data, to url: URL) {
        guard !sealed.contains(url.lastPathComponent) else { return }
        try? data.write(to: url, options: [.atomic])
    }

    /// Just enough of the stored shape to spot a file written before tasks had days.
    private struct StoredTask: Decodable {
        let day: Bucket?
        let space: Space?
    }

    private func load() {
        guard let data = contents(of: saveURL) else { return }
        guard let decoded = try? JSONDecoder().decode([TaskItem].self, from: data) else {
            // The one that matters most. `seedPlanningTask()` runs moments after
            // this and saves, so without the move aside the file would already
            // be gone by the time anyone noticed.
            quarantine(saveURL)
            return
        }
        // Re-group in case the file predates the week split, predates the
        // priority bands, or was hand-edited. Stable, so each band's own order
        // survives — see `Ordering.regrouped`.
        tasks = Ordering.regrouped(decoded)

        // Day-less tasks defaulted to *today*. Write that back now, so they stay
        // put instead of following today around until the first edit.
        // Same for tasks written before the personal/work split: they read as
        // personal, and that is written back rather than re-derived every load.
        let stored = (try? JSONDecoder().decode([StoredTask].self, from: data)) ?? []
        if stored.contains(where: { $0.day == nil || $0.space == nil }) { save() }
        // And write back a file whose order the bands have changed — the first
        // launch after the sort arrived, or after the file was hand-edited.
        // Otherwise `tasks.json` would disagree with the panel until the next
        // mutation happened to save it, which makes the file a liar and any
        // inspection of it misleading.
        else if tasks.map(\.id) != decoded.map(\.id) { save() }

        // Areas that predate `areas.json` — or arrived by hand — get their hue
        // now, once, rather than falling back to the hash for ever.
        assignHues()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        write(data, to: saveURL)
    }

    /// The tallies on disk: the week they cover plus a count per weekday number.
    /// Keys are strings so the JSON stays readable (an `Int`-keyed dictionary
    /// encodes as a flat array of alternating keys and values).
    /// Counts are nested per space — `{"week": "2026-34", "counts":
    /// {"personal": {"3": 2}}}`. A pre-split file's flat `counts` decode as the
    /// personal space's, so the week's tallies survive the split.
    private struct StoredCompletions: Codable {
        var week: String
        var counts: [String: [String: Int]]

        init(week: String, counts: [String: [String: Int]]) {
            self.week = week
            self.counts = counts
        }

        private enum CodingKeys: String, CodingKey { case week, counts }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            week = try container.decode(String.self, forKey: .week)
            if let bySpace = try? container.decode([String: [String: Int]].self, forKey: .counts) {
                counts = bySpace
            } else {
                counts = [Space.legacy.rawValue:
                    (try? container.decode([String: Int].self, forKey: .counts)) ?? [:]]
            }
        }
    }

    /// Identifies the current Mon→Sun week, e.g. "2026-34". A tally stamped with
    /// a different week is stale and reads as zero.
    private static var currentWeek: String { week(of: Date()) }

    /// The ISO year-week a moment falls in, in `currentWeek`'s shape, so an
    /// archived completion can be matched against the week the tallies cover.
    private static func week(of date: Date) -> String {
        var calendar = Calendar(identifier: .iso8601)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return "\(parts.yearForWeekOfYear ?? 0)-\(parts.weekOfYear ?? 0)"
    }

    private func loadDone() {
        guard let data = contents(of: doneURL) else { return }
        guard let stored = try? JSONDecoder().decode(StoredCompletions.self, from: data) else {
            quarantine(doneURL)
            return
        }
        doneWeek = stored.week
        done = Dictionary(uniqueKeysWithValues: stored.counts.compactMap { name, counts in
            guard let space = Space(rawValue: name) else { return nil }
            return (space, Dictionary(uniqueKeysWithValues: counts.compactMap { number, count in
                Bucket(rawValue: Int(number) ?? 0).map { ($0, count) }
            }))
        })
    }

    private func saveDone() {
        let stored = StoredCompletions(
            week: doneWeek,
            counts: Dictionary(uniqueKeysWithValues: done.map { space, counts in
                (space.rawValue,
                 Dictionary(uniqueKeysWithValues: counts.map { (String($0.key.rawValue), $0.value) }))
            })
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        write(data, to: doneURL)
    }

    private func loadArchive() {
        guard let data = contents(of: archiveURL) else { return }
        guard let stored = try? JSONDecoder().decode([CompletedTask].self, from: data) else {
            quarantine(archiveURL)
            return
        }
        archive = stored
    }

    private func saveArchive() {
        guard let data = try? JSONEncoder().encode(archive) else { return }
        write(data, to: archiveURL)
    }
}
