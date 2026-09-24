@testable import AppBundle
import Common
import XCTest

@MainActor
final class CenterFloatingCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc("center-floating", CenterFloatingCmdArgs(rawArgs: []))
        testParseSingleCommandSucc(
            "center-floating --width 70% --height 800",
            CenterFloatingCmdArgs(rawArgs: [])
                .copy(\.width, .percent(70))
                .copy(\.height, .points(800)),
        )

        testParseCommandFail("center-floating --width", msg: "ERROR: '--width' must be followed by '<size>'", exitCode: 2)
        testParseCommandFail("center-floating --width 0%", msg: "ERROR: Failed to parse '0%' CLI argument: Percentage must be in 1%...100% range", exitCode: 2)
        testParseCommandFail("center-floating --height 150%", msg: "ERROR: Failed to parse '150%' CLI argument: Percentage must be in 1%...100% range", exitCode: 2)
        testParseCommandFail("center-floating --width abc", msg: "ERROR: Failed to parse 'abc' CLI argument: <size> must be a positive number or a percentage (e.g. 70%)", exitCode: 2)

        testParseCommandHelp("center-floating -h")
    }

    func testCenterWithPercentSize() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: Rect(topLeftX: 10, topLeftY: 20, width: 300, height: 200))
        assertEquals(window.focusWindow(), true)

        let result = await parseCommand("center-floating --width 50% --height 50%").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.topLeftCorner, CGPoint(x: 480, y: 270))
        assertEquals(rect?.size, CGSize(width: 960, height: 540))
        assertEquals(window.lastFloatingSize, CGSize(width: 960, height: 540))
    }

    func testCenterKeepsSize() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer, rect: Rect(topLeftX: 10, topLeftY: 20, width: 400, height: 200))
        assertEquals(window.focusWindow(), true)

        let result = await parseCommand("center-floating").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 0)
        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.topLeftCorner, CGPoint(x: 760, y: 440))
        assertEquals(rect?.size, CGSize(width: 400, height: 200))
    }

    func testFailsForTilingWindow() async {
        let workspace = Workspace.get(byName: name)
        assertEquals(TestWindow.new(id: 1, parent: workspace.rootTilingContainer).focusWindow(), true)

        let result = await parseCommand("center-floating --width 50%").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["The window is not floating. Tip: use 'layout floating' first"])
    }
}
