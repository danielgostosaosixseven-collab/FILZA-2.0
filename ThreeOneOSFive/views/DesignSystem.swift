import SwiftUI

enum AppTheme {
    // Filza: azul e vermelho vivos, porém com contraste mais confortável e menos neon.
    static let accent = Color(red: 0.08, green: 0.62, blue: 0.98)
    static let secondaryAccent = Color(red: 0.96, green: 0.08, blue: 0.16)
    static let cyberBlue = Color(red: 0.24, green: 0.72, blue: 1.00)
    static let rgbRed = Color(red: 0.14, green: 0.72, blue: 0.96)
    // Mantido pelo nome legado; estados positivos usam azul, sem verde na UI.
    static let rgbGreen = accent // compatibilidade interna; a UI usa azul, nunca verde
    static let pageBackground = Color(red: 0.008, green: 0.010, blue: 0.020)
    static let consoleBackground = Color(red: 0.018, green: 0.035, blue: 0.070)
    static let referenceCard = Color(red: 0.035, green: 0.075, blue: 0.125)
    static let controlSurface = Color(red: 0.055, green: 0.115, blue: 0.185)
    // Stops pretos separam azul e vermelho para evitar qualquer faixa roxa/rosa.
    static let rgbGradient = LinearGradient(colors: [Color(red: 0.04, green: 0.38, blue: 0.72), Color(red: 0.05, green: 0.68, blue: 0.92), accent], startPoint: .leading, endPoint: .trailing)
    static let panelGradient = LinearGradient(colors: [referenceCard, consoleBackground], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let signalEdge = LinearGradient(colors: [secondaryAccent.opacity(0.55), Color.white.opacity(0.10), accent.opacity(0.65)], startPoint: .leading, endPoint: .trailing)
    static let pageInset: CGFloat = 16
    static let rowIconSize: CGFloat = 17
    static let rowIconFrame: CGFloat = 28
    static let fileRowIconSize: CGFloat = 17
    static let fileRowIconFrame: CGFloat = 30
    static let fileRowHeight: CGFloat = 60
    static let appIconSize: CGFloat = 32
    static let emptyIconSize: CGFloat = 30
    static let selectionIconSize: CGFloat = 22
    static let categorySelected = LinearGradient(colors: [Color(red: 0.02, green: 0.42, blue: 0.78), Color(red: 0.04, green: 0.72, blue: 0.92)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let categorySurface = Color(red: 0.018, green: 0.030, blue: 0.058)
    static let patchCardGradient = LinearGradient(colors: [Color(red: 0.025, green: 0.065, blue: 0.115), Color(red: 0.008, green: 0.018, blue: 0.040)], startPoint: .topLeading, endPoint: .bottomTrailing)
}

struct AppRowIcon: View {
    let systemName: String
    var tint: Color = AppTheme.accent
    var symbolSize: CGFloat = AppTheme.rowIconSize
    var frameSize: CGFloat = AppTheme.rowIconFrame

    var body: some View {
        ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(tint.opacity(0.14))
            Image(systemName: systemName)
                .font(.system(size: symbolSize, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: frameSize, height: frameSize)
        .accessibilityHidden(true)
    }
}

struct AppSearchField: View {
    @Binding var text: String
    let prompt: String
    let clearLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(clearLabel)
            }
        }
        .padding(.horizontal, 11)
        .frame(minHeight: 38)
        .background(AppTheme.controlSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, AppTheme.pageInset)
        .padding(.vertical, 8)
        .background(AppTheme.pageBackground)
    }
}

struct AppLogo: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let icon = Bundle.main.path(forResource: "REALExternalMark", ofType: "png")
                .flatMap(UIImage.init(contentsOfFile:)) {
                Image(uiImage: icon)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "slider.horizontal.3")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppTheme.accent)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct FilzaBrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        Group {
            if let image = UIImage(named: "REALExternalMark") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                AppLogo(size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .accessibilityLabel("FILZA EXTERNAL BYPASS")
    }
}

