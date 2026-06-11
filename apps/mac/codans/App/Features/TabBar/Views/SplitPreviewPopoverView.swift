import SwiftUI
import CodansCore

/// Miniature of the active tab's pane tree, shown in a popover below the
/// trailing split buttons after a short hover delay. Gives users a cheap
/// "is this where I want the split to land?" glance without actually
/// performing the split — matches the plan's hover-preview affordance.
struct SplitPreviewPopoverView: View {
  let tree: SplitTree<PaneID>

  var body: some View {
    Group {
      if let root = tree.root {
        NodePreviewView(node: root)
          .frame(width: 140, height: 88)
          .padding(12)
      } else {
        Text("No panes")
          .font(.caption)
          .foregroundStyle(.secondary)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
      }
    }
  }
}

/// Recursive miniature of a single node. Leaves render as a stroked /
/// tinted rounded rectangle; splits lay their two children out in the
/// matching direction with a 2-pt gutter and a flex ratio that mirrors
/// the stored split ratio.
private struct NodePreviewView: View {
  let node: SplitTree<PaneID>.Node

  var body: some View {
    switch node {
    case .leaf:
      leafView
    case .split(let split):
      splitView(split)
    }
  }

  private var leafView: some View {
    RoundedRectangle(cornerRadius: 2)
      .strokeBorder(Color.secondary, lineWidth: 1)
      .background(
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.secondary.opacity(0.15))
      )
  }

  @ViewBuilder
  private func splitView(_ split: SplitTree<PaneID>.Split) -> some View {
    GeometryReader { geo in
      switch split.direction {
      case .horizontal:
        let gutter: CGFloat = 2
        let leftWidth = max(0, (geo.size.width - gutter) * CGFloat(split.ratio))
        let rightWidth = max(0, (geo.size.width - gutter) * CGFloat(1 - split.ratio))
        HStack(spacing: gutter) {
          NodePreviewView(node: split.left).frame(width: leftWidth)
          NodePreviewView(node: split.right).frame(width: rightWidth)
        }
      case .vertical:
        let gutter: CGFloat = 2
        let topHeight = max(0, (geo.size.height - gutter) * CGFloat(split.ratio))
        let bottomHeight = max(0, (geo.size.height - gutter) * CGFloat(1 - split.ratio))
        VStack(spacing: gutter) {
          NodePreviewView(node: split.left).frame(height: topHeight)
          NodePreviewView(node: split.right).frame(height: bottomHeight)
        }
      }
    }
  }
}
