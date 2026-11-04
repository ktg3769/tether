import AppIntents

// Actions for the Shortcuts app, Siri, Spotlight and the Action button. In this fork Tether stays
// running in the background with iOS 26's background task, which iOS takes only while Tether is on
// screen. So Start Tether opens Tether: coming on screen requests the task, and Tether shares from
// then on, also after leaving the screen. Shortcuts has no trigger for Personal Hotspot turning on,
// so a shortcut turns the hotspot on with Set Personal Hotspot, then runs Start Tether.

struct StartTetherIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Tether"
    static var description = IntentDescription(
        "Opens Tether, which asks iOS to keep it running in the background, and starts sharing when a device joins Personal Hotspot. Put it after Set Personal Hotspot.")
    /// Coming on screen is what lets Tether request its background task.
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = Model.shared
        let keptAlive = model.wake()
        let state = model.shortcutState()
        return .result(value: state.sharing, dialog: "\(ShortcutReply.start(state, keptAlive: keptAlive))")
    }
}

struct TetherStatusIntent: AppIntent {
    static var title: LocalizedStringResource = "Is Tether Sharing?"
    static var description = IntentDescription(
        "True while Tether is sharing Personal Hotspot, for an If in a shortcut. It also says how many devices are connected.")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let model = Model.shared
        model.syncWithHotspot() // a cold launch for this action hasn't looked at the hotspot yet
        let state = model.shortcutState()
        return .result(value: state.sharing, dialog: "\(ShortcutReply.status(state))")
    }
}

/// Ready in Shortcuts, Siri and Spotlight as soon as Tether is installed, with nothing to set up.
struct TetherShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartTetherIntent(),
                    phrases: ["Start \(.applicationName)", "Share internet with \(.applicationName)"],
                    shortTitle: "Start Tether", systemImageName: "link")
        AppShortcut(intent: TetherStatusIntent(),
                    phrases: ["Is \(.applicationName) sharing", "\(.applicationName) status"],
                    shortTitle: "Is Tether Sharing?", systemImageName: "link.circle")
    }
}
