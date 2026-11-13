import Foundation
import UIKit

/// Configuração oficial da marca. O canal não é editável por preferências ou conteúdo remoto.
enum BrandProtection {
    private static let channelParts = [
        "https://whatsapp.com/",
        "channel/",
        "0029Vb8fCNt7NoZwop5I6409"
    ]

    static var channelURL: URL {
        URL(string: channelParts.joined())!
    }

    static func openChannel() {
        let url = channelURL
        guard url.scheme == "https", url.host == "whatsapp.com", url.path.hasPrefix("/channel/") else { return }
        UIApplication.shared.open(url)
    }

    static var canonicalChannelIsIntact: Bool {
        channelURL.absoluteString == "https://whatsapp.com/channel/0029Vb8fCNt7NoZwop5I6409"
    }
}
