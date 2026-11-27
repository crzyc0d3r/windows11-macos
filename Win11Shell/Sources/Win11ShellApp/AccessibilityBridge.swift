import AppKit
import ApplicationServices
import Foundation
@preconcurrency import ScreenCaptureKit
import Win11ShellCore

// Private AX helper to extract CGWindowID when available
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

public struct AXWindowInfo: @unchecked Sendable {
    public let pid: pid_t
    public let windowID: CGWindowID
    public let title: String
    public let axFrame: CGRect
    public let isMinimized: Bool
    public let isFullScreen: Bool
    public let element: AXUIElement
}

public struct MirroredMenuItem: @unchecked Sendable {
    public let title: String
    public let isEnabled: Bool
    public let isSeparator: Bool
    public let markChar: String?
    public let keyEquivalent: String?
    public let element: AXUIElement
    public let children: [MirroredMenuItem]
}

public struct TrayExtraItem: @unchecked Sendable, Identifiable {
    public var id: String { "\(pid)-\(index)-\(title)" }
    public let pid: pid_t
    public let index: Int
    public let appName: String
    public let bundleID: String
    public let title: String
    public let icon: NSImage?
    public let element: AXUIElement
}

public struct OnScreenWindowSnapshot: Sendable {
    public let windowID: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    public let axBounds: CGRect
}

