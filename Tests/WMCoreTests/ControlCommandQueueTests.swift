import Foundation
import Testing
@testable import WMCore

@Suite struct ControlCommandQueueTests {
    @Test func drainReturnsCommandsInOrderAndEmpties() {
        var queue = ControlCommandQueue()
        #expect(queue.isEmpty)
        queue.enqueue(.run(profile: "Work"))
        queue.enqueue(.list)
        queue.enqueue(.capture(name: "Home"))
        #expect(queue.pending == [.run(profile: "Work"), .list, .capture(name: "Home")])

        #expect(queue.drain() == [.run(profile: "Work"), .list, .capture(name: "Home")])
        #expect(queue.isEmpty)
        #expect(queue.drain().isEmpty)
    }

    @Test func commandsQueuedAfterDrainWaitForTheNextDrain() {
        var queue = ControlCommandQueue()
        queue.enqueue(.list)
        _ = queue.drain()
        queue.enqueue(.run(profile: "Day"))
        #expect(queue.drain() == [.run(profile: "Day")])
    }
}
