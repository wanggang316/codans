import SwiftUI
import TouchCodeCore

/// macOS-System-Settings-style appearance picker. Three preview tiles laid out
/// horizontally, each labelled with a radio dot + caption underneath. The
/// selected tile is ringed in the accent color and its radio dot is filled —
/// matching the native System Settings → Appearance control.
///
/// Drives the same `AppearancePreference` binding the previous segmented Picker
/// did; rendering is the only thing that changes. Tile images live in
/// `Assets.xcassets` as `theme_light` / `theme_dark` / `theme_system`.
struct AppearancePicker: View {
  @Binding var selection: AppearancePreference

  var body: some View {
    HStack(alignment: .top, spacing: 18) {
      tile(.system, imageName: "theme_system", label: "Auto")
      tile(.light, imageName: "theme_light", label: "Light")
      tile(.dark, imageName: "theme_dark", label: "Dark")
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Appearance")
  }

  @ViewBuilder
  private func tile(
    _ value: AppearancePreference,
    imageName: String,
    label: String
  ) -> some View {
    let isSelected = selection == value
    Button {
      if selection != value { selection = value }
    } label: {
      VStack(spacing: 8) {
        Image(imageName)
          .resizable()
          .aspectRatio(contentMode: .fill)
          .frame(width: 92, height: 60)
          .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
          .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .strokeBorder(
                isSelected ? Color.accentColor : Color.secondary.opacity(0.25),
                lineWidth: isSelected ? 3 : 1
              )
          )
          .accessibilityHidden(true)

        HStack(spacing: 5) {
          ZStack {
            Circle()
              .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
              .frame(width: 12, height: 12)
            if isSelected {
              Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
            }
          }
          Text(label)
            .font(.callout)
            .foregroundStyle(.primary)
        }
      }
    }
    .buttonStyle(.plain)
    .contentShape(Rectangle())
    .focusEffectDisabled()
    .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    .accessibilityLabel(label)
  }
}

#if DEBUG
  private struct AppearancePickerPreview: View {
    @State private var preference: AppearancePreference = .system
    var body: some View {
      AppearancePicker(selection: $preference)
        .padding(24)
    }
  }

  #Preview("AppearancePicker") {
    AppearancePickerPreview()
  }
#endif
