import SwiftUI
import AVKit
import UIKit

/// Página de ajuda oficial com cartões compactos e reprodução sob demanda.
struct TutorialsView: View {
    private let tutorials: [TutorialItem] = [
        TutorialItem(id: "others", title: "Erro em Outros", subtitle: "Como resolver", resource: "tutorial_error_others", thumbnail: "tutorial_error_banner", icon: "exclamationmark.triangle.fill"),
        TutorialItem(id: "ffth-ffmax", title: "FFTH e FFMax", subtitle: "Como jogar", resource: "tutorial_ffth_ffmax", thumbnail: "tutorial_ffth_banner", icon: "flame.fill"),
        TutorialItem(id: "ap", title: "Opções AP", subtitle: "Como usar", resource: "tutorial_ap", thumbnail: "tutorial_ap_banner", icon: "shield.lefthalf.filled")
    ]
    @State private var selectedTutorial: TutorialItem?

    var body: some View {
        ZStack {
            AppTheme.pageBackground.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(tutorials) { tutorial in
                            TutorialCard(item: tutorial) { selectedTutorial = tutorial }
                        }
                    }
                    Text("Toque em um cartão para assistir em tela cheia.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.48))
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 120)
            }
        }
        .fullScreenCover(item: $selectedTutorial) { tutorial in
            TutorialPlayerView(item: tutorial)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("GUIA OFICIAL", systemImage: "play.rectangle.fill")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .tracking(1.1)
                .foregroundStyle(AppTheme.accent)
            Text("Tutoriais")
                .font(.system(size: 25, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            Text("Escolha um dos três guias para assistir.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.62))
        }
    }
}

private struct TutorialItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let resource: String
    let thumbnail: String
    let icon: String
}

private struct TutorialCard: View {
    let item: TutorialItem
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                ZStack {
                    if let path = Bundle.main.path(forResource: item.thumbnail, ofType: "jpg", inDirectory: "Tutorials"),
                       let image = UIImage(contentsOfFile: path) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Color.black
                        Image(systemName: item.icon)
                            .font(.system(size: 24, weight: .black))
                            .foregroundStyle(.white.opacity(0.82))
                    }
                    LinearGradient(
                        colors: [Color.black.opacity(0.08), Color.black.opacity(0.48)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 31, weight: .bold))
                        .foregroundStyle(.white.opacity(0.94))
                }
                .frame(maxWidth: .infinity, minHeight: 116)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                }
            }
            .padding(10)
            .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

private struct TutorialPlayerView: View {
    let item: TutorialItem
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .onDisappear { player.pause() }
            } else {
                ProgressView().tint(.white)
            }
            Button {
                player?.pause()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(Color.black.opacity(0.62), in: Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 18)
            .padding(.trailing, 16)
        }
        .onAppear {
            guard let url = Bundle.main.url(forResource: item.resource, withExtension: "mov", subdirectory: "Tutorials") else { return }
            player = AVPlayer(url: url)
            player?.play()
        }
        .preferredColorScheme(.dark)
    }
}
