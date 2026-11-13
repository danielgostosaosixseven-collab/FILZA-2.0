import SwiftUI

/// Fundo estático de assinatura: trilhas rubi/azul sobre obsidiana, sem animações ou blur.
struct AnimatedHyperBackdrop: View {
    var body: some View {
        ZStack {
            AppTheme.pageBackground

            RadialGradient(
                colors: [AppTheme.accent.opacity(0.19), .clear],
                center: .topLeading,
                startRadius: 8,
                endRadius: 390
            )

            RadialGradient(
                colors: [AppTheme.secondaryAccent.opacity(0.15), .clear],
                center: .bottomTrailing,
                startRadius: 12,
                endRadius: 360
            )

            GeometryReader { proxy in
                ZStack(alignment: .topTrailing) {
                    Rectangle()
                        .fill(AppTheme.signalEdge.opacity(0.25))
                        .frame(width: proxy.size.width * 0.72, height: 1)
                        .rotationEffect(.degrees(-24))
                        .offset(x: proxy.size.width * 0.18, y: proxy.size.height * 0.20)

                    Rectangle()
                        .fill(AppTheme.signalEdge.opacity(0.16))
                        .frame(width: proxy.size.width * 0.56, height: 1)
                        .rotationEffect(.degrees(-24))
                        .offset(x: proxy.size.width * 0.16, y: proxy.size.height * 0.23)

                    VStack {
                        HStack {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppTheme.accent)
                                .frame(width: 24, height: 3)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(AppTheme.secondaryAccent.opacity(0.7))
                                .frame(width: 12, height: 3)
                            Spacer()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                }
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}
