import Foundation

/// Compatibility cleanup for directories created by old releases.
/// New patch editing/application operates on in-memory package models and the
/// encrypted `.r7v` cache; this service intentionally has no workspace writer.
enum PatchWorkspaceService {
    static func clearWorkspaceArtifacts(fileManager: FileManager = .default) {
        let temporary = fileManager.temporaryDirectory
            .appendingPathComponent(".fp-session", isDirectory: true)
            .appendingPathComponent(".workspaces", isDirectory: true)
        let documentsRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
        let supportRoot = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let documentsSessionWorkspace = documentsRoot?
            .appendingPathComponent(".fp-session", isDirectory: true)
            .appendingPathComponent(".workspaces", isDirectory: true)
        let supportSessionWorkspace = supportRoot?
            .appendingPathComponent(".fp-session", isDirectory: true)
            .appendingPathComponent(".workspaces", isDirectory: true)
        let legacyDirectories = [
            temporary,
            documentsRoot?.appendingPathComponent(".workspaces", isDirectory: true),
            documentsSessionWorkspace,
            supportRoot?.appendingPathComponent(".workspaces", isDirectory: true),
            supportSessionWorkspace
        ].compactMap({ $0 })
        for url in legacyDirectories {
            try? fileManager.removeItem(at: url)
        }
    }
}
