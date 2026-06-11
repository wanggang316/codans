import AppKit
import Carbon.HIToolbox
import os

/// Global hotkey wrapper that dispatches a single chord to a callback.
///
/// Implementation uses Carbon's `RegisterEventHotKey` because (a) it works
/// system-wide regardless of which app is frontmost, (b) it consumes the
/// event so the chord doesn't leak to whichever app currently holds focus,
/// and (c) it does not require Accessibility permission. The chord is
/// hard-coded to ⌥⌘\` for v1 (see ExecPlan Decision Log D3).
@MainActor
final class MasterTerminalHotkey {
  // `nonisolated(unsafe)` because deinit on a @MainActor class is nonisolated
  // in Swift 6 yet must release the Carbon refs. Single-writer (init/deinit
  // only) and pointer-typed, so the unsafe carve-out is sound.
  private nonisolated(unsafe) var hotKeyRef: EventHotKeyRef?
  private nonisolated(unsafe) var eventHandlerRef: EventHandlerRef?
  /// Held as a property on `self` so the C handler can reach it via
  /// `Unmanaged.passUnretained(...).toOpaque()` (see `init` below). The
  /// strong reference here is what keeps the box alive for the handler's
  /// lifetime — do NOT switch to `Unmanaged.passRetained`, since `deinit`
  /// does not perform a matching `takeRetainedValue` release.
  private let callbackBox: CallbackBox

  init(onTrigger: @escaping @MainActor () -> Void) {
    self.callbackBox = CallbackBox(callback: onTrigger)

    let hotKeyID = EventHotKeyID(
      signature: Self.hotKeySignature,
      id: Self.hotKeyIdentifier
    )
    var hotKeyRef: EventHotKeyRef?
    let registerStatus = RegisterEventHotKey(
      UInt32(kVK_ANSI_Grave),
      UInt32(optionKey | cmdKey),
      hotKeyID,
      GetEventDispatcherTarget(),
      0,
      &hotKeyRef
    )
    if registerStatus != noErr {
      Logger.masterTerminal.error(
        "RegisterEventHotKey returned status \(registerStatus, privacy: .public); chord ⌥⌘` will not work"
      )
      return
    }
    self.hotKeyRef = hotKeyRef

    var eventType = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed)
    )
    var handlerRef: EventHandlerRef?
    let handlerStatus = InstallEventHandler(
      GetEventDispatcherTarget(),
      Self.eventHandler,
      1,
      &eventType,
      Unmanaged.passUnretained(callbackBox).toOpaque(),
      &handlerRef
    )
    if handlerStatus != noErr {
      Logger.masterTerminal.error(
        "InstallEventHandler returned status \(handlerStatus, privacy: .public); chord ⌥⌘` will not work"
      )
      if let registered = self.hotKeyRef {
        UnregisterEventHotKey(registered)
        self.hotKeyRef = nil
      }
      return
    }
    self.eventHandlerRef = handlerRef
  }

  deinit {
    if let handlerRef = eventHandlerRef {
      RemoveEventHandler(handlerRef)
    }
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
    }
  }

  // MARK: - Carbon glue

  /// Distinct signature so the four-char-code is identifiable in
  /// `EventHotKeyID` traces — `'tcMT'` = codans Master Terminal.
  private static let hotKeySignature: OSType = 0x74_63_4D_54  // 'tcMT'
  private static let hotKeyIdentifier: UInt32 = 1

  /// C-style event handler callback. Resolves the user data back to the
  /// `CallbackBox` and hops to the main actor to invoke the Swift closure.
  private static let eventHandler: EventHandlerUPP = { _, _, userData in
    guard let userData else { return noErr }
    let box = Unmanaged<CallbackBox>.fromOpaque(userData).takeUnretainedValue()
    Task { @MainActor in
      box.callback()
    }
    return noErr
  }

  private final class CallbackBox {
    let callback: @MainActor () -> Void
    init(callback: @escaping @MainActor () -> Void) { self.callback = callback }
  }
}
