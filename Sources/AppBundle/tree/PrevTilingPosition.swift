import AppKit
import Common

/// Where the window was in the tiling tree before it became floating.
/// Used by 'layout tiling' to put the window back to the same (or the closest) place
struct PrevTilingPosition {
    weak var parent: TilingContainer?
    let index: Int
    /// The share of the parent container that the window occupied. Weights are absolute (points), so they can't be
    /// restored as is: the siblings grow to fill the space while the window is floating
    let fraction: CGFloat
    let siblingsCount: Int
    let orientation: Orientation
    weak var prevSibling: TreeNode?
    weak var nextSibling: TreeNode?
}

extension Window {
    @MainActor
    func rememberTilingPosition() {
        guard let parent = parent as? TilingContainer, let index = ownIndex else { return }
        let total = CGFloat(parent.children.sumOfDouble { $0.getWeight(parent.orientation) })
        prevTilingPosition = PrevTilingPosition(
            parent: parent,
            index: index,
            fraction: total > 0 ? getWeight(parent.orientation) / total : 0,
            siblingsCount: parent.children.count - 1,
            orientation: parent.orientation,
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
            // If the container changed while the window was floating, the previous share doesn't make sense anymore
            let isSameContainer = parent.orientation == pos.orientation && parent.children.count == pos.siblingsCount
            bind(to: parent, index: index, fraction: isSameContainer ? pos.fraction : nil)
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
            bind(to: anchorParent, index: anchorIndex + (isAfterAnchor ? 1 : 0), fraction: nil)
        } else {
            let anchorSize = anchor.lastAppliedLayoutVirtualRect?.getDimension(pos.orientation)
            let binding = anchor.unbindFromParent()
            let container = TilingContainer(
                parent: binding.parent,
                adaptiveWeight: binding.adaptiveWeight,
                pos.orientation,
                index: binding.index,
            )
            anchor.bind(to: container, adaptiveWeight: anchorSize ?? 1, index: 0)
            bind(to: container, index: isAfterAnchor ? 1 : 0, fraction: pos.siblingsCount == 1 ? pos.fraction : nil)
        }
        return true
    }

    /// Binds the window so that it occupies `fraction` of the container (or an equal share if nil).
    /// The siblings shrink proportionally, so the sum of weights stays the same
    @MainActor
    private func bind(to parent: TilingContainer, index: Int, fraction: CGFloat?) {
        let siblings = parent.children
        let total = CGFloat(siblings.sumOfDouble { $0.getWeight(parent.orientation) })
        guard total > 0 else {
            bind(to: parent, adaptiveWeight: WEIGHT_AUTO, index: index)
            return
        }
        let fraction = (fraction ?? 1 / CGFloat(siblings.count + 1)).coerce(in: 0.05 ... 0.95)
        for sibling in siblings {
            sibling.setWeight(parent.orientation, sibling.getWeight(parent.orientation) * (1 - fraction))
        }
        bind(to: parent, adaptiveWeight: total * fraction, index: index)
    }
}
