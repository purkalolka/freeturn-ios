import AppIntents
import NetworkExtension
import SwiftUI
import WidgetKit

/// Control Center toggle for the FreeTurn VPN. It only starts/stops the tunnel that the
/// app configured earlier (the saved NETunnelProviderManager), so the VPN has to be
/// started from the app at least once.
let controlKind = "FreeTurnToggle"

struct FreeTurnVPNError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
}

private func loadManager() async throws -> NETunnelProviderManager {
    let managers = try await NETunnelProviderManager.loadAllFromPreferences()
    guard let m = managers.first else {
        throw FreeTurnVPNError(localizedStringResource: "Open FreeTurn and start the VPN once first")
    }
    return m
}

struct ToggleVPNIntent: SetValueIntent {
    static let title: LocalizedStringResource = "FreeTurn VPN"

    @Parameter(title: "Enabled")
    var value: Bool

    func perform() async throws -> some IntentResult {
        let m = try await loadManager()
        if value {
            m.isEnabled = true
            try await m.saveToPreferences()
            try m.connection.startVPNTunnel()
        } else {
            m.connection.stopVPNTunnel()
        }
        return .result()
    }
}

struct VPNValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        guard let m = try? await loadManager() else { return false }
        switch m.connection.status {
        case .connected, .connecting, .reasserting: return true
        default: return false
        }
    }
}

struct FreeTurnControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: controlKind, provider: VPNValueProvider()) { isOn in
            ControlWidgetToggle("FreeTurn", isOn: isOn, action: ToggleVPNIntent()) { on in
                if UIImage(named: "FreeTurnLogo") != nil {
                    Label(on ? "On" : "Off", image: "FreeTurnLogo")
                } else {
                    Label(on ? "On" : "Off", systemImage: "shield.fill")
                }
            }
        }
        .displayName("FreeTurn VPN")
        .description("Turn the FreeTurn VPN on or off.")
    }
}

@main
struct FreeTurnControlBundle: WidgetBundle {
    var body: some Widget {
        FreeTurnControl()
    }
}
