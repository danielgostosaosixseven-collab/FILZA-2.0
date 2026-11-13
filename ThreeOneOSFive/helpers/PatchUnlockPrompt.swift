import SwiftUI

struct PatchUnlockPrompt: View {
    @ObservedObject var store: PatchProjectStore
    @Environment(\.appLanguage) private var language
    @State private var password = ""
    @FocusState private var fieldFocused: Bool
    private var errorMessage: String? {
        guard let key = store.unlockErrorKey else { return nil }
        return language.text(key)
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                FilzaBrandMark(size: 64).padding(.top, 24)
                Text("PATCH PROTEGIDO").font(.system(size: 18, weight: .black, design: .rounded)).tracking(1.5).foregroundStyle(.white)
                Text("Entre a senha para desbloquear este patch.").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.6)).multilineTextAlignment(.center)
                SecureField("Senha", text: $password).textFieldStyle(.roundedBorder).focused($fieldFocused).autocorrectionDisabled().textInputAutocapitalization(.never).padding(.horizontal, 24).onSubmit(submit)
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 12, weight: .semibold)).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal, 24)
                }
                Button(action: submit) {
                    Text("DESBLOQUEAR").font(.system(size: 14, weight: .black, design: .rounded)).tracking(1).foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 14).background(Capsule().fill(AppTheme.rgbGradient))
                }.disabled(store.isBusy || password.isEmpty).opacity(store.isBusy || password.isEmpty ? 0.5 : 1.0).padding(.horizontal, 24)
            }
            .navigationTitle("UNLOCK").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancelar") { store.clearUnlockError(); store.cancelUnlock() } } }
            .onAppear { fieldFocused = true }
        }
        .preferredColorScheme(.dark).presentationDetents([.medium])
    }
    private func submit() { guard !password.isEmpty else { return }; store.unlock(password: password) }
}
