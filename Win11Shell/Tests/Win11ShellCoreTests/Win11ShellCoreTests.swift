import CoreGraphics
import Foundation
import Testing
@testable import Win11ShellCore

@Suite("Win11ShellCore Tests")
struct Win11ShellCoreTests {
    @Test("Config round-trip serialization")
    func configRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Win11ShellConfigTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("config.json")
        let store = Win11ConfigStore(configURL: url)
        var config = Win11Config.default
        config.taskbarAlignment = .left
        config.taskbarAutoHide = true
        config.showWidgetsButton = false

        try store.save(config)
        let loaded = store.load()
        #expect(loaded == config)
    }

    @Test("Karabiner profile merge preserves existing profiles, places built-in swap in devices, and avoids Home/End collision")
    func karabinerMergeAndRules() throws {
        let existingJSON = """
        {
          "global": { "check_for_updates_on_startup": false },
          "profiles": [
            { "name": "Default profile", "selected": true, "complex_modifications": { "rules": [] } }
          ]
        }
        """.data(using: .utf8)!

        let cliDevices = """
        [
          {
            "device_identifiers": { "is_keyboard": true, "product_id": 0, "vendor_id": 0 },
            "is_built_in_keyboard": true,
            "is_keyboard": true
          },
          {
            "device_identifiers": { "is_keyboard": true, "product_id": 1234, "vendor_id": 5678 },
            "is_built_in_keyboard": false,
            "is_keyboard": true
          }
        ]
        """.data(using: .utf8)!

        let builtIns = KarabinerConfigGenerator.parseConnectedBuiltInDevices(from: cliDevices)
        #expect(builtIns == [KarabinerDeviceIdentifier(vendorID: 0, productID: 0, isKeyboard: true)])

        let merged = try KarabinerConfigGenerator.mergeProfile(
            into: existingJSON,
            builtInDevices: builtIns,
            config: .default
        )

        let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let profiles = try #require(root["profiles"] as? [[String: Any]])
        #expect(profiles.count == 2)

        let defaultProfile = try #require(profiles.first { ($0["name"] as? String) == "Default profile" })
        #expect((defaultProfile["selected"] as? Bool) == false)

        let win11Profile = try #require(profiles.first { ($0["name"] as? String) == "Win11" })
        #expect((win11Profile["selected"] as? Bool) == true)

        // Built-in device swap MUST be in devices[].simple_modifications
        let devices = try #require(win11Profile["devices"] as? [[String: Any]])
        #expect(devices.count == 1)
        let simpleMods = try #require(devices[0]["simple_modifications"] as? [[String: Any]])
        #expect(simpleMods.count == 4)

        let complex = try #require(win11Profile["complex_modifications"] as? [String: Any])
        let rules = try #require(complex["rules"] as? [[String: Any]])
        #expect(rules.count == 4)

        // Verify Home/End do NOT collide with Win+Left/Right (Win+Left maps to Ctrl+Opt+Cmd+Left)
        let globalRules = try #require(rules[1]["manipulators"] as? [[String: Any]])
        let winLeft = globalRules.first {
            let from = $0["from"] as? [String: Any]
            return (from?["key_code"] as? String) == "left_arrow"
                && (from?["modifiers"] as? [String: Any])?["mandatory"] as? [String] == ["command"]
        }
        let winLeftTo = try #require((winLeft?["to"] as? [[String: Any]])?.first)
        #expect((winLeftTo["modifiers"] as? [String]) == ["control", "option", "command"])

        // Verify Terminal apps are excluded in rule 4 and Ctrl+Tab is NOT remapped
        let nonTermRule = rules[3]
        let nonTermManipulators = try #require(nonTermRule["manipulators"] as? [[String: Any]])
        let firstCond = try #require((nonTermManipulators[0]["conditions"] as? [[String: Any]])?.first)
        #expect((firstCond["type"] as? String) == "frontmost_application_unless")
        let hasCtrlTab = nonTermManipulators.contains {
            let from = $0["from"] as? [String: Any]
            return (from?["key_code"] as? String) == "tab"
        }
        #expect(!hasCtrlTab)

        // Verify FileExplorer rule 3 targets com.hackedple.fileexplorer
        let feRule = rules[2]
        let feManipulators = try #require(feRule["manipulators"] as? [[String: Any]])
        let feCond = try #require((feManipulators[0]["conditions"] as? [[String: Any]])?.first)
        #expect((feCond["type"] as? String) == "frontmost_application_if")
        #expect((feCond["bundle_identifiers"] as? [String]) == ["^com\\.hackedple\\.fileexplorer$"])

        // Verify removal restores selection to Default profile
        let removed = try KarabinerConfigGenerator.removeWin11Profile(from: merged)
        let removedRoot = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
        let remaining = try #require(removedRoot["profiles"] as? [[String: Any]])
        #expect(remaining.count == 1)
        #expect((remaining[0]["selected"] as? Bool) == true)
    }

    @Test("Rectangle and AltTab defaults avoid Cmd+Arrow collision and reserve 28pt/48pt gaps")
    func externalToolConfigs() {
        let rect = ExternalToolConfigGenerator.rectangleCommands()
        let topGap = rect.first { $0.key == "screenEdgeGapTop" }
        let bottomGap = rect.first { $0.key == "screenEdgeGapBottom" }
        let leftHalf = rect.first { $0.key == "leftHalf" }
        #expect(topGap?.arguments == ["-int", "28"])
        #expect(bottomGap?.arguments == ["-int", "48"])
        #expect(leftHalf?.arguments.contains("1835008") == true)

        let altTab = ExternalToolConfigGenerator.altTabCommands()
        #expect(altTab.contains { $0.key == "holdShortcut" && $0.arguments == ["-string", "⌥"] })
        #expect(altTab.contains { $0.key == "nextWindowShortcut" && $0.arguments == ["-string", "⇥"] })
    }

    @Test("AX <-> Cocoa geometry conversion, docked bar placement, and maximized frame")
    func geometryCalculations() {
        let primaryHeight: CGFloat = 982
        let screenFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleFrame = CGRect(x: 0, y: 0, width: 1512, height: 944) // 38pt notch safe area at top

        let axWindow = CGRect(x: 100, y: 120, width: 800, height: 600)
        let cocoaWindow = WindowChromeGeometry.axRectToCocoa(axWindow, primaryScreenHeight: primaryHeight)
        #expect(cocoaWindow == CGRect(x: 100, y: 262, width: 800, height: 600))
        #expect(WindowChromeGeometry.cocoaRectToAX(cocoaWindow, primaryScreenHeight: primaryHeight) == axWindow)

        let barFrame = WindowChromeGeometry.dockedBarFrame(
            forAXWindowFrame: axWindow,
            primaryScreenHeight: primaryHeight,
            screenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            barHeight: 28,
            taskbarHeight: 48
        )
        #expect(barFrame == CGRect(x: 100, y: 862, width: 800, height: 28))

        // Fullscreen window hides bar
        let fullscreenAX = CGRect(x: 0, y: 0, width: 1512, height: 982)
        #expect(
            WindowChromeGeometry.dockedBarFrame(
                forAXWindowFrame: fullscreenAX,
                primaryScreenHeight: primaryHeight,
                screenFrameCocoa: screenFrame,
                visibleFrameCocoa: visibleFrame,
                barHeight: 28,
                taskbarHeight: 48
            ) == nil
        )

        // Maximized window reserves 28pt bar under visibleFrame top and 48pt taskbar at bottom
        let maxAX = WindowChromeGeometry.maximizedAXFrame(
            forScreenFrameCocoa: screenFrame,
            visibleFrameCocoa: visibleFrame,
            primaryScreenHeight: primaryHeight,
            barHeight: 28,
            taskbarHeight: 48
        )
        let maxCocoa = WindowChromeGeometry.axRectToCocoa(maxAX, primaryScreenHeight: primaryHeight)
        #expect(maxCocoa.minY == 48)
        #expect(maxCocoa.maxY == CGFloat(944 - 28))
        #expect(maxCocoa.width == 1512)
    }

    @Test("WindowClosePolicy quits on last window except keep-alive apps")
    func closePolicy() {
        let keepAlive: Set<String> = ["com.microsoft.Outlook", "com.apple.finder"]
        #expect(WindowClosePolicy.decide(bundleID: "com.google.Chrome", standardWindowCount: 2, keepAliveBundleIDs: keepAlive) == .closeWindow)
        #expect(WindowClosePolicy.decide(bundleID: "com.google.Chrome", standardWindowCount: 1, keepAliveBundleIDs: keepAlive) == .quitApp)
        #expect(WindowClosePolicy.decide(bundleID: "com.microsoft.Outlook", standardWindowCount: 1, keepAliveBundleIDs: keepAlive) == .hideApp)
    }

    @Test("AppCatalog hides Finder and ranks prefix matches first")
    func appCatalogSearch() {
        let sample = [
            InstalledAppEntry(bundleID: "com.apple.finder", name: "Finder", url: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")),
            InstalledAppEntry(bundleID: "com.apple.Safari", name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app")),
            InstalledAppEntry(bundleID: "com.hackedple.fileexplorer", name: "File Explorer", url: URL(fileURLWithPath: "/Applications/FileExplorer.app")),
            InstalledAppEntry(bundleID: "com.foo.myfiles", name: "My Files", url: URL(fileURLWithPath: "/Applications/MyFiles.app"))
        ]

        let all = AppCatalog.filterApps(sample, query: "", hideFinder: true)
        #expect(!all.contains { $0.bundleID == "com.apple.finder" })
        #expect(all.count == 3)

        let queryMatches = AppCatalog.filterApps(sample, query: "file", hideFinder: true)
        #expect(queryMatches.map(\.name) == ["File Explorer", "My Files"])
    }
}
