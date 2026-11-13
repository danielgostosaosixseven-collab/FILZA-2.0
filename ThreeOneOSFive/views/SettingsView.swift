import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var language
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedHyperBackdrop()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            AppLogo(size: 48)
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.65), lineWidth: 1))
                            VStack(alignment: .leading, spacing: 4) {
                                Text("FILZA EXTERNAL BYPASS")
                                    .font(.system(size: 18, weight: .black, design: .rounded))
                                    .tracking(0.5)
                                    .foregroundStyle(.white)
                                Text("CENTRAL DE CONFIGURAÇÕES · v\(appVersion)")
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .tracking(0.7)
                                    .foregroundStyle(AppTheme.cyberBlue)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 8)

                        settingsCard("ESTE DISPOSITIVO", subtitle: "Estado de compatibilidade", icon: "iphone.gen3") {
                            settingRow(language.text("settings.ios_version"), value: "\(AppInfo.osVersion) (\(AppInfo.osBuild))")
                            HStack {
                                Text(language.text("settings.current_version"))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.72))
                                Spacer()
                                statusPill(language.text(appState.isSupported ? "settings.supported" : "settings.unsupported"), color: appState.isSupported ? AppTheme.accent : AppTheme.rgbRed)
                            }
                            .padding(.top, 8)
                        }

                        settingsCard("VERSÕES VERIFICADAS", subtitle: language.text("settings.supported_versions_footer"), icon: "checkmark.shield.fill") {
                            settingRow("App", value: appVersion)
                            settingRow("iOS 16", value: ExploitSupportPolicy.verifiedIOS16Range)
                            settingRow("iOS 17", value: ExploitSupportPolicy.verifiedIOS17Range)
                            settingRow("iOS 18", value: ExploitSupportPolicy.verifiedIOS18Range)
                            settingRow("iOS 26", value: ExploitSupportPolicy.verifiedIOS26Range)
                            settingRow("iOS 26.6", value: ExploitSupportPolicy.verifiedIOS26ExtendedRange)
                            settingRow("iOS 27", value: ExploitSupportPolicy.verifiedIOS27Range)
                            settingRow("iOS 27.2", value: ExploitSupportPolicy.verifiedIOS27ExtendedRange)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(ExploitSupportPolicy.verifiedIOS27Range)
                                    .font(.system(size: 11, weight: .black, design: .monospaced))
                                    .tracking(0.5)
                                    .foregroundStyle(AppTheme.secondaryAccent)
                                ForEach(ExploitSupportPolicy.verifiedIOS27Builds, id: \.build) { version in
                                    Text(versionLabel(version))
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                            }
                            .padding(.top, 8)
                        }


                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle(language.text("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(language.text("common.done")) { dismiss() }
                        .fontWeight(.bold)
                }
            }
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.dark)
    }

    private func settingsCard<Content: View>(
        _ title: String,
        subtitle: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .black))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 34, height: 34)
                    .background(AppTheme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(.white)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                }
                Spacer(minLength: 0)
                Capsule().fill(AppTheme.signalEdge).frame(width: 3, height: 24)
            }
            content()
        }
        .padding(15)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.8))
    }

    private func settingRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.90))
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5) }
    }

    private func statusPill(_ title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title.uppercased())
                .font(.system(size: 9, weight: .black, design: .monospaced))
                .tracking(0.4)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(color.opacity(0.40), lineWidth: 0.8))
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "AppReleaseDisplayVersion") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "1.0"
    }

    private func versionLabel(_ version: (beta: Int, publicBeta: Int?, build: String)) -> String {
        if let publicBeta = version.publicBeta {
            return language.text("settings.developer_public_beta_build", Int64(version.beta), Int64(publicBeta), version.build)
        }
        return language.text("settings.developer_beta_build", Int64(version.beta), version.build)
    }
}
