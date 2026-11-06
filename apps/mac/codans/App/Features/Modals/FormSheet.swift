import SwiftUI

/// Shared frame for the add-project and worktree sheets: a headline title,
/// a grouped form, and a bottom bar with status on the leading side and
/// Cancel / the primary button on the trailing side. Shape and insets match
/// the New Agent title and the Create Workspace bottom bar.
struct FormSheet<Content: View, Status: View>: View {
  static var width: CGFloat { 560 }

  let title: String
  let primaryTitle: String
  let canSubmit: Bool
  let canCancel: Bool
  let onCancel: () -> Void
  let onSubmit: () -> Void
  @ViewBuilder let content: () -> Content
  @ViewBuilder let status: () -> Status

  init(
    _ title: String,
    primaryTitle: String,
    canSubmit: Bool,
    canCancel: Bool = true,
    onCancel: @escaping () -> Void,
    onSubmit: @escaping () -> Void,
    @ViewBuilder content: @escaping () -> Content,
    @ViewBuilder status: @escaping () -> Status = { EmptyView() },
  ) {
    self.title = title
    self.primaryTitle = primaryTitle
    self.canSubmit = canSubmit
    self.canCancel = canCancel
    self.onCancel = onCancel
    self.onSubmit = onSubmit
    self.content = content
    self.status = status
  }

  var body: some View {
    // The bar sits below the form rather than over it, so rows never
    // scroll behind the buttons.
    VStack(spacing: 0) {
      Text(title)
        .font(.headline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 24)
      Form {
        content()
      }
      .formStyle(.grouped)
      .scrollBounceBehavior(.basedOnSize)
      bar
    }
    .frame(width: Self.width)
  }

  private var bar: some View {
    HStack(spacing: 8) {
      status()
      Spacer(minLength: 12)
      Button("Cancel", role: .cancel, action: onCancel)
        .keyboardShortcut(.cancelAction)
        .disabled(!canCancel)
      Button(primaryTitle, action: onSubmit)
        .keyboardShortcut(.defaultAction)
        .disabled(!canSubmit)
    }
    .padding(.horizontal, 20)
    .padding(.top, 4)
    .padding(.bottom, 20)
  }
}

/// Progress text with a small spinner, for a `FormSheet` status slot.
struct FormSheetProgress: View {
  let text: String

  var body: some View {
    HStack(spacing: 8) {
      ProgressView().controlSize(.small)
      Text(text)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}
