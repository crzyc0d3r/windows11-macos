import AppKit
import FileExplorerCore
@preconcurrency import QuickLookUI
import SwiftUI

public struct QuickLookBridgeView: NSViewRepresentable {
    public let store: ExplorerStore

    public init(store: ExplorerStore) {
        self.store = store
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(store: store)
    }

    public func makeNSView(context: Context) -> QuickLookHostView {
        let view = QuickLookHostView()
        view.coordinator = context.coordinator
        context.coordinator.hostView = view
        return view
    }

    public func updateNSView(_ nsView: QuickLookHostView, context: Context) {
        guard !store.snapshotMode else { return }
        context.coordinator.sync(
            isPresented: store.isQuickLookPresented,
            urls: store.selectedItems.map(\.url).filter { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    @MainActor
    public final class Coordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
        private let store: ExplorerStore
        fileprivate var previewURLs: [URL] = []
        fileprivate weak var hostView: QuickLookHostView?
        private var closeObserver: NSObjectProtocol?
        private var keyMonitor: Any?

        init(store: ExplorerStore) {
            self.store = store
            super.init()
        }

        func sync(isPresented: Bool, urls: [URL]) {
            previewURLs = urls
            guard let panel = QLPreviewPanel.shared() else { return }

            if isPresented && !previewURLs.isEmpty {
                panel.dataSource = self
                panel.delegate = self
                installObservers(for: panel)
                if !panel.isVisible {
                    panel.makeKeyAndOrderFront(nil)
                }
                panel.reloadData()
            } else if panel.isVisible && panel.dataSource === self {
                panel.orderOut(nil)
                removeObservers()
            }
        }

        private func installObservers(for panel: QLPreviewPanel) {
            if closeObserver == nil {
                closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: panel,
                    queue: .main
                ) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.removeObservers()
                        if self.store.isQuickLookPresented {
                            self.store.isQuickLookPresented = false
                        }
                    }
                }
            }
            if keyMonitor == nil {
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard let self else { return event }
                    if event.window === QLPreviewPanel.shared() && (event.keyCode == 49 || event.keyCode == 53) {
                        Task { @MainActor [weak self] in
                            self?.store.isQuickLookPresented = false
                        }
                        return nil
                    }
                    return event
                }
            }
        }

        private func removeObservers() {
            if let closeObserver {
                NotificationCenter.default.removeObserver(closeObserver)
                self.closeObserver = nil
            }
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }

        public nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
            MainActor.assumeIsolated {
                previewURLs.count
            }
        }

        public nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
            let url: URL? = MainActor.assumeIsolated {
                guard previewURLs.indices.contains(index) else { return nil }
                return previewURLs[index]
            }
            return url.map { $0 as NSURL }
        }
    }

    public final class QuickLookHostView: NSView {
        weak var coordinator: Coordinator?

        public nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
            true
        }

        public nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated {
                panel.dataSource = coordinator
                panel.delegate = coordinator
            }
        }

        public nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
            MainActor.assumeIsolated {
                if panel.dataSource === coordinator {
                    panel.dataSource = nil
                    panel.delegate = nil
                }
            }
        }
    }
}
