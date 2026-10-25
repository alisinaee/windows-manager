import Foundation
import Testing
@testable import WMCore

/// Tests for the pure parts of the Space switcher: step counting, symbolic hotkey parsing, method
/// availability and the synthetic swipe payload. Nothing here posts events or touches the system.
@Suite struct SpaceSwitcherTests {
    // MARK: steps

    @Test func stepsRight() {
        let result = SpaceSwitcher.steps(from: 0, to: 3)
        #expect(result.direction == .right)
        #expect(result.count == 3)
    }

    @Test func stepsLeft() {
        let result = SpaceSwitcher.steps(from: 4, to: 1)
        #expect(result.direction == .left)
        #expect(result.count == 3)
    }

    @Test func stepsOneNeighbourEachWay() {
        #expect(SpaceSwitcher.steps(from: 2, to: 3) == (.right, 1))
        #expect(SpaceSwitcher.steps(from: 2, to: 1) == (.left, 1))
    }

    @Test func stepsSamePositionIsNone() {
        let result = SpaceSwitcher.steps(from: 2, to: 2)
        #expect(result.direction == .none)
        #expect(result.count == 0)
    }

    // MARK: hotkey plist

    /// Shaped like the real `defaults read com.apple.symbolichotkeys AppleSymbolicHotKeys` of a Mac:
    /// 79 and 81 are on but carry no `value` (macOS then uses its default Ctrl+Arrow), 118 has a key
    /// combo and is on, 119 has one and is off, 120 is remapped to Ctrl+Option+3, 128 is on without any
    /// key, 164 has the "no key" marker 65535.
    private static let fixtureXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>79</key><dict><key>enabled</key><true/></dict>
          <key>80</key><dict><key>enabled</key><true/></dict>
          <key>81</key><dict><key>enabled</key><true/></dict>
          <key>82</key><dict><key>enabled</key><true/></dict>
          <key>118</key><dict><key>enabled</key><true/><key>value</key><dict>
            <key>parameters</key><array><integer>49</integer><integer>18</integer><integer>262144</integer></array>
            <key>type</key><string>standard</string></dict></dict>
          <key>119</key><dict><key>enabled</key><false/><key>value</key><dict>
            <key>parameters</key><array><integer>50</integer><integer>19</integer><integer>262144</integer></array>
            <key>type</key><string>standard</string></dict></dict>
          <key>120</key><dict><key>enabled</key><true/><key>value</key><dict>
            <key>parameters</key><array><integer>65535</integer><integer>20</integer><integer>786432</integer></array>
            <key>type</key><string>standard</string></dict></dict>
          <key>128</key><dict><key>enabled</key><true/></dict>
          <key>164</key><dict><key>enabled</key><false/><key>value</key><dict>
            <key>parameters</key><array><integer>65535</integer><integer>65535</integer><integer>0</integer></array>
            <key>type</key><string>standard</string></dict></dict>
        </dict>
        </plist>
        """

    private static func fixture() throws -> [String: Any] {
        let data = Data(fixtureXML.utf8)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(object as? [String: Any])
    }

    @Test func moveKeysWithoutValueGetTheDefaultCtrlArrow() throws {
        let keys = SymbolicHotKeys.parse(try Self.fixture())
        let left = try #require(keys[79])
        let right = try #require(keys[81])
        #expect(left.enabled && right.enabled)
        #expect(left.keyCode == 123 && right.keyCode == 124)
        #expect(left.modifiers == 0x840000 && right.modifiers == 0x840000)
        #expect(left.comboIsDefault && left.inPlist)
        #expect(left.isUsable && right.isUsable)
        #expect(left.combo == "Ctrl+Left")
        #expect(right.combo == "Ctrl+Right")
    }

    @Test func explicitComboIsReadFromParameters() throws {
        let keys = SymbolicHotKeys.parse(try Self.fixture())
        let one = try #require(keys[118])
        #expect(one.enabled)
        #expect(one.keyCode == 18)
        #expect(one.modifiers == 262144)
        #expect(!one.comboIsDefault)
        #expect(one.combo == "Ctrl+1")
        #expect(one.isUsable)
    }

    @Test func disabledEntryKeepsItsComboButIsNotUsable() throws {
        let keys = SymbolicHotKeys.parse(try Self.fixture())
        let two = try #require(keys[119])
        #expect(!two.enabled)
        #expect(two.keyCode == 19)
        #expect(!two.isUsable)
    }

    @Test func remappedComboNamesAllModifiers() throws {
        let keys = SymbolicHotKeys.parse(try Self.fixture())
        let three = try #require(keys[120])
        #expect(three.modifiers == 786432)           // Ctrl + Option
        #expect(three.combo == "Ctrl+Opt+3")
    }

    @Test func enabledEntryWithoutAnyKeyIsNotUsable() throws {
        let keys = SymbolicHotKeys.parse(try Self.fixture())
        let eleven = try #require(keys[128])          // Desktop 11 has no default key
        #expect(eleven.enabled)
        #expect(eleven.keyCode == nil)
        #expect(!eleven.isUsable)
        #expect(eleven.combo == "none")
    }

    @Test func noKeyMarkerBecomesNil() throws {
        let keys = SymbolicHotKeys.parse(try Self.fixture())
        let other = try #require(keys[164])
        #expect(!other.enabled)
        #expect(other.keyCode == nil)
        #expect(other.modifiers == nil)
    }

    @Test func missingEntriesGetMacOSDefaults() throws {
        let keys = SymbolicHotKeys.parse([:])
        // "Move left/right a space" are on by default, "Switch to Desktop n" are off.
        #expect(keys[79]?.isUsable == true)
        #expect(keys[81]?.isUsable == true)
        #expect(keys[79]?.inPlist == false)
        let desktop4 = try #require(keys[121])
        #expect(!desktop4.enabled)
        #expect(desktop4.keyCode == 21)               // Ctrl+4
        #expect(desktop4.combo == "Ctrl+4")
        #expect(!desktop4.isUsable)
        for id in SymbolicHotKeys.relevantIDs { #expect(keys[id] != nil) }
    }

    @Test func defaultDesktopKeyCodesFollowTheNumberRow() {
        let keys = SymbolicHotKeys.parse([:])
        let expected = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]    // 1 2 3 4 5 6 7 8 9 0
        for (offset, code) in expected.enumerated() {
            #expect(keys[118 + offset]?.keyCode == code)
            #expect(keys[118 + offset]?.modifiers == 0x40000)
        }
    }

    @Test func nonStringOrMalformedEntriesAreIgnored() {
        let keys = SymbolicHotKeys.parse(["abc": ["enabled": 1], "79": "oops", "81": ["enabled": 0]])
        #expect(keys.count == SymbolicHotKeys.relevantIDs.count)    // "abc" adds nothing
        #expect(keys[79]?.enabled == true)            // malformed entry: default
        #expect(keys[81]?.enabled == false)
        #expect(keys[81]?.isUsable == false)
    }

    @Test func desktopHotKeyIDs() {
        #expect(SymbolicHotKeys.desktopHotKeyID(forDesktop: 1) == 118)
        #expect(SymbolicHotKeys.desktopHotKeyID(forDesktop: 10) == 127)
        #expect(SymbolicHotKeys.desktopHotKeyID(forDesktop: 16) == 133)
        #expect(SymbolicHotKeys.desktopHotKeyID(forDesktop: 0) == nil)
        #expect(SymbolicHotKeys.desktopHotKeyID(forDesktop: 17) == nil)
    }

    // MARK: method availability

    @Test func availabilityFollowsHotkeysAndPermission() throws {
        let keys = SymbolicHotKeys.parse(try Self.fixture())
        let list = SpaceSwitcher.evaluateMethods(hotKeys: keys, axTrusted: true, slsSetCurrentSpace: true,
                                                 slsShowHide: true, osMajor: 27)
        func entry(_ method: SwitchMethod) -> MethodAvailability { list.first { $0.method == method }! }
        #expect(list.map(\.method) == SwitchMethod.allCases)
        #expect(entry(.swipe).usable)
        #expect(entry(.swipe).reason.contains("modern"))
        #expect(entry(.keys).usable)
        #expect(entry(.number).usable)                // Desktop 1 and 3 are on in the fixture
        #expect(entry(.number).reason.contains("1, 3"))
        #expect(entry(.sls).usable)
    }

    @Test func availabilityWithoutAccessibilityBlocksPostingMethods() throws {
        let keys = SymbolicHotKeys.parse(try Self.fixture())
        let list = SpaceSwitcher.evaluateMethods(hotKeys: keys, axTrusted: false, slsSetCurrentSpace: true,
                                                 slsShowHide: false, osMajor: 26)
        for item in list where item.method != .sls {
            #expect(!item.usable)
            #expect(item.reason.contains("Accessibility"))
        }
        #expect(list.first { $0.method == .sls }?.usable == true)
        #expect(list.first { $0.method == .sls }?.reason.contains("missing") == true)
    }

    @Test func availabilityWithDefaultsHasNoNumberMethod() {
        let list = SpaceSwitcher.evaluateMethods(hotKeys: SymbolicHotKeys.parse([:]), axTrusted: true,
                                                 slsSetCurrentSpace: false, slsShowHide: false, osMajor: 26)
        func entry(_ method: SwitchMethod) -> MethodAvailability { list.first { $0.method == method }! }
        #expect(entry(.swipe).reason.contains("legacy"))
        #expect(entry(.keys).usable)
        #expect(!entry(.number).usable)
        #expect(!entry(.sls).usable)
    }

    @Test func disabledMoveKeysMakeKeysUnusable() {
        let plist: [String: Any] = ["79": ["enabled": 0], "81": ["enabled": 1]]
        let list = SpaceSwitcher.evaluateMethods(hotKeys: SymbolicHotKeys.parse(plist), axTrusted: true,
                                                 slsSetCurrentSpace: true, slsShowHide: true, osMajor: 27)
        let keys = list.first { $0.method == .keys }
        #expect(keys?.usable == false)
        #expect(keys?.reason.contains("Move left a space") == true)
        #expect(keys?.reason.contains("disabled") == true)
    }

    @Test func rangeText() {
        #expect(SpaceSwitcher.rangeText([1, 2, 3, 5, 7, 8]) == "1-3, 5, 7-8")
        #expect(SpaceSwitcher.rangeText([4]) == "4")
        #expect(SpaceSwitcher.rangeText([]) == "")
        #expect(SpaceSwitcher.rangeText([3, 1, 2, 2]) == "1-3")
    }

    // MARK: swipe sign

    @Test func legacySwipeSign() {
        #expect(DockSwipe.sign(direction: .right, variant: .legacy, naturalScrolling: true, invert: false) == 1)
        #expect(DockSwipe.sign(direction: .left, variant: .legacy, naturalScrolling: true, invert: false) == -1)
        // Natural scrolling does not matter for the legacy fields.
        #expect(DockSwipe.sign(direction: .right, variant: .legacy, naturalScrolling: false, invert: false) == 1)
    }

    @Test func modernSwipeSignDependsOnNaturalScrolling() {
        #expect(DockSwipe.sign(direction: .right, variant: .modern, naturalScrolling: true, invert: false) == -1)
        #expect(DockSwipe.sign(direction: .left, variant: .modern, naturalScrolling: true, invert: false) == 1)
        #expect(DockSwipe.sign(direction: .right, variant: .modern, naturalScrolling: false, invert: false) == 1)
        #expect(DockSwipe.sign(direction: .left, variant: .modern, naturalScrolling: false, invert: false) == -1)
    }

    @Test func invertAndNoDirection() {
        #expect(DockSwipe.sign(direction: .right, variant: .modern, naturalScrolling: true, invert: true) == 1)
        #expect(DockSwipe.sign(direction: .left, variant: .legacy, naturalScrolling: true, invert: true) == 1)
        #expect(DockSwipe.sign(direction: .none, variant: .modern, naturalScrolling: true, invert: false) == 0)
    }

    // MARK: swipe payload

    @Test func fixedPointKeepsTinyValuesNonZero() {
        #expect(DockSwipe.fixed1616(0.000016) == 1)
        #expect(DockSwipe.fixed1616(-0.000016) == -1)
        #expect(DockSwipe.fixed1616(0) == 0)
        #expect(DockSwipe.fixed1616(0.1) == 6553)
        #expect(DockSwipe.fixed1616(9999) == 655_294_464)
        #expect(DockSwipe.fixed1616(-9999) == -655_294_464)
    }

    private func read<T: FixedWidthInteger>(_ data: Data, _ offset: Int, as type: T.Type) -> T {
        var value: T = 0
        withUnsafeMutableBytes(of: &value) { buffer in
            for index in 0..<MemoryLayout<T>.size { buffer[index] = data[data.startIndex + offset + index] }
        }
        return T(littleEndian: value)
    }

    @Test func beganPayloadHasQueueHeaderAndFluidRecord() {
        let data = DockSwipe.payload(phase: 1, positionX: 0.1, positionY: 0, progress: -0.000016,
                                     velocityX: 0, velocityY: 0, timestamp: 0x1122_3344_5566)
        #expect(data.count == 68)                                        // 28 + 40
        #expect(read(data, 0, as: UInt64.self) == 0x1122_3344_5566)      // timestamp
        #expect(read(data, 24, as: UInt32.self) == 1)                    // event count
        #expect(read(data, 28, as: UInt32.self) == 40)                   // fluid record size
        #expect(read(data, 32, as: UInt32.self) == 23)                   // type: dock swipe
        #expect(read(data, 36, as: UInt32.self) == 1 << 24)              // options: phase 1 in top byte
        #expect(read(data, 44, as: Int32.self) == 6553)                  // position x
        #expect(read(data, 60, as: UInt16.self) == 1)                    // motion: horizontal
        #expect(read(data, 62, as: UInt16.self) == 3)                    // flavor
        #expect(read(data, 64, as: Int32.self) == -1)                    // progress
    }

    @Test func changedPayloadCarriesItsPhase() {
        let data = DockSwipe.payload(phase: 2, positionX: 0.1, positionY: 0, progress: 0.000016,
                                     velocityX: 0, velocityY: 0, timestamp: 1)
        #expect(data.count == 68)
        #expect(read(data, 36, as: UInt32.self) == 2 << 24)
        #expect(read(data, 64, as: Int32.self) == 1)
    }

    @Test func endedPayloadAddsVelocityRecordAndSecondEvent() {
        let data = DockSwipe.payload(phase: 4, positionX: 0.1, positionY: 0, progress: 0.000016,
                                     velocityX: -9999, velocityY: 0, timestamp: 7)
        #expect(data.count == 96)                                        // 28 + 40 + 28
        #expect(read(data, 24, as: UInt32.self) == 2)                    // two records
        #expect(read(data, 36, as: UInt32.self) == 4 << 24)
        #expect(read(data, 68, as: UInt32.self) == 28)                   // velocity record size
        #expect(read(data, 72, as: UInt32.self) == 9)                    // type: velocity
        #expect(read(data, 80, as: UInt8.self) == 1)                     // depth
        #expect(read(data, 84, as: Int32.self) == -655_294_464)          // velocity x
        #expect(read(data, 88, as: Int32.self) == 0)                     // velocity y
    }

    @Test func trailerIsAppendedWithBigEndianLengthAndFieldID() throws {
        let serialized = Data([0, 0, 0, 2, 9, 9, 9, 9])
        let payload = Data(repeating: 0xAB, count: 68)
        let joined = try #require(DockSwipe.appendPayload(to: serialized, payload: payload))
        #expect(joined.count == 8 + 4 + 68)
        let bytes = [UInt8](joined)
        #expect(Array(bytes[0..<8]) == [0, 0, 0, 2, 9, 9, 9, 9])
        #expect(Array(bytes[8..<12]) == [0, 68, 0x10, 0x6D])             // length 68, field 4205 = 0x106D
        #expect(bytes[12] == 0xAB && bytes.last == 0xAB)
    }

    @Test func trailerNeedsSerializationVersionTwo() {
        #expect(DockSwipe.appendPayload(to: Data([0, 0, 0, 1, 5]), payload: Data([1])) == nil)
        #expect(DockSwipe.appendPayload(to: Data([0, 0]), payload: Data([1])) == nil)
    }

    // MARK: misc

    @Test func comboTextForUnknownKeyAndNoModifiers() {
        #expect(SymbolicHotKeys.comboText(keyCode: 12, modifiers: 0) == "keycode 12")
        #expect(SymbolicHotKeys.comboText(keyCode: nil, modifiers: 0x40000) == "none")
        #expect(SymbolicHotKeys.comboText(keyCode: 49, modifiers: 0x100000 | 0x20000) == "Shift+Cmd+Space")
    }

    @Test func outcomeWorkedMeansReachedAndNotAStaleScreen() {
        var outcome = SwitchOutcome(method: .sls, displayIdentifier: "Main", targetSpaceID: 5)
        #expect(!outcome.worked)
        outcome.reached = true
        #expect(outcome.worked)
        outcome.repaint = .stale
        #expect(!outcome.worked)
        outcome.method = .swipe                       // only sls is judged by the screen check
        #expect(outcome.worked)
    }

    @Test func swipeVariantAutoFollowsTheOSVersion() {
        #expect(SpaceSwitcher.resolvedSwipeVariant(.legacy) == .legacy)
        #expect(SpaceSwitcher.resolvedSwipeVariant(.modern) == .modern)
        let auto = SpaceSwitcher.resolvedSwipeVariant(.auto)
        #expect(auto == (ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 ? .modern : .legacy))
    }
}
