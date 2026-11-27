import Foundation

private final class FileSystemSourceHandle: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let lock = NSLock()
    private var isCancelled = false

    init?(url: URL, onEvent: @escaping @Sendable () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }

        let mask: DispatchSource.FileSystemEvent = [.write, .delete, .rename, .extend, .attrib]
        let queue = DispatchQueue(label: "com.fileexplorer.directorywatcher", qos: .utility)
        let dispatchSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: mask,
            queue: queue
        )
        dispatchSource.setEventHandler(handler: onEvent)
        dispatchSource.setCancelHandler {
            close(fd)
        }
        self.source = dispatchSource
        dispatchSource.resume()
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !isCancelled else { return }
        isCancelled = true
        source.cancel()
    }

    deinit {
        cancel()
    }
}

@MainActor
public final class DirectoryWatcher {
    private var handle: FileSystemSourceHandle?
    private var watchedURL: URL?
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: Duration
    private var onChange: (@MainActor () -> Void)?

    public init(debounceInterval: Duration = .milliseconds(200)) {
        self.debounceInterval = debounceInterval
    }

    public func watch(url: URL?, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        let standardized = url?.standardizedFileURL

        if standardized == watchedURL && handle != nil {
            return
        }

        stop()
        guard let targetURL = standardized else { return }

        let newHandle = FileSystemSourceHandle(url: targetURL) { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedNotification()
            }
        }
        guard let newHandle else { return }

        watchedURL = targetURL
        handle = newHandle
    }

    public func stop() {
        debounceTask?.cancel()
        debounceTask = nil
        handle?.cancel()
        handle = nil
        watchedURL = nil
    }

    private func scheduleDebouncedNotification() {
        debounceTask?.cancel()
        let interval = debounceInterval
        debounceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }
}
