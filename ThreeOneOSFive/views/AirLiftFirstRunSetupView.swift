import SwiftUI

/// Compatibility wrapper: device setup lives directly in the settings screen.
struct AirLiftFirstRunSetupView: View {
    @ObservedObject var controller: AirLiftPairingController
    var onCompleted: () -> Void = {}

    var body: some View {
        SettingsView()
            .onChange(of: controller.step) { step in
                if step == .readyToUse { onCompleted() }
            }
    }
}
