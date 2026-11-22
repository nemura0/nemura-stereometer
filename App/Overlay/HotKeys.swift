import AppKit
import Carbon.HIToolbox
import os

/// The app's global hotkeys (⌃⌥⌘S click-through, ⌃⌥⌘H show/hide), through Carbon's
/// RegisterEventHotKey, which needs no Accessibility permission. Handlers run on the main thread.
///
/// The Carbon handler holds an unretained reference to this object; the registration it owns
/// removes the handler and the hotkeys when this object goes away.
@MainActor
final class HotKeys {
  enum Action: UInt32, CaseIterable, Sendable {
    case toggleClickThrough = 1
    case toggleShown = 2

    var keyCode: UInt32 {
      switch self {
      case .toggleClickThrough: UInt32(kVK_ANSI_S)
      case .toggleShown: UInt32(kVK_ANSI_H)
      }
    }

    /// For menus: the shortcut as it appears there.
    /// How menus write it: "⌃⌥⌘S".
    var shortcut: String { "⌃⌥⌘" + keyEquivalent.uppercased() }

    var keyEquivalent: String {
      switch self {
      case .toggleClickThrough: "s"
      case .toggleShown: "h"
      }
    }

    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let menuModifiers: NSEvent.ModifierFlags = [.control, .option, .command]
  }

  private static let signature: OSType = 0x4E4D_5253  // 'NMRS'
  private static let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "app", category: "hotkeys")

  private let carbon = CarbonRegistration()
  private var handlers: [Action: @MainActor () -> Void] = [:]
  /// The actions whose shortcut is registered now.
  var registered: Set<Action> { Set(carbon.references.keys) }

  /// False (and logged) when the shortcut is taken by another app or cannot be registered.
  func register(_ action: Action, _ handler: @escaping @MainActor () -> Void) -> Bool {
    guard installEventHandler() else { return false }
    carbon.unregister(action)
    var reference: EventHotKeyRef?
    let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
    let status = RegisterEventHotKey(
      action.keyCode, Action.modifiers, id, GetApplicationEventTarget(), 0, &reference)
    guard status == noErr, let reference else {
      Self.log.error("hotkey \(action.rawValue) could not be registered: \(status)")
      return false
    }
    carbon.references[action] = reference
    handlers[action] = handler
    return true
  }

  func unregisterAll() {
    carbon.removeAll()
    handlers = [:]
  }

  private func installEventHandler() -> Bool {
    if carbon.eventHandler != nil { return true }
    var pressed = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    let context = Unmanaged.passUnretained(self).toOpaque()
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      { _, event, context in
        guard let event, let context else { return OSStatus(eventNotHandledErr) }
        var id = EventHotKeyID()
        let status = GetEventParameter(
          event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
          MemoryLayout<EventHotKeyID>.size, nil, &id)
        guard status == noErr else { return status }
        let keys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
        // Carbon delivers application events on the main thread.
        return MainActor.assumeIsolated { keys.fire(id) }
      }, 1, &pressed, context, &carbon.eventHandler)
    if status != noErr {
      Self.log.error("the hotkey handler could not be installed: \(status)")
      carbon.eventHandler = nil
    }
    return status == noErr
  }

  private func fire(_ id: EventHotKeyID) -> OSStatus {
    guard id.signature == Self.signature, let action = Action(rawValue: id.id),
      let handler = handlers[action]
    else { return OSStatus(eventNotHandledErr) }
    handler()
    return noErr
  }
}

/// The Carbon objects behind HotKeys, released in deinit so a dropped HotKeys leaves no handler
/// pointing at freed memory. Main thread only, like HotKeys.
private final class CarbonRegistration {
  var references: [HotKeys.Action: EventHotKeyRef] = [:]
  var eventHandler: EventHandlerRef?

  func unregister(_ action: HotKeys.Action) {
    if let reference = references.removeValue(forKey: action) { UnregisterEventHotKey(reference) }
  }

  func removeAll() {
    for reference in references.values { UnregisterEventHotKey(reference) }
    references = [:]
    if let eventHandler { RemoveEventHandler(eventHandler) }
    eventHandler = nil
  }

  deinit { removeAll() }
}
