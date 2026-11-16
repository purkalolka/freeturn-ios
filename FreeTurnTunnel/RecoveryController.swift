import Foundation

/// Keeps a long-running tunnel healthy while the app is not running.
///
/// `MobileReconnect()` cancels whatever relay attempt is in flight, and a full
/// re-establishment costs the 20 s first-stream barrier plus VK credentials and twelve
/// DTLS handshakes. The old watchdog retried every 45 s unconditionally, so on a slow
/// mobile network it killed every attempt before it could converge: the stream count
/// stayed low, throughput collapsed and, once the session itself died, nothing restarted
/// it.
///
/// This controller only reacts to a *sustained lack of progress*, never interrupts an
/// attempt it has started, backs off between attempts and escalates to a full session
/// restart when a soft reconnect is not enough.
///
/// All methods must be called on the provider's serial work queue.
final class RecoveryController {

    struct Snapshot {
        var state = "idle"
        var streams = 0
        var total = 0
        var rxTotal: Int64 = 0
        var txTotal: Int64 = 0
        var rxRate: Int64 = 0
        var txRate: Int64 = 0
        /// Seconds since the last WireGuard handshake, -1 when there was none.
        var handshakeAge: Int64 = -1
    }

    enum Phase: String {
        case idle
        case healthy
        case recovering
        case backingOff
        case captcha
        case failed
    }

    struct Policy {
        /// A stream count that does not move for this long is not regular churn: the core
        /// re-dials a dead stream within seconds, so a full relay restart is only worth it
        /// once per-stream recovery has clearly given up.
        var partialGrace: TimeInterval = 45
        /// We send but nothing comes back: the relay stopped forwarding for us.
        var blackholeGrace: TimeInterval = 30
        /// No progress at all for this long means the attempt will not converge.
        var recoveryDeadline: TimeInterval = 120
        /// Uninterrupted health that resets the escalation ladder.
        var healthyReset: TimeInterval = 300
        /// A core that neither connects nor errors for this long is stuck.
        var connectingGrace: TimeInterval = 180
        /// WireGuard drops a silent peer after ~180 s (REJECT_AFTER_TIME).
        var handshakeStale: Int64 = 210
        /// After a wake the radio needs a moment before we judge the link.
        var wakeProbe: TimeInterval = 8
        /// Backoff before the next escalation, in seconds; the last value repeats.
        var backoff: [TimeInterval] = [15, 30, 60, 120, 300]
        var maxSoft = 3
        var maxHard = 2
    }

    private enum Action: Equatable {
        case soft
        case hard
        case giveUp
    }

    var policy = Policy()

    /// Rebuild TURN allocations; the tunnel and the Go session stay alive.
    var softRecovery: ((String) -> Void)?
    /// Stop the Go session and start it again on a fresh tun fd.
    var hardRecovery: ((String) -> Void)?
    /// Nothing worked: cancel the tunnel and let on-demand start a fresh process.
    var giveUp: ((String) -> Void)?
    /// Called on phase changes only; `detail` is meant for the log.
    var phaseChanged: ((Phase, String) -> Void)?

    private(set) var phase: Phase = .idle
    private var running = false
    private var startedAt = Date()

    private var lastStreams = 0
    private var lastRx: Int64 = 0
    private var lastTx: Int64 = 0
    private var lastState = "idle"
    private var streamsChangedAt = Date()
    private var rxChangedAt = Date()
    private var connectingSince: Date?
    private var healthySince: Date?
    private var recoveringSince: Date?
    private var lastProgressAt: Date?
    private var backoffUntil: Date?
    private var pending: Action?
    private var attempts = 0
    private var softAttempts = 0
    private var hardAttempts = 0
    private var lastTriggerAt = Date.distantPast
    private var lastDemandAt = Date.distantPast
    private var wakeProbeUntil: Date?
    private var lastDetail = ""

    var isRecovering: Bool { phase == .recovering || phase == .backingOff }

    // MARK: - Lifecycle

    func start() {
        running = true
        startedAt = Date()
        phase = .idle
        lastStreams = 0
        lastRx = 0
        lastTx = 0
        // Not "idle": the session is starting, and a soft reconnect must not be promoted to
        // a full restart just because no tick has run yet.
        lastState = "connecting"
        streamsChangedAt = startedAt
        rxChangedAt = startedAt
        connectingSince = nil
        healthySince = nil
        recoveringSince = nil
        lastProgressAt = nil
        backoffUntil = nil
        pending = nil
        attempts = 0
        softAttempts = 0
        hardAttempts = 0
        lastTriggerAt = .distantPast
        lastDemandAt = .distantPast
        wakeProbeUntil = nil
        lastDetail = ""
    }

