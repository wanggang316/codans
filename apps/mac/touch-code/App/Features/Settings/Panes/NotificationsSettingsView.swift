import AppKit
import SwiftUI
import TouchCodeCore
@preconcurrency import UserNotifications

/// Settings → Notifications pane (v1.1). Surfaces every user-visible knob
/// consumed by `NotificationCoordinator` plus the v1.0 macOS authorization
/// recovery surface:
///
/// 1. Three sections by surface (`In-app`, `System`, `Command Finished`).
///    Each parent toggle has an action-oriented label ("Show in this app",
///    "Show macOS banners", "Notify when a command finishes") rather than
///    a noun phrase that would duplicate the section title.
///    - In-app section gates every surface inside the app: bell popover,
///      Dock badge, and the unread roll-up counts on projects, worktrees,
///      tabs, and panes. Implementation: when off, no entries reach the
///      inbox, so RollupIndex naturally reports 0 across the hierarchy.
///      The Dock badge child auto-disables when the parent is off; it
///      exists so users can suppress just the icon overlay while keeping
///      in-window roll-up badges visible.
///    - System section gates macOS banner + Notification Center entries.
///      The Sound child auto-disables when the parent is off. Below the
///      toggles, a conditional permission row appears ONLY when System
///      is enabled and the OS-level permission is not yet authorized —
///      otherwise the section ends at the toggles. The permission is
///      a System-only dependency (it controls UNNotification posting,
///      nothing else), so it lives inside this section rather than as
///      a separate concept.
///    Writes go through `SettingsStore.mutateNotifications(_:)`, which the
///    coordinator reads via `NotificationSettingsReader` at decision time —
///    every flip therefore takes effect on the next event.
/// 2. Command-finished detector — master toggle plus the minimum-duration
///    threshold. The threshold field clamps writes to
///    `NotificationsSettings.thresholdRange` so hand-typed extremes never
///    reach the persisted JSON.
///
/// Permission alert (D1 in the v1.1 design doc): flipping System notifications
/// on while macOS authorization is `.denied` shows an alert that deep-links
/// into System Settings. The toggle's persisted value is preserved regardless
/// of the user's alert choice — we only inform; we don't roll back state.
///
/// Authorization is re-read on every appear and on `applicationDidBecomeActive`
/// so a flip in System Settings takes effect without a relaunch.
///
/// The Mute rules section is intentionally absent until the rule editor
/// lands; the underlying `NotificationsSettings.mute` fields persist but
/// nothing currently writes them (per-pane mute uses `Pane.labels` directly
/// — see `PaneContextMenu`).
struct NotificationsSettingsView: View {
  @Environment(SettingsStore.self) private var settingsStore
  @Environment(UserNotificationsOSNotifier.self) private var osNotifier: UserNotificationsOSNotifier?
  @State private var status: AuthorizationStatus = .notDetermined
  @State private var isRefreshing = false
  @State private var showPermissionAlert = false

  var body: some View {
    Form {
      Section("In-app") {
        Toggle("Show status-bar bell", isOn: statusBarBellBinding)
        Toggle("Show project-level bell", isOn: projectBellBinding)
        Toggle("Show worktree-level bell", isOn: worktreeBellBinding)
        Toggle("Show tab-level bell", isOn: tabBellBinding)
        Toggle("Show Dock badge", isOn: dockBadgeBinding)
      }

      Section("System") {
        Toggle(isOn: systemBinding) {
          SettingLabel(
            title: "Show macOS banners",
            caption: "Show banners in macOS Notification Center."
          )
        }

        Toggle("Play sound", isOn: soundBinding)
          .disabled(!settingsStore.settings.notifications.systemEnabled)
          .help("Requires Show macOS banners to be on.")

        // macOS authorization gates the banner regardless of the toggle
        // above. Only surface it when actionable — when System is enabled
        // and the OS-level permission is not authorized. When authorized
        // we trust silence; when off the permission is irrelevant.
        if settingsStore.settings.notifications.systemEnabled && status != .authorized {
          permissionWarningRow
        }
      }

      Section("Command Finished") {
        Toggle(isOn: commandFinishedBinding) {
          SettingLabel(
            title: "Notify when a command finishes",
            caption: "Commands shorter than the minimum duration are silent. Cancelled "
              + "commands (Ctrl-C) are always silent. Notifications are also suppressed for "
              + "1 second after you type in the pane."
          )
        }

        HStack {
          Text("Minimum duration")
          Spacer()
          TextField("", value: thresholdBinding, format: .number)
            .textFieldStyle(.plain)
            .multilineTextAlignment(.trailing)
            .frame(width: 48)
            .disabled(!settingsStore.settings.notifications.commandFinishedEnabled)
          Text("seconds")
            .foregroundStyle(.secondary)
        }
      }

    }
    .formStyle(.grouped)
    .alert("Notifications are blocked", isPresented: $showPermissionAlert) {
      Button("Open System Settings…") { openSystemNotificationsPane() }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(
        "macOS is currently blocking notifications for TouchCode. "
          + "Open System Settings to allow them."
      )
    }
    .task { await refresh() }
    .onReceive(
      NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
    ) { _ in
      Task { await refresh() }
    }
  }

