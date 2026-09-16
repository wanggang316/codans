import ComposableArchitecture
import SwiftUI

/// The sheet's one entry point for members: paste a URL, type a path, or
/// search the open projects. The reducer classifies the text; this view
/// shows the classification, the suggestion list for a search, and the two
/// picker buttons for a folder or a bare repository.
struct WorkspaceAddField: View {
  @Bindable var store: StoreOf<CreateWorkspaceFeature>
  @FocusState private var isFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        HStack(spacing: 6) {
          Image(systemName: "plus")
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
          TextField(
            "Paste a URL, type a path, or search open projects…",
            text: Binding(get: { store.addDraft }, set: { store.send(.addDraftChanged($0)) })
          )
          .textFieldStyle(.plain)
          .focused($isFocused)
          .onSubmit { store.send(.addSubmitted) }
          .onKeyPress(.downArrow) {
            store.send(.addMoveHighlight(by: 1))
            return .handled
          }
          .onKeyPress(.upArrow) {
            store.send(.addMoveHighlight(by: -1))
            return .handled
          }
          .onKeyPress(.escape) {
            guard !store.addDraft.isEmpty else { return .ignored }
            store.send(.addCleared)
            return .handled
          }
          .onChange(of: isFocused) { _, focused in
            if !focused { store.send(.addFieldLostFocus) }
          }
          if store.isResolvingAdd {
            ProgressView().controlSize(.mini)
          } else if let badge {
            Text(badge)
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
          }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.background, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        Button("Add Folder…") { store.send(.addFolderTapped) }
        Button("Bare…") { store.send(.addBareTapped) }
          .help("Add a bare repository")
      }
      .disabled(store.creation != .idle)

      if let issue = store.addIssue {
        Text(issue)
          .font(.caption)
          .foregroundStyle(.red)
          .textSelection(.enabled)
      }

      if isFocused, showsSuggestions {
        suggestions
      }
    }
  }

  private var badge: String? {
    switch store.addKind {
    case .empty: return nil
    case .url: return "URL"
    case .path: return "Path"
    case .search: return store.addSuggestions.isEmpty ? nil : "Project"
    }
  }

  private var showsSuggestions: Bool {
    switch store.addKind {
    case .search, .empty: return !store.addSuggestions.isEmpty
    case .url, .path: return false
    }
  }

  private var suggestions: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(Array(store.addSuggestions.enumerated()), id: \.element.id) { index, candidate in
        Button {
          store.send(.addSuggestionTapped(candidate.id))
        } label: {
          HStack(spacing: 6) {
            Image(systemName: "folder")
              .foregroundStyle(.secondary)
              .accessibilityHidden(true)
            Text(candidate.name)
            Text((candidate.gitRoot as NSString).abbreviatingWithTildeInPath)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
              .truncationMode(.middle)
            Spacer(minLength: 0)
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            store.addHighlightedIndex == index ? Color.accentColor.opacity(0.15) : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
          )
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .background(.background, in: RoundedRectangle(cornerRadius: 6))
    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
  }
}