    func stop() {
        running = false
        phase = .idle
        pending = nil
        backoffUntil = nil
        wakeProbeUntil = nil
    }

    // MARK: - External events

    /// The device woke up: the radio may be attached to a different network now.
    func noteWake() {
        guard running, !isRecovering, phase != .failed else { return }
        wakeProbeUntil = Date().addingTimeInterval(policy.wakeProbe)
        setPhase(phase, "device woke up")
    }

    /// Going to sleep freezes every timer, so the gap afterwards is not a stall.
    func noteSleep() {
        guard running else { return }
        let now = Date()
        streamsChangedAt = now
        rxChangedAt = now
        setPhase(phase, "device is going to sleep")
    }

    /// The physical path changed (Wi-Fi <-> cellular): the old TURN sockets are dead.
    func notePathChange(_ key: String) {
        guard running, !isRecovering, phase != .failed else { return }
        // Only when a working tunnel existed; a handover during the initial connect is
        // already covered by the "stuck connecting" rule.
        guard lastState == "connected" else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTriggerAt) > 10 else { return }
        trigger(.soft, reason: "network path \(key)", now: now)
    }

    /// Explicit request from the app (the "Reconnect" button in the log view).
    func requestSoftRecovery(_ reason: String) {
        guard running, !isRecovering, phase != .failed else { return }
        let now = Date()
        lastTriggerAt = now
        perform(.soft, reason: reason, now: now)
    }

    // MARK: - Main tick

    func tick(_ s: Snapshot) {
        guard running else { return }
        let now = Date()
        let streamsGrew = s.streams > lastStreams
        let rxGrew = s.rxTotal > lastRx
        let txDelta = s.txTotal - lastTx
        updateTrackers(s, now)
        if (streamsGrew || rxGrew) && phase == .recovering {
            lastProgressAt = now
        }

        if s.state == "captcha" {
            if phase != .captcha { setPhase(.captcha, "manual captcha pending") }
            return
        }

        if let probe = wakeProbeUntil {
            if now < probe { return }
            wakeProbeUntil = nil
            if s.state == "connected", (txDelta > 0 || s.txRate > 0), !rxGrew {
                trigger(.soft, reason: "no rx after wake", now: now)
                return
            }
        }

        switch phase {
        case .recovering:
            checkRecovery(s, now)
            return
        case .backingOff:
            if let until = backoffUntil, now < until { return }
            backoffUntil = nil
            performPending(now)
            return
        case .failed:
            return
        case .idle, .healthy, .captcha:
            break
        }

        if s.state == "error" {
            trigger(.hard, reason: "session error", now: now)
            return
        }
        if s.state == "idle" {
            if now.timeIntervalSince(startedAt) > 10 {
                trigger(.hard, reason: "session died", now: now)
            }
            return
        }
        if s.state == "connecting" {
            if let since = connectingSince, now.timeIntervalSince(since) > policy.connectingGrace {
                trigger(.soft, reason: "stuck connecting \(Int(now.timeIntervalSince(since)))s", now: now)
            }
            return
        }

        let converged = s.total > 0 && s.streams >= s.total
        // "Demand" is any traffic leaving the device in the last minute: idle is not a stall.
        let demand = txDelta > 0 || s.txRate > 0 || now.timeIntervalSince(lastDemandAt) < 60

        // Traffic leaves the device but nothing comes back: the relay black-holes us.
        if demand {
            let quiet = now.timeIntervalSince(rxChangedAt)
            if quiet >= policy.blackholeGrace {
                trigger(.soft, reason: "tx without rx for \(Int(quiet))s", now: now)
                return
            }
        }

        if converged {
            let handshakeStale = s.handshakeAge >= 0 && s.handshakeAge > policy.handshakeStale
            if handshakeStale && demand {
                trigger(.soft, reason: "handshake age \(s.handshakeAge)s with traffic", now: now)
                return
            }
            let healthyFrom = healthySince ?? now
            healthySince = healthyFrom
            if now.timeIntervalSince(healthyFrom) >= policy.healthyReset {
                resetLadder()
            }
            // Detail is deliberately stable: the phase callback logs every change, and a
            // handshake age in the string would emit a line on every tick.
            setPhase(.healthy, "streams \(s.streams)/\(s.total)")
            return
        }

        healthySince = nil
        let stalled = now.timeIntervalSince(streamsChangedAt)
        if stalled >= policy.partialGrace {
            trigger(.soft, reason: "streams \(s.streams)/\(s.total) stalled \(Int(stalled))s", now: now)
        }
    }

    // MARK: - Decision making

    private func trigger(_ action: Action, reason: String, now: Date) {
        guard running, !isRecovering, phase != .failed else { return }
        // The same bad tick must not produce two recoveries.
        guard now.timeIntervalSince(lastTriggerAt) > 5 else { return }
        lastTriggerAt = now
        perform(action, reason: reason, now: now)
    }

    private func perform(_ action: Action, reason: String, now: Date) {
        // A relay reconnect cannot revive a session that is no longer running.
        var action = action
        if action == .soft, lastState == "error" || lastState == "idle" {
            action = .hard
        }
        switch action {
        case .soft:
            softAttempts += 1
            attempts += 1
            beginRecovery(label: "soft", reason: reason, now: now)
            softRecovery?(reason)
        case .hard:
            hardAttempts += 1
            attempts += 1
            beginRecovery(label: "hard", reason: reason, now: now)
            hardRecovery?(reason)
        case .giveUp:
            pending = nil
            setPhase(.failed, "giving up: \(reason)")
            giveUp?(reason)
        }
    }

    private func beginRecovery(label: String, reason: String, now: Date) {
        recoveringSince = now
        lastProgressAt = now
        // Fresh windows: the previous stall must not be counted against the new attempt.
        streamsChangedAt = now
        rxChangedAt = now
        setPhase(.recovering, "\(label): \(reason)")
    }

    private func checkRecovery(_ s: Snapshot, _ now: Date) {
        guard let since = recoveringSince else {
            setPhase(.healthy, "recovery state without a start time")
            return
        }
        if s.total > 0 && s.streams >= s.total {
            // Give the core a moment to drop the old allocations first, otherwise a
            // reconnect that has not started yet looks like an immediate success.
            guard now.timeIntervalSince(since) > 20 else { return }
            recoveringSince = nil
            healthySince = now
            resetLadder()
            setPhase(.healthy, "recovered in \(Int(now.timeIntervalSince(since)))s, streams \(s.streams)/\(s.total)")
            return
        }
        let last = max(since, lastProgressAt ?? since)
        guard now.timeIntervalSince(last) >= policy.recoveryDeadline else { return }
        recoveringSince = nil
        escalate(now)
    }

    private func escalate(_ now: Date) {
        let action: Action
        if softAttempts < policy.maxSoft {
            action = .soft
        } else if hardAttempts < policy.maxHard {
            action = .hard
        } else {
            action = .giveUp
        }
        pending = action
        let index = min(attempts, policy.backoff.count - 1)
        let delay = policy.backoff[index] * Double.random(in: 0.85...1.15)
        backoffUntil = now.addingTimeInterval(delay)
        setPhase(.backingOff, "\(action) in \(Int(delay))s")
    }

    private func performPending(_ now: Date) {
        guard let action = pending else { return }
        pending = nil
        perform(action, reason: "after backoff", now: now)
    }

    private func resetLadder() {
        attempts = 0
        softAttempts = 0
        hardAttempts = 0
        pending = nil
        backoffUntil = nil
    }

    // MARK: - Bookkeeping

    private func updateTrackers(_ s: Snapshot, _ now: Date) {
        if s.streams != lastStreams {
            lastStreams = s.streams
            streamsChangedAt = now
        }
        if s.rxTotal != lastRx {
            lastRx = s.rxTotal
            rxChangedAt = now
        }
        if s.txTotal != lastTx {
            lastDemandAt = now
        }
        lastTx = s.txTotal
        if s.state == "connecting" {
            if connectingSince == nil { connectingSince = now }
        } else {
            connectingSince = nil
        }
        lastState = s.state
    }

    private func setPhase(_ next: Phase, _ detail: String) {
        guard next != phase || detail != lastDetail else { return }
        phase = next
        lastDetail = detail
        phaseChanged?(next, detail)
    }
}
