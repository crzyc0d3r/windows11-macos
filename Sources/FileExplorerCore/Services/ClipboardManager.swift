import AppKit
import Foundation

@MainActor
public final class ClipboardManager {
    private let pasteboard: NSPasteboard
    private var lastManagedChangeCount: Int
    private var managedPayload: ClipboardPayload?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastManagedChangeCount = pasteboard.changeCount
    }

    public func copy(urls: [URL]) -> ClipboardPayload? {
        guard !urls.isEmpty else { return nil }
        writeURLsToPasteboard(urls)
        let payload = ClipboardPayload(operation: .copy, urls: urls.map(\.standardizedFileURL))
        managedPayload = payload
        lastManagedChangeCount = pasteboard.changeCount
        return payload
    }

    public func cut(urls: [URL]) -> ClipboardPayload? {
        guard !urls.isEmpty else { return nil }
        writeURLsToPasteboard(urls)
        let payload = ClipboardPayload(operation: .cut, urls: urls.map(\.standardizedFileURL))
        managedPayload = payload
        lastManagedChangeCount = pasteboard.changeCount
        return payload
    }

    public func currentPayload() -> ClipboardPayload? {
        if pasteboard.changeCount == lastManagedChangeCount, let managedPayload {
            return managedPayload
        }

        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let readURLs = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]) ?? []
        if readURLs.isEmpty {
            managedPayload = nil
            return nil
        }

        let externalPayload = ClipboardPayload(
            operation: .copy,
            urls: readURLs.map(\.standardizedFileURL)
        )
        managedPayload = externalPayload
        lastManagedChangeCount = pasteboard.changeCount
        return externalPayload
    }

    public func clearCutStateIfNeeded() -> ClipboardPayload? {
        guard managedPayload?.operation == .cut else {
            return currentPayload()
        }
        managedPayload = nil
        pasteboard.clearContents()
        lastManagedChangeCount = pasteboard.changeCount
        return nil
    }

    public func clear() {
        managedPayload = nil
        pasteboard.clearContents()
        lastManagedChangeCount = pasteboard.changeCount
    }

    public func copyPathsToStringPasteboard(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let joined = urls.map(\.path).joined(separator: "\n")
        pasteboard.clearContents()
        pasteboard.setString(joined, forType: .string)
        managedPayload = nil
        lastManagedChangeCount = pasteboard.changeCount
    }

    private func writeURLsToPasteboard(_ urls: [URL]) {
        pasteboard.clearContents()
        let nsURLs = urls.map { $0.standardizedFileURL as NSURL }
        pasteboard.writeObjects(nsURLs)
    }
}
