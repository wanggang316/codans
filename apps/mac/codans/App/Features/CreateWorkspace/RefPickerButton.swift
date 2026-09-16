import Foundation
import SwiftUI

/// A compact dropdown for choosing a git ref: a borderless button showing
/// the selection, a popover with a filter field and the refs grouped Local /
/// Remote. Rows another worktree already holds are shown but disabled, with
/// the path as the reason. Stateless beyond the open flag and the filter;
/// the caller owns the selection.
struct RefPickerButton: View {
  let selection: String?
  let options: [BranchRefOption]
  var isLoading = false
  /// Offers a first row that clears the selection, labelled with the
  /// repository's default when known.
  var allowsDefault = false
  var defaultBaseRef: String?
  var placeholder = "Choose a branch"
  let onSelect: (String?) -> Void

  @State private var isPresented = false
  @State private var query = ""

  var body: some View {
    Button {
      query = ""
      isPresented = true
    } label: {
      HStack(spacing: 4) {
        if isLoading {
          ProgressView().controlSize(.mini)
        }
        Text(title)
          .lineLimit(1)
          .truncationMode(.middle)
          .foregroundStyle(selection == nil && !allowsDefault ? .secondary : .primary)
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.semibold))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(options.isEmpty && !allowsDefault)
    .accessibilityLabel("Branch: \(title)")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) { popoverBody }
  }

  private var title: String {
    if let selection { return selection }
    if allowsDefault {
      return defaultBaseRef.map { "Repository default (\($0))" } ?? "Repository default"
    }
    return isLoading ? "Loading…" : placeholder
  }

  private var popoverBody: some View {
    VStack(alignment: .leading, spacing: 0) {
      TextField("Filter branches", text: $query)
        .textFieldStyle(.roundedBorder)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          if allowsDefault, query.isEmpty {
            row(
              title: defaultBaseRef.map { "Repository default (\($0))" } ?? "Repository default",
              selected: selection == nil, disabledReason: nil
            ) {
              onSelect(nil)
            }
            Divider().padding(.vertical, 4)
          }
          let locals = filtered(options.filter { !$0.isRemote })
          let remotes = filtered(options.filter(\.isRemote))
          if !locals.isEmpty {
            sectionHeader("Local")
            ForEach(locals) { option in optionRow(option) }
          }
          if !remotes.isEmpty {
            if !locals.isEmpty { Divider().padding(.vertical, 4) }
            sectionHeader("Remote")
            ForEach(remotes) { option in optionRow(option) }
          }
          if locals.isEmpty, remotes.isEmpty {
            Text(options.isEmpty ? "No branches loaded." : "No matching branches.")
              .font(.caption)
              .foregroundStyle(.secondary)
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
          }
        }
        .padding(.bottom, 8)
      }
      // A minimum height keeps the popover from collapsing on first open.
      .frame(minHeight: 160, maxHeight: 360)
    }
    .frame(width: 320)
  }

  private func sectionHeader(_ text: String) -> some View {
    Text(text)
      .font(.caption.weight(.semibold))
      .foregroundStyle(.secondary)
      .padding(.horizontal, 12)
      .padding(.top, 4)
  }

  private func optionRow(_ option: BranchRefOption) -> some View {
    row(
      title: option.isDefault ? "\(option.shortName)  · default" : option.shortName,
      selected: option.shortName == selection,
      disabledReason: option.checkedOutAt.map { "checked out at \(($0 as NSString).abbreviatingWithTildeInPath)" }
    ) {
      onSelect(option.shortName)
    }
  }

  private func row(title: String, selected: Bool, disabledReason: String?, action: @escaping () -> Void) -> some View {
    Button {
      action()
      isPresented = false
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "checkmark")
          .font(.caption.weight(.semibold))
          .opacity(selected ? 1 : 0)
          .accessibilityHidden(true)
        Text(title)
          .font(.callout.monospaced())
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer(minLength: 0)
        if let disabledReason {
          Text(disabledReason)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 3)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(disabledReason != nil)
    .help(disabledReason ?? "")
  }

  private func filtered(_ refs: [BranchRefOption]) -> [BranchRefOption] {
    let needle = query.trimmingCharacters(in: .whitespaces)
    if needle.isEmpty { return refs }
    return refs.filter { $0.shortName.range(of: needle, options: [.caseInsensitive]) != nil }
  }
}
