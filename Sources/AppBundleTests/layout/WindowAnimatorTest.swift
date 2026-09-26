@testable import AppBundle
import XCTest

final class WindowAnimatorTest: XCTestCase {
    private let leftMonitor = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 1000)
    private let rightMonitor = Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 1000)
    private var monitors: [Rect] { [leftMonitor, rightMonitor] }

    private func limit(_ from: Rect, _ to: Rect, separateSpaces: Bool = true) -> [CGFloat?] {
        let limit = stickOutLimit(from: from, to: to, monitors: monitors, separateSpaces: separateSpaces)
        return [limit.x, limit.y]
    }

    func testGrowToTheLeftAtTheOuterEdge() {
        let from = Rect(topLeftX: 1500, topLeftY: 0, width: 500, height: 1000)
        let to = Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 1000)
        assertEquals(limit(from, to), [.infinity, nil])
    }

    func testGrowToTheLeftNextToAnotherMonitor() {
        let from = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)
        let to = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 1000)
        // macOS doesn't show the part on the other monitor as long as most of the window stays on its own monitor
        assertEquals(limit(from, to), [1.7, nil])
        // Without separate Spaces, the part that sticks out would show on the other monitor
        assertEquals(limit(from, to, separateSpaces: false), [nil, nil])
    }

    func testGrowToTheLeftNextToAnotherWindow() {
        // The right edge is inside the monitor
        let from = Rect(topLeftX: 1500, topLeftY: 0, width: 250, height: 1000)
        let to = Rect(topLeftX: 1000, topLeftY: 0, width: 750, height: 1000)
        assertEquals(limit(from, to), [nil, nil])
    }

    func testGrowUpAtTheBottomEdge() {
        let from = Rect(topLeftX: 1000, topLeftY: 500, width: 1000, height: 500)
        let to = Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 1000)
        assertEquals(limit(from, to), [nil, .infinity])
    }

    func testGrowToTheRightShrinkAndMove() {
        let left = Rect(topLeftX: 1000, topLeftY: 0, width: 500, height: 1000)
        let full = Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 1000)
        let right = Rect(topLeftX: 1500, topLeftY: 0, width: 500, height: 1000)
        assertEquals(limit(left, full), [nil, nil])
        assertEquals(limit(full, right), [nil, nil])
        assertEquals(limit(right, left), [nil, nil])
    }

    func testShrinksAtMonitorEdge() {
        let full = Rect(topLeftX: 1000, topLeftY: 0, width: 1000, height: 1000)
        let right = Rect(topLeftX: 1500, topLeftY: 0, width: 500, height: 1000)
        // The right edge stays at the outer edge: move first, then resize
        XCTAssertTrue(shrinksAtMonitorEdge(from: full, to: right, monitors: monitors, separateSpaces: false))
        // Next to another monitor: only with separate Spaces
        let leftFull = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 1000)
        let leftRight = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)
        XCTAssertTrue(shrinksAtMonitorEdge(from: leftFull, to: leftRight, monitors: monitors, separateSpaces: true))
        XCTAssertFalse(shrinksAtMonitorEdge(from: leftFull, to: leftRight, monitors: monitors, separateSpaces: false))
        // The right edge is inside the monitor (a tile in the middle): unchanged order
        XCTAssertFalse(shrinksAtMonitorEdge(from: full, to: Rect(topLeftX: 1250, topLeftY: 0, width: 500, height: 1000), monitors: monitors, separateSpaces: true))
        // Growing, or shrinking from the right: unchanged order
        XCTAssertFalse(shrinksAtMonitorEdge(from: right, to: full, monitors: monitors, separateSpaces: true))
        XCTAssertFalse(shrinksAtMonitorEdge(from: full, to: Rect(topLeftX: 1000, topLeftY: 0, width: 500, height: 1000), monitors: monitors, separateSpaces: true))
        // Vertical: shrinking from the top at the bottom edge
        XCTAssertTrue(shrinksAtMonitorEdge(from: full, to: Rect(topLeftX: 1000, topLeftY: 500, width: 1000, height: 500), monitors: monitors, separateSpaces: false))
    }

    func testStuckOutLength() {
        // Nothing beyond the edge: the final size right away, then no more resizes
        assertEquals(stuckOutLength(visible: 520, target: 1000, lastSent: 500, limit: .infinity), 1000)
        assertEquals(stuckOutLength(visible: 700, target: 1000, lastSent: 1000, limit: .infinity), 1000)
        // Another monitor beyond the edge: most of the window stays on its monitor
        assertEquals(stuckOutLength(visible: 520, target: 1000, lastSent: 500, limit: 1.7), 884)
        assertEquals(stuckOutLength(visible: 600, target: 1000, lastSent: 884, limit: 1.7), 884) // Still enough room
        assertEquals(stuckOutLength(visible: 650, target: 1000, lastSent: 884, limit: 1.7), 1000)
        // Can't stick out
        assertEquals(stuckOutLength(visible: 600, target: 1000, lastSent: 500, limit: nil), 600)
    }
}

@MainActor
final class WindowAnimatorFullscreenTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testLeavingFullscreenAnimatesFromTheFullscreenFrame() {
        let window = TestWindow.new(id: 1, parent: Workspace.get(byName: name).rootTilingContainer)
        let fullscreen = Rect(topLeftX: 0, topLeftY: 30, width: 2560, height: 1410)
        WindowAnimator.shared.setFullscreenFrame(window, from: nil, to: fullscreen)
        assertEquals(WindowAnimator.shared.takeFullscreenFrame(1)?.width, 2560)
        // Taken once: a later layout of the window as a tile doesn't animate from a stale fullscreen frame
        assertNil(WindowAnimator.shared.takeFullscreenFrame(1))
    }
}
