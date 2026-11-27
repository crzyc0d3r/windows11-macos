import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import Win11ShellCore

public enum SnippingRecorderError: LocalizedError {
    case displayNotFound
    case alreadyRecording
    case notRecording
    case emptyOutputFile
    case recordingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .displayNotFound:
            return "Could not find target display for recording."
        case .alreadyRecording:
            return "A screen recording is already in progress."
        case .notRecording:
            return "No screen recording is currently active."
        case .emptyOutputFile:
            return "The recorded video file was empty or not finalized."
        case .recordingFailed(let message):
            return message
        }
    }
}

private final class StreamRecorderDelegate: NSObject, SCRecordingOutputDelegate, SCStreamDelegate, @unchecked Sendable {
    var onStarted: (@Sendable () -> Void)?
    var onFinished: (@Sendable () -> Void)?
    var onFailed: (@Sendable (any Error) -> Void)?

    func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        onStarted?()
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        onFinished?()
    }

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        onFailed?(error)
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onFailed?(error)
    }
}

@MainActor
public final class SnippingVideoRecorder {
    private var activeStream: SCStream?
    private var activeOutput: SCRecordingOutput?
    private var activeDelegate: StreamRecorderDelegate?
    private var activeOutputURL: URL?
    private var unexpectedErrorHandler: ((String) -> Void)?

    private var didFinishCallback = false
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var isStopping = false
    private var terminalError: (any Error)?

    public init() {}

    public var isRecording: Bool {
        activeStream != nil
    }

    public func startRecording(
        displayID: CGDirectDisplayID,
        sourceRectInDisplayPoints: CGRect,
        backingScale: CGFloat,
        outputURL: URL,
        captureSystemAudio: Bool,
        captureMicrophone: Bool,
        excludedWindowIDs: Set<CGWindowID>,
        onUnexpectedError: @escaping @MainActor (String) -> Void
    ) async throws {
        guard activeStream == nil else {
            throw SnippingRecorderError.alreadyRecording
        }

        if captureMicrophone {
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            }
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw SnippingRecorderError.displayNotFound
        }

        let excludedWindows = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)

        let displayBounds = CGRect(x: 0, y: 0, width: CGFloat(scDisplay.width), height: CGFloat(scDisplay.height))
        let clipped = sourceRectInDisplayPoints.standardized.intersection(displayBounds)
        let clampedRect = CGRect(
            x: max(0, min(displayBounds.width - 16, clipped.minX)),
            y: max(0, min(displayBounds.height - 16, clipped.minY)),
            width: max(16, min(displayBounds.width, clipped.width)),
            height: max(16, min(displayBounds.height, clipped.height))
        )

        let effectiveScale = max(1.0, min(2.0, backingScale))
        let streamCfg = SCStreamConfiguration()
        streamCfg.sourceRect = clampedRect
        streamCfg.width = SnippingGeometry.evenPixelDimension(clampedRect.width * effectiveScale)
        streamCfg.height = SnippingGeometry.evenPixelDimension(clampedRect.height * effectiveScale)
        streamCfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        streamCfg.showsCursor = true
        streamCfg.capturesAudio = captureSystemAudio
        streamCfg.captureMicrophone = captureMicrophone
        streamCfg.scalesToFit = true
        streamCfg.captureResolution = .best

        try? FileManager.default.removeItem(at: outputURL)

        let recCfg = SCRecordingOutputConfiguration()
        recCfg.outputURL = outputURL
        recCfg.outputFileType = .mp4
        recCfg.videoCodecType = .h264

        let delegate = StreamRecorderDelegate()
        delegate.onFinished = { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.didFinishCallback = true
                let cont = self.finishContinuation
                self.finishContinuation = nil
                cont?.resume()
            }
        }
        delegate.onFailed = { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.terminalError = error
                self.didFinishCallback = true
                let cont = self.finishContinuation
                self.finishContinuation = nil
                cont?.resume()
                if !self.isStopping {
                    let handler = self.unexpectedErrorHandler
                    self.resetState(deletePartialFile: false)
                    handler?(error.localizedDescription)
                }
            }
        }

        let recordingOutput = SCRecordingOutput(configuration: recCfg, delegate: delegate)
        let stream = SCStream(filter: filter, configuration: streamCfg, delegate: delegate)

        self.didFinishCallback = false
        self.terminalError = nil
        self.isStopping = false
        self.unexpectedErrorHandler = onUnexpectedError
        self.activeDelegate = delegate
        self.activeOutput = recordingOutput
        self.activeStream = stream
        self.activeOutputURL = outputURL

        do {
            try stream.addRecordingOutput(recordingOutput)
            try await stream.startCapture()
        } catch {
            resetState(deletePartialFile: true)
            throw error
        }
    }

    public func stopRecording() async throws -> URL {
        guard let stream = activeStream, let outputURL = activeOutputURL else {
            throw SnippingRecorderError.notRecording
        }

        isStopping = true
        let output = activeOutput

        if !didFinishCallback {
            let timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, let cont = self.finishContinuation else { return }
                self.didFinishCallback = true
                self.finishContinuation = nil
                cont.resume()
            }

            if let output {
                try? stream.removeRecordingOutput(output)
            }
            try? await stream.stopCapture()

            if !didFinishCallback {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if didFinishCallback {
                        continuation.resume()
                    } else {
                        finishContinuation = continuation
                    }
                }
            }
            timeoutTask.cancel()
        } else {
            if let output {
                try? stream.removeRecordingOutput(output)
            }
            try? await stream.stopCapture()
        }

        let recordedError = terminalError
        resetState(deletePartialFile: false)

        if let recordedError {
            throw SnippingRecorderError.recordingFailed(recordedError.localizedDescription)
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        guard FileManager.default.fileExists(atPath: outputURL.path), fileSize > 0 else {
            throw SnippingRecorderError.emptyOutputFile
        }
        return outputURL
    }

    public func cancelRecording() async {
        guard let stream = activeStream else {
            resetState(deletePartialFile: true)
            return
        }
        isStopping = true
        if let output = activeOutput {
            try? stream.removeRecordingOutput(output)
        }
        try? await stream.stopCapture()
        resetState(deletePartialFile: true)
    }

    private func resetState(deletePartialFile: Bool) {
        let partialURL = activeOutputURL
        activeStream = nil
        activeOutput = nil
        activeDelegate = nil
        activeOutputURL = nil
        unexpectedErrorHandler = nil
        finishContinuation?.resume()
        finishContinuation = nil
        didFinishCallback = false
        terminalError = nil
        isStopping = false

        if deletePartialFile, let partialURL {
            try? FileManager.default.removeItem(at: partialURL)
        }
    }
}
