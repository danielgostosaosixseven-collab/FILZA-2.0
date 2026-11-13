import SwiftUI
import UIKit



struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var appState: AppState
    @State private var showSettings = false
    @State private var revealLicenseKey = false
    @State private var showCleaner = false
    @StateObject private var patchStore = PatchProjectStore.shared
    @StateObject private var onlineCatalog = PatchCatalogStore.shared
    @State private var patchOperationBusy = false
    @State private var pairingRecoveryBusy = false
    @State private var fileAccessMessage: String?
    @State private var fileAccessChecking = false
    @State private var resetInProgress = false
    @State private var patchMessage = "PRONTO — SELECIONE UM PATCH"
    @State private var activationFailureDetails = ""
    @State private var showActivationFailureAlert = false
    @State private var selectedGameTab: GameTab = .ffNormal
    @State private var activePatchID: UUID?
    @State private var selectionTapLocked = false
    @State private var appliedPatchIDs: Set<UUID> = []
    @State private var showManualRestorePrompt = false
    @State private var currentTestPatchName: String?
    @State private var selectedMainPage = 0

    enum GameTab: String, CaseIterable {
        case ffNormal = "FF NORMAL"
        case ffMax = "FF MAX"
        case ap = "AP"
        case textures = "TEXTURAS"
        case holograms = "HOLOGRAMAS"
        case others = "OUTROS"

        var category: PatchCatalog.Category {
            switch self {
            case .ffNormal: return .ffNormal
            case .ffMax: return .ffMax
            case .ap: return .ap
            case .textures: return .textures
            case .holograms: return .holograms
            case .others: return .others
            }
        }

        var icon: String {
            switch self {
            case .ffNormal: return "flame.fill"
            case .ffMax: return "flame.circle.fill"
            case .ap: return "shield.lefthalf.filled"
            case .textures: return "square.grid.2x2.fill"
            case .holograms: return "wand.and.stars"
            case .others: return "shippingbox.fill"
            }
        }

        var displayTitle: String {
            switch self {
            case .ffNormal: return "FF Normal"
            case .ffMax: return "FF Max"
            case .ap: return "AP"
            case .textures: return "Texturas"
            case .holograms: return "Hologramas"
            case .others: return "Outros"
            }
        }

        var gradientColors: [Color] {
            switch self {
            case .ffNormal: return [AppTheme.accent, Color(red: 0.02, green: 0.28, blue: 0.56)]
            case .ffMax: return [AppTheme.secondaryAccent, Color(red: 0.02, green: 0.34, blue: 0.32)]
            case .ap: return [AppTheme.cyberBlue, Color(red: 0.03, green: 0.04, blue: 0.14)]
            case .textures: return [AppTheme.accent, Color(red: 0.04, green: 0.22, blue: 0.44)]
            case .holograms: return [Color(red: 0.32, green: 0.86, blue: 1.00), Color(red: 0.08, green: 0.30, blue: 0.52)]
            case .others: return [Color(red: 0.16, green: 0.70, blue: 0.64), Color(red: 0.04, green: 0.16, blue: 0.24)]
            }
        }
    }

    var filteredLocalItems: [PatchLibraryItem] {
        patchStore.items.filter { item in
            matchesSelectedCategory(item)
        }
    }

    private var remotePlaceholderItems: [FilzaLicense.CatalogItem] {
        onlineCatalog.items.filter { remote in
            let category = (remote.cat ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let aliases = ["HOLOGRAMA": "HOLOGRAMAS", "TEXTURA": "TEXTURAS", "OUTRO": "OUTROS", "PATCH": "OUTROS", "PATCHS": "OUTROS"]
            guard (aliases[category] ?? category) == selectedGameTab.rawValue else { return false }
            return !patchStore.items.contains { $0.packageURL.lastPathComponent == remote.localFilename }
        }
    }

    private func matchesSelectedCategory(_ item: PatchLibraryItem) -> Bool {
        let filename = item.packageURL.lastPathComponent

        if let remote = onlineCatalog.items.first(where: {
            $0.localFilename == filename
        }) {
            let category = (remote.cat ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let aliases: [String: String] = [
                "HOLOGRAMA": "HOLOGRAMAS",
                "TEXTURA": "TEXTURAS",
                "OUTRO": "OUTROS",
                "PATCH": "OUTROS",
                "PATCHS": "OUTROS"
            ]
            return (aliases[category] ?? category) == selectedGameTab.rawValue
        }

        if let directEntry = PatchCatalog.entry(forBundledFile: filename) {
            return directEntry.category == selectedGameTab.category
        }

        return false
    }

    private let persistedPatchIDsKey = "com.hyperregedit.appliedPatchIDs"

    private func restorePersistedPatchIDs() {
        let values = UserDefaults.standard.stringArray(forKey: persistedPatchIDsKey) ?? []
        let stored = Set(values.compactMap(UUID.init(uuidString:)))
        DispatchQueue.global(qos: .utility).async {
            let pending = Set(DevicePatchService.pendingReceipts().map(\.projectID))
            DispatchQueue.main.async {
                guard !self.patchOperationBusy else { return }
                self.appliedPatchIDs = stored.intersection(pending).union(pending)
                self.persistAppliedPatchIDs()
                self.onlineCatalog.syncEnabledStates()
            }
        }
    }

    private func persistAppliedPatchIDs() {
        UserDefaults.standard.set(appliedPatchIDs.map(\.uuidString), forKey: persistedPatchIDsKey)
    }

    private var dashboardPage: some View {
        ZStack {
            AnimatedHyperBackdrop()
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        brandHeader
                        devicePanel.padding(.top, 16)
                        if patchStore.isLoading {
                            HStack(spacing: 8) {
                                ProgressView().tint(AppTheme.secondaryAccent)
                                Text("Carregando patches…")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.72))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 18)
                        }
                        if shouldShowPairingRecovery {
                            pairingRecoveryPanel.padding(.top, 16)
                        }
                        patchSection.padding(.top, 20)
                        launchSection.padding(.top, 24)
                        footerSection.padding(.top, 24)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 28)
                }
                .onChange(of: showManualRestorePrompt) { isVisible in
                    guard isVisible else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.easeInOut(duration: 0.20)) {
                            proxy.scrollTo("manualRestorePrompt", anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private var bottomNavigation: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AppTheme.signalEdge).frame(height: 1)
            HStack(spacing: 8) {
                navigationButton(title: "Patchs", icon: "square.grid.2x2.fill", page: 0)
                navigationButton(title: "Tutoriais", icon: "play.rectangle.fill", page: 1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(AppTheme.pageBackground.opacity(0.98))
    }

    private func navigationButton(title: String, icon: String, page: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.22)) { selectedMainPage = page }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .black))
                Text(title)
                    .font(.system(size: 10, weight: .black, design: .rounded))
                    .tracking(0.5)
            }
            .foregroundStyle(selectedMainPage == page ? .white : .white.opacity(0.55))
            .frame(maxWidth: .infinity, minHeight: 42)
            .background {
                if selectedMainPage == page {
                    Capsule().fill(AppTheme.rgbGradient)
                } else {
                    Capsule().fill(AppTheme.consoleBackground)
                }
            }
            .overlay(Capsule().stroke(selectedMainPage == page ? AppTheme.accent.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 0.8))
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        Group {
            if selectedMainPage == 0 {
                dashboardPage
                    .transition(.opacity)
            } else {
                TutorialsView()
                    .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomNavigation
        }
        .animation(.easeInOut(duration: 0.22), value: selectedMainPage)
        .transition(.opacity)
        .preferredColorScheme(.dark)
        .task {
            while !Task.isCancelled {
                await licenseManager.refreshActiveCount()
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showCleaner) {
            CleanerView()
        }
        .sheet(item: $patchStore.passwordRequest, onDismiss: patchStore.cancelUnlock) { _ in
            PatchUnlockPrompt(store: patchStore)
        }
            .onAppear {
                restorePersistedPatchIDs()
                self.patchStore.reload()
                Task { await onlineCatalog.refresh() }
                reconnectSavedAirLiftIfNeeded()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                }
        }
        .onChange(of: scenePhase, perform: { phase in
            if phase == .background {
                BackgroundTaskKeeper.shared.appDidEnterBackground()
                // Keep the verified, hidden session cache so returning to the app
                // does not redownload every package. It is still outside Documents,
                // excluded from backup, protected at rest, and cleared on explicit
                // cleanup/license reset.
                self.patchStore.reload()
                return
            }
            guard phase == .active, !patchOperationBusy else { return }
            BackgroundTaskKeeper.shared.appWillEnterForeground()
            reconnectSavedAirLiftIfNeeded()
            self.patchStore.reload()
            Task { await onlineCatalog.refresh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            }
        })
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard !Task.isCancelled else { continue }
                await onlineCatalog.refresh()
            }
        }
        .alert("Falha na operação do patch", isPresented: $showActivationFailureAlert) {
            Button("Copiar detalhes") {
                UIPasteboard.general.string = activationFailureDetails
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(activationFailureDetails)
        }
    }

    // MARK: - Brand Header

    private var brandHeader: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 13) {
                AppLogo(size: 52)
                    .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text("FILZA EXTERNAL BYPASS")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .tracking(0.35)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)
                }
                Spacer(minLength: 2)
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppTheme.secondaryAccent.opacity(0.65), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configurações")
            }
        }
        .padding(.vertical, 5)
    }

    // MARK: - Device Panel

    @EnvironmentObject private var licenseManager: LicenseManager
    @State private var now = Date()
    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var licenseRemainingText: String {
        guard let expiration = licenseManager.expirationDate else { return "VITALÍCIA" }
        let remaining = expiration.timeIntervalSince(now)
        guard remaining > 0 else { return "EXPIRADO" }
        let totalSeconds = Int(remaining)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m \(seconds)s" }
        if hours > 0 { return "\(hours)h \(minutes)m \(seconds)s" }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }

    private var licenseKeyText: String {
        guard let key = licenseManager.rememberedKey(), !key.isEmpty else { return "KEY NÃO DISPONÍVEL" }
        guard !revealLicenseKey else { return key }
        let hiddenCount = max(0, key.count - 4)
        return String(repeating: "•", count: hiddenCount) + String(key.suffix(4))
    }

    private var licenseRemainingColor: Color {
        guard let expiration = licenseManager.expirationDate else { return AppTheme.secondaryAccent }
        let remaining = expiration.timeIntervalSince(now)
        if remaining < 0 { return AppTheme.rgbRed }
        if remaining < 86_400 { return AppTheme.cyberBlue }
        if remaining < 7 * 86_400 { return AppTheme.rgbRed }
        return AppTheme.accent
    }

    private var devicePanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "iphone").font(.system(size: 12, weight: .medium))
                Text("\(AppInfo.displayMachineName) · iOS \(AppInfo.osVersion)")
                    .font(.system(size: 12, weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 5)
                HStack(spacing: 6) {
                    Circle().fill(appState.isSupported ? AppTheme.accent : AppTheme.secondaryAccent).frame(width: 7, height: 7)
                    Text(appState.isSupported ? "COMPATÍVEL" : "NÃO COMPATÍVEL")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(appState.isSupported ? AppTheme.accent : AppTheme.secondaryAccent)
                }
            }
            .foregroundStyle(.white.opacity(0.76))
            .padding(.vertical, 10)

            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)

            HStack(spacing: 8) {
                Image(systemName: "clock").font(.system(size: 12, weight: .regular)).foregroundStyle(AppTheme.secondaryAccent)
                Text("Licença").font(.system(size: 12, weight: .regular)).foregroundStyle(.white.opacity(0.55))
                Text(licenseRemainingText).font(.system(size: 12, weight: .medium)).foregroundStyle(licenseRemainingColor)
                Spacer(minLength: 6)
                Text("\(licenseManager.activeKeysCount.map(String.init) ?? "—") em uso")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.white.opacity(0.64))
            }
            .padding(.vertical, 10)
            licenseKeyStatusRow
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 4)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.8))
        .onReceive(timer) { date in now = date }
    }

    private var licenseKeyStatusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(AppTheme.secondaryAccent)
            Text("Chave").font(.system(size: 12, weight: .regular)).foregroundStyle(.white.opacity(0.55))
            Text(licenseKeyText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Spacer(minLength: 4)
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { revealLicenseKey.toggle() }
            } label: {
                Image(systemName: revealLicenseKey ? "eye.slash.fill" : "eye.fill")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
            .disabled(licenseManager.rememberedKey() == nil)
            .accessibilityLabel(revealLicenseKey ? "Ocultar key" : "Mostrar key")
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5) }
    }

    private func deviceStatusTile(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 8, weight: .black, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(.white.opacity(0.48))
                Text(value)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.consoleBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(tint.opacity(0.24), lineWidth: 1))
    }

    // MARK: - Patch Section

    private var patchSection: some View {
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("PATCH LIBRARY / 01")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(AppTheme.secondaryAccent)
                    Text("Patchs")
                        .font(.system(size: 25, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Escolha uma categoria")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.52))
                }
                Spacer()
                Text("\(filteredLocalItems.count + remotePlaceholderItems.count) opções")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(AppTheme.cyberBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(AppTheme.cyberBlue.opacity(0.12), in: Capsule())
                    .overlay(Capsule().stroke(AppTheme.cyberBlue.opacity(0.35), lineWidth: 0.8))
            }

            Text("Modo manual: entre no jogo até 40%, volte aqui e ative o patch escolhido. Retorne ao jogo e espere chegar ao lobby; depois volte aqui, toque no patch novamente para desativá-lo e retorne ao jogo.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(alignment: .leading) { Capsule().fill(AppTheme.signalEdge).frame(width: 3, height: 32).padding(.leading, 0.5) }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(GameTab.allCases, id: \.self) { tab in
                        Button {
                            guard !selectionTapLocked else { return }
                            selectionTapLocked = true
                            withAnimation(.easeInOut(duration: 0.16)) { selectedGameTab = tab }
                            DispatchQueue.main.async { selectionTapLocked = false }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 16, weight: .bold))
                                Text(tab.displayTitle)
                                    .font(.system(size: 12, weight: selectedGameTab == tab ? .black : .semibold, design: .rounded))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(selectedGameTab == tab ? .white : .white.opacity(0.68))
                            .padding(.horizontal, 17)
                            .frame(minHeight: 48)
                            .background(selectedGameTab == tab ? AnyShapeStyle(AppTheme.categorySelected) : AnyShapeStyle(AppTheme.categorySurface), in: Capsule())
                            .overlay(Capsule().stroke(selectedGameTab == tab ? AppTheme.accent.opacity(0.78) : Color.white.opacity(0.14), lineWidth: selectedGameTab == tab ? 1.2 : 0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 1)
            }
            .padding(.top, 15)
            .padding(.bottom, 10)

            let localItems = filteredLocalItems
            let remoteItems = remotePlaceholderItems

            if let downloadError = onlineCatalog.downloadError {
                Text(downloadError)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.orange.opacity(0.9))
                    .padding(.vertical, 8)
            }

            if localItems.isEmpty && remoteItems.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nenhum patch nesta categoria")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                    Text("Os patches disponíveis aparecerão aqui.")
                        .font(.system(size: 12, weight: .regular))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 22)
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(localItems) { item in
                        patchCardView(for: item)
                    }
                    ForEach(remoteItems, id: \.id) { remote in
                        PremiumPatchCard(
                            name: remote.name,
                            target: selectedGameTab.rawValue,
                            color: AppTheme.accent,
                            isEnabled: onlineCatalog.isEnabled(remote),
                            isPending: false,
                            isBusy: onlineCatalog.activeID != nil || patchOperationBusy,
                            isAvailable: false,
                            isDownloadable: true,
                            previewURL: remote.img
                        ) {
                            onlineCatalog.toggle(remote) { message in
                                patchMessage = message
                                patchStore.reload()
                            }
                        }
                    }
                }
            }

            if patchOperationBusy || patchMessage != "PRONTO — SELECIONE UM PATCH" {
                StatusMessageBar(
                    message: patchMessage,
                    isSuccess: patchMessage.localizedCaseInsensitiveContains("successful"),
                    isBusy: patchOperationBusy
                )
            }
        }
    }

    // MARK: - Launch Section

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("02 / JOGO")
                        .font(.system(size: 9, weight: .black, design: .monospaced))
                        .tracking(1.1)
                        .foregroundStyle(AppTheme.secondaryAccent)
                    Text("Abrir Free Fire")
                        .font(.system(size: 17, weight: .black, design: .rounded))
                        .foregroundStyle(.white)
                }
                Spacer()
                Image(systemName: "gamecontroller.fill")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(AppTheme.cyberBlue)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.cyberBlue.opacity(0.13), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            HStack(spacing: 10) {
                PremiumLaunchButton(title: "Free Fire", subtitle: "Normal", color: AppTheme.accent, assetName: "FreeFireNormal") {
                    openGame(scheme: "freefireth")
                }
                PremiumLaunchButton(title: "Free Fire", subtitle: "MAX", color: AppTheme.secondaryAccent, assetName: "FreeFireMax") {
                    openGame(scheme: "freefiremax")
                }
            }
            HStack(spacing: 10) {
                Button { forceRestoreAll() } label: {
                    Label("Restaurar", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppTheme.referenceCard, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                Button { showCleaner = true } label: {
                    Label("Limpar cache", systemImage: "trash.slash")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.84))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(AppTheme.consoleBackground, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 21, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 21, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.8))
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: 8) {
            Button { BrandProtection.openChannel() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(AppTheme.accent)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Canal oficial")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.88))
                        Text("Avisos e atualizações")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.white.opacity(0.48))
                    }
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.46))
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 12)
                .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.7))
            }
            .buttonStyle(.plain)
            Text("v5.0.11 Secure")
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(.white.opacity(0.38))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Helpers

    private func isPackageAvailable(_ item: PatchLibraryItem) -> Bool {
        guard FileManager.default.fileExists(atPath: item.packageURL.path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: item.packageURL.path),
              let size = attributes[.size] as? NSNumber,
              size.int64Value > 0 else { return false }
        return true
    }

    private func isReadyToSelect(_ item: PatchLibraryItem) -> Bool {
        isPackageAvailable(item) && item.project != nil
    }

    private func isPatchApplied(_ item: PatchLibraryItem) -> Bool {
        // Journal snapshots are loaded off-main. Never wait for a remote write lock during SwiftUI rendering.
        appliedPatchIDs.contains(item.uniqueID)
    }

    private func remoteCatalogItem(for item: PatchLibraryItem) -> FilzaLicense.CatalogItem? {
        let filename = item.packageURL.lastPathComponent
        return onlineCatalog.items.first { remote in
            remote.localFilename == filename
        }
    }

    @ViewBuilder
    private func patchCardView(for item: PatchLibraryItem) -> some View {
        let enabled = isPatchApplied(item)
        let busy = patchOperationBusy || onlineCatalog.activeID != nil
        let remote = remoteCatalogItem(for: item)
        PremiumPatchCard(
            name: remote?.name ?? item.displayName,
            target: selectedGameTab.rawValue,
            color: AppTheme.accent,
            isEnabled: enabled,
            isPending: false,
            isBusy: busy,
            isAvailable: enabled || isPackageAvailable(item),
            previewURL: remote?.img
        ) {
            if item.isLocked && !isPatchApplied(item) {
                patchStore.requestUnlock(for: item)
            } else {
                toggleLocalPatch(item)
            }
        }
    }
    private func category(for item: PatchLibraryItem) -> PatchCatalog.Category? {
        let filename = item.packageURL.lastPathComponent
        if let remote = onlineCatalog.items.first(where: {
            $0.localFilename == filename
        }), let rawCategory = remote.cat?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            let aliases: [String: String] = [
                "HOLOGRAMA": "HOLOGRAMAS",
                "TEXTURA": "TEXTURAS",
                "OUTRO": "OUTROS",
                "PATCH": "OUTROS",
                "PATCHS": "OUTROS"
            ]
            return PatchCatalog.Category(rawValue: aliases[rawCategory] ?? rawCategory)
        }
        return PatchCatalog.entry(forBundledFile: filename)?.category
    }

    private func isPersistentCategory(_ category: PatchCatalog.Category) -> Bool {
        switch category {
        case .textures, .holograms, .others:
            return true
        default:
            return false
        }
    }

    private var shouldShowPairingRecovery: Bool {
        let v = AppInfo.versionTuple
        let wasNativelyUnsupported = !ExploitSupportPolicy.isSupported(
            major: v.major,
            minor: v.minor,
            patch: v.patch,
            build: AppInfo.osBuild
        )
        guard wasNativelyUnsupported else { return false }
        let store = AirLiftPairingStore.shared
        return appState.isSupported || store.hasPersistentResetRecoveryAfterPairing
    }

    private var pairingRecoveryPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Vai usar outra opção?")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text("Caso deseje usar outra opção, clique nesse botão, feche e abra a IPA")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.68))
                .fixedSize(horizontal: false, vertical: true)
            Button { restoreOriginals(reconnect: true) } label: {
                HStack(spacing: 8) {
                    if pairingRecoveryBusy { ProgressView().tint(.white) }
                    else { Image(systemName: "arrow.triangle.2.circlepath") }
                    Text(pairingRecoveryBusy ? "Reconectando e restaurando…" : "Reconectar e restaurar originais")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.accent)
            .disabled(patchOperationBusy || onlineCatalog.activeID != nil)

            Button { checkFileAccess(forceReconnect: false) } label: {
                HStack(spacing: 8) {
                    if fileAccessChecking { ProgressView().tint(.white) }
                    else { Image(systemName: "doc.text.magnifyingglass") }
                    Text(fileAccessChecking ? "Verificando acesso…" : "Verificar acesso aos arquivos")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.secondaryAccent)
            if let fileAccessMessage {
                Text(fileAccessMessage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(fileAccessMessage.hasPrefix("OK") ? AppTheme.accent : AppTheme.secondaryAccent)
                    .fixedSize(horizontal: false, vertical: true)
                Button { checkFileAccess(forceReconnect: true) } label: {
                    Label("Reconectar e obter acesso aos arquivos", systemImage: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.accent)
                Text("O emparelhamento está salvo, mas a sessão de arquivos ainda não respondeu. Mantenha o LocalDevVPN ligado e toque no botão para tentar novamente.")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.58))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                resetFromZero()
            } label: {
                HStack(spacing: 8) {
                    if resetInProgress { ProgressView().tint(AppTheme.rgbRed) }
                    else { Image(systemName: "trash.slash") }
                    Text(resetInProgress ? "Resetando e aguardando…" : "Resetar do zero")
                        .font(.system(size: 12, weight: .semibold))
                }
                .frame(maxWidth: .infinity, minHeight: 40)
            }
            .buttonStyle(.bordered)
            .tint(AppTheme.rgbRed)
            // A reset may be requested while the recovery button is still
            // finishing. It is serialized on operationQueue instead of being
            // silently ignored by the old patchOperationBusy guard.
            .disabled(resetInProgress || onlineCatalog.activeID != nil)
        }
        .padding(14)
        .background(AppTheme.panelGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(AppTheme.signalEdge, lineWidth: 0.8))
    }

    private func checkFileAccess(forceReconnect: Bool) {
        guard !fileAccessChecking else { return }
        fileAccessChecking = true
        fileAccessMessage = nil
        DevicePatchService.operationQueue.async {
            do {
                if WorseQueryAccess.isRequired {
                    let bundleID = selectedGameTab == .ffMax ? "com.dts.freefiremax" : "com.dts.freefireth"
                    try DevicePatchService.verifyDirectFileAccess(bundleID: bundleID)
                    DispatchQueue.main.async {
                        self.fileAccessMessage = "OK — COM ACESSO AOS ARQUIVOS"
                        self.fileAccessChecking = false
                    }
                    return
                }

                if forceReconnect || AirLiftTransport.shared.state != .connected {
                    guard AirLiftTransport.shared.connectWithRecovery(pin: nil, attempts: 5) else {
                        throw AirLiftTransportError.tunnelUnavailable
                    }
                }
                let target: (String, String)
                switch selectedGameTab {
                case .ffMax:
                    target = ("com.dts.freefiremax", "Documents/contentcache/Compulsory/ios/gameassetbundles/avatar/assetindexer.YJ~2FW7EkU5pRkVg51NrKyx4LXid8~3D")
                default:
                    target = ("com.dts.freefireth", "Documents/contentcache/Compulsory/ios/gameassetbundles/avatar/assetindexer.U6Zffc4YIR3DslNj3cXvYGAqz58~3D")
                }
                try AirTrafficPatchTransaction.verifyFileAccess(bundleID: target.0, relativePath: target.1)
                DispatchQueue.main.async { self.fileAccessMessage = "OK — COM ACESSO AOS ARQUIVOS"; self.fileAccessChecking = false }
            } catch {
                DispatchQueue.main.async { self.fileAccessMessage = "PAIRING — PAREADO, MAS SEM ACESSO AOS ARQUIVOS\n\(error.localizedDescription)"; self.fileAccessChecking = false }
            }
        }
    }

    private func forceRestoreAll() {
        restoreOriginals(reconnect: false)
    }

    /// Returns this installation to the first-run state without uninstalling.
    private func resetFromZero() {
        guard !resetInProgress, onlineCatalog.activeID == nil else {
            patchMessage = "AGUARDE O RESET ATUAL TERMINAR"
            return
        }
        patchOperationBusy = true
        pairingRecoveryBusy = true
        resetInProgress = true
        activePatchID = nil
        currentTestPatchName = nil
        patchMessage = "RESTAURANDO E RESETANDO..."

        DevicePatchService.operationQueue.async {
            let result = DevicePatchService.restorePendingOriginals(reconnect: true)
            DispatchQueue.main.async {
                guard result.failures.isEmpty else {
                    self.patchOperationBusy = false
                    self.pairingRecoveryBusy = false
                    self.resetInProgress = false
                    self.patchMessage = "RESET INCOMPLETO — TENTE NOVAMENTE"
                    self.activationFailureDetails = "Antes de resetar, todos os originais precisam ser confirmados.\n\n" + result.failures.joined(separator: "\n\n")
                    self.showActivationFailureAlert = true
                    return
                }
                DevicePatchService.discardResolvedJournals()
                self.appliedPatchIDs.removeAll()
                self.persistAppliedPatchIDs()
                self.clearTemporaryPatchState()
                self.showManualRestorePrompt = false
                AirLiftPairingStore.shared.clearConnectionConfirmationForThisInstallation()
                AirLiftPairingStore.shared.deletePairingFile()
                AirLiftTransport.shared.disconnect()
                self.patchOperationBusy = false
                self.pairingRecoveryBusy = false
                self.resetInProgress = false
                self.patchMessage = "FECHE E ABRA O EXTERNAL NOVAMENTE PARA PODER USAR OUTRA OPÇÃO"
                self.patchStore.reload()
                self.onlineCatalog.clearEnabledStates()
                self.onlineCatalog.syncEnabledStates()
                self.appState.refreshAirLiftConnectionState()
                // O iOS não permite que uma IPA encerre o próprio processo
                // de forma suportada. O estado abaixo deixa o reset concluído
                // e exige fechar e abrir a IPA para iniciar novamente.
            }
        }
    }

    /// Cancel future timers, but never overlap a write already in progress.
    private func restoreOriginals(reconnect: Bool, onlyIDs: Set<UUID>? = nil) {
        guard !patchOperationBusy, onlineCatalog.activeID == nil else {
            patchMessage = "AGUARDE A OPERAÇÃO ATUAL TERMINAR"
            return
        }
        patchOperationBusy = true
        pairingRecoveryBusy = reconnect
        activePatchID = nil
        currentTestPatchName = nil
        patchMessage = reconnect ? "RECONECTANDO E RESTAURANDO..." : "RESTAURANDO ORIGINAIS..."

        DevicePatchService.operationQueue.async {
            let result = DevicePatchService.restorePendingOriginals(reconnect: reconnect, projectIDs: onlyIDs)
            DispatchQueue.main.async {
                if result.failures.isEmpty {
                    if let onlyIDs { self.appliedPatchIDs.subtract(onlyIDs) }
                    else { self.appliedPatchIDs.removeAll() }
                    self.clearTemporaryPatchState()
                    self.showManualRestorePrompt = false
                    self.patchMessage = reconnect
                        ? "CONEXÃO PRONTA — ESCOLHA OUTRO PATCH"
                        : (result.restoredTransactions > 0 ? "ORIGINAIS RESTAURADOS" : "NENHUM PATCH ATIVO")
                } else {
                    self.appliedPatchIDs.subtract(result.restoredIDs)
                    self.appliedPatchIDs.formUnion(result.remainingIDs)
                    self.showManualRestorePrompt = !result.remainingIDs.isEmpty
                    self.patchMessage = "RESTAURAÇÃO INCOMPLETA — TENTE NOVAMENTE"
                    self.activationFailureDetails = "Não foi possível restaurar todos os originais. Os patches pendentes continuam marcados.\n\n" + result.failures.joined(separator: "\n\n")
                    self.showActivationFailureAlert = true
                }
                self.persistAppliedPatchIDs()
                self.patchOperationBusy = false
                self.pairingRecoveryBusy = false
                self.patchStore.reload()
                self.restorePersistedPatchIDs()
                self.onlineCatalog.syncEnabledStates()
                self.appState.refreshAirLiftConnectionState()
            }
        }
    }

    /// FF/AP only: persistent categories are left intact by the manual FF button.
    private func forceRestoreFFOnly() {
        let ffIDs = Set(patchStore.items.compactMap { item -> UUID? in
            guard let itemCategory = category(for: item), !isPersistentCategory(itemCategory) else { return nil }
            return item.uniqueID
        })
        restoreOriginals(reconnect: false, onlyIDs: ffIDs)
    }

    /// Restore the journaled bytes directly, like the Amazon reference IPA.
    /// DevicePatchService restores the AirTraffic connection only when the
    /// actual journal operation needs it, so a stale session does not block
    /// an otherwise valid restore before it starts.
    private func restoreManualOriginalFromDevice() {
        // A recuperação manual deve descobrir o journal real no disco. O
        // conjunto em memória pode ficar desatualizado após reinício ou
        // atualização e, nesse caso, o botão aparecia mas não restaurava nada.
        restoreOriginals(reconnect: true, onlyIDs: nil)
    }

    private var forceOriginalButtonTitle: String {
        switch selectedGameTab {
        case .ffMax: return "RESTAURAR ORIGINAL DO FF MAX"
        default: return "RESTAURAR ORIGINAL DO FREE FIRE"
        }
    }

    private var isFreeFireGameTab: Bool {
        switch selectedGameTab {
        case .ffNormal, .ffMax: return true
        default: return false
        }
    }

    private func forceOriginalFileInSelectedGame() {
        guard isFreeFireGameTab, !patchOperationBusy, onlineCatalog.activeID == nil else {
            patchMessage = "AGUARDE A OPERAÇÃO ATUAL TERMINAR"
            return
        }
        let bundleID: String
        let gameName: String
        switch selectedGameTab {
        case .ffMax:
            bundleID = "com.dts.freefiremax"
            gameName = "FF MAX"
        default:
            bundleID = "com.dts.freefireth"
            gameName = "FREE FIRE"
        }
        patchOperationBusy = true
        pairingRecoveryBusy = true
        patchMessage = "RESTAURANDO ORIGINAL DO \(gameName)..."
        DevicePatchService.operationQueue.async {
            var lastError: Error?
            var completed = false
            for attempt in 1...8 {
                do {
                    try DevicePatchService.forceOriginalForCurrentBackend(bundleID: bundleID)
                    completed = true
                    break
                } catch {
                    lastError = error
                    if attempt < 8 { Thread.sleep(forTimeInterval: 0.6) }
                }
            }
            DispatchQueue.main.async {
                self.patchOperationBusy = false
                self.pairingRecoveryBusy = false
                if completed {
                    let ffIDs = Set(self.patchStore.items.compactMap { item -> UUID? in
                        guard let itemCategory = self.category(for: item), !self.isPersistentCategory(itemCategory) else { return nil }
                        return item.uniqueID
                    })
                    self.appliedPatchIDs.subtract(ffIDs)
                    self.persistAppliedPatchIDs()
                    self.showManualRestorePrompt = false
                    self.patchStore.reload()
                    self.onlineCatalog.syncEnabledStates()
                    self.patchMessage = "ORIGINAL RESTAURADO — \(gameName)"
                } else {
                    self.patchMessage = "NÃO FOI POSSÍVEL RESTAURAR O ORIGINAL"
                    self.activationFailureDetails = lastError?.localizedDescription ?? "No fue posible confirmar la escritura."
                    self.showActivationFailureAlert = true
                }
            }
        }
    }

    private func toggleLocalPatch(_ item: PatchLibraryItem) {
        guard !patchOperationBusy, onlineCatalog.activeID == nil, !selectionTapLocked,
              isPatchApplied(item) || isReadyToSelect(item) else {
            patchMessage = "AGUARDE O CARREGAMENTO DO PATCH TERMINAR"
            return
        }
        selectionTapLocked = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            selectionTapLocked = false
        }
        let wasApplied = isPatchApplied(item)
        let selectedCategory = category(for: item) ?? selectedGameTab.category

        // Categorias diferentes podem coexistir. A fila transacional do
        // DevicePatchService serializa as escritas e cada categoria mantém
        // seu próprio journal; não bloquear FF/AP só porque outra categoria
        // já tem um patch ativo.

        if !wasApplied {
            // A troca exige o reset explícito para evitar journals antigos e
            // garantir que o próximo patch comece em estado limpo.
            let previousSameCategoryItems = patchStore.items.filter { candidate in
                candidate.uniqueID != item.uniqueID &&
                category(for: candidate) == selectedCategory &&
                isPatchApplied(candidate)
            }

            patchOperationBusy = true
            activePatchID = item.uniqueID
            patchMessage = "PROCESSANDO..."

            DevicePatchService.operationQueue.async {
                var inactiveIDs = Set<UUID>()
                var restoreFailure: String?
                if !isPersistentCategory(selectedCategory) {
                    let previousIDs = Set(previousSameCategoryItems.map(\.uniqueID))
                    // Do not make an empty recovery reconnect gate the first
                    // manual apply. Reconnect only when there is an older
                    // patch that actually needs restoration.
                    if !previousIDs.isEmpty {
                        let recovery = DevicePatchService.restorePendingOriginals(
                            reconnect: true,
                            projectIDs: previousIDs
                        )
                        if recovery.failures.isEmpty {
                            inactiveIDs.formUnion(previousIDs.subtracting(recovery.remainingIDs))
                        } else {
                            restoreFailure = recovery.failures.joined(separator: "\n\n")
                        }
                    }
                }

                var message: String
                if let restoreFailure {
                    message = "ERROR — " + restoreFailure
                } else {
                    do {
                        var project = item.project!
                        project.id = item.uniqueID
                        _ = try DevicePatchService.apply(project: project)
                        message = "ATIVO — " + item.displayName
                    } catch {
                        message = "ERROR — " + error.localizedDescription
                    }
                }

                DispatchQueue.main.async { [self] in
                    appliedPatchIDs.subtract(inactiveIDs)
                    if message.hasPrefix("ATIVO") {
                        appliedPatchIDs.insert(item.uniqueID)
                        if !isPersistentCategory(selectedCategory) {
                            showManualRestorePrompt = true
                        }
                        PatchAudioFeedback.bypassActivated()
                    }
                    persistAppliedPatchIDs()
                    patchMessage = message.hasPrefix("ATIVO") ? "PATCH ATIVO" : "NÃO FOI POSSÍVEL ATIVAR"
                    if !message.hasPrefix("ATIVO") {
                        activationFailureDetails = message.replacingOccurrences(of: "ERROR — ", with: "")
                        showActivationFailureAlert = true
                    }
                    if !message.hasPrefix("ATIVO") { showManualRestorePrompt = false }
                    patchOperationBusy = false
                    activePatchID = nil
                }
            }
            return
        }

        // Já aplicado? Desliga agora.
        if wasApplied {
            patchOperationBusy = true
            activePatchID = item.uniqueID
            patchMessage = "PROCESSANDO..."
            DevicePatchService.operationQueue.async {
                var message: String
                if let receipt = DevicePatchService.latestReceipt(projectID: item.uniqueID) {
                    do {
                        try DevicePatchService.restore(receipt: receipt, allowModifiedPatchedFiles: true)
                        message = "RESTORE SUCCESSFUL"
                    } catch {
                        message = "ERROR — \(error.localizedDescription)"
                    }
                } else {
                    message = "RESTORE SUCCESSFUL — NO ACTIVE JOURNAL"
                }
                DispatchQueue.main.async {
                    self.patchMessage = message.lowercased().contains("successful")
                        ? "PATCH DESATIVADO"
                        : "NÃO FOI POSSÍVEL DESATIVAR"
                    if message.lowercased().contains("successful") {
                        PatchAudioFeedback.originalRestored()
                        self.appliedPatchIDs.remove(item.uniqueID)
                        self.persistAppliedPatchIDs()
                        self.showManualRestorePrompt = false
                    }
                    if !message.lowercased().contains("successful") {
                        self.activationFailureDetails = message.replacingOccurrences(of: "ERROR — ", with: "")
                        self.showActivationFailureAlert = true
                    }
                    self.onlineCatalog.syncEnabledStates()
                    self.patchOperationBusy = false
                    self.activePatchID = nil
                }
            }
            return
        }

    }

    private func reconnectSavedAirLiftIfNeeded() {
        guard !patchOperationBusy,
              AirLiftPairingStore.shared.hasPairingFile else { return }
        DispatchQueue.global(qos: .utility).async {
            let connected = AirLiftTransport.shared.reconnectSavedPairingIfNeeded()
            DispatchQueue.main.async {
                guard connected else { return }
                // A saved pairing plus an active LocalDevVPN is enough to
                // restore compatibility on the next launch; no second manual
                // pairing action is needed.
                AirLiftPairingStore.shared.markConnectionConfirmedForThisInstallation()
                self.appState.refreshAirLiftConnectionState()
            }
        }
    }

    private func openGame(scheme: String) {
        guard !patchOperationBusy, onlineCatalog.activeID == nil,
              let url = URL(string: "\(scheme)://") else { return }
        log("openGame: opening \(scheme) in manual mode")
        UIApplication.shared.open(url, options: [:]) { success in
            log("launch: \(scheme) success=\(success)")
        }
    }

}

// Os callbacks permanecem sem efeito para preservar a sequência dos handlers.
private enum PatchAudioFeedback {
    static func bypassActivated() {}
    static func originalRestored() {}
}
