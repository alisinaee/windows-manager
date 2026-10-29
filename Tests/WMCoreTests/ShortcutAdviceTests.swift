import Foundation
import Testing
@testable import WMCore

@Suite struct ShortcutAdviceTests {
    @Test func suggestionsCoverDigitsOneToNineInBothSets() {
        #expect(ShortcutAdvice.hyperSuggestions.count == 9)
        #expect(ShortcutAdvice.lightSuggestions.count == 9)
        #expect(Set(ShortcutAdvice.hyperSuggestions.map(\.keyCode)).count == 9)
        #expect(ShortcutAdvice.hyperSuggestions.allSatisfy { $0.modifiers == [.control, .option, .command] })
        #expect(ShortcutAdvice.lightSuggestions.allSatisfy { $0.modifiers == [.control, .option] })
    }

    @Test func digitMapping() {
        #expect(ShortcutAdvice.digit(forKeyCode: 18) == 1)
        #expect(ShortcutAdvice.digit(forKeyCode: 25) == 9)
        #expect(ShortcutAdvice.digit(forKeyCode: 0) == nil)
    }

    @Test func suggestionsAreNeverSystemShortcuts() {
        for combo in ShortcutAdvice.hyperSuggestions + ShortcutAdvice.lightSuggestions {
            #expect(ShortcutAdvice.warning(for: combo) == nil)
        }
    }

    @Test func wellKnownSystemShortcutsWarn() {
        #expect(ShortcutAdvice.warning(for: ShortcutCombo(keyCode: 49, modifiers: [.command])) != nil)
        #expect(ShortcutAdvice.warning(for: ShortcutCombo(keyCode: 48, modifiers: [.command])) != nil)
        #expect(ShortcutAdvice.warning(for: ShortcutCombo(keyCode: 12, modifiers: [.command])) != nil)
        #expect(ShortcutAdvice.warning(for: ShortcutCombo(keyCode: 21, modifiers: [.command, .shift])) != nil)
        #expect(ShortcutAdvice.warning(for: ShortcutCombo(keyCode: 53, modifiers: [.command, .option])) != nil)
        #expect(ShortcutAdvice.warning(for: ShortcutCombo(keyCode: 123, modifiers: [.control])) != nil)
    }

    @Test func extraModifiersMakeItADifferentShortcut() {
        #expect(ShortcutAdvice.warning(for: ShortcutCombo(keyCode: 49, modifiers: [.command, .option])) == nil)
        #expect(ShortcutAdvice.warning(for: ShortcutCombo(keyCode: 12, modifiers: [.command, .shift])) == nil)
    }

    @Test func conflictNamesTheOwnerButIgnoresTheProfilesOwnCombo() {
        let combo = ShortcutAdvice.hyperSuggestions[0]
        let other = ShortcutAdvice.hyperSuggestions[1]
        let taken = [combo: "Work", other: "Zone 2"]
        #expect(ShortcutAdvice.conflict(for: combo, taken: taken, ownCombo: nil) == "Already used by Work")
        #expect(ShortcutAdvice.conflict(for: combo, taken: taken, ownCombo: combo) == nil)
        #expect(ShortcutAdvice.conflict(for: ShortcutAdvice.hyperSuggestions[2], taken: taken, ownCombo: nil) == nil)
    }
}

@Suite struct ShortcutSuggestionTests {
    @Test func firstFreeIsTheFirstSafeComboWhenNothingIsTaken() {
        #expect(ShortcutAdvice.firstFreeSuggestion(taken: [:], ownCombo: nil) == ShortcutAdvice.hyperSuggestions[0])
    }

    @Test func takenCombosAreSkipped() {
        let hyper = ShortcutAdvice.hyperSuggestions
        let taken = [hyper[0]: "profile A", hyper[1]: "Snap zone 1"]
        #expect(ShortcutAdvice.firstFreeSuggestion(taken: taken, ownCombo: nil) == hyper[2])
    }

    @Test func fallsBackToLighterSetThenNil() {
        var taken: [ShortcutCombo: String] = [:]
        for c in ShortcutAdvice.hyperSuggestions { taken[c] = "x" }
        #expect(ShortcutAdvice.firstFreeSuggestion(taken: taken, ownCombo: nil) == ShortcutAdvice.lightSuggestions[0])
        for c in ShortcutAdvice.lightSuggestions { taken[c] = "x" }
        #expect(ShortcutAdvice.firstFreeSuggestion(taken: taken, ownCombo: nil) == nil)
    }

    @Test func ownComboCountsAsFree() {
        let own = ShortcutAdvice.hyperSuggestions[0]
        #expect(ShortcutAdvice.firstFreeSuggestion(taken: [own: "this"], ownCombo: own) == own)
    }
}