struct GlassPanel<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                AppRowIcon(systemName: icon, tint: accentColor, symbolSize: 15, frameSize: 32)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Spacer()
            }
            content
        }
        .padding(16)
        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 1))
    }
}

struct SectionDivider: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(AppTheme.accent.opacity(0.24)).frame(height: 1)
            Text(label)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(1.4)
                .foregroundStyle(.white.opacity(0.48))
            Rectangle().fill(AppTheme.accent.opacity(0.24)).frame(height: 1)
        }
        .padding(.horizontal, 8)
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 8

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

struct PremiumCard<Content: View>: View {
    let title: String
    let icon: String
    let accentColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(spacing: 10) {
                AppRowIcon(systemName: icon, tint: accentColor, symbolSize: 15, frameSize: 34)
                Text(title)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(.white)
                Spacer(minLength: 0)
                RoundedRectangle(cornerRadius: 1).fill(accentColor).frame(width: 3, height: 18)
            }
            content
        }
        .padding(16)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 1))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 4) {
                Capsule().fill(accentColor).frame(width: 24, height: 3)
                Capsule().fill(AppTheme.secondaryAccent.opacity(0.85)).frame(width: 10, height: 3)
            }
            .padding(.leading, 16)
        }
    }
}

struct HeroStatusRow: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 11) {
            AppRowIcon(systemName: icon, tint: color, symbolSize: 13, frameSize: 30)
            Text(title)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 4)
    }
}

struct PremiumLaunchButton: View {
    let title: String
    let subtitle: String
    let color: Color
    let assetName: String?
    let action: () -> Void

    init(title: String, subtitle: String, color: Color, assetName: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.subtitle = subtitle
        self.color = color
        self.assetName = assetName
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                if let assetName {
                    ZStack(alignment: .bottomTrailing) {
                        Image(assetName)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.white.opacity(0.16), lineWidth: 1))
                        Circle()
                            .fill(color)
                            .frame(width: 12, height: 12)
                            .overlay(Circle().stroke(AppTheme.pageBackground, lineWidth: 2))
                            .offset(x: 3, y: 3)
                    }
                    .accessibilityHidden(true)
                } else {
                    Image(systemName: "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(color)
                        .frame(width: 58, height: 58)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(subtitle.uppercased())
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.0)
                        .foregroundStyle(color)
                    Text(title)
                        .font(.system(size: 13, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("ABRIR")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(0.7)
                        .foregroundStyle(.white.opacity(0.54))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 25, height: 25)
                    .background(color.opacity(0.78), in: Circle())
            }
            .frame(maxWidth: .infinity, minHeight: 82)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).stroke(color.opacity(0.62), lineWidth: 1))
            .overlay(alignment: .topLeading) { Capsule().fill(color).frame(width: 34, height: 3).padding(.leading, 14) }
        }
        .buttonStyle(.plain)
    }
}

struct TimerRing: View {
    let progress: Double
    let seconds: Double
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(color.opacity(0.16), lineWidth: 3).frame(width: 36, height: 36)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.1f", seconds))
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("PATCH ATIVO")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text("Auto-restore em \(Int(seconds))s")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(AppTheme.controlSurface, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }
}

private struct CutCornerPlate: Shape {
    var cut: CGFloat = 7

    func path(in rect: CGRect) -> Path {
        let c = min(cut, min(rect.width, rect.height) / 3)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + c, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + c))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - c))
            path.addLine(to: CGPoint(x: rect.maxX - c, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + c, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - c))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + c))
            path.closeSubpath()
        }
    }
}

private struct DraggablePatchSwitch: View {
    let name: String
    let isEnabled: Bool
    let isPending: Bool
    let isBusy: Bool
    let isAvailable: Bool
    let isDownloadable: Bool
    let isSpanish: Bool
    let color: Color
    let action: () -> Void
    @State private var dragOffset: CGFloat = 0