@MainActor
public enum AccessibilityBridge {
    public static func hasAccessibilityPermission(prompt: Bool = false) -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    public static func hasInputMonitoringPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static func primaryScreenHeight() -> CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.screens.first?.frame.height ?? 900
    }

    public static func screenContaining(axFrame: CGRect) -> NSScreen? {
        let primaryH = primaryScreenHeight()
        let cocoaRect = WindowChromeGeometry.axRectToCocoa(axFrame, primaryScreenHeight: primaryH)
        let center = CGPoint(x: cocoaRect.midX, y: cocoaRect.midY)
        if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) {
            return match
        }
        return NSScreen.screens.max { a, b in
            a.frame.intersection(cocoaRect).area < b.frame.intersection(cocoaRect).area
        } ?? NSScreen.main ?? NSScreen.screens.first
    }

    public static func focusedWindow(for pid: pid_t) -> AXWindowInfo? {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)

        var focusedRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXFocusedWindowAttribute as CFString, &focusedRef)
        guard err == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            return standardWindows(for: pid).first
        }
        let winEl = focusedRef as! AXUIElement
        return windowInfo(for: winEl, pid: pid)
    }

    public static func standardWindows(for pid: pid_t) -> [AXWindowInfo] {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)

        var listRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appEl, kAXWindowsAttribute as CFString, &listRef)
        guard err == .success, let elements = listRef as? [AXUIElement] else {
            return []
        }

        return elements.compactMap { windowInfo(for: $0, pid: pid, requireStandardRole: true) }
    }

    public static func windowInfo(
        for element: AXUIElement,
        pid: pid_t,
        requireStandardRole: Bool = false
    ) -> AXWindowInfo? {
        AXUIElementSetMessagingTimeout(element, 0.25)

        if requireStandardRole {
            let role = stringAttribute(element, kAXRoleAttribute)
            let subrole = stringAttribute(element, kAXSubroleAttribute)
            if role != (kAXWindowRole as String) {
                return nil
            }
            if let subrole, subrole != (kAXStandardWindowSubrole as String) {
                return nil
            }
        }

        guard let frame = rectAttribute(element) else {
            return nil
        }

        var wid: CGWindowID = 0
        _ = _AXUIElementGetWindow(element, &wid)

        let title = stringAttribute(element, kAXTitleAttribute) ?? ""
        let isMinimized = boolAttribute(element, kAXMinimizedAttribute) ?? false
        let isFullScreen = boolAttribute(element, "AXFullScreen") ?? false

        return AXWindowInfo(
            pid: pid,
            windowID: wid,
            title: title,
            axFrame: frame,
            isMinimized: isMinimized,
            isFullScreen: isFullScreen,
            element: element
        )
    }

    public static func focusWindow(_ info: AXWindowInfo) {
        if let app = NSRunningApplication(processIdentifier: info.pid) {
            if app.isHidden {
                app.unhide()
            }
            app.activate(options: [.activateAllWindows])
        }
        AXUIElementSetMessagingTimeout(info.element, 0.25)
        if info.isMinimized {
            AXUIElementSetAttributeValue(info.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        AXUIElementPerformAction(info.element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(info.element, kAXMainAttribute as CFString, kCFBooleanTrue)
    }

    public static func setMinimized(_ element: AXUIElement, minimized: Bool) {
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementSetAttributeValue(
            element,
            kAXMinimizedAttribute as CFString,
            minimized ? kCFBooleanTrue : kCFBooleanFalse
        )
    }

    public static func setFrame(_ element: AXUIElement, axFrame: CGRect) {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var pos = axFrame.origin
        var size = axFrame.size
        let posVal = AXValueCreate(.cgPoint, &pos)
        let sizeVal = AXValueCreate(.cgSize, &size)
        // Position -> Size -> Position -> Size prevents AppKit/Electron edge-clamping
        // both when shrinking+moving down (e.g. from native Zoom) and when growing+moving up/left.
        if let posVal {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        }
        if let posVal {
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
        }
        if let sizeVal {
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
        }
    }

    @discardableResult
    public static func setPosition(_ element: AXUIElement, origin: CGPoint, timeout: Float = 0.25) -> Bool {
        AXUIElementSetMessagingTimeout(element, timeout)
        var pos = origin
        guard let posVal = AXValueCreate(.cgPoint, &pos) else {
            return false
        }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal) == .success
    }

    @discardableResult
    public static func pressCloseButton(_ element: AXUIElement) -> Bool {
        AXUIElementSetMessagingTimeout(element, 0.25)
        var closeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
              let closeRef,
              CFGetTypeID(closeRef) == AXUIElementGetTypeID()
        else {
            return false
        }
        let closeEl = closeRef as! AXUIElement
        AXUIElementSetMessagingTimeout(closeEl, 0.25)
        return AXUIElementPerformAction(closeEl, kAXPressAction as CFString) == .success
    }

    public static func performPress(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, 0.25)
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    // MARK: - Live Menu Bar Mirroring

    public static func readAppMenuBar(pid: pid_t) -> [MirroredMenuItem] {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.25)

        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef,
              CFGetTypeID(menuBarRef) == AXUIElementGetTypeID()
        else {
            return []
        }

        let menuBarEl = menuBarRef as! AXUIElement
        let topItems = childElements(of: menuBarEl)
        // Skip index 0 (Apple menu) when its title is "Apple" or empty
        var results: [MirroredMenuItem] = []
        for (idx, itemEl) in topItems.enumerated() {
            let title = stringAttribute(itemEl, kAXTitleAttribute) ?? ""
            if idx == 0 && (title == "Apple" || title.isEmpty) {
                continue
            }
            if title.isEmpty { continue }
            results.append(MirroredMenuItem(
                title: title,
                isEnabled: boolAttribute(itemEl, kAXEnabledAttribute) ?? true,
                isSeparator: false,
                markChar: nil,
                keyEquivalent: nil,
                element: itemEl,
                children: []
            ))
        }
        return results
    }

    public static func readMenuChildren(of menuBarItem: AXUIElement, maxDepth: Int = 2) -> [MirroredMenuItem] {
        guard maxDepth > 0 else { return [] }
        AXUIElementSetMessagingTimeout(menuBarItem, 0.25)
        let children = childElements(of: menuBarItem)
        guard let menuEl = children.first(where: { stringAttribute($0, kAXRoleAttribute) == (kAXMenuRole as String) })
            ?? (stringAttribute(menuBarItem, kAXRoleAttribute) == (kAXMenuRole as String) ? menuBarItem : nil)
        else {
            return []
        }

        let itemElements = childElements(of: menuEl)
        var items: [MirroredMenuItem] = []
        for el in itemElements {
            let title = stringAttribute(el, kAXTitleAttribute) ?? ""
            let role = stringAttribute(el, kAXRoleAttribute) ?? ""
            if role == "AXSeparatorMenuItem" || title.isEmpty {
                items.append(MirroredMenuItem(
                    title: "",
                    isEnabled: false,
                    isSeparator: true,
                    markChar: nil,
                    keyEquivalent: nil,
                    element: el,
                    children: []
                ))
                continue
            }
            let enabled = boolAttribute(el, kAXEnabledAttribute) ?? true
            let mark = stringAttribute(el, kAXMenuItemMarkCharAttribute)
            let cmdChar = stringAttribute(el, kAXMenuItemCmdCharAttribute)
            let subChildren = readMenuChildren(of: el, maxDepth: maxDepth - 1)
            items.append(MirroredMenuItem(
                title: title,
                isEnabled: enabled,
                isSeparator: false,
                markChar: mark,
                keyEquivalent: cmdChar,
                element: el,
                children: subChildren
            ))
        }
        return items
    }

    public static func buildNSMenu(from items: [MirroredMenuItem], target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let keyEq = item.keyEquivalent?.lowercased() ?? ""
            let menuItem = NSMenuItem(title: item.title, action: item.children.isEmpty ? action : nil, keyEquivalent: keyEq)
            menuItem.target = item.children.isEmpty ? target : nil
            menuItem.isEnabled = item.isEnabled
            menuItem.representedObject = item.element
            if item.markChar == "✓" {
                menuItem.state = .on
            }
            if !item.children.isEmpty {
                menuItem.submenu = buildNSMenu(from: item.children, target: target, action: action)
            }
            menu.addItem(menuItem)
        }
        return menu
    }

    // MARK: - Third-Party Top-Right Menu Bar Extras Mirroring

    public static func readTrayExtras(excludingBundleIDs: Set<String>) -> [TrayExtraItem] {
        var extras: [TrayExtraItem] = []
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier,
                  !excludingBundleIDs.contains(bundleID),
                  !bundleID.hasPrefix("com.apple.controlcenter"),
                  bundleID != "com.apple.Spotlight",
                  bundleID != "com.apple.systemuiserver"
            else {
                continue
            }

            let appEl = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(appEl, 0.15)
            var extrasRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appEl, kAXExtrasMenuBarAttribute as CFString, &extrasRef) == .success,
                  let extrasRef,
                  CFGetTypeID(extrasRef) == AXUIElementGetTypeID()
            else {
                continue
            }

            let barEl = extrasRef as! AXUIElement
            let children = childElements(of: barEl)
            for (idx, child) in children.enumerated() {
                let title = stringAttribute(child, kAXTitleAttribute)
                    ?? stringAttribute(child, kAXDescriptionAttribute)
                    ?? app.localizedName
                    ?? bundleID
                extras.append(TrayExtraItem(
                    pid: app.processIdentifier,
                    index: idx,
                    appName: app.localizedName ?? bundleID,
                    bundleID: bundleID,
                    title: title,
                    icon: app.icon,
                    element: child
                ))
            }
        }
        return extras
    }

    // MARK: - Fast WindowServer Bounds & Z-Order Inspection

    public static func onScreenNormalWindows() -> [OnScreenWindowSnapshot] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var results: [OnScreenWindowSnapshot] = []
        results.reserveCapacity(list.count)
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let alpha = entry[kCGWindowAlpha as String] as? Double, alpha > 0.05,
                  let widNum = entry[kCGWindowNumber as String] as? UInt32,
                  let pidNum = entry[kCGWindowOwnerPID as String] as? Int32,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  rect.width >= 200,
                  rect.height >= 100
            else {
                continue
            }
            let owner = (entry[kCGWindowOwnerName as String] as? String) ?? ""
            results.append(OnScreenWindowSnapshot(
                windowID: CGWindowID(widNum),
                pid: pid_t(pidNum),
                ownerName: owner,
                axBounds: rect
            ))
        }
        return results
    }

    public static func liveWindowBounds(windowID: CGWindowID) -> CGRect? {
        guard windowID != 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let first = list.first,
              let boundsDict = first[kCGWindowBounds as String] as? [String: Any]
        else {
            return nil
        }
        return CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    }

    public enum TitlebarHitResult: Equatable, Sendable {
        case trafficLight
        case interactiveControl
        case nativeTitlebarDragSurface
        case unknown
    }

    private static let titlebarAncestorStopRoles: Set<String> = [
        "AXWindow",
        "AXToolbar",
        "AXWebArea",
        "AXApplication",
        "AXScrollArea",
        "AXTabGroup"
    ]

    /// Fast AX hit-test used by `CGEventTap` to distinguish interactive titlebar controls
    /// from native traffic lights and empty OS titlebar drag regions.
    public static func classifyTitlebarHit(atAXPoint axPoint: CGPoint, pid: pid_t) -> TitlebarHitResult {
        let appEl = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appEl, 0.04)

        var hitElement: AXUIElement?
        let err = AXUIElementCopyElementAtPosition(appEl, Float(axPoint.x), Float(axPoint.y), &hitElement)
        guard err == .success, let startEl = hitElement else {
            return .unknown
        }

        var current: AXUIElement? = startEl
        for _ in 0..<4 {
            guard let el = current else { break }
            AXUIElementSetMessagingTimeout(el, 0.03)
            let role = stringAttribute(el, kAXRoleAttribute)
            if role == (kAXMenuBarRole as String) {
                return .unknown
            }
            let subrole = stringAttribute(el, kAXSubroleAttribute)
            var actionsRef: CFArray?
            AXUIElementCopyActionNames(el, &actionsRef)
            let actions = (actionsRef as? [String]) ?? []

            switch WindowChromeGeometry.classifyTitlebarElement(role: role, subrole: subrole, actions: actions) {
            case .trafficLight:
                return .trafficLight
            case .interactiveControl:
                return .interactiveControl
            case .dragSurface:
                if let role, titlebarAncestorStopRoles.contains(role) {
                    return .nativeTitlebarDragSurface
                }
            }

            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
               let parentRef,
               CFGetTypeID(parentRef) == AXUIElementGetTypeID() {
                current = (parentRef as! AXUIElement)
            } else {
                current = nil
            }
        }

        return .nativeTitlebarDragSurface
    }

    // MARK: - Traffic Light Inspection & Titlebar Color Sampling

    public static func trafficLightUnionAXRect(for windowElement: AXUIElement) -> CGRect? {
        AXUIElementSetMessagingTimeout(windowElement, 0.15)
        let attrs = [
            kAXCloseButtonAttribute as String,
            kAXMinimizeButtonAttribute as String,
            "AXFullScreenButton",
            kAXZoomButtonAttribute as String
        ]

        var unionRect = CGRect.null
        for attr in attrs {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(windowElement, attr as CFString, &ref) == .success,
                  let ref,
                  CFGetTypeID(ref) == AXUIElementGetTypeID()
            else {
                continue
            }
            let btnEl = ref as! AXUIElement
            AXUIElementSetMessagingTimeout(btnEl, 0.1)
            if let r = rectAttribute(btnEl), r.width >= 6, r.height >= 6 {
                unionRect = unionRect.isNull ? r : unionRect.union(r)
            }
        }

        guard !unionRect.isNull,
              unionRect.width >= 32,
              unionRect.width <= 110,
              unionRect.height >= 10,
              unionRect.height <= 36
        else {
            return nil
        }

        return unionRect.insetBy(dx: -4, dy: -3)
    }

    public static func sampleTitlebarColor(
        windowID: CGWindowID,
        windowAXFrame: CGRect,
        buttonUnionAXRect: CGRect
    ) async -> NSColor? {
        guard windowID != 0,
              windowAXFrame.width > 40,
              windowAXFrame.height > 40,
              ProcessInfo.processInfo.systemUptime >= screenCaptureCooldownUntil
        else {
            return nil
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            config.width = max(120, Int(windowAXFrame.width.rounded()))
            config.height = max(80, Int(windowAXFrame.height.rounded()))
            config.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if !screenCaptureLiveVerified {
                screenCaptureLiveVerified = true
                ShellLogger.log("ScreenCaptureKit live window snapshot verified (\(cgImage.width)x\(cgImage.height))")
            }
            didLogScreenCaptureError = false
            guard let provider = cgImage.dataProvider,
                  let data = provider.data,
                  let ptr = CFDataGetBytePtr(data)
            else {
                return nil
            }

            let imgW = cgImage.width
            let imgH = cgImage.height
            let scaleX = CGFloat(imgW) / windowAXFrame.width
            let scaleY = CGFloat(imgH) / windowAXFrame.height

            let buttonRightLocal = buttonUnionAXRect.maxX - windowAXFrame.minX
            let buttonLeftLocal = buttonUnionAXRect.minX - windowAXFrame.minX
            let buttonTopLocal = buttonUnionAXRect.minY - windowAXFrame.minY
            let buttonMidYLocal = buttonUnionAXRect.midY - windowAXFrame.minY

            let sampleXPt = min(windowAXFrame.width - 4, buttonRightLocal + 8)
            let sampleYPt = max(2, min(windowAXFrame.height - 4, buttonMidYLocal))
            let fallbackXPt = max(2, min(windowAXFrame.width - 4, buttonLeftLocal + 4))
            let fallbackYPt = max(2, buttonTopLocal - 4)

            let candidates = [
                (Int((sampleXPt * scaleX).rounded()), Int((sampleYPt * scaleY).rounded())),
                (Int((fallbackXPt * scaleX).rounded()), Int((fallbackYPt * scaleY).rounded()))
            ]

            let bytesPerPixel = max(4, cgImage.bitsPerPixel / 8)
            let bytesPerRow = cgImage.bytesPerRow
            let isLittleEndian = cgImage.bitmapInfo.contains(.byteOrder32Little)

            for (rawX, rawY) in candidates {
                let px = max(0, min(imgW - 1, rawX))
                let py = max(0, min(imgH - 1, rawY))
                let offset = py * bytesPerRow + px * bytesPerPixel
                guard offset + 3 < CFDataGetLength(data) else { continue }

                let b0 = CGFloat(ptr[offset]) / 255.0
                let b1 = CGFloat(ptr[offset + 1]) / 255.0
                let b2 = CGFloat(ptr[offset + 2]) / 255.0

                if isLittleEndian {
                    return NSColor(srgbRed: b2, green: b1, blue: b0, alpha: 1.0)
                } else {
                    return NSColor(srgbRed: b0, green: b1, blue: b2, alpha: 1.0)
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Live Window Thumbnail & Snapshot (ScreenCaptureKit)

    private static var cachedCaptureFilters: [CGWindowID: (filter: SCContentFilter, frame: CGRect, cachedAt: TimeInterval)] = [:]
    private static var screenCaptureCooldownUntil: TimeInterval = 0
    private static var didLogScreenCaptureError = false
    public static var screenCaptureLiveVerified: Bool = false

    public static func invalidateCaptureFilter(for windowID: CGWindowID) {
        cachedCaptureFilters.removeValue(forKey: windowID)
    }

    public static func captureWindowSnapshot(windowID: CGWindowID, windowAXFrame: CGRect) async -> NSImage? {
        guard windowID != 0,
              windowAXFrame.width >= 100,
              windowAXFrame.height >= 100,
              ProcessInfo.processInfo.systemUptime >= screenCaptureCooldownUntil
        else {
            return nil
        }

        let scale = min(2.0, NSScreen.main?.backingScaleFactor ?? 2.0)
        let config = SCStreamConfiguration()
        config.width = max(200, Int((windowAXFrame.width * scale).rounded()))
        config.height = max(120, Int((windowAXFrame.height * scale).rounded()))
        config.showsCursor = false
        config.scalesToFit = true
        config.captureResolution = .best

        let now = ProcessInfo.processInfo.systemUptime
        var usedCached = false
        var filter: SCContentFilter?

        if let cached = cachedCaptureFilters[windowID],
           abs(cached.frame.width - windowAXFrame.width) < 2,
           abs(cached.frame.height - windowAXFrame.height) < 2,
           (now - cached.cachedAt) < 15.0 {
            filter = cached.filter
            usedCached = true
        }

        do {
            if filter == nil {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                    return nil
                }
                let created = SCContentFilter(desktopIndependentWindow: scWindow)
                cachedCaptureFilters[windowID] = (created, windowAXFrame, ProcessInfo.processInfo.systemUptime)
                filter = created
            }

            guard let activeFilter = filter else { return nil }
            do {
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: activeFilter, configuration: config)
                if !screenCaptureLiveVerified {
                    screenCaptureLiveVerified = true
                    ShellLogger.log("ScreenCaptureKit live window snapshot verified (\(cgImage.width)x\(cgImage.height))")
                }
                didLogScreenCaptureError = false
                return NSImage(cgImage: cgImage, size: windowAXFrame.size)
            } catch {
                if !usedCached {
                    screenCaptureCooldownUntil = ProcessInfo.processInfo.systemUptime + 4.0
                    if !didLogScreenCaptureError {
                        didLogScreenCaptureError = true
                        ShellLogger.log("ScreenCaptureKit snapshot error: \(error.localizedDescription)")
                    }
                    return nil
                }
                cachedCaptureFilters.removeValue(forKey: windowID)
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                    return nil
                }
                let freshFilter = SCContentFilter(desktopIndependentWindow: scWindow)
                cachedCaptureFilters[windowID] = (freshFilter, windowAXFrame, ProcessInfo.processInfo.systemUptime)
                let cgImage = try await SCScreenshotManager.captureImage(contentFilter: freshFilter, configuration: config)
                if !screenCaptureLiveVerified {
                    screenCaptureLiveVerified = true
                    ShellLogger.log("ScreenCaptureKit live window snapshot verified (\(cgImage.width)x\(cgImage.height))")
                }
                didLogScreenCaptureError = false
                return NSImage(cgImage: cgImage, size: windowAXFrame.size)
            }
        } catch {
            screenCaptureCooldownUntil = ProcessInfo.processInfo.systemUptime + 4.0
            if !didLogScreenCaptureError {
                didLogScreenCaptureError = true
                ShellLogger.log("ScreenCaptureKit snapshot error: \(error.localizedDescription)")
            }
            return nil
        }
    }

    public static func captureWindowThumbnail(windowID: CGWindowID) async -> NSImage? {
        guard windowID != 0,
              ProcessInfo.processInfo.systemUptime >= screenCaptureCooldownUntil
        else {
            return nil
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
                return nil
            }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = min(1.0, 260.0 / max(1.0, scWindow.frame.width))
            config.width = max(120, Int(scWindow.frame.width * scale))
            config.height = max(80, Int(scWindow.frame.height * scale))
            config.showsCursor = false
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            if !screenCaptureLiveVerified {
                screenCaptureLiveVerified = true
                ShellLogger.log("ScreenCaptureKit live window snapshot verified (\(cgImage.width)x\(cgImage.height))")
            }
            didLogScreenCaptureError = false
            return NSImage(cgImage: cgImage, size: NSSize(width: config.width, height: config.height))
        } catch {
            screenCaptureCooldownUntil = ProcessInfo.processInfo.systemUptime + 4.0
            if !didLogScreenCaptureError {
                didLogScreenCaptureError = true
                ShellLogger.log("ScreenCaptureKit snapshot error: \(error.localizedDescription)")
            }
            return nil
        }
    }

    // MARK: - Attribute Helpers

    private static func childElements(of element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let list = ref as? [AXUIElement]
        else {
            return []
        }
        return list
    }

    private static func stringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ attr: String) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success else {
            return nil
        }
        return ref as? Bool
    }

    private static func rectAttribute(_ element: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let posRef, let sizeRef,
              CFGetTypeID(posRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else {
            return nil
        }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }
}

private extension CGRect {
    var area: CGFloat {
        isNull || isEmpty ? 0 : width * height
    }
}
