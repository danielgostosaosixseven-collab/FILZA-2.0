import SwiftUI
import UIKit

private let realExternalMarkUIImage: UIImage = {
    if let path = Bundle.main.path(forResource: "REALExternalMark", ofType: "png"),
       let image = UIImage(contentsOfFile: path) {
        return image
    }
    return UIImage(systemName: "shield.fill")!
}()

private struct LicensePanelShape: Shape {
    var cut: CGFloat = 18

    func path(in rect: CGRect) -> Path {
        let radius = min(cut, min(rect.width, rect.height) * 0.18)
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}

struct LicenseActivationView: View {
    @ObservedObject var manager: LicenseManager
    @State private var key = ""
    @FocusState private var keyFocused: Bool
    @State private var showSecurityBadge = false
    @State private var animatedCount: Int = 0

    var body: some View {
        ZStack {
            // Layer 1: Background
            backgroundLayer

            // The static surface keeps the key form responsive on older devices.

            // Content
            let activationWidth = min(560, max(0, UIScreen.main.bounds.width - 32))
            ScrollViewReader { scrollProxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        Color.clear
                            .frame(height: 0)
                            .id("activationTop")
                        Spacer(minLength: 24)
                        heroSection
                        portalStatusStrip
                        verseCard
                        Spacer(minLength: 20)
                        keyCard
                        Spacer(minLength: 24)
                        if manager.isActive {
                            licenseCountdownCard
                        }
                        Spacer(minLength: 18)
                        activeKeysCounterCard
                        Spacer(minLength: 18)
                        securityFooter
                        Spacer(minLength: 30)
                    }
                    .frame(maxWidth: 560)
                    .frame(width: activationWidth)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .scrollDismissesKeyboard(.immediately)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .onChange(of: keyFocused) { focused in
                    guard !focused else { return }
                    for delay in [0.15, 0.35, 0.70] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                            guard !keyFocused else { return }
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                scrollProxy.scrollTo("activationTop", anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { showSecurityBadge = true }
    }

    // MARK: - Background

    private var backgroundLayer: some View {
        AppTheme.pageBackground.ignoresSafeArea()
    }

    // MARK: - Hero Section

    private var portalStatusStrip: some View {
        HStack(spacing: 9) {
            Image(systemName: "key.horizontal.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(AppTheme.accent)
            Text("ACESSO DE LICENÇA")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.76))
            Spacer(minLength: 4)
            Text("01 / FILZA")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.secondaryAccent)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AppTheme.signalEdge).frame(height: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var heroSection: some View {
        HStack(spacing: 15) {
            Image(uiImage: realExternalMarkUIImage)
                .resizable()
                .scaledToFill()
                .frame(width: 68, height: 68)
                .clipShape(LicensePanelShape(cut: 15))
                .overlay(LicensePanelShape(cut: 15).stroke(AppTheme.signalEdge, lineWidth: 1))
            VStack(alignment: .leading, spacing: 5) {
                Text("FILZA")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.accent)
                Text("FILZA EXTERNAL BYPASS")
                    .font(.system(size: 19, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Text("LICENCIA · ACCESO SEGURO")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var verseCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("“")
                .font(.system(size: 42, weight: .black, design: .serif))
                .foregroundStyle(AppTheme.secondaryAccent)
                .frame(width: 28, alignment: .leading)
                .offset(y: -5)
            VStack(alignment: .leading, spacing: 7) {
                Text("Peça a Deus que abençoe os seus planos, e eles darão certo.")
                    .font(.system(size: 12, weight: .semibold, design: .serif))
                    .italic()
                    .foregroundStyle(.white.opacity(0.92))
                    .fixedSize(horizontal: false, vertical: true)
                Text("PROVÉRBIOS 16:3")
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(AppTheme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.referenceCard, in: LicensePanelShape(cut: 14))
        .overlay(LicensePanelShape(cut: 14).stroke(AppTheme.secondaryAccent.opacity(0.42), lineWidth: 1))
        .overlay(alignment: .leading) {
            Rectangle().fill(AppTheme.accent).frame(width: 2, height: 30).padding(.leading, 0.5)
        }
        .padding(.top, 14)
    }

    private func hudBadge(icon: String, title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .shadow(color: color, radius: 4)
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
            Text(title)
                .font(.system(size: 8, weight: .black, design: .monospaced))
                .tracking(0.8)
        }
        .foregroundStyle(color.opacity(0.9))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.08))
                .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 0.8))
        )
    }

    // MARK: - Key Card

    private var keyCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                Text("CREDENCIAL / FILZA")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.secondaryAccent)
                    Text(manager.isBusy ? "Validando acesso" : "Entre com sua chave")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Use a licença vinculada a este dispositivo.")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.58))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: manager.isBusy ? "arrow.triangle.2.circlepath" : "key.fill")
                    .font(.system(size: 19, weight: .bold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 46, height: 46)
                    .background(AppTheme.accent.opacity(0.12), in: LicensePanelShape(cut: 12))
                    .overlay(LicensePanelShape(cut: 12).stroke(AppTheme.accent.opacity(0.45), lineWidth: 1))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("CHAVE DE LICENÇA")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                HStack(spacing: 12) {
                    FilzaBrandMark(size: 22)
                        .opacity(keyFocused ? 1.0 : 0.72)
                    TextField("SUA CHAVE AQUI", text: $key)
                        .focused($keyFocused)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit { activate() }
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .tint(AppTheme.accent)
                    if manager.isBusy {
                        ProgressView().tint(AppTheme.accent).scaleEffect(0.85)
                    }
                }
                .padding(.horizontal, 15)
                .frame(height: 58)
                .background(AppTheme.consoleBackground, in: LicensePanelShape(cut: 12))
                .overlay(LicensePanelShape(cut: 12).stroke(keyFocused ? AppTheme.accent : Color.white.opacity(0.16), lineWidth: keyFocused ? 1.6 : 1))
            }

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { manager.rememberKey.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: manager.rememberKey ? "checkmark.square.fill" : "square")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(manager.rememberKey ? AppTheme.accent : .white.opacity(0.42))
                    Text("Lembrar chave neste dispositivo")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                    Spacer(minLength: 0)
                    Image(systemName: "info.circle")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.35))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Lembrar chave neste dispositivo")
            .accessibilityValue(manager.rememberKey ? "Ativado" : "Desativado")

            Button(action: activate) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(manager.isBusy ? "VALIDANDO CREDENCIAL" : "ACESSAR PAINEL")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .tracking(0.8)
                        Text(manager.isBusy ? "AGUARDE UM INSTANTE" : "FILZA EXTERNAL BYPASS")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    Spacer()
                    if manager.isBusy {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "arrow.right")
                            .font(.system(size: 15, weight: .black))
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.22), in: Circle())
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, minHeight: 64)
                        .background(AppTheme.rgbGradient, in: LicensePanelShape(cut: 14))
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .background(AppTheme.referenceCard, in: LicensePanelShape(cut: 20))
        .overlay(LicensePanelShape(cut: 20).stroke(AppTheme.signalEdge, lineWidth: 1))
        .overlay(alignment: .leading) {
            Rectangle().fill(AppTheme.accent).frame(width: 3, height: 54).padding(.leading, 0.5)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Active Keys Counter

    private var activeKeysCounterCard: some View {
        let rawCount = manager.activeKeysCount ?? 0
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(AppTheme.accent).frame(width: 6, height: 6)
                    Text("SINAL AO VIVO")
                        .font(.system(size: 8, weight: .black, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(AppTheme.accent)
                }
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text("\(animatedCount)")
                        .font(.system(size: 37, weight: .black, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("JOGADORES\nONLINE")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(0.7)
                        .lineSpacing(2)
                        .foregroundStyle(.white.opacity(0.78))
                }
                Text("Chaves em uso agora na IPA")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
            }
            Spacer(minLength: 2)
            Image(systemName: "person.3.fill")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(AppTheme.secondaryAccent)
                .frame(width: 48, height: 48)
                .background(AppTheme.secondaryAccent.opacity(0.12), in: LicensePanelShape(cut: 12))
                .overlay(LicensePanelShape(cut: 12).stroke(AppTheme.secondaryAccent.opacity(0.42), lineWidth: 1))
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .background(AppTheme.consoleBackground, in: LicensePanelShape(cut: 18))
        .overlay(LicensePanelShape(cut: 18).stroke(AppTheme.accent.opacity(0.38), lineWidth: 1))
        .frame(maxWidth: .infinity)
        .onAppear { animatedCount = rawCount }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { break }
                await manager.refreshActiveCount()
                if let count = manager.activeKeysCount { animatedCount = count }
            }
        }
    }

    // MARK: - Security Footer

    private var securityFooter: some View {
        VStack(spacing: 0) {
            if showSecurityBadge {
                Button { BrandProtection.openChannel() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(AppTheme.secondaryAccent)
                            .frame(width: 40, height: 40)
                            .background(AppTheme.secondaryAccent.opacity(0.12), in: LicensePanelShape(cut: 11))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Canal oficial de atualizações")
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(.white.opacity(0.92))
                            Text("Novidades e avisos da IPA")
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.54))
                        }
                        Spacer(minLength: 2)
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .black))
                            .foregroundStyle(.white.opacity(0.72))
                            .frame(width: 30, height: 30)
                            .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    }
                    .padding(12)
                    .background(AppTheme.referenceCard, in: LicensePanelShape(cut: 15))
                    .overlay(LicensePanelShape(cut: 15).stroke(AppTheme.signalEdge, lineWidth: 0.8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func securityBadge(icon: String, label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AppTheme.secondaryAccent.opacity(0.7))
            Text(label)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.3), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.06), lineWidth: 1))
    }

    // MARK: - License Countdown Card

    @State private var nowDate = Date()
    private let countdownTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var licenseCountdownCard: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.secondaryAccent.opacity(0.12))
                        .frame(width: 40, height: 40)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.secondaryAccent.opacity(0.3), lineWidth: 1)
                        )
                    Image(systemName: "clock.fill")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(AppTheme.secondaryAccent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("LICENÇA ATIVA")
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .tracking(1.5)
                        .foregroundStyle(.white)
                    Text("Chave validada e sincronizada")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
                Spacer()
                Circle().fill(AppTheme.accent).frame(width: 8, height: 8)
            }

            // Countdown display: lifetime keys have an explicit state, not fake numbers.
            if manager.expirationDate == nil {
                Text("VITALÍCIA")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(AppTheme.secondaryAccent)
                    .frame(maxWidth: .infinity, minHeight: 52)
            } else {
                HStack(spacing: 0) {
                    countdownBlock(value: countdownDays, label: "DIAS")
                    countdownSeparator
                    countdownBlock(value: countdownHours, label: "HORAS")
                    countdownSeparator
                    countdownBlock(value: countdownMinutes, label: "MIN")
                    countdownSeparator
                    countdownBlock(value: countdownSeconds, label: "SEG")
                }
            }
        }
        .padding(20)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.20), lineWidth: 1))
        .onReceive(countdownTimer) { date in nowDate = date }
    }

    private var countdownRemaining: TimeInterval {
        guard let exp = manager.expirationDate else { return 0 }
        return max(0, exp.timeIntervalSince(nowDate))
    }

    private var countdownDays: Int { Int(countdownRemaining) / 86400 }
    private var countdownHours: Int { (Int(countdownRemaining) % 86400) / 3600 }
    private var countdownMinutes: Int { (Int(countdownRemaining) % 3600) / 60 }
    private var countdownSeconds: Int { Int(countdownRemaining) % 60 }

    private var countdownSeparator: some View {
        Text(":")
            .font(.system(size: 24, weight: .black, design: .monospaced))
            .foregroundStyle(AppTheme.secondaryAccent.opacity(0.5))
            .padding(.horizontal, 6)
            .offset(y: -8)
    }

    private func countdownBlock(value: Int, label: String) -> some View {
        VStack(spacing: 4) {
            Text(String(format: "%02d", value))
                .font(.system(size: 26, weight: .black, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 52, height: 44)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(AppTheme.consoleBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(AppTheme.secondaryAccent.opacity(0.2), lineWidth: 1)
                        )
                )
            Text(label)
                .font(.system(size: 8, weight: .black, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.4))
        }
    }

    // MARK: - Action

    private func activate() {
        keyFocused = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        manager.activate(key: key)
    }
}
