import Foundation

enum PatchCatalog {

    enum Category: String, CaseIterable {
        case ffNormal = "FF NORMAL"
        case ffMax = "FF MAX"
        case ap = "AP"
        case textures = "TEXTURAS"
        case holograms = "HOLOGRAMAS"
        case others = "OUTROS"
    }

    struct Entry: Identifiable {
        let id: Int
        let filename: String
        let displayName: String
        let category: Category
    }

    // Patches are now supplied by the authenticated online catalog.
    static let entries: [Entry] = [
    ]

    static func entry(forBundledFile filename: String) -> Entry? {
        if let match = entries.first(where: { $0.filename == filename }) {
            return match
        }
        if !filename.hasSuffix(".3105"), let match = entries.first(where: { $0.filename == filename + ".3105" }) {
            return match
        }
        return nil
    }

    static func displayName(forBundledFile filename: String) -> String? {
        entry(forBundledFile: filename)?.displayName
    }

    static func entries(in category: Category) -> [Entry] {
        entries.filter { $0.category == category }
    }
}
