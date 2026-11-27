import CoreGraphics
import Foundation
import Testing
@testable import Win11ShellCore

@Suite("Keyboard Engine Tests")
struct KeyboardEngineTests {
    private static let ctrl = CGEventFlags.maskControl.rawValue
    private static let alt = CGEventFlags.maskAlternate.rawValue
    private static let win = CGEventFlags.maskCommand.rawValue
    private static let shift = CGEventFlags.maskShift.rawValue

    // MARK: - HIDMappingGenerator

    @Test("HIDMappingGenerator generates valid built-in swap, reset, and matching JSON")
    func hidMappingJSON() throws {
        #expect(HIDMappingGenerator.resetPropertyJSON() == #"{"UserKeyMapping":[]}"#)
        #expect(HIDMappingGenerator.builtInMatchingJSON() == #"{"Built-In":true}"#)

        let resetObj = try #require(
            JSONSerialization.jsonObject(with: Data(HIDMappingGenerator.resetPropertyJSON().utf8)) as? [String: Any]
        )
        let resetArray = try #require(resetObj["UserKeyMapping"] as? [Any])
        #expect(resetArray.isEmpty)

        let matchObj = try #require(
            JSONSerialization.jsonObject(with: Data(HIDMappingGenerator.builtInMatchingJSON().utf8)) as? [String: Any]
        )
        #expect((matchObj["Built-In"] as? Bool) == true)

        let swapJSON = HIDMappingGenerator.builtInSwapPropertyJSON()
        let swapObj = try #require(
            JSONSerialization.jsonObject(with: Data(swapJSON.utf8)) as? [String: Any]
        )
        let mappings = try #require(swapObj["UserKeyMapping"] as? [[String: UInt64]])
        #expect(mappings.count == 4)

        let leftOpt: UInt64 = 0x7000000E2
        let leftCmd: UInt64 = 0x7000000E3
        let rightOpt: UInt64 = 0x7000000E6
        let rightCmd: UInt64 = 0x7000000E7

        #expect(mappings.contains(["HIDKeyboardModifierMappingSrc": leftOpt, "HIDKeyboardModifierMappingDst": leftCmd]))
        #expect(mappings.contains(["HIDKeyboardModifierMappingSrc": leftCmd, "HIDKeyboardModifierMappingDst": leftOpt]))
        #expect(mappings.contains(["HIDKeyboardModifierMappingSrc": rightOpt, "HIDKeyboardModifierMappingDst": rightCmd]))
        #expect(mappings.contains(["HIDKeyboardModifierMappingSrc": rightCmd, "HIDKeyboardModifierMappingDst": rightOpt]))
    }

    // MARK: - Global Win11 Hotkeys

    @Test("Global Windows 11 shortcuts emit expected ShellCommandActions and system remaps")
    func globalShortcuts() {
        let cfg = Win11Config.default
        let app = "com.google.Chrome"

        #expect(KeyboardRemapper.decide(keyCode: 118, flagsRaw: Self.alt, frontmostBundleID: app, config: cfg) == .command(.closeOrQuitFrontWindow))
        #expect(KeyboardRemapper.decide(keyCode: 14, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.openFileExplorer))
        #expect(KeyboardRemapper.decide(keyCode: 2, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.toggleShowDesktop))
        #expect(KeyboardRemapper.decide(keyCode: 1, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.openStartSearch))
        #expect(KeyboardRemapper.decide(keyCode: 0, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.toggleQuickSettings))
        #expect(KeyboardRemapper.decide(keyCode: 45, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.toggleCalendarFlyout))
        #expect(KeyboardRemapper.decide(keyCode: 34, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.openSystemSettings))
        #expect(KeyboardRemapper.decide(keyCode: 48, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.openTaskView))
        #expect(KeyboardRemapper.decide(keyCode: 1, flagsRaw: Self.win | Self.shift, frontmostBundleID: app, config: cfg) == .command(.snippingTool))
        #expect(KeyboardRemapper.decide(keyCode: 53, flagsRaw: Self.ctrl | Self.shift, frontmostBundleID: app, config: cfg) == .command(.openTaskManager))

        // Win+L -> Ctrl+Cmd+Q, Win+. -> Ctrl+Cmd+Space
        #expect(
            KeyboardRemapper.decide(keyCode: 37, flagsRaw: Self.win, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 12, flagsRaw: Self.ctrl | Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 47, flagsRaw: Self.win, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 49, flagsRaw: Self.ctrl | Self.win))
        )

        // Win+Ctrl+Left/Right -> Virtual Desktops, Win+Arrows -> Snap
        #expect(KeyboardRemapper.decide(keyCode: 123, flagsRaw: Self.win | Self.ctrl, frontmostBundleID: app, config: cfg) == .command(.switchDesktopLeft))
        #expect(KeyboardRemapper.decide(keyCode: 124, flagsRaw: Self.win | Self.ctrl, frontmostBundleID: app, config: cfg) == .command(.switchDesktopRight))
        #expect(KeyboardRemapper.decide(keyCode: 123, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.snapLeft))
        #expect(KeyboardRemapper.decide(keyCode: 124, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.snapRight))
        #expect(KeyboardRemapper.decide(keyCode: 126, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.snapMaximize))
        #expect(KeyboardRemapper.decide(keyCode: 125, flagsRaw: Self.win, frontmostBundleID: app, config: cfg) == .command(.snapDownOrMinimize))

        // Alt+Tab / Alt+Shift+Tab
        #expect(KeyboardRemapper.decide(keyCode: 48, flagsRaw: Self.alt, frontmostBundleID: app, config: cfg) == .command(.altTabNext(reverse: false)))
        #expect(KeyboardRemapper.decide(keyCode: 48, flagsRaw: Self.alt | Self.shift, frontmostBundleID: app, config: cfg) == .command(.altTabNext(reverse: true)))
    }

    // MARK: - FileExplorer

    @Test("FileExplorer applies Windows Explorer shortcuts")
    func fileExplorerShortcuts() {
        let cfg = Win11Config.default
        let fe = cfg.fileExplorerBundleID

        #expect(
            KeyboardRemapper.decide(keyCode: 117, flagsRaw: 0, frontmostBundleID: fe, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 51, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 126, flagsRaw: Self.alt, frontmostBundleID: fe, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 126, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 36, flagsRaw: Self.alt, frontmostBundleID: fe, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 34, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 2, flagsRaw: Self.alt, frontmostBundleID: fe, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 37, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 4, flagsRaw: Self.ctrl, frontmostBundleID: fe, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 47, flagsRaw: Self.win | Self.shift))
        )

        // Ctrl+H in Chrome maps to Cmd+H, not Cmd+Shift+.
        #expect(
            KeyboardRemapper.decide(keyCode: 4, flagsRaw: Self.ctrl, frontmostBundleID: "com.google.Chrome", config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 4, flagsRaw: Self.win))
        )
    }

    // MARK: - Non-Terminal Editing & Ctrl->Cmd

    @Test("Non-terminal apps remap Windows editing keys, F5, Alt+Arrows, and Ctrl+<key> without touching Ctrl+Tab")
    func nonTerminalEditing() {
        let cfg = Win11Config.default
        let app = "com.apple.TextEdit"
        let noiseFlags = CGEventFlags.maskNumericPad.rawValue | CGEventFlags.maskSecondaryFn.rawValue

        // Ctrl+Y -> Cmd+Shift+Z
        #expect(
            KeyboardRemapper.decide(keyCode: 16, flagsRaw: Self.ctrl, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 6, flagsRaw: Self.win | Self.shift))
        )

        // Ctrl+Left/Right (+Shift) -> Opt+Left/Right (+Shift)
        #expect(
            KeyboardRemapper.decide(keyCode: 123, flagsRaw: Self.ctrl | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 123, flagsRaw: Self.alt))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 124, flagsRaw: Self.ctrl | Self.shift | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 124, flagsRaw: Self.alt | Self.shift))
        )

        // Ctrl+Backspace/Delete -> Opt+Backspace/Delete
        #expect(
            KeyboardRemapper.decide(keyCode: 51, flagsRaw: Self.ctrl, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 51, flagsRaw: Self.alt))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 117, flagsRaw: Self.ctrl | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 117, flagsRaw: Self.alt))
        )

        // Home/End (+Shift) -> Cmd+Left/Right (+Shift)
        #expect(
            KeyboardRemapper.decide(keyCode: 115, flagsRaw: noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 123, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 119, flagsRaw: Self.shift | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 124, flagsRaw: Self.win | Self.shift))
        )

        // Ctrl+Home/End (+Shift) -> Cmd+Up/Down (+Shift)
        #expect(
            KeyboardRemapper.decide(keyCode: 115, flagsRaw: Self.ctrl | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 126, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 119, flagsRaw: Self.ctrl | Self.shift | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 125, flagsRaw: Self.win | Self.shift))
        )

        // Alt+Left/Right -> Cmd+[/]
        #expect(
            KeyboardRemapper.decide(keyCode: 123, flagsRaw: Self.alt | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 33, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 124, flagsRaw: Self.alt | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 30, flagsRaw: Self.win))
        )

        // F5 / Ctrl+F5 -> Cmd+R / Cmd+Shift+R
        #expect(
            KeyboardRemapper.decide(keyCode: 96, flagsRaw: noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 15, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 96, flagsRaw: Self.ctrl | noiseFlags, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 15, flagsRaw: Self.win | Self.shift))
        )

        // Standard Ctrl+<key> (+Shift/Opt) -> Cmd+<key>
        #expect(
            KeyboardRemapper.decide(keyCode: 8, flagsRaw: Self.ctrl, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 8, flagsRaw: Self.win))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 17, flagsRaw: Self.ctrl | Self.shift, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 17, flagsRaw: Self.win | Self.shift))
        )
        #expect(
            KeyboardRemapper.decide(keyCode: 34, flagsRaw: Self.ctrl | Self.alt, frontmostBundleID: app, config: cfg)
                == .remap(RemappedKeyEvent(keyCode: 34, flagsRaw: Self.win | Self.alt))
        )

        // Ctrl+Tab and Ctrl+Shift+Tab pass through untouched
        #expect(KeyboardRemapper.decide(keyCode: 48, flagsRaw: Self.ctrl, frontmostBundleID: app, config: cfg) == .passthrough)
        #expect(KeyboardRemapper.decide(keyCode: 48, flagsRaw: Self.ctrl | Self.shift, frontmostBundleID: app, config: cfg) == .passthrough)

        // Win+Ctrl+<key> is not treated as Ctrl+<key> -> Cmd+<key>
        #expect(KeyboardRemapper.decide(keyCode: 8, flagsRaw: Self.win | Self.ctrl, frontmostBundleID: app, config: cfg) == .passthrough)
    }

    // MARK: - Terminals

    @Test("Terminal apps leave Ctrl untouched and allow Win+C/V passthrough while keeping global shortcuts")
    func terminalBehavior() {
        let cfg = Win11Config.default

        for term in ["com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2"] {
            #expect(KeyboardRemapper.decide(keyCode: 8, flagsRaw: Self.ctrl, frontmostBundleID: term, config: cfg) == .passthrough)
            #expect(KeyboardRemapper.decide(keyCode: 16, flagsRaw: Self.ctrl, frontmostBundleID: term, config: cfg) == .passthrough)
            #expect(KeyboardRemapper.decide(keyCode: 123, flagsRaw: Self.ctrl, frontmostBundleID: term, config: cfg) == .passthrough)
            #expect(KeyboardRemapper.decide(keyCode: 115, flagsRaw: 0, frontmostBundleID: term, config: cfg) == .passthrough)
            #expect(KeyboardRemapper.decide(keyCode: 96, flagsRaw: 0, frontmostBundleID: term, config: cfg) == .passthrough)

            // Win+C / Win+V pass through as Cmd+C / Cmd+V
            #expect(KeyboardRemapper.decide(keyCode: 8, flagsRaw: Self.win, frontmostBundleID: term, config: cfg) == .passthrough)
            #expect(KeyboardRemapper.decide(keyCode: 9, flagsRaw: Self.win, frontmostBundleID: term, config: cfg) == .passthrough)

            // Global Win11 shortcuts still apply inside terminals
            #expect(KeyboardRemapper.decide(keyCode: 14, flagsRaw: Self.win, frontmostBundleID: term, config: cfg) == .command(.openFileExplorer))
            #expect(KeyboardRemapper.decide(keyCode: 48, flagsRaw: Self.alt, frontmostBundleID: term, config: cfg) == .command(.altTabNext(reverse: false)))
            #expect(KeyboardRemapper.decide(keyCode: 118, flagsRaw: Self.alt, frontmostBundleID: term, config: cfg) == .command(.closeOrQuitFrontWindow))
        }
    }
}
