import Foundation
import AppKit

/// The task boxes: a 20-minute focus timer, and a 60-minute one for a task
/// handed to an agent. Several tasks can be timed at once — one box each, of
/// either kind — and none of them are persisted: quitting drops them.
///
/// Each countdown is derived from its `deadline` rather than counted down tick by
/// tick, so it stays accurate if ticks are delayed (menu tracking, app nap). One
/// ticker drives them all, and it only runs while there's something to count.
///
/// The 4×/s tick is published by a *separate* object (`clock`), not by
/// `TaskTimer` itself: only the countdown labels observe it, so a running timer
/// no longer rebuilds the whole panel — rows, day slices and drop delegates
/// included — four times a second. `TaskTimer` republishes only when a timer
/// actually starts or stops.
@MainActor
final class TimerClock: ObservableObject {
    /// What the countdowns are measured against; refreshed on every tick.
    @Published fileprivate(set) var now = Date()
}

@MainActor
final class TaskTimer: ObservableObject {
    /// How long an ordinary task gets. Fixed by design — the point is a constant
    /// box; the caller passes a different one only for the planning task.
    nonisolated static let duration: TimeInterval = 20 * 60

    /// How long a task handed to an agent gets. An hour, because that is what
    /// an agent typically takes to come back — the box is a reminder to go and
    /// look, not a stretch of focus.
    nonisolated static let agentDuration: TimeInterval = 60 * 60

    /// What a running box is for. A row has at most one at a time, so the kind
    /// is what tells the two buttons which of them is showing a stop glyph —
    /// and what colours the countdown.
    enum Kind {
        /// The user sitting with the task.
        case focus
        /// An agent working on it somewhere else.
        case agent

        /// The default box for this kind (the planning task overrides `focus`).
        var duration: TimeInterval {
            switch self {
            case .focus: TaskTimer.duration
            case .agent: TaskTimer.agentDuration
            }
        }
    }

    /// One running box: when it runs out, and what it is for.
    private struct Run {
        var deadline: Date
        var kind: Kind
    }

    /// The boxes currently running, keyed by task.
    @Published private var runs: [UUID: Run] = [:]
    /// The shared tick. Observed only where a countdown is actually drawn.
    let clock = TimerClock()

    private var now: Date {
        get { clock.now }
        set { clock.now = newValue }
    }

    private var ticker: Timer?

    var isRunning: Bool { !runs.isEmpty }

    func isRunning(_ id: UUID) -> Bool { runs[id] != nil }

    /// Whether `id` is being timed *for that purpose* — which is what each of
    /// the row's two buttons asks about itself.
    func isRunning(_ id: UUID, kind: Kind) -> Bool { runs[id]?.kind == kind }

    /// What `id`'s running box is for (`nil` when it isn't running).
    func kind(_ id: UUID) -> Kind? { runs[id]?.kind }

    /// Seconds left on `id`'s timer (0 when it isn't running).
    func remaining(_ id: UUID) -> TimeInterval {
        guard let run = runs[id] else { return 0 }
        return max(0, run.deadline.timeIntervalSince(now))
    }

    /// Starts (or restarts) the countdown for `id`, alongside any others. A row
    /// gets one box at a time, so starting one kind replaces the other.
    func start(_ id: UUID, kind: Kind = .focus, duration: TimeInterval? = nil) {
        now = Date()
        runs[id] = Run(deadline: now.addingTimeInterval(duration ?? kind.duration), kind: kind)
        guard ticker == nil else { return }

        // .common mode so the countdowns keep ticking while a menu or the
        // popover is tracking events.
        let ticker = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    /// Stops one countdown (the stop button, or the timed task disappearing).
    /// A no-op if that task isn't being timed.
    func stop(_ id: UUID) {
        guard runs.removeValue(forKey: id) != nil else { return }
        stopTickerIfIdle()
    }

    /// Toggle used by the row's two run buttons: pressing the kind that is
    /// already running stops it, pressing the other one takes the row over.
    func toggle(_ id: UUID, kind: Kind = .focus, duration: TimeInterval? = nil) {
        if isRunning(id, kind: kind) { stop(id) } else { start(id, kind: kind, duration: duration) }
    }

    /// `mm:ss` for one task's timer.
    func display(_ id: UUID) -> String { Self.format(remaining(id)) }

    /// `mm:ss` for the timer that runs out first — what the menu bar shows.
    var display: String {
        Self.format(runs.values.map(\.deadline).min().map { max(0, $0.timeIntervalSince(now)) } ?? 0)
    }

    /// Rounded up, so a countdown starts at 20:00 and only reads 0:00 when the
    /// time is actually gone.
    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func tick() {
        now = Date()
        let expired = runs.filter { $0.value.deadline <= now }.keys
        guard !expired.isEmpty else { return }
        expired.forEach { runs.removeValue(forKey: $0) }
        stopTickerIfIdle()
        // One sound even if two boxes run out in the same tick.
        Self.alarm()
    }

    private func stopTickerIfIdle() {
        guard runs.isEmpty else { return }
        ticker?.invalidate()
        ticker = nil
    }

    /// One single sound when the time is up — no repeat, no notification.
    private static func alarm() {
        (NSSound(named: "Glass") ?? NSSound(named: "Ping"))?.play()
    }
}
