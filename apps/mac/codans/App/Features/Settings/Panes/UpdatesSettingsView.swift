import AppKit
import ComposableArchitecture
import Sparkle
import SwiftUI
import CodansCore

/// Settings → Updates pane. `settings.json` is the source of truth — every
/// toggle / picker writes to `SettingsStore` and immediately replays the
/// full preference triple through `UpdatesClient.applyPreferences(...)` so
/// the running Sparkle instance never drifts from disk. The same client
/// runs once on launch (see `AppState.bringUp`), so a relaunch reproduces
/// whatever state the user left the pane in.
///
/// Channel selection is the headline knob. `tip` opts into pre-release
/// builds via Sparkle's appcast `<sparkle:channel>` filter and tightens
/// the background-check cadence; `stable` only sees release-cut items.
struct UpdatesSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Dependency(UpdatesClient.self) private var updatesClient

  @State private var lastCheckedAt: Date?
  @State private var feedURL: URL?

  private var general: GeneralSettings { settingsStore.settings.general }

  private var updateChannelBinding: Binding<UpdateChannel> {
    Binding(
      get: { general.updateChannel },
      set: { newValue in
        settingsStore.setUpdateChannel(newValue)
        applyToSparkle(triggerBackgroundCheck: true)
      }
    )
  }

  private var updateCheckIntervalBinding: Binding<UpdateCheckInterval> {
    Binding(
      get: { general.updateCheckInterval },
      set: { newValue in
        settingsStore.setUpdateCheckInterval(newValue)
        // Picking a new cadence implies "I'd like a fresh probe now" — same
        // semantics the channel picker carries.
        applyToSparkle(triggerBackgroundCheck: true)
      }
    )
  }

  private var automaticChecksBinding: Binding<Bool> {
    Binding(
      get: { general.updatesAutomaticallyCheckForUpdates },
      set: { newValue in
        let wasOff = !general.updatesAutomaticallyCheckForUpdates
        settingsStore.setUpdatesAutomaticallyCheckForUpdates(newValue)
        // Only fire a background probe when transitioning OFF→ON; ON→OFF
        // and OFF→OFF should never trigger a network check.
        applyToSparkle(triggerBackgroundCheck: newValue && wasOff)
      }
    )
  }

  private var automaticDownloadsBinding: Binding<Bool> {
    Binding(
      get: { general.updatesAutomaticallyDownloadUpdates },
      set: { newValue in
        settingsStore.setUpdatesAutomaticallyDownloadUpdates(newValue)
        applyToSparkle(triggerBackgroundCheck: false)
      }
    )
  }

  var body: some View {
    Form {
      channelSection
      cadenceSection
      automaticSection
      manualSection
      feedSection
    }
    .formStyle(.grouped)
    .task {
      // Capture once on appear — Sparkle owns these strings and doesn't
      // emit change notifications on a hot reconfigure.
      let updater = UpdatesEnvironment.updater
      lastCheckedAt = updater.lastUpdateCheckDate
      feedURL = updater.feedURL
    }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      lastCheckedAt = UpdatesEnvironment.updater.lastUpdateCheckDate
    }
  }

  // MARK: - Sections

  @ViewBuilder
  private var channelSection: some View {
    Section {
      Picker(selection: updateChannelBinding) {
        ForEach(UpdateChannel.allCases, id: \.self) { channel in
          Text(channel.title).tag(channel)
        }
      } label: {
        Text("Release channel")
        Text(general.updateChannel.subtitle)
      }
    }
  }

  @ViewBuilder
  private var cadenceSection: some View {
    Section {
      Picker(selection: updateCheckIntervalBinding) {
        ForEach(UpdateCheckInterval.allCases, id: \.self) { interval in
          Text(interval.title).tag(interval)
        }
      } label: {
        Text("Check interval")
        Text("How often the app polls for new builds in the background.")
      }
    }
  }

  @ViewBuilder
  private var automaticSection: some View {
    Section("Automatic updates") {
      Toggle(isOn: automaticChecksBinding) {
        Text("Check for updates automatically")
        Text("Polls in the background while running.")
      }
      Toggle(isOn: automaticDownloadsBinding) {
        Text("Download and install in the background")
        Text("Installs on next relaunch.")
      }
      .disabled(!general.updatesAutomaticallyCheckForUpdates)
    }
  }

  @ViewBuilder
  private var manualSection: some View {
    Section("Manual check") {
      HStack(alignment: .firstTextBaseline) {
        Button("Check for Updates…") {
          updatesClient.checkNow()
          // Sparkle stamps lastUpdateCheckDate after the request completes;
          // re-read after a short delay so the relative-time label
          // refreshes without forcing the user to leave + reopen the pane.
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            lastCheckedAt = UpdatesEnvironment.updater.lastUpdateCheckDate
          }
        }
        .disabled(!UpdatesEnvironment.updater.canCheckForUpdates)
        .commandKeyHint(.checkForUpdates)
        .helpWithShortcut("Check for Updates", .checkForUpdates)
        Spacer()
        Text(lastCheckedLabel)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private var feedSection: some View {
    #if DEBUG
      if let feedURL {
        Section("Feed") {
          LabeledContent("Appcast URL") {
            Text(feedURL.absoluteString)
              .font(.callout.monospaced())
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
              .lineLimit(2)
              .truncationMode(.middle)
          }
        }
      }
    #endif
  }

  // MARK: - Helpers

  private func applyToSparkle(triggerBackgroundCheck: Bool) {
    let g = settingsStore.settings.general
    updatesClient.applyPreferences(
      g.updateChannel,
      g.updateCheckInterval,
      g.updatesAutomaticallyCheckForUpdates,
      g.updatesAutomaticallyDownloadUpdates,
      triggerBackgroundCheck
    )
  }

  private var lastCheckedLabel: String {
    guard let lastCheckedAt else { return "Never checked" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return "Last checked \(formatter.localizedString(for: lastCheckedAt, relativeTo: Date()))"
  }
}

extension UpdateChannel {
  /// Display name shown in the channel `Picker` row.
  fileprivate var title: String {
    switch self {
    case .stable: return "Stable"
    case .tip: return "Tip"
    }
  }

  /// Sub-label rendered below the picker so the difference between the
  /// channels is visible without opening release notes.
  fileprivate var subtitle: String {
    switch self {
    case .stable: return "Released versions."
    case .tip: return "Pre-release builds."
    }
  }
}

extension UpdateCheckInterval {
  /// Display label rendered inside the cadence picker. Singular "hour" only at 1 (not used
  /// here — smallest case is 3) keeps the formatter dumb; days are spelled out separately so
  /// `oneDay` reads naturally rather than as "24 hours".
  fileprivate var title: String {
    switch self {
    case .threeHours: return "3 hours"
    case .sixHours: return "6 hours"
    case .twelveHours: return "12 hours"
    case .oneDay: return "Daily (24 hours)"
    case .twoDays: return "Every 2 days (48 hours)"
    case .threeDays: return "Every 3 days (72 hours)"
    }
  }
}

#Preview {
  UpdatesSettingsView()
    .frame(width: 600, height: 500)
}
