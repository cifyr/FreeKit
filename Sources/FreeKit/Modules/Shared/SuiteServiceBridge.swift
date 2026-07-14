import AppKit
import FreeKitCore

// Registered as NSApp.servicesProvider at launch (a single object can host
// several NSServices entries; each Info.plist entry just points its NSMessage
// at a different selector here) so "Optimize with Clop" and "Convert with
// FreeKit" always resolve, and gates each on its module actually being enabled
// rather than failing silently.
final class SuiteServiceBridge: NSObject {
    private let registry: ModuleRegistry

    init(registry: ModuleRegistry) {
        self.registry = registry
    }

    @objc func optimizeWithClop(_ pasteboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Log.info("clop: service invoked with \(urls.count) file(s)")
        guard let module = registry.module(id: ModuleCatalog.clop.id) as? ClopModule,
              registry.isEnabled(id: ModuleCatalog.clop.id) else {
            ClopToast.show("Turn on Clop in FreeKit to optimize files")
            return
        }
        guard !urls.isEmpty else { return }
        module.optimizeFiles(urls)
    }

    @objc func convertWithFreeKit(_ pasteboard: NSPasteboard, userData: String?,
                                  error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Log.info("convert: service invoked with \(urls.count) file(s)")
        guard let module = registry.module(id: ModuleCatalog.convert.id) as? ConvertModule,
              registry.isEnabled(id: ModuleCatalog.convert.id) else {
            ConvertToast.show("Turn on Convert in FreeKit to convert files")
            return
        }
        guard !urls.isEmpty else { return }
        module.convertFiles(urls)
    }

    // Backs every "Convert to X" entry (one per format Convert supports):
    // they all point at this single selector and disambiguate via NSUserData
    // ("<mediaKind>:<formatRawValue>", e.g. "image:heic") rather than each
    // getting its own selector.
    @objc func convertToFormat(_ pasteboard: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        Log.info("convert: convert-to-format service invoked with \(urls.count) file(s), userData=\(userData ?? "nil")")
        guard let module = registry.module(id: ModuleCatalog.convert.id) as? ConvertModule,
              registry.isEnabled(id: ModuleCatalog.convert.id) else {
            ConvertToast.show("Turn on Convert in FreeKit to convert files")
            return
        }
        guard !urls.isEmpty else { return }
        guard let userData, let separator = userData.firstIndex(of: ":") else {
            Log.error("convert: convert-to-format service missing userData")
            return
        }
        let kindRaw = String(userData[userData.startIndex..<separator])
        let formatRaw = String(userData[userData.index(after: separator)...])
        guard let kind = ConvertPlan.MediaKind(rawValue: kindRaw) else {
            Log.error("convert: convert-to-format service got unrecognized userData \(userData)")
            return
        }
        module.convertFiles(urls, overridingKind: kind, rawValue: formatRaw)
    }
}
