import SwiftUI
import UniformTypeIdentifiers

/// The dropdown panel: a Personal/Work space switch, a text field to capture a
/// task, a day picker, the open tasks grouped Monday→Sunday, a transient undo
/// bar, and a footer (launch-at-login + quit).
///
/// Everything below the space switch is a view of *one* space: the week, the
/// long-term list, the tallies and the fold state all belong to whichever space
/// is on show.
struct MenuBarView: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var timer: TaskTimer

    @State private var showUndo = false
    @State private var launchAtLogin = false
    @State private var undoDismissWork: DispatchWorkItem?
    @State private var listContentHeight: CGFloat = 0
    @State private var dragging: UUID?
    /// The day new tasks land on. Defaults to today, and the user can aim
    /// elsewhere in the week before pressing Return.
    @State private var targetDay: Bucket = .current
    /// Held in state (rather than read per render) so "today" is resolved once
    /// per panel opening.
    @State private var today: Bucket = .current
    /// The quadrant new tasks are captured with, `nil` for untriaged — where a
    /// freshly opened panel starts. Sticky for the rest of the session, like
    /// `targetDay`: filing a batch of urgent things shouldn't mean re-picking
    /// `!` for each one.
    @State private var targetPriority: Priority?
    /// The days folded shut, as a comma-separated list of weekday numbers — one
    /// list per space, since a day folded shut at work says nothing about the
    /// evening's. Persisted so the panel opens the way it was left; it's pure UI
    /// state, so it lives here rather than in `TaskStore`.
    /// The days whose ✓ tally has been clicked open, so their completed tasks
    /// are listed under the heading. Session-only, unlike the fold state: it's a
    /// peek at what's been done, not a way the panel is arranged.
    @State private var showingDone: Set<Bucket> = []
    /// What is being searched for, or "" when the panel is showing the week.
    @State private var query = ""
    /// Whether the search field is on screen at all. It isn't, until ⌘F asks
    /// for it: the panel is meant to be read at a glance, and a box that is
    /// empty nine openings out of ten is one line of chrome above the week for
    /// nothing. Closing the panel puts it away again — a search is a question
    /// being asked right now, not a way the panel is set up.
    @State private var showSearch = false
    @FocusState private var searching: Bool
    @AppStorage("collapsedDays") private var collapsedPersonalRaw = ""
    @AppStorage("collapsedDays.work") private var collapsedWorkRaw = ""

    /// Tallest the task list may grow before it starts scrolling: sized so the
    /// whole panel takes about three quarters of the screen, so a long list
    /// shows as much of itself as it can. Falls back to a fixed cap when there's
    /// no screen to ask.
    private var maxListHeight: CGFloat {
        guard let screen = NSScreen.main else { return fallbackListHeight }
        // Everything above and below the rows: space picker, capture field, day
        // picker, dividers, the transient undo bar, and the footer.
        let chrome: CGFloat = 180
        // Three quarters of the screen — but never taller than the room the
        // popover actually has below the menu bar (Dock included).
        let panel = min(screen.frame.height * 0.75, screen.visibleFrame.height - 24)
        return max(fallbackListHeight, panel - chrome)
    }

    private let fallbackListHeight: CGFloat = 380

    /// The fold state of the space on show. The personal one keeps the original
    /// `collapsedDays` key, so an existing install opens folded as it was left.
    private var collapsedDaysRaw: String {
        get { store.space == .work ? collapsedWorkRaw : collapsedPersonalRaw }
        nonmutating set {
            if store.space == .work { collapsedWorkRaw = newValue }
            else { collapsedPersonalRaw = newValue }
        }
    }

    private var collapsedDays: Set<Bucket> {
        Set(collapsedDaysRaw.split(separator: ",").compactMap {
            Int($0).flatMap(Bucket.init(rawValue:))
        })
    }

    private func setCollapsed(_ day: Bucket, _ collapsed: Bool) {
        var days = collapsedDays
        if collapsed { days.insert(day) } else { days.remove(day) }
        collapsedDaysRaw = days.map { String($0.rawValue) }.sorted().joined(separator: ",")
    }

    /// The height to give the list: the rows' own height while they fit, capped
    /// once they don't. Before the rows have been measured the cap stands in, so
    /// a long list is never rendered at full height.
    private var listHeight: CGFloat {
        min(listContentHeight > 0 ? listContentHeight : maxListHeight, maxListHeight)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !store.recoveries.isEmpty { recoveryBanner }
            spacePicker
            captureField
            dayPicker
            if showSearch { searchField }
            Divider()
            taskList
            if showUndo { undoBar }
            Divider()
            footer
        }
        // 520pt, not the 300 it opened at: tasks here are deliberately specific,
        // and at 300 a long one wrapped to eight or nine lines. This is about
        // 64 characters a line, which brings the same task down to four.
        .frame(width: 520)
        .onAppear {
            launchAtLogin = LaunchAtLogin.isEnabled
            // Re-derive in case the app has been running since before midnight.
            today = .current
            // Aiming at another day is a per-capture decision; the space is a
            // lasting one, so it is left exactly as it was.
            targetDay = today
            // Same reasoning, and the same reason it starts at none: a quadrant
            // set last night shouldn't silently tag tomorrow's first capture.
            targetPriority = nil
            // The panel opens on the week, never on the last search — and
            // without the box that asked it.
            closeSearch()
            // A panel opened the morning after the app was launched still gets
            // that day's planning task.
            store.seedPlanningTask()
        }
        // Clicking away shuts the popover; the search goes with it, so the
        // panel is never reopened onto a question asked an hour ago. `onAppear`
        // does the same, for the case where a popover is reused rather than
        // torn down.
        .onDisappear { closeSearch() }
        // ⌘F reaches the field whether or not it is on screen, so it lives out
        // here rather than inside it. Pressing it again puts the search away —
        // the same key both opens and closes, and it is how the field is
        // dismissed without waiting for the panel to close (Escape belongs to
        // the popover).
        .background(
            Button("") { toggleSearch() }
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    // MARK: - Sections

    /// The Personal/Work switch, at the very top: it governs everything under
    /// it, so it reads as the frame around the panel rather than one more
    /// control inside it.
    private var spacePicker: some View {
        Picker("", selection: $store.space) {
            ForEach(Space.allCases) { space in
                Text(space.name).tag(space)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .help("Which list to show — each space has its own week and long-term list")
    }

    private var captureField: some View {
        // The draft text lives in `CaptureField`, not here: held on the panel it
        // rebuilt every row on every keystroke.
        CaptureField { store.add($0, on: targetDay, priority: targetPriority) }
    }

    /// The long-term list's colour, kept away from the app's tint (which means
    /// "today") and from the planning task's orange, so the three never read as
    /// each other.
    private let longTermTint = Color.purple

    /// Where new tasks land: the week as a segmented picker, with the long-term
    /// list deliberately *outside* it. An eighth segment made "L" look like an
    /// eighth day; a separate, purple button says it is somewhere else entirely.
    private var dayPicker: some View {
        HStack(spacing: 8) {
            Picker("", selection: $targetDay) {
                ForEach(Bucket.week) { day in
                    Text(day.shortName).tag(day)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .help("The day new tasks are added to")

            longTermButton

            // A wider gap than the row's own: what follows answers a different
            // question — not which list the task goes in, but how much it
            // matters. Same row all the same, so everything the capture field
            // is aimed at is in one place rather than two bands of chrome.
            Spacer().frame(width: 4)

            ForEach(Priority.allCases) { priority in
                priorityButton(priority)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// One quadrant button for the capture row, shaped like the `L` button
    /// beside it. Pressing the chosen one again clears it — exactly as `L`
    /// comes back to today — so the picker can never trap every new task in a
    /// quadrant the user has forgotten is set.
    private func priorityButton(_ priority: Priority) -> some View {
        let selected = targetPriority == priority
        let tint = priorityColor(priority)
        return Button {
            targetPriority = selected ? nil : priority
        } label: {
            Text(priority.symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
                .frame(width: 22, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(tint.opacity(selected ? 1 : 0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(tint.opacity(selected ? 0 : 0.45))
                )
        }
        .buttonStyle(.plain)
        .help(
            selected
                ? "New tasks are tagged \(priority.symbol) — press again to stop"
                : "Tag new tasks \(priority.symbol) \(priority.action) — \(priority.axes)"
        )
    }

    /// The `L` tag. Selecting it aims new tasks at the long-term list; pressing
    /// it again comes back to today, so it never traps the capture field
    /// somewhere the user has forgotten about.
    private var longTermButton: some View {
        let selected = targetDay == .longTerm
        return Button {
            targetDay = selected ? today : .longTerm
        } label: {
            Text(Bucket.longTerm.shortName)
                .font(.caption.weight(.bold))
                .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(longTermTint))
                .frame(width: 24, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(longTermTint.opacity(selected ? 1 : 0.14))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(longTermTint.opacity(selected ? 0 : 0.45))
                )
        }
        .buttonStyle(.plain)
        .help("Add to the long-term list instead of a day")
    }

    /// The search box: one line under the capture chrome, shown only once ⌘F
    /// has asked for it and taken away again as soon as the panel closes.
    ///
    /// Separate from the capture field on purpose: that one is aimed at a day,
    /// a space and a quadrant, and everything typed into it becomes a task.
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($searching)
                .help("Show only the tasks matching what you type — text and #area, either space")
            // One button, and it closes the whole thing rather than only
            // emptying it: an empty search box is the clutter ⌘F exists to
            // avoid, so there is nothing worth leaving behind.
            Button {
                closeSearch()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Close the search (⌘F)")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    /// ⌘F: open the search and put the caret in it, or put it away if it is
    /// already open.
    private func toggleSearch() {
        if showSearch {
            closeSearch()
        } else {
            withAnimation { showSearch = true }
            // Deferred a turn, like the list's opening scroll: focusing a field
            // in the same frame it appears in doesn't take.
            DispatchQueue.main.async { searching = true }
        }
    }

    /// Put the search away, taking the query with it — so the week comes back
    /// rather than the panel being left on a stale set of matches.
    private func closeSearch() {
        query = ""
        searching = false
        showSearch = false
    }

    /// The space that isn't on show — where a search says how many matches it
    /// found without going there.
    private var otherSpace: Space {
        store.space == .work ? .personal : .work
    }

    /// The matching rows, grouped under the days they are filed on. Days with
    /// no match are left out entirely (unlike the week, where every day renders
    /// because every day is a drop target), and the fold state is ignored: a
    /// task hidden in a shut day is exactly what a search is for.
    ///
    /// The rows are ordinary `TaskRow`s, so a task found here can be edited,
    /// timed or ticked off where it stands rather than hunted down afterwards.
    @ViewBuilder
    private var searchResults: some View {
        let results = store.search(query)
        let elsewhere = store.searchCount(query, in: otherSpace)
        VStack(spacing: 0) {
            if results.isEmpty {
                Text("Nothing in \(store.space.name) matches.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                ForEach(Bucket.allCases) { day in
                    let hits = results.filter { $0.day == day }
                    if !hits.isEmpty {
                        resultHeader(day, count: hits.count)
                        ForEach(hits) { task in
                            TaskRow(
                                task: task,
                                dragging: $dragging,
                                onComplete: { complete(task) },
                                onDelete: { remove(task) },
                                onEdit: { store.update(task.id, text: $0) },
                                onReschedule: { target in
                                    withAnimation {
                                        setCollapsed(target, false)
                                        store.move(task.id, to: target)
                                    }
                                }
                            )
                            Divider()
                        }
                    }
                }
            }
            if elsewhere > 0 { otherSpaceHint(elsewhere) }
        }
        // Measured like the week's rows, so a short result list shrinks the
        // panel instead of leaving it at the height the week needed.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { listContentHeight = geo.size.height }
                    .onChange(of: geo.size.height) { listContentHeight = $0 }
            }
        )
    }

    /// A day heading for the results list. Deliberately not `dayHeader`: there
    /// is no chevron and no ✓ tally, because neither folding nor the week's
    /// tallies mean anything about a set of matches.
    private func resultHeader(_ day: Bucket, count: Int) -> some View {
        HStack(spacing: 6) {
            if day == .longTerm {
                Image(systemName: "tray.full")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(longTermTint)
            }
            Text(day.name.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(headingStyle(day))
            if day == today {
                Text("today")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(day == .longTerm ? AnyShapeStyle(longTermTint.opacity(0.12)) : AnyShapeStyle(Color.primary.opacity(0.05)))
    }

    /// "3 in Personal" — the one thing a search can't show, since the panel is
    /// a view of one space. A button rather than a note: the answer to finding
    /// the task somewhere else is to go there, carrying the query along.
    private func otherSpaceHint(_ count: Int) -> some View {
        Button {
            store.space = otherSpace
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                Text("\(count) also in \(otherSpace.name)")
                    .font(.caption)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(otherSpace.name) instead, keeping the search")
    }

    @ViewBuilder
    private var taskList: some View {
        // A search replaces the week outright rather than dimming the rows
        // that don't match: what is being asked for is a short list, and the
        // week around it is what made the task hard to find in the first place.
        if !query.trimmingCharacters(in: .whitespaces).isEmpty {
            ScrollView { searchResults }
                .frame(height: listHeight)
        // Nothing left to do *and* nothing done yet — otherwise keep the day
        // sections up, so a cleared list still shows what was cleared.
        } else if store.visibleTasks.isEmpty && store.completedThisWeek == 0 {
            Text("No tasks. Type above to add one.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
        } else {
            // The rows always live in a ScrollView, given an explicit height:
            // one that hugs the rows while they fit, and stops at the cap once
            // they don't. A ScrollView reports ~0 ideal height in this
            // self-sizing panel, so the height has to be stated — it comes from
            // measuring the rows (which are laid out at their natural height
            // inside the ScrollView, whatever height we give it). Until that
            // measurement lands, assume the cap: a long list then scrolls from
            // the first frame instead of briefly rendering taller than the
            // screen.
            ScrollViewReader { proxy in
                ScrollView { taskRows }
                    .frame(height: listHeight)
                    // A five-day list usually starts scrolled past today; open
                    // on it instead. Deferred a turn: scrolling before the rows
                    // have been laid out does nothing.
                    .onAppear {
                        DispatchQueue.main.async { proxy.scrollTo(today, anchor: .top) }
                    }
                    // Switching space shows a different week; start it on today
                    // too, rather than wherever the last one was scrolled to.
                    .onChange(of: store.space) { _ in
                        DispatchQueue.main.async { proxy.scrollTo(today, anchor: .top) }
                    }
            }
        }
    }

    private var taskRows: some View {
        VStack(spacing: 0) {
            ForEach(Bucket.allCases) { day in
                // Sunday ends the week; the long-term list starts something
                // else, so it gets air above it rather than another divider.
                if day == .longTerm { Spacer().frame(height: 10) }
                daySection(day)
            }
        }
        // Report the rows' natural height so the list can be sized to fit. The
        // height is handed up through state rather than a `PreferenceKey`:
        // preferences set inside a `background` don't reach the parent.
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { listContentHeight = geo.size.height }
                    .onChange(of: geo.size.height) { listContentHeight = $0 }
            }
        )
        // Catches drops that land in the gaps between rows so the drag always
        // resolves (and the faded row is restored) instead of getting stuck.
        .onDrop(of: [.text], delegate: ListDropDelegate(dragging: $dragging, store: store))
    }

    /// One day's heading plus its rows. Both the heading and the empty-day
    /// placeholder accept drops, so a task can be moved to a day that has no
    /// rows to aim at.
    private func daySection(_ day: Bucket) -> some View {
        let dayTasks = store.tasks(on: day)
        let collapsed = collapsedDays.contains(day)
        let doneTasks = showingDone.contains(day) ? store.completedTasks(on: day) : []
        return VStack(spacing: 0) {
            dayHeader(
                day,
                count: dayTasks.count,
                done: store.completedCount(on: day),
                collapsed: collapsed,
                showingDone: showingDone.contains(day),
                toggleDone: {
                    withAnimation {
                        if showingDone.contains(day) {
                            showingDone.remove(day)
                        } else {
                            showingDone.insert(day)
                            // No point revealing them into a section that's shut.
                            setCollapsed(day, false)
                        }
                    }
                }
            )
            .onTapGesture { withAnimation { setCollapsed(day, !collapsed) } }
            .onDrop(
                of: [.text],
                delegate: DayDropDelegate(
                    day: day,
                    dragging: $dragging,
                    store: store,
                    // Unfold the day as the drag lands on it, so the task is
                    // seen arriving instead of vanishing into a shut section.
                    expand: { setCollapsed(day, false) }
                )
            )

            if !collapsed {
                ForEach(doneTasks) { completed in
                    completedRow(completed)
                    Divider()
                }
            }

            if collapsed {
                Divider()
            } else if dayTasks.isEmpty {
                Text("—")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onDrop(
                        of: [.text],
                        delegate: DayDropDelegate(
                            day: day,
                            dragging: $dragging,
                            store: store,
                            expand: {}
                        )
                    )
                Divider()
            } else {
                ForEach(dayTasks) { task in
                    TaskRow(
                        task: task,
                        dragging: $dragging,
                        onComplete: { complete(task) },
                        onDelete: { remove(task) },
                        onEdit: { store.update(task.id, text: $0) },
                        onReschedule: { target in
                            withAnimation {
                                // Unfold the destination first, for the same
                                // reason a drag does: the task should be seen
                                // arriving rather than disappearing.
                                setCollapsed(target, false)
                                store.move(task.id, to: target)
                            }
                        }
                    )
                    Divider()
                }
            }
        }
        .id(day)
    }

    /// One ticked-off task, listed under its day's heading while the ✓ tally is
    /// open. Struck through and greyed, and deliberately inert — the registry is
    /// a record of what was done, not another list to work on. (Undo is the
    /// transient bar, which reaches only the last one.)
    private func completedRow(_ task: CompletedTask) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green.opacity(0.6))
            // The quadrant it was in, if any — faint, like the rest of the
            // record. Only when there is one: a blank slot on every done row
            // would be more noise than the alignment is worth.
            if let priority = task.priority {
                Text(priority.symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.quaternary)
            }
            if let area = task.area {
                AreaCapsule(name: area, hue: store.hue(of: area), faded: true)
            }
            Text(task.text)
                .font(.callout)
                .strikethrough()
                .foregroundStyle(.tertiary)
            Spacer(minLength: 0)
            Text(task.completedAt, style: .time)
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.green.opacity(0.05))
    }

    /// `count` is what's left on the day, `done` how many were completed on it
    /// this week. Tapping the heading folds the day shut — the counts stay put,
    /// so a collapsed day still says what's inside it. Tapping the ✓ tally
    /// instead lists what that number counts, without folding anything.
    private func dayHeader(
        _ day: Bucket,
        count: Int,
        done: Int,
        collapsed: Bool,
        showingDone: Bool,
        toggleDone: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                // Fixed width so the day names line up whichever way it points.
                .frame(width: 8)
            if day == .longTerm {
                Image(systemName: "tray.full")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(longTermTint)
            }
            Text(day.name.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(headingStyle(day))
            if day == today {
                Text("today")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if day == .longTerm {
                Text("someday")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if done > 0 {
                Label("\(done)", systemImage: "checkmark")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .labelStyle(TightLabelStyle())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.green.opacity(showingDone ? 0.18 : 0))
                    )
                    .contentShape(Rectangle())
                    // Ahead of the heading's own tap gesture, so clicking the
                    // tally lists the tasks instead of folding the day shut.
                    .onTapGesture(perform: toggleDone)
                    .help(showingDone
                        ? "Hide what was completed \(day.place)"
                        : "\(done) completed \(day.place) — click to list them")
            }
            if count > 0 {
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("\(count) left \(day.place)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        // The long-term heading carries its own colour rather than the shared
        // grey, so the eye stops at the point the week ends.
        .background(day == .longTerm ? AnyShapeStyle(longTermTint.opacity(0.12)) : AnyShapeStyle(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
        .help(collapsed ? "Show the tasks \(day.place)" : "Hide the tasks \(day.place)")
    }

    /// Three distinct headings: today in the app's tint, the long-term list in
    /// purple, every other day in plain secondary grey.
    private func headingStyle(_ day: Bucket) -> AnyShapeStyle {
        if day == .longTerm { return AnyShapeStyle(longTermTint) }
        return day == today ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }

    /// Shown only when a data file could not be read at launch — empty in every
    /// ordinary session. Not a toast: it stays until dismissed, because the copy
    /// it names is the only one left, and a user who misses the message has no
    /// way to find out later that their list was replaced rather than lost.
    private var recoveryBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.recoveries) { recovery in
                if let backup = recovery.backup {
                    Text("Couldn't read \(recovery.file) — its contents were kept as \(backup), and the app started without them.")
                } else {
                    Text("Couldn't read \(recovery.file), and couldn't move it aside either. Nothing will be written to it this session, so whatever is in it is safe.")
                }
            }
            HStack(spacing: 8) {
                Text("~/Library/Application Support/Zundra")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Dismiss") { store.dismissRecoveries() }
                    .buttonStyle(.link)
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
    }

    private var undoBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(store.pendingUndoKind == .deleted ? "Task deleted" : "Task completed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo", action: performUndo)
                    .buttonStyle(.link)
            }
            .padding(10)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var footer: some View {
        HStack {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .toggleStyle(.checkbox)
                .font(.caption)
                .onChange(of: launchAtLogin) { newValue in
                    LaunchAtLogin.set(newValue)
                }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(10)
    }

    // MARK: - Actions

    private func complete(_ task: TaskItem) {
        timer.stop(task.id)
        store.complete(task)
        offerUndo()
    }

    /// Delete a task — no tally, no archive entry. Shares the undo bar with
    /// completion, which says which of the two it is taking back.
    private func remove(_ task: TaskItem) {
        timer.stop(task.id)
        store.delete(task)
        offerUndo()
    }

    /// Shows the undo bar for 4 seconds. A second act cancels the previous
    /// timer so the bar doesn't vanish early.
    private func offerUndo() {
        withAnimation { showUndo = true }

        undoDismissWork?.cancel()
        let work = DispatchWorkItem {
            withAnimation { showUndo = false }
            store.clearUndo()
        }
        undoDismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    private func performUndo() {
        undoDismissWork?.cancel()
        store.undoLast()
        withAnimation { showUndo = false }
    }
}

/// The capture field. Owns its own draft text so typing redraws one text field
/// rather than the whole panel (five day slices, every row, the drop delegates).
private struct CaptureField: View {
    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        // Vertical axis so a long, specific task wraps instead of scrolling
        // sideways out of view; `lineLimit(1...)` keeps the field one line tall
        // until there is a second line to show.
        // The placeholder is where `#area` is discovered — there is no area list
        // to find it in, by design.
        TextField("Add a task…  (#area to file it)", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .lineLimit(1...)
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .focused($focused)
            .onSubmit {
                // A vertical-axis field can take newlines (⌥Return, or a
                // pasted block); a task is one line of text, so flatten them.
                onSubmit(text.replacingOccurrences(of: "\n", with: " "))
                text = ""
                focused = true
            }
            .onAppear { focused = true }
    }
}

/// The colour a quadrant is drawn in — the row's badge and the capture row's
/// picker, so the `!` you press to aim and the `!` that lands on the row are
/// unmistakably the same thing.
///
/// Only the *important* half of the matrix gets a hue; the two unimportant
/// quadrants are grey, told apart by their glyph. `.blue` by name rather than
/// the accent, so a badge means the same thing whatever accent the Mac is set to.
private func priorityColor(_ priority: Priority) -> Color {
    switch priority {
    case .now: .red
    case .schedule: .blue
    case .delegate, .drop: .gray
    }
}

/// The colour of an area's capsule: sixteen hues round the wheel, indexed by the
/// hue the store assigned that area the first time it appeared
/// (`TaskStore.hue(of:)`) — so no colour is ever chosen by hand, no two areas
/// share one until there are more than sixteen, and an area's colour never
/// changes afterwards.
///
/// **Slots 0-9 must stay exactly as they are**: a hue is persisted as an index,
/// so reordering or restyling them repaints every row already tagged. The six
/// after them were added when twelve areas were in use and ten hues weren't
/// enough; they go in the widest gaps between the original ten rather than at
/// the end of the wheel, so the *sixteenth* area is still as far from its
/// neighbours as the palette allows.
///
/// An earlier palette dodged every colour this panel spends meaning on — red
/// `!`, blue `↑`, purple long-term, orange planning, green tallies — and what
/// was left (teal, cyan and mint side by side, plus a grey that isn't a hue)
/// couldn't be told apart. A capsule can't be confused with those signals
/// anyway, because it doesn't share their *form*: they are saturated glyphs and
/// headings, a capsule is a pale tinted pill with neutral text.
///
/// Must hold exactly `Area.paletteCount` colours; the modulo is a
/// belt-and-braces guard, not a licence to disagree.
private func areaColor(hue: Int) -> Color {
    // The six additions have no system name, so they are stated outright. Fixed
    // rather than theme-adaptive, which the ten system colours are — it shows
    // less than it sounds, since a capsule only ever draws them at a fifth
    // opacity behind neutral text.
    func fixed(_ hue: Double, _ saturation: Double, _ brightness: Double) -> Color {
        Color(hue: hue, saturation: saturation, brightness: brightness)
    }
    let palette: [Color] = [
        // 0-9: the original ten. Do not move.
        .red, .orange, .yellow, .green, .teal, .cyan, .blue, .indigo, .purple, .pink,
        fixed(0.19, 0.75, 0.80),   // 10 lime — into the wide yellow→green gap
        fixed(0.27, 0.65, 0.68),   // 11 grass — the other half of that gap
        fixed(0.40, 0.60, 0.76),   // 12 spring — between green and teal
        fixed(0.73, 0.58, 0.86),   // 13 violet — between indigo and purple
        fixed(0.87, 0.70, 0.84),   // 14 magenta — between purple and pink
        // 15 rust — orange's own hue, set apart by depth rather than by
        // position, there being no gap left worth taking on that side.
        fixed(0.07, 0.72, 0.48),
    ]
    return palette[abs(hue) % palette.count]
}

/// An area tag: a small tinted pill carrying the area's own word, sitting
/// immediately before the task text so a week split into areas can be read down
/// the panel without anything being reordered.
///
/// The *name* is in the label colour and only the pill is tinted — coloured text
/// at this size is hard to read in one theme or the other, and the hue only has
/// to say "different area", not which one. `fixedSize` keeps it from being
/// squeezed by the text field beside it; `Area.maxLength` is what keeps it small.
private struct AreaCapsule: View {
    let name: String
    /// Which of the palette's hues this area was assigned — handed in rather
    /// than looked up here, so the capsule stays a dumb view and the store is
    /// read once, by the row that owns it.
    let hue: Int
    /// Quieter still, for the struck-through rows under an open ✓ tally.
    var faded = false

    private var tint: Color { areaColor(hue: hue) }

    var body: some View {
        Text(name)
            .font(.caption)
            .lineLimit(1)
            .foregroundStyle(faded ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.primary.opacity(0.75)))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(tint.opacity(faded ? 0.08 : 0.20))
            )
            // A border in the same hue, at roughly twice the fill's strength.
            // A pale fill alone reads as "some colour"; the outline is what
            // makes two neighbouring hues tell themselves apart at this size.
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(tint.opacity(faded ? 0.15 : 0.45))
            )
            .fixedSize()
            .help("Area: \(name)")
    }
}

/// One row: a click-to-complete circle, the task text (editable in place), and
/// two run buttons — the 20-minute focus timer and the hour-long agent one.
/// Edits commit on Return or when the field loses focus; clearing the text
/// reverts to the original (use the circle to remove a task instead).
struct TaskRow: View {
    @EnvironmentObject private var store: TaskStore
    @EnvironmentObject private var timer: TaskTimer

    let task: TaskItem
    @Binding var dragging: UUID?
    let onComplete: () -> Void
    /// Removes the task outright. Separate from `onComplete` because the two
    /// mean opposite things to the ✓ tally.
    let onDelete: () -> Void
    let onEdit: (String) -> Void
    /// Refiles the task under another bucket. Handed in rather than called on
    /// the store directly so the section can unfold the destination first — a
    /// task that lands in a shut day would otherwise just vanish.
    let onReschedule: (Bucket) -> Void

    @State private var draft: String
    @FocusState private var editing: Bool
    /// Whether the pointer is over this row — the only thing that reveals the
    /// priority badge on an untagged one.
    @State private var hovering = false

    init(
        task: TaskItem,
        dragging: Binding<UUID?>,
        onComplete: @escaping () -> Void,
        onDelete: @escaping () -> Void,
        onEdit: @escaping (String) -> Void,
        onReschedule: @escaping (Bucket) -> Void
    ) {
        self.task = task
        _dragging = dragging
        self.onComplete = onComplete
        self.onDelete = onDelete
        self.onEdit = onEdit
        self.onReschedule = onReschedule
        _draft = State(initialValue: task.text)
    }

    /// The space this task is *not* in — where the context menu offers to send
    /// it. Derived from the task rather than from the store's current space, so
    /// it stays right even mid-switch.
    private var other: Space {
        task.space == .work ? .personal : .work
    }

    /// The bucket the context menu offers to send the task to: out of the way
    /// when a day is overloaded, and back onto today when a long-term task is
    /// being picked up. One item, because those are the only two directions
    /// worth a menu — any other day is a drag away.
    private var otherBucket: Bucket {
        task.day == .longTerm ? .current : .longTerm
    }

    /// The row's colour: the app's tint for ordinary tasks, a distinct one for
    /// the planning task the app seeds each morning.
    private var accent: Color { task.kind == .planning ? .orange : .accentColor }

    /// The quadrant a click on the badge moves to: the first one when the row is
    /// untagged, the next one along otherwise, and untagged again after the last
    /// — so the one control reaches all five states without opening a menu.
    private var nextPriority: Priority? {
        guard let current = task.priority else { return .first }
        return current.next
    }

    /// How the badge glyph is inked — `priorityColor` for the important pair,
    /// hierarchical grey for the rest. Keeping ink for importance is the
    /// matrix's own point, and it keeps the badges clear of the three colours
    /// the panel already spends: the tint for today, purple for long-term,
    /// orange for the planning task.
    private var priorityStyle: AnyShapeStyle {
        switch task.priority {
        case .now: AnyShapeStyle(priorityColor(.now))
        case .schedule: AnyShapeStyle(priorityColor(.schedule))
        // The unimportant pair take the hierarchical greys rather than the
        // picker's flat one: as glyphs on a row they should fade with the text
        // around them, which `.secondary`/`.tertiary` do and a fixed grey won't.
        case .delegate: AnyShapeStyle(.secondary)
        case .drop: AnyShapeStyle(.tertiary)
        // The hover hint is `!`, so it previews the colour a click would set.
        case nil: AnyShapeStyle(priorityColor(.first))
        }
    }

    /// The one-character quadrant badge, in a fixed-width slot so the task text
    /// starts at the same x whether a row is tagged or not.
    ///
    /// An untagged row shows nothing until the pointer is over it, and then only
    /// a whisper of the first glyph: the point of the matrix is that most rows
    /// aren't in it, and a placeholder on every row would be exactly the noise
    /// the tags exist to cut through. The slot stays clickable either way —
    /// `opacity` hides a button without un-hitting it.
    private var priorityBadge: some View {
        Button { store.setPriority(task.id, to: nextPriority) } label: {
            Text(task.priority?.symbol ?? Priority.first.symbol)
                .font(.callout.weight(.bold))
                .foregroundStyle(priorityStyle)
                .opacity(task.priority == nil ? (hovering ? 0.35 : 0) : 1)
                .frame(width: 14, height: 19)
                // A bounded slot while the pointer is on the row: it says where
                // this button ends, which is the whole point of separating it
                // from the complete circle.
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(hovering ? 0.06 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            task.priority.map { "\($0.action) — \($0.axes). Click for the next quadrant" }
                ?? "Set a priority: ! do now, ↑ schedule, → delegate, · drop"
        )
    }

    /// What colours a running box. Teal for an agent's hour: the countdown is
    /// then saying "something is happening elsewhere", which shouldn't wear the
    /// same colour as the row you are sitting with.
    private func timerTint(_ kind: TaskTimer.Kind) -> Color {
        kind == .agent ? .teal : accent
    }

    /// How long this row's box runs, per kind. Only the focus box varies — the
    /// planning task gets a shorter one.
    private func duration(_ kind: TaskTimer.Kind) -> TimeInterval {
        kind == .agent ? TaskTimer.agentDuration : task.kind.timerDuration
    }

    /// One of the row's two run buttons. Both are toggles over the same single
    /// box, so pressing the one already running stops it and pressing the other
    /// hands the row over.
    private func runButton(_ kind: TaskTimer.Kind, glyph: String) -> some View {
        let running = timer.isRunning(task.id, kind: kind)
        return Button { timer.toggle(task.id, kind: kind, duration: duration(kind)) } label: {
            Image(systemName: running ? "stop.fill" : glyph)
                .font(.caption)
                .foregroundStyle(running ? AnyShapeStyle(timerTint(kind)) : AnyShapeStyle(.tertiary))
                // A fixed slot, so the text beside it doesn't shift as the
                // glyph swaps between play/sparkles and stop.
                .frame(width: 14)
        }
        .buttonStyle(.plain)
        .help(
            running
                ? (kind == .agent ? "Stop the agent timer" : "Stop the timer")
                : (kind == .agent
                    ? "Handed to an agent — start a \(Int(TaskTimer.agentDuration / 60))-minute timer"
                    : "Start a \(Int(task.kind.timerDuration / 60))-minute timer")
        )
    }

    var body: some View {
        // Top-aligned: on a wrapped row the controls stay level with the first
        // line of text instead of floating to the middle of the block.
        HStack(alignment: .top, spacing: 10) {
            // Grip handle: press and drag to reorder, within a day or across to
            // another one. Kept separate from the text field so a plain click
            // still lands in the field for editing.
            Image(systemName: "line.3.horizontal")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .contentShape(Rectangle())
                .onDrag {
                    dragging = task.id
                    return NSItemProvider(object: task.id.uuidString as NSString)
                }
                .help("Drag to reorder within a band, to another day or the long-term list, or into another priority band to retag it")

            Button(action: onComplete) {
                Image(systemName: "circle")
                    .font(.title3)
                    .foregroundStyle(task.kind == .planning ? AnyShapeStyle(accent) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.plain)
            .help("Complete task")

            // Deliberately *not* clustered against the circle. It sat 5pt from
            // it at first, which put a small, mostly invisible target next to
            // the one control that removes a task — and the undo bar reaches
            // only the last completion, so a mis-click streak is unrecoverable
            // from the panel. The row's full spacing, plus the bounded slot the
            // badge draws under the pointer, keeps the two apart.
            priorityBadge

            if let area = task.area {
                AreaCapsule(name: area, hue: store.hue(of: area))
            }

            TextField("", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                // Wraps rather than clipping: tasks are deliberately specific,
                // so they're often longer than the panel is wide.
                .lineLimit(1...)
                // The planning task carries its own colour, so it reads as the
                // one row the app put there rather than one the user typed.
                .foregroundStyle(task.kind == .planning ? AnyShapeStyle(accent) : AnyShapeStyle(.primary))
                .focused($editing)
                .onSubmit(commit)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The countdown only appears while this task is being timed, and
            // takes the colour of whichever box is running. Several rows can be
            // counting down at once, of either kind.
            if let kind = timer.kind(task.id) {
                // Its own view, observing only the clock, so the 4×/s tick
                // redraws this label alone instead of the whole row.
                TimerCountdown(clock: timer.clock, id: task.id, tint: timerTint(kind))
            }

            // Two run buttons, the focus box and the agent box, in that order.
            // A row gets one at a time — pressing the other takes it over —
            // which is why each button only shows a stop glyph for its own kind.
            runButton(.focus, glyph: "play.fill")
            runButton(.agent, glyph: "sparkles")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        // Right-click to send the task across to the other space. A drag can't
        // do this — it only ever reaches rows of the space on show — and with
        // two spaces there is exactly one destination, so it's a single item.
        .contextMenu {
            // The four quadrants by name, for picking one outright — the badge
            // cycles, which is quick for the row in front of you and tedious
            // when you know exactly which quadrant you mean.
            ForEach(Priority.allCases) { priority in
                Button("\(priority.symbol)  \(priority.action) — \(priority.axes)") {
                    store.setPriority(task.id, to: priority)
                }
            }
            if task.priority != nil {
                Button("Clear priority") { store.setPriority(task.id, to: nil) }
            }
            // The areas already in use, for refiling a row without retyping it.
            // No "new area…" item: an area is *made* by typing `#name` in the
            // task, which is the one place a name can actually be entered — a
            // context menu has nowhere to type.
            let others = store.areas.filter { $0 != task.area }
            if !others.isEmpty || task.area != nil {
                Divider()
                ForEach(others, id: \.self) { area in
                    Button("Area: \(area)") { store.setArea(task.id, to: area) }
                }
                if task.area != nil {
                    Button("Clear area") { store.setArea(task.id, to: nil) }
                }
            }
            Divider()
            Button("Move to \(otherBucket == .current ? "Today" : otherBucket.name)") {
                onReschedule(otherBucket)
            }
            Button("Move to \(other.name)") { store.move(task.id, to: other) }
            // Last, under its own divider, and nowhere near the complete
            // circle. Completing a task captured by mistake is the wrong verb:
            // it inflates the day's ✓ tally and files the row in a registry
            // that has no way back out.
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
        .opacity(dragging == task.id ? 0.4 : 1)
        .onDrop(
            of: [.text],
            delegate: TaskDropDelegate(item: task, dragging: $dragging, store: store)
        )
        // Commit when the field loses focus.
        .onChange(of: editing) { isEditing in
            if !isEditing { commit() }
        }
        // Keep the draft in sync if the task text changes elsewhere (e.g. undo),
        // but never clobber what the user is actively typing.
        .onChange(of: task.text) { newValue in
            if !editing { draft = newValue }
        }
    }

    private func commit() {
        let trimmed = draft
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft = task.text          // revert; deletion is via the circle
        } else {
            onEdit(trimmed)
            // The store takes a leading `#area` *off* the text, so the field has
            // to drop it too — otherwise the row would keep showing a token
            // that is now the capsule beside it.
            draft = Area.parse(trimmed).text
        }
    }
}

/// The `mm:ss` for one running timer. Split out of `TaskRow` deliberately: it is
/// the only thing that needs the 4×/s tick, so it is the only thing that
/// observes the clock.
private struct TimerCountdown: View {
    @EnvironmentObject private var timer: TaskTimer
    @ObservedObject var clock: TimerClock
    let id: UUID
    let tint: Color

    var body: some View {
        Text(timer.display(id))
            .font(.caption.monospacedDigit())
            .foregroundStyle(tint)
    }
}

/// Reorders the list live as a dragged task hovers over `item`, then persists
/// the final order on drop. Reordering while hovering (rather than only on drop)
/// makes the list animate under the cursor the way a native `List` does.
private struct TaskDropDelegate: DropDelegate {
    let item: TaskItem
    @Binding var dragging: UUID?
    let store: TaskStore

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != item.id else { return }
        withAnimation { store.move(dragging, before: item) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        store.commitOrder()
        return true
    }
}

/// Drop target for a day heading (and for a day with no rows): files the dragged
/// task at the end of that day.
private struct DayDropDelegate: DropDelegate {
    let day: Bucket
    @Binding var dragging: UUID?
    let store: TaskStore
    let expand: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging else { return }
        withAnimation {
            expand()
            store.move(dragging, toEndOf: day)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        store.commitOrder()
        return true
    }
}

/// Container-level catch-all so a drop released in the gap between rows (or on a
/// divider) still resolves the drag: clears the dragging state and saves.
private struct ListDropDelegate: DropDelegate {
    @Binding var dragging: UUID?
    let store: TaskStore

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        store.commitOrder()
        return true
    }
}

/// A checkmark hugging its number, for the day headings' completed tally — the
/// default label style spaces icon and title like a menu item, which is too airy
/// at caption size.
private struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon
            configuration.title
        }
    }
}
