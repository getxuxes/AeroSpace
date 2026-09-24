import AppKit
import Common

/// Where the window was in the tiling tree before it became floating.
/// Used by 'layout tiling' to put the window back to the same (or the closest) place
struct PrevTilingPosition {
    weak var parent: TilingContainer?
    let index: Int
    let weight: CGFloat
    let orientation: Orientation
    let layout: Layout
    weak var prevSibling: TreeNode?
    weak var nextSibling: TreeNode?
}

extension Window {
    @MainActor
    func rememberTilingPosition() {
        guard let parent = parent as? TilingContainer, let index = ownIndex else { return }
        prevTilingPosition = PrevTilingPosition(
            parent: parent,
            index: index,
            weight: getWeight(parent.orientation),
            orientation: parent.orientation,
            layout: parent.layout,
            prevSibling: parent.children.getOrNil(atIndex: index - 1),
            nextSibling: parent.children.getOrNil(atIndex: index + 1),
        )
    }

    /// Returns false if there is no remembered position that can be restored on the workspace
    @MainActor
    func restoreTilingPosition(on workspace: Workspace) -> Bool {
        guard let pos = prevTilingPosition else { return false }
        prevTilingPosition = nil

        // 1. The previous parent container is still in the tree
        if let parent = pos.parent, parent.nodeWorkspace === workspace {
            let index: Int = if let prev = pos.prevSibling, prev.parent === parent, let i = prev.ownIndex {
                i + 1
            } else if let next = pos.nextSibling, next.parent === parent, let i = next.ownIndex {
                i
            } else {
                min(pos.index, parent.children.count)
            }
            bind(to: parent, adaptiveWeight: pos.weight, index: index)
            return true
        }

        // 2. The previous parent container was flattened by normalization. Split the sibling again
        let anchor: TreeNode
        let isAfterAnchor: Bool
        if let prev = pos.prevSibling, prev.nodeWorkspace === workspace, prev.parent is TilingContainer {
            (anchor, isAfterAnchor) = (prev, true)
        } else if let next = pos.nextSibling, next.nodeWorkspace === workspace, next.parent is TilingContainer {
            (anchor, isAfterAnchor) = (next, false)
        } else {
            return false
        }
        guard let anchorParent = anchor.parent as? TilingContainer, let anchorIndex = anchor.ownIndex else { return false }
        if anchorParent.orientation == pos.orientation {
            bind(to: anchorParent, adaptiveWeight: WEIGHT_AUTO, index: anchorIndex + (isAfterAnchor ? 1 : 0))
        } else {
            let binding = anchor.unbindFromParent()
            let container = TilingContainer(
                parent: binding.parent,
                adaptiveWeight: binding.adaptiveWeight,
                pos.orientation,
                pos.layout,
                index: binding.index,
            )
            anchor.bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: 0)
            bind(to: container, adaptiveWeight: WEIGHT_AUTO, index: isAfterAnchor ? 1 : 0)
        }
        return true
    }
}
