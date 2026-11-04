import Foundation

/// What the Shortcuts actions (Shortcuts.swift) say back. Foundation only, so `swift test` covers it.
enum ShortcutReply {
    /// Where Tether stands. `problem` is why WireGuard isn't running, see `Model.wireGuardProblem`.
    struct State: Equatable {
        var running: Bool
        var connected: Int
        var problem: String?
        /// The hotspot is on and WireGuard runs. `running` alone is only the hotspot.
        var sharing: Bool { running && problem == nil }
    }

    /// After Start Tether. `keptAlive` is false when the background task isn't running (yet), and then
    /// iOS may suspend Tether once it leaves the screen.
    static func start(_ state: State, keptAlive: Bool) -> String {
        if !keptAlive { return "Tether asked iOS to keep it running in the background. Check Background on its screen." }
        if state.running { return status(state) }
        return "Tether is ready. It starts sharing when a device joins Personal Hotspot."
    }

    static func status(_ state: State) -> String {
        if state.running, let problem = state.problem { return "Personal Hotspot is on, but WireGuard isn't running. \(problem)" }
        // iOS makes the hotspot's network only while a device is on it, so no device and the hotspot off look the same.
        guard state.running else { return "Tether is waiting for a device to join Personal Hotspot." }
        switch state.connected {
        case 0: return "Tether is sharing. No device is using it yet."
        case 1: return "Tether is sharing with 1 device."
        case let n: return "Tether is sharing with \(n) devices."
        }
    }
}
