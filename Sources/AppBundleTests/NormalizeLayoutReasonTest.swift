@testable import AppBundle
import XCTest

@MainActor
final class NormalizeLayoutReasonTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    private func isBackgroundTab(_ window: Window, _ windows: [Window]) async throws -> Bool {
        var tabCounts: [UInt32: Int] = [:]
        return try await isBackgroundNativeTab(window, among: windows, OnScreenWindows(), &tabCounts)
    }

    func testBackgroundTabOfTheSelectedTab() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let selected = TestWindow.new(id: 1, parent: root)
        let background = TestWindow.new(id: 2, parent: root)
        selected.nativeTabCountForTest = 2
        background.isOnScreenForTest = false
        assertEquals(try await isBackgroundTab(background, [selected, background]), true)
        assertEquals(try await isBackgroundTab(selected, [selected, background]), false)
    }

    func testWindowNotShownYetIsNotATab() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let existing = TestWindow.new(id: 1, parent: root)
        let new = TestWindow.new(id: 2, parent: root)
        new.isOnScreenForTest = false
        assertEquals(try await isBackgroundTab(new, [existing, new]), false)
    }

    func testNoWindowOfTheAppIsShown() async throws {
        let root = Workspace.get(byName: name).rootTilingContainer
        let first = TestWindow.new(id: 1, parent: root)
        let second = TestWindow.new(id: 2, parent: root)
        first.nativeTabCountForTest = 2
        first.isOnScreenForTest = false
        second.isOnScreenForTest = false
        assertEquals(try await isBackgroundTab(second, [first, second]), false)
    }

    func testTabsOfAFullscreenWindowDontCount() async throws {
        let workspace = Workspace.get(byName: name)
        let fullscreen = TestWindow.new(id: 1, parent: workspace.macOsNativeFullscreenWindowsContainer)
        let other = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        fullscreen.nativeTabCountForTest = 2
        other.isOnScreenForTest = false
        assertEquals(try await isBackgroundTab(other, [fullscreen, other]), false)
    }
}