  // MARK: - Bindings

  // `inAppEnabled` is intentionally not surfaced — it stays at its default-on
  // value and gates `inbox.append` inside the coordinator. The per-level
  // bell toggles below are visual-only filters on the always-computed
  // `RollupIndex` data; they hide the indicator at a given level without
  // touching the inbox itself.

  private var systemBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.systemEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.systemEnabled = newValue }
        // D1 — when the user enables System notifications while macOS has
        // already denied authorization, the toggle alone has no runtime
        // effect. Surface the alert so they know to flip the OS-level switch
        // too. The persisted value is intentionally NOT rolled back; the
        // setting reflects user intent, the alert reflects current reality.
        guard newValue, let notifier = osNotifier else { return }
        Task {
          let current = await notifier.currentAuthorizationStatus()
          if current == .denied {
            showPermissionAlert = true
          }
        }
      }
    )
  }

  private var soundBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.soundEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.soundEnabled = newValue }
      }
    )
  }

  private var dockBadgeBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.dockBadgeEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.dockBadgeEnabled = newValue }
      }
    )
  }

  private var statusBarBellBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.statusBarBellEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.statusBarBellEnabled = newValue }
      }
    )
  }

  private var projectBellBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.projectBellEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.projectBellEnabled = newValue }
      }
    )
  }

  private var worktreeBellBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.worktreeBellEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.worktreeBellEnabled = newValue }
      }
    )
  }

  private var tabBellBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.tabBellEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.tabBellEnabled = newValue }
      }
    )
  }

  private var commandFinishedBinding: Binding<Bool> {
    Binding(
      get: { settingsStore.settings.notifications.commandFinishedEnabled },
      set: { newValue in
        settingsStore.mutateNotifications { $0.commandFinishedEnabled = newValue }
      }
    )
  }

  /// Threshold binding that clamps writes to `NotificationsSettings.thresholdRange`
  /// before persistence so a hand-typed `0` or `99999` never reaches `settings.json`.
  /// `get` returns the stored value verbatim — clamping on read would mask
  /// any drift introduced by other writers.
  private var thresholdBinding: Binding<Int> {
    Binding(
      get: { settingsStore.settings.notifications.commandFinishedThresholdSec },
      set: { newValue in
        let range = NotificationsSettings.thresholdRange
        let clamped = max(range.lowerBound, min(range.upperBound, newValue))
        settingsStore.mutateNotifications { $0.commandFinishedThresholdSec = clamped }
      }
    )
  }

  /// Deep-links into System Settings → Notifications → touch-code if the
  /// per-app anchor is supported; otherwise falls back to the top-level
  /// Notifications pane. The fallback covers older macOS releases and the
  /// rare case where `NSWorkspace.open` declines the anchored URL.
  private func openSystemNotificationsPane() {
    let bundleID = Bundle.main.bundleIdentifier ?? "com.gumpw.touch-agent-mac"
    let withID = URL(string: "x-apple.systempreferences:com.apple.preference.notifications?id=\(bundleID)")
    let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
    if let withID, NSWorkspace.shared.open(withID) { return }
    NSWorkspace.shared.open(fallback)
  }

  // MARK: - Permission warning row (System section, conditional)

  /// Single row that appears beneath the System toggles only when the OS
  /// permission is in a state the user can act on (denied / notDetermined)
  /// AND System notifications are enabled. When authorized we render
  /// nothing — the absence is the signal that things are healthy. When
  /// System is off the permission is irrelevant to current behaviour.
  @ViewBuilder
  private var permissionWarningRow: some View {
    HStack(spacing: 8) {
      Image(systemName: status == .denied ? "exclamationmark.triangle.fill" : "questionmark.circle.fill")
        .foregroundStyle(status == .denied ? Color.orange : Color.yellow)
      Text(
        status == .denied
          ? "macOS is blocking notifications for TouchCode."
          : "macOS has not yet been asked for permission."
      )
      .foregroundStyle(.secondary)
      Spacer()
      if isRefreshing {
        ProgressView().controlSize(.small)
      }
      switch status {
      case .denied:
        Button("Open System Settings…") { openSystemNotificationsPane() }
      case .notDetermined:
        Button("Request…") {
          Task {
            guard let notifier = osNotifier else { return }
            status = await notifier.requestAuthorization()
          }
        }
        .disabled(osNotifier == nil)
      case .authorized:
        EmptyView()
      }
    }
  }

  // MARK: - State

  private func refresh() async {
    guard let notifier = osNotifier else { return }
    isRefreshing = true
    status = await notifier.currentAuthorizationStatus()
    isRefreshing = false
  }
}

/// Title + secondary caption that fits inside a `Toggle`'s label slot so
/// the caption rides on the same Form row as its control instead of being
/// rendered as a separate row (which would force a divider between them).
private struct SettingLabel: View {
  let title: String
  let caption: String

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
      Text(caption)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