    private var displayedEnabled: Bool { isEnabled || isPending }
    private var isInteractive: Bool { !isBusy && isAvailable }
    private var stateTint: Color {
        if isPending { return AppTheme.secondaryAccent }
        if displayedEnabled { return color }
        return isAvailable ? color.opacity(0.78) : Color.white.opacity(0.40)
    }
    private var accessibilityState: String {
        if isPending { return "Aguardando" }
        return displayedEnabled
            ? ("Ativado")
            : ("Desativado")
    }
    private var gestureHint: String {
        displayedEnabled
            ? ("Arraste para a esquerda para desativar")
            : ("Arraste para a direita para ativar")
    }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(4, proxy.size.width - 28)
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(AppTheme.controlSurface)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(stateTint.opacity(displayedEnabled ? 0.82 : 0.38), lineWidth: 1)
                HStack {
                    if displayedEnabled {
                        Text("SIM")
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                        Text("NO")
                    }
                }
                .font(.system(size: 7, weight: .black, design: .monospaced))
                .foregroundStyle(stateTint.opacity(0.82))
                .padding(.horizontal, 8)
                .allowsHitTesting(false)
                Circle()
                    .fill(stateTint)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: displayedEnabled ? "checkmark" : "chevron.right")
                            .font(.system(size: 10, weight: .black))
                            .foregroundStyle(AppTheme.pageBackground)
                    }
                    .offset(x: min(travel, max(3, (displayedEnabled ? travel : 3) + dragOffset)))
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard isInteractive, abs(value.translation.width) > abs(value.translation.height) else { return }
                        dragOffset = min(travel, max(-travel, value.translation.width))
                    }
                    .onEnded { value in
                        let dx = value.translation.width
                        let dy = value.translation.height
                        withAnimation(.easeOut(duration: 0.10)) { dragOffset = 0 }
                        guard isInteractive, abs(dx) >= 15, abs(dx) > abs(dy) * 1.2 else { return }
                        requestEnabled(dx > 0)
                    }
            )
            .onTapGesture { requestEnabled(!displayedEnabled) }
            .animation(.easeInOut(duration: 0.10), value: displayedEnabled)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(name)
            .accessibilityValue(accessibilityState)
            .accessibilityHint(gestureHint)
            .accessibilityAddTraits(.isButton)
        }
        .frame(width: 86, height: 36)
        .opacity(isInteractive ? 1 : 0.58)
    }

    private func requestEnabled(_ requested: Bool) {
        guard isInteractive, requested != displayedEnabled else { return }
        action()
    }
}

struct PremiumPatchCard: View {
    let name: String
    let target: String
    let color: Color
    let isEnabled: Bool
    let isPending: Bool
    let isBusy: Bool
    let isAvailable: Bool
    let isDownloadable: Bool
    let isSpanish: Bool
    let previewURL: String?
    let action: () -> Void

