import Testing
@testable import WMCore

@Suite struct ShortcutBridgeTests {
    /// Virtual key codes of 1...9 as KeyboardShortcuts stores them.
    static let digitCodes = [18, 19, 20, 21, 23, 22, 26, 28, 25]

    @Test func hyperShortcutMatchesCarbonBits() {
        // ctrl (4096) + opt (2048) + cmd (256) on the "1" key (18).
        #expect(ShortcutBridge.text(carbonKeyCode: 18, carbonModifiers: 6400) == "ctrl+opt+cmd+1")
        #expect(ShortcutBridge.carbon(text: "ctrl+opt+cmd+1")?.carbonKeyCode == 18)
        #expect(ShortcutBridge.carbon(text: "ctrl+opt+cmd+1")?.carbonModifiers == 6400)
    }

    @Test func everyDigitAndModifierSubsetRoundTrips() {
        let all: [ShortcutModifiers] = [.control, .option, .shift, .command]
        for (index, code) in Self.digitCodes.enumerated() {
            for mask in 1..<16 {
                var mods: ShortcutModifiers = []
                for bit in 0..<4 where mask & (1 << bit) != 0 { mods.insert(all[bit]) }
                let combo = ShortcutCombo(keyCode: code, modifiers: mods)
                let (keyCode, bits) = ShortcutBridge.carbon(of: combo)
                let text = ShortcutBridge.text(carbonKeyCode: keyCode, carbonModifiers: bits)
                #expect(text != nil)
                guard let text else { continue }
                #expect(text.hasSuffix("+\(index + 1)"))
                #expect(ShortcutBridge.carbon(text: text)?.carbonKeyCode == code)
                #expect(ShortcutBridge.carbon(text: text)?.carbonModifiers == bits)
                #expect(ShortcutBridge.combo(carbonKeyCode: code, carbonModifiers: bits) == combo)
            }
        }
    }

    @Test func textAcceptsSynonymsButWritesCanonicalForm() {
        #expect(ShortcutBridge.carbon(text: "control+alt+command+9")?.carbonModifiers == 6400)
        #expect(ShortcutBridge.text(carbonKeyCode: 25, carbonModifiers: 6400) == "ctrl+opt+cmd+9")
        #expect(ShortcutBridge.text(carbonKeyCode: 20, carbonModifiers: 512 | 256) == "shift+cmd+3")
    }

    @Test func keyOutsideDigitsIsNotRepresentable() {
        // "a" is key code 0; F2 is 120.
        #expect(ShortcutBridge.text(carbonKeyCode: 0, carbonModifiers: 6400) == nil)
        #expect(ShortcutBridge.text(carbonKeyCode: 120, carbonModifiers: 4096) == nil)
        #expect(ShortcutBridge.combo(carbonKeyCode: 0, carbonModifiers: 256) == nil)
    }

    @Test func shortcutWithoutModifiersIsNotRepresentable() {
        #expect(ShortcutBridge.text(carbonKeyCode: 18, carbonModifiers: 0) == nil)
    }

    @Test func extraModifierBitsAreNotRepresentable() {
        // 135168 is ctrl + F2 with the fn bit; 1 << 17 is the fn flag on its own.
        #expect(ShortcutBridge.text(carbonKeyCode: 18, carbonModifiers: 4096 | (1 << 17)) == nil)
        #expect(ShortcutBridge.modifiers(carbon: 135168) == nil)
        #expect(ShortcutBridge.modifiers(carbon: 4096 | 256) == [.control, .command])
    }

    @Test func invalidTextIsNotConverted() {
        for text in ["", "1", "ctrl+opt+cmd+0", "ctrl+opt+cmd+10", "ctrl+opt+cmd+a", "fn+1"] {
            #expect(ShortcutBridge.carbon(text: text) == nil, "\(text) should not convert")
        }
    }
}
