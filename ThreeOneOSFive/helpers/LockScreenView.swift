import SwiftUI

struct LockScreenView: View {
    @ObservedObject var manager: LicenseManager

    var body: some View {
        ZStack {
            AnimatedHyperBackdrop()
                .ignoresSafeArea()
            Color.black.opacity(0.55)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.white)
                Text("FILZA EXTERNAL BYPASS")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                Text(manager.lockMessage?.isEmpty == false ? manager.lockMessage! : "This app has been temporarily disabled by the owner.")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Button {
                    Task { await manager.refreshRemoteState() }
                } label: {
                    Text("CHECK AGAIN")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(maxWidth: 200, minHeight: 46)
                        .background(Color.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .preferredColorScheme(.dark)
    }
}
