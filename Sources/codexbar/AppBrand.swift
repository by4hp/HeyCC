import AppKit

enum AppBrand {
    static let name = "HeyCC"

    @MainActor static var logo: NSImage? {
        loadLogo(size: NSSize(width: 44, height: 44))
    }

    @MainActor static var menuLogo: NSImage? {
        loadLogo(size: NSSize(width: 18, height: 18))
    }

    @MainActor static var settingsLogo: NSImage? {
        loadLogo(size: NSSize(width: 48, height: 48))
    }

    @MainActor
    private static func loadLogo(size: NSSize) -> NSImage? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("Brand/heycc-logo.png"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/Brand/heycc-logo.png"),
        ].compactMap { $0 }

        for url in candidates {
            guard let image = NSImage(contentsOf: url) else { continue }
            image.size = size
            return image
        }
        return nil
    }
}
