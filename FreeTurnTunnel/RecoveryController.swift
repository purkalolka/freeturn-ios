import Foundation

/// Keeps a long-running tunnel healthy while the app is not running.
///
/// The core can now recycle a single dead stream (`MobileEnsureStreams`) instead of
/// rebuilding the whole relay, so the controller prefers that for partial loss and keeps a
/// full `MobileReconnect` for signals that mean the entire path is gone (network handover,
/// black-holed traffic, a stuck connect). A full reconnect costs a credential fetch plus
/// twelve handshakes; a per-stream restart costs one.
///
/// Recovery is driven by progress, not by a fixed timer: a started attempt is never
/// interrupted, and only a sustained lack of progress escalates.
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
        /// No streams at all while the session claims to be connected.
        var emptyGrace: TimeInterval = 3
        /// At least half of the streams are gone.
        var severeGrace: TimeInterval = 10
        /// A single stream or two missing; per-stream re-dial may still fix it.
        var partialGrace: TimeInterval = 20
        /// Outbound traffic with no inbound reply at all.
        var blackholeGrace: TimeInterval = 8
        /// A single request must not look like a black hole: require real volume.
        var blackholeMinTxBytes: Int64 = 4096
        /// No progress at all for this long means the attempt will not converge.
        var recoveryDeadline: TimeInterval = 75
        /// Uninterrupted health that resets the escalation ladder.
        var healthyReset: TimeInterval = 300
        /// A core that neither connects nor errors for this long is stuck.
        var connectingGrace: TimeInterval = 180
        /// WireGuard rekeys under traffic every 120 s; older means the data plane is dead.
        var handshakeStale: Int64 = 140
        /// After a wake the radio needs a moment before we judge the link.
        var wakeProbe: TimeInterval = 3
        /// Backoff before the next escalation, seconds; the last value repeats.
        var backoff: [TimeInterval] = [5, 15, 30, 60, 120]
        var maxStreams = 2
        var maxReconnect = 2
        var maxHard = 2
    }

    private enum Action: Equatable {
        case streams
        case reconnect
        case hard
        case giveUp
    }

    var policy = Policy()

    /// Restart only the stalled streams (cheap, no session or tunnel disruption).
    var streamRecovery: ((String) -> Void)?
    /// Rebuild all TURN allocations and DTLS sessions, keeping the tunnel and WireGuard keys.
    var reconnect: ((String) -> Void)?
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
    private var lastState = "connecting"
    private var streamsChangedAt = Date()
    private var rxChangedAt = Date()
    /// Bytes sent since the last inbound packet; reset whenever anything is received.
    private var txSinceRx: Int64 = 0
    private var connectingSince: Date?
    private var healthySince: Date?
    private var recoveringSince: Date?
    private var lastProgressAt: Date?
    private var backoffUntil: Date?
    private var pending: Action?
    private var attempts = 0
    private var streamAttempts = 0
    private var reconnectAttempts = 0
    private var hardAttempts = 0
    private var lastAction: Action = .streams
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
        // Not "idle": the session is starting, and a soft action must not be promoted to a
        // full restart just because no tick has run yet.
        lastState = "connecting"
        streamsChangedAt = startedAt
        rxChangedAt = startedAt
        txSinceRx = 0
        connectingSince = nil
        healthySince = nil
        recoveringSince = nil
        lastProgressAt = nil
        backoffUntil = nil
        pending = nil
        attempts = 0
        streamAttempts = 0
        reconnectAttempts = 0
        hardAttempts = 0
        lastAction = .streams
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

    /// The physical path changed (Wi-Fi <-> cellular): every TURN socket is dead.
    func notePathChange(_ key: String) {
        guard running, !isRecovering, phase != .failed else { return }
        guard lastState == "connected" else { return }
        let now = Date()
        guard now.timeIntervalSince(lastTriggerAt) > 3 else { return }
        trigger(.reconnect, reason: "network path \(key)", now: now)
    }

    /// Explicit request from the app (the "Reconnect" button in the log view).
    func requestSoftRecovery(_ reason: String) {
        guard running, !isRecovering, phase != .failed else { return }
        let now = Date()
        lastTriggerAt = now
        perform(.reconnect, reason: reason, now: now)
    }

    // MARK: - Main tick

    func tick(_ s: Snapshot) {
        guard running else { return }
        let now = Date()
        let streamsGrew = s.streams > lastStreams
        let rxGrew = s.rxTotal > lastRx
        let txDelta = max(0, s.txTotal - lastTx)
        updateTrackers(s, now, txDelta: txDelta, rxGrew: rxGrew)
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
                trigger(.reconnect, reason: "no rx after wake", now: now)
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
                trigger(.reconnect, reason: "stuck connecting \(Int(now.timeIntervalSince(since)))s", now: now)
            }
            return
        }

        let demand = txDelta > 0 || s.txRate > 0 || now.timeIntervalSince(lastDemandAt) < 60

        // Outbound traffic with no inbound reply: the whole path is black-holed, a
        // per-stream restart cannot help.
        if txSinceRx >= policy.blackholeMinTxBytes {
            let quiet = now.timeIntervalSince(rxChangedAt)
            if quiet >= policy.blackholeGrace {
                trigger(.reconnect, reason: "tx \(txSinceRx)B without rx for \(Int(quiet))s", now: now)
                return
            }
        }

        let converged = s.total > 0 && s.streams >= s.total
        if converged {
            let handshakeStale = s.handshakeAge >= 0 && s.handshakeAge > policy.handshakeStale
            if handshakeStale && demand {
                trigger(.reconnect, reason: "handshake age \(s.handshakeAge)s with traffic", now: now)
                return
            }
            let healthyFrom = healthySince ?? now
            healthySince = healthyFrom
            if now.timeIntervalSince(healthyFrom) >= policy.healthyReset {
                resetLadder()
            }
            // Detail is deliberately stable: it is logged on phase changes only.
            setPhase(.healthy, "streams \(s.streams)/\(s.total)")
            return
        }

        healthySince = nil
        let stalled = now.timeIntervalSince(streamsChangedAt)
        let grace: TimeInterval
        if s.streams == 0 {
            grace = policy.emptyGrace
        } else if s.streams * 2 <= s.total {
            grace = policy.severeGrace
        } else {
            grace = policy.partialGrace
        }
        if stalled >= grace {
            trigger(.streams, reason: "streams \(s.streams)/\(s.total) stalled \(Int(stalled))s", now: now)
        }
    }

    // MARK: - Decision making

    private func trigger(_ preferred: Action, reason: String, now: Date) {
        guard running, !isRecovering, phase != .failed else { return }
        // The same bad tick must not produce two recoveries.
        guard now.timeIntervalSince(lastTriggerAt) > 2 else { return }
        var action = preferred
        // A per-stream restart cannot revive a session that is gone, and cannot help while
        // the first connect has not produced a stream yet.
        if lastState == "error" || lastState == "idle" {
            action = .hard
        } else if lastState == "connecting", action == .streams {
            action = .reconnect
        }
        if action == .streams, streamAttempts >= policy.maxStreams {
            action = .reconnect
        }
        lastTriggerAt = now
        perform(action, reason: reason, now: now)
    }

    private func perform(_ action: Action, reason: String, now: Date) {
        switch action {
        case .streams:
            streamAttempts += 1
            attempts += 1
            beginRecovery(action: .streams, label: "streams", reason: reason, now: now)
            streamRecovery?(reason)
        case .reconnect:
            reconnectAttempts += 1
            attempts += 1
            beginRecovery(action: .reconnect, label: "reconnect", reason: reason, now: now)
            reconnect?(reason)
        case .hard:
            hardAttempts += 1
            attempts += 1
            beginRecovery(action: .hard, label: "hard", reason: reason, now: now)
            hardRecovery?(reason)
        case .giveUp:
            pending = nil
            setPhase(.failed, "giving up: \(reason)")
            giveUp?(reason)
        }
    }

    private func beginRecovery(action: Action, label: String, reason: String, now: Date) {
        lastAction = action
        recoveringSince = now
        lastProgressAt = now
        // Fresh windows: the previous stall must not be counted against the new attempt.
        streamsChangedAt = now
        rxChangedAt = now
        txSinceRx = 0
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
            guard now.timeIntervalSince(since) > 10 else { return }
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
        switch lastAction {
        case .streams:
            action = reconnectAttempts < policy.maxReconnect ? .reconnect
                : (hardAttempts < policy.maxHard ? .hard : .giveUp)
        case .reconnect, .hard:
            action = hardAttempts < policy.maxHard ? .hard : .giveUp
        case .giveUp:
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
        streamAttempts = 0
        reconnectAttempts = 0
        hardAttempts = 0
        pending = nil
        backoffUntil = nil
    }

    // MARK: - Bookkeeping

    private func updateTrackers(_ s: Snapshot, _ now: Date, txDelta: Int64, rxGrew: Bool) {
        if s.streams != lastStreams {
            lastStreams = s.streams
            streamsChangedAt = now
        }
        if rxGrew {
            lastRx = s.rxTotal
            rxChangedAt = now
            txSinceRx = 0
        } else {
            lastRx = s.rxTotal
            txSinceRx += txDelta
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