    private var canStartAction: Bool { isAvailable || isDownloadable || isEnabled || isPending }
    private var displayName: String {
        name.split(separator: " ").map { part in
            let word = String(part)
            let keepUppercase: Set<String> = ["FF", "FFTH", "AP", "HS", "MAX", "FPS", "MVP"]
            if keepUppercase.contains(word.uppercased()) { return word.uppercased() }
            return word.prefix(1).uppercased() + String(word.dropFirst()).lowercased()
        }.joined(separator: " ")
    }
    private var displayTarget: String {
        switch target.uppercased() {
        case "FF NORMAL": return isSpanish ? "FREE FIRE · NORMAL" : "FREE FIRE · NORMAL"
        case "FF MAX": return "FREE FIRE · MAX"
        default: return target.uppercased()
        }
    }
    private var monogram: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "•" : String(letters).uppercased()
    }
    private var stateTint: Color {
        if isBusy { return AppTheme.secondaryAccent }
        if isPending { return AppTheme.secondaryAccent }
        if isEnabled { return color }
        if isDownloadable { return AppTheme.cyberBlue }
        return isAvailable ? color : Color.white.opacity(0.42)
    }
    private var stateLabel: String {
        if isBusy { return "PROCESSANDO" }
        if isPending { return "AGUARDANDO" }
        if isEnabled { return "ATIVO" }
        if isDownloadable { return "REMOTO" }
        if !isAvailable { return "INDISPONÍVEL" }
        return "PRONTO"
    }
    private var iconSize: CGFloat { previewURL == nil ? 44 : 46 }

    init(name: String, target: String, color: Color, isEnabled: Bool, isPending: Bool, isBusy: Bool, isAvailable: Bool = true, isDownloadable: Bool = false, previewURL: String? = nil, isSpanish: Bool = false, action: @escaping () -> Void) {
        self.name = name
        self.target = target
        self.color = color
        self.isEnabled = isEnabled
        self.isPending = isPending
        self.isBusy = isBusy
        self.isAvailable = isAvailable
        self.isDownloadable = isDownloadable
        self.previewURL = previewURL
        self.isSpanish = isSpanish
        self.action = action
    }

    var body: some View {
        HStack(spacing: 9) {
            Button(action: action) {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous).fill(stateTint.opacity(0.14))
                        if isBusy {
                            ProgressView().tint(stateTint)
                        } else if let previewURL, let url = URL(string: previewURL) {
                            AsyncImage(url: url) { phase in
                                if let image = phase.image { image.resizable().scaledToFill() }
                                else { fallbackIcon }
                            }
                            .frame(width: iconSize, height: iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else {
                            fallbackIcon
                        }
                        RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(stateTint.opacity(0.42), lineWidth: 1)
                    }
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayTarget)
                            .font(.system(size: 7, weight: .black, design: .monospaced))
                            .tracking(0.55)
                            .foregroundStyle(color)
                            .lineLimit(1)
                        Text(displayName)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .minimumScaleFactor(0.75)
                        Text(isPending
                             ? ("SELEÇÃO PREPARADA")
                             : (isDownloadable && !isEnabled ? ("PACOTE REMOTO") : ("MÓDULO DE JOGO")))
                            .font(.system(size: 7, weight: .bold, design: .monospaced))
                            .tracking(0.2)
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isBusy || !canStartAction)

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 4) {
                Text(stateLabel)
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.25)
                    .foregroundStyle(stateTint)
                    .lineLimit(1)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(stateTint.opacity(0.12), in: Capsule())
                Text(isDownloadable && !isEnabled ? ("BAIXAR") : ((isEnabled || isPending) ? "DESATIVAR" : "ATIVAR"))
                    .font(.system(size: 7, weight: .black, design: .monospaced))
                    .tracking(0.2)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
                DraggablePatchSwitch(
                    name: displayName,
                    isEnabled: isEnabled,
                    isPending: isPending,
                    isBusy: isBusy,
                    isAvailable: canStartAction,
                    isDownloadable: isDownloadable && !isEnabled,
                    isSpanish: isSpanish,
                    color: color,
                    action: action
                )
            }
            .frame(width: 86)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .background(AppTheme.patchCardGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(stateTint.opacity(isEnabled || isPending ? 0.82 : 0.36), lineWidth: 1.15))
        .overlay(alignment: .leading) {
            Capsule().fill(stateTint).frame(width: 4, height: 44).padding(.leading, 0.5)
        }
        .opacity((isBusy || !canStartAction) ? 0.66 : 1)
    }

    private var fallbackIcon: some View {
        Group {
            if isEnabled {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 22, weight: .bold))
            } else if isPending {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 22, weight: .bold))
            } else if isAvailable || isDownloadable {
                Text(monogram)
                    .font(.system(size: 14, weight: .black, design: .monospaced))
                    .tracking(0.4)
            } else {
                Image(systemName: "lock.fill")
                    .font(.system(size: 17, weight: .bold))
            }
        }
        .foregroundStyle(stateTint)
        .frame(width: iconSize, height: iconSize)
    }
}

struct StatusMessageBar: View {
    let message: String
    let isSuccess: Bool
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            if isBusy {
                ProgressView().tint(AppTheme.accent).controlSize(.small)
            } else {
                Image(systemName: isSuccess ? "checkmark.circle.fill" : "info.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isSuccess ? AppTheme.accent : AppTheme.secondaryAccent)
            }
            Text(isBusy ? "PROCESSANDO…" : message)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.74))
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }
}
