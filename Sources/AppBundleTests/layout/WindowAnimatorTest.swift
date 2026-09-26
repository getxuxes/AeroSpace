@testable import AppBundle
import XCTest

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

final class CriticallyDampedSpringTest: XCTestCase {
    private let spring = CriticallyDampedSpring(settleTime: 0.12)
    private let from = Rect(topLeftX: 0, topLeftY: 0, width: 1000, height: 1000)
    private let to = Rect(topLeftX: 500, topLeftY: 0, width: 500, height: 1000)

    func testStartsWhereItIsWithTheGivenVelocity() {
        let v0 = RectVelocity(x: 3000, y: 0, width: -1000, height: 0)
        assertEquals(spring.frame(from: from, to: to, v0: v0, 0).topLeftX, 0)
        assertEquals(spring.velocity(from: from, to: to, v0: v0, 0), v0)
    }

    func testSettlesWithinTheDurationFromRest() {
        let end = spring.frame(from: from, to: to, v0: .zero, 0.12)
        XCTAssert(abs(end.topLeftX - 500) <= 5, "\(end.topLeftX)") // 1% of 500
        XCTAssert(spring.isSettled(from: from, to: to, v0: .zero, 0.2))
        XCTAssertFalse(spring.isSettled(from: from, to: to, v0: .zero, 0.05))
    }

    func testDoesNotOvershootFromRest() {
        for t in stride(from: 0.0, through: 0.3, by: 0.001) {
            XCTAssert(spring.frame(from: from, to: to, v0: .zero, t).topLeftX <= 500)
        }
    }

    func testVelocityIsContinuousWhenInterrupted() {
        // An animation to `to` is interrupted halfway by one back to `from`: the second starts with the first's velocity
        let v = spring.velocity(from: from, to: to, v0: .zero, 0.03)
        let at = spring.frame(from: from, to: to, v0: .zero, 0.03)
        let dt = 0.0001
        let before = (spring.frame(from: from, to: to, v0: .zero, 0.03).topLeftX - spring.frame(from: from, to: to, v0: .zero, 0.03 - dt).topLeftX) / dt
        let after = (spring.frame(from: at, to: from, v0: v, dt).topLeftX - spring.frame(from: at, to: from, v0: v, 0).topLeftX) / dt
        XCTAssert(abs(before - after) < abs(before) * 0.02, "\(before) vs \(after)")
    }
}
