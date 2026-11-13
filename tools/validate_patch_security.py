#!/usr/bin/env python3
"""Static security contract checks for the Filza V5 patch cache and UI."""
from __future__ import annotations

from pathlib import Path
import plistlib
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "ThreeOneOSFive"


def read(rel: str) -> str:
    return (ROOT / rel).read_text(encoding="utf-8", errors="replace")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)
    print("PASS:", message)


def between(source: str, start: str, end: str) -> str:
    i = source.find(start)
    if i < 0:
        raise ValueError("missing source marker: " + start)
    j = source.find(end, i + len(start))
    if j < 0:
        raise ValueError("missing source marker: " + end)
    return source[i:j]


def main() -> int:
    project = read("ThreeOneOSFive/helpers/PatchProjectLibrary.swift")
    crypto = between(project, "enum PatchAtRestCrypto", "struct PatchLibraryItem")
    save = between(project, "    static func save(", "    static func installImportedPackage(")
    ensure = between(project, "    static func ensureProtectedAtRest(", "    static func save(")
    load = between(project, "    static func load(", "    private static func migrateOpaqueCatalogURLIfNeeded(")

    require('AES.GCM.seal(data, using: try key(), authenticating: Data(filename.utf8))' in crypto,
            "cache payloads use authenticated AES-GCM with filename-bound AAD")
    require('AES.GCM.open(box, using: try key(), authenticating: Data(filename.utf8))' in crypto,
            "cache reads authenticate ciphertext and reject tampering or renamed files")
    require('result.append(combined)' in crypto and 'private static let magic = Data("FPENC1\\0".utf8)' in crypto,
            "encrypted files use the explicit FPENC1 AES-GCM envelope")
    require('PatchAtRestCrypto.seal(data, filename: destination.lastPathComponent)' in save
            and '.completeFileProtection' in save,
            "every saved local package is encrypted before atomic, file-protected write")
    require('try ensureProtectedAtRest(at: url, fileManager: fileManager)' in load
            and 'if !isProtectedAtRest(at: url)' in load
            and 'try? fileManager.removeItem(at: url)' in load,
            "legacy plaintext is encrypted before use or deleted on migration failure")
    imported = between(project, "    static func installImportedPackage(", "    static func delete(")
    require('previousData.write' not in imported and '_ = try? save(' in imported,
            "failed package replacement restores the previous item only through encrypted save")
    require('for: .applicationSupportDirectory' in project
            and 'appendingPathComponent(".fp-session"' in project
            and 'appendingPathComponent(".packages"' in project
            and 'values.isHidden = true' in project,
            "package cache is persistent in hidden Application Support, not tmp/Documents")

    catalog = read("ThreeOneOSFive/helpers/PatchCatalogStore.swift")
    catalog_exists = between(catalog, "    private nonisolated static func isValidCachedPackage(at url: URL) -> Bool {", "    private static func normalizedCategory(")
    require('ensureProtectedAtRest(at: url)' in catalog_exists
            and 'readPackage(at: url)' in catalog_exists,
            "remote catalog only reports a cache ready after protected read succeeds")
    refresh = between(catalog, "    func refresh() async {", "    private func publishCatalogIfChanged(")
    require("publishCatalogIfChanged(incoming)" in refresh
            and refresh.index("publishCatalogIfChanged(incoming)") < refresh.index("let batchSize = 2")
            and "let batchSize = 2" in refresh,
            "catalog options appear before automatic two-at-a-time prefetch")
    require("inFlightDownloads" in catalog and "Task.detached(priority: .utility)" in catalog,
            "prefetch reuses in-flight downloads and validates encrypted cache off the UI thread")

    license = read("ThreeOneOSFive/helpers/FilzaLicense.swift")
    cache_name = between(license, "        static func cacheFilename(", "        var localFilename")
    require('SHA256.hash(data: source)' in cache_name and '.r7v' in cache_name
            and 'catalogID' in cache_name and 'remoteFilename' in cache_name,
            "local .r7v filenames are stable opaque SHA-256 names, not server titles")

    server = read("server/filza_control.py")
    legacy_auth = between(server, "def legacy_license_key(", "def get_control(")
    catalog_auth = between(server, "def authorized_request(", "def catalog(")
    require("if not activate and row['status'] != 'used':" in legacy_auth
            and "legacy_license_key(key, device_id, activate=False)" in catalog_auth
            and "allow_legacy=True" in server,
            "catalog accepts only already-activated legacy reseller keys and does not consume unused keys")
    license_catalog = between(license, "    static func fetchCatalog()", "    private static func openTransport(")
    license_download = between(license, "    static func downloadItem(", "    // MARK: - Active Keys Counter")
    require('X-Filza-Device' in license_catalog and 'X-Filza-Device' in license_download
            and 'failureMessage' in license_catalog and 'HTTP \\(http.statusCode)' in license_catalog,
            "client sends device binding for reseller keys and reports catalog authorization failures")

    workspace = read("ThreeOneOSFive/helpers/PatchWorkspaceService.swift")
    require('removeItem(at: url)' in workspace
            and not re.search(r'createDirectory|write\s*\(|synchronizeWorkspace|snapshotWorkspace|documentsRootURL', workspace),
            "workspace compatibility service only removes legacy data; it cannot create plaintext workspaces")
    store = read("ThreeOneOSFive/helpers/PatchProjectStore.swift")
    require('PatchProjectLibrary.purgeLegacyBundledArtifacts()' in store
            and 'PatchWorkspaceService.clearWorkspaceArtifacts' in project,
            "legacy plaintext workspace folders are removed during app startup")
    project_views = read("ThreeOneOSFive/views/PatchProjectsView.swift")
    require('workspaceURL' not in project_views and 'synchronizeWorkspace' not in project_views,
            "patch UI has no workspace path/link and applies from the in-memory model")
    app_browser = read("ThreeOneOSFive/views/AppDataBrowserView.swift")
    require('workspaceURL' not in app_browser and 'documentsRootURL' not in app_browser,
            "app-data browser does not expose a plaintext workspace route")
    file_browser = read("ThreeOneOSFive/views/FileBrowserView.swift")
    require('.workspaces' in file_browser and '.fp-session' in file_browser and 'pathComponents.contains' in file_browser,
            "file browser hides internal cache paths and blocks legacy workspace deep links")

    view = read("ThreeOneOSFive/ContentView.swift")
    require('case ap = "AP"' in view and 'case .ap: return .ap' in view
            and 'ForEach(GameTab.allCases' in view,
            "AP is a visible game category rendered from GameTab.allCases and mapped to the remote catalog")
    require(('FILZA EXTERNAL BYPASS EXTERNAL' in view or 'FILZA EXTERNAL BYPASS' in view)
            and 'TOMMY' not in view,
            "dashboard uses Filza branding and contains no Tommy brand string")
    require('isBusy: onlineCatalog.isRefreshing' not in view and 'LazyVStack(spacing: 10)' in view,
            "background catalog refresh does not dim the whole options list; rows are lazy-rendered")
    category_controls = between(view, "ForEach(GameTab.allCases, id: \\.self)", "let localItems = filteredLocalItems")
    require("pendingPatchID" not in category_controls
            and "automaticPatchMode" not in category_controls,
            "changing categories does not create automatic patch state")
    require('Text("Patchs")' in view
            and 'CATEGORIAS ONLINE' not in view
            and 'CATEGORÍAS ONLINE' not in view,
            "dashboard heading uses the requested Patchs wording, not Spanish")
    tutorials = read("ThreeOneOSFive/TutorialsView.swift")
    require('navigationButton(title: "Patchs"' in view
            and 'navigationButton(title: "Tutoriais"' in view
            and 'TutorialsView()' in view
            and 'withAnimation(.easeInOut(duration: 0.22))' in view,
            "dashboard restores the bottom Patches/Tutorials navigation without swipe gestures over draggable switches")
    require('title: "Erro em Outros"' in tutorials
            and 'title: "FFTH e FFMax"' in tutorials
            and 'title: "Opções AP"' in tutorials
            and 'VideoPlayer(player: player)' in tutorials,
            "Portuguese tutorial page provides the three original videos and full-screen player")
    require('Text("v5.0.11 Secure")' in view,
            "visible in-app version label matches the update release")
    manual_guidance = "Modo manual: entre no jogo até 40%, volte aqui e ative o patch escolhido. Retorne ao jogo e espere chegar ao lobby; depois volte aqui, toque no patch novamente para desativá-lo e retorne ao jogo."
    require(manual_guidance in view,
            "manual mode shows the requested Portuguese 40%-to-lobby instructions")
    require("Modo manual:" in view
            and "automaticPatchMode" not in view
            and "startGameLaunchTimer" not in view
            and "resumeAutomaticCycleIfNeeded" not in view,
            "AP, FF Normal and FF Max use manual activation with no automatic cycle")
    activation = read("ThreeOneOSFive/helpers/LicenseActivationView.swift")
    require('verseCard' in activation
            and 'Peça a Deus que abençoe os seus planos, e eles darão certo.' in activation
            and 'PROVÉRBIOS 16:3' in activation,
            "original Portuguese Proverbs 16:3 verse card is present on the activation screen")
    portuguese_activation = [
        "ACESSO DE LICENÇA", "ACESSAR PAINEL",
        "Use a licença vinculada a este dispositivo.", "SUA CHAVE AQUI",
        "Lembrar chave neste dispositivo", "JOGADORES\\nONLINE",
        "Chaves em uso agora na IPA",
        "Canal oficial de atualizações", "LICENÇA ATIVA",
        "Chave validada e sincronizada", "HORAS", "SEG",
    ]
    require(all(text in activation for text in portuguese_activation),
            "activation screen labels are translated to Brazilian Portuguese")
    spanish_activation = [
        "ACCESS PORTAL", "ENTRAR EN FILZA", "Introduce tu key",
        "SUA KEY AQUI", "Recordar key", "ACCEDER AHORA",
        "JUGADORES ONLINE", "Keys activas ahora", "Actualizaciones",
        "LICENCIA ACTIVA", "Key validada y sincronizada", "HOURS", "SEC",
    ]
    require(not any(text in activation for text in spanish_activation),
            "activation screen contains none of the previous Spanish/English labels")
    info = plistlib.loads((APP / "Info.plist").read_bytes())
    require(info.get("CFBundleShortVersionString") == "5.0.11"
            and info.get("CFBundleVersion") == "19",
            "source Info.plist has the new version/build required to update the installed app")
    project_settings = read("ThreeOneOSFive.xcodeproj/project.pbxproj")
    require(project_settings.count("CURRENT_PROJECT_VERSION = 19;") == 2
            and project_settings.count("MARKETING_VERSION = 5.0.11;") == 2,
            "both Xcode configurations generate the new version/build")
    require("TutorialsView.swift in Sources" in project_settings
            and "Tutorials folder in Resources" in project_settings,
            "Xcode compiles TutorialsView and copies the Tutorials folder into the app bundle")
    design = read("ThreeOneOSFive/views/DesignSystem.swift")
    require('DragGesture(minimumDistance: 4)' in design
            and 'Arraste para a esquerda' in design
            and 'Arraste para a direita' in design,
            "patch cards retain a real draggable switch")

    anti = read("ThreeOneOSFive/helpers/AntiCrack.swift")
    resource_tests = read("tools/validate_ipa_resources.py")
    require('signatureOffset' in anti
            and '["mov", "mp4", "m4v"].contains(mediaType) ? 4 : 0' in anti,
            "integrity check recognizes ISO-BMFF video ftyp at offset 4")
    require('bundleID == "com.apple.mobile.MobileHouseArrest"' in anti
            and 'Bundle ID divergente — bloqueando interface protegida' in anti
            and 'return appContainerIsValid && canonicalBrand' in anti
            and 'if !resourcesMatch' in anti
            and 'diferenças não bloqueiam a instalação' in anti,
            "a changed Bundle ID is blocked, while normalized media cannot trigger a false startup block")
    tutorial_specs = [
        "Tutorials/tutorial_error_others.mov|mov|1000|10000000|66747970",
        "Tutorials/tutorial_ffth_ffmax.mov|mov|1000|10000000|66747970",
        "Tutorials/tutorial_ap.mov|mov|1000|10000000|66747970",
        "Tutorials/tutorial_error_banner.jpg|jpg|1000|2000000|ffd8ff",
        "Tutorials/tutorial_ffth_banner.jpg|jpg|1000|2000000|ffd8ff",
        "Tutorials/tutorial_ap_banner.jpg|jpg|1000|2000000|ffd8ff",
    ]
    require(all(spec in anti for spec in tutorial_specs)
            and 'FileHandle(forReadingFrom: resolvedURL)' in anti
            and 'read(upToCount: signature.count)' in anti
            and 'APPROVED_TUTORIAL_SHA256' in resource_tests,
            "AntiCrack recognizes tutorial MOV/JPG signatures and audits approved media without loading whole videos at launch")
    require('ftyp' in resource_tests and 'offset = 4' in resource_tests,
            "resource validator includes MOV/MP4/M4V ftyp offset-4 test cases")

    icon_path = APP / "Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
    mark_path = APP / "REALExternalMark.png"
    require(icon_path.is_file() and mark_path.is_file()
            and icon_path.read_bytes() == mark_path.read_bytes(),
            "Filza shield artwork replaces the Tommy icon and activation mark consistently")
    print("Security source audit completed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("FAIL:", exc, file=sys.stderr)
        raise SystemExit(1)
