// The keyboard, IME and mouse handling here is adapted from Ghostty's
// macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift and
// NSEvent+Extension.swift (MIT License, Copyright (c) 2024 Mitchell Hashimoto,
// Ghostty contributors).

import AppKit
import GhosttyKit

/// How a terminal starts.
struct TerminalLaunch {
  var command: String
  var workingDirectory: String
  var environment: [String: String]
  /// Typed into the terminal once it starts.
  var initialInput: String?
}

/// One terminal: a view libghostty draws into with Metal, and the plumbing
/// that hands it AppKit's keyboard, IME and mouse events.
@MainActor
final class TerminalView: NSView, @preconcurrency NSTextInputClient {
  private(set) var surface: ghostty_surface_t?
  /// What the terminal asks for: Ghostty keybinds, its title, closing.
  var onCommand: ((TerminalCommand) -> Void)?
  /// Called when the terminal gets the keyboard.
  var onFocus: (() -> Void)?

  private var markedText = NSMutableAttributedString()
  /// Non-nil while a keyDown is being interpreted: text AppKit inserts then.
  private var keyTextAccumulator: [String]?

  private static var live: [UInt: WeakTerminal] = [:]

  /// The view at a surface's userdata address, if it still exists.
  static func live(at pointer: UnsafeRawPointer) -> TerminalView? {
    live[UInt(bitPattern: pointer)]?.view
  }

  init?(app: ghostty_app_t, launch: TerminalLaunch) {
    super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

    var owned: [UnsafeMutablePointer<CChar>] = []
    defer { owned.forEach { free($0) } }
    func cString(_ s: String) -> UnsafePointer<CChar> {
      let pointer = strdup(s)!
      owned.append(pointer)
      return UnsafePointer(pointer)
    }

    let me = Unmanaged.passUnretained(self).toOpaque()
    var config = ghostty_surface_config_new()
    config.userdata = me
    config.platform_tag = GHOSTTY_PLATFORM_MACOS
    config.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(nsview: me))
    config.scale_factor = Double(NSScreen.main?.backingScaleFactor ?? 2)
    config.font_size = 0
    config.wait_after_command = false
    config.context = GHOSTTY_SURFACE_CONTEXT_WINDOW
    config.command = cString(launch.command)
    config.working_directory = cString(launch.workingDirectory)
    config.initial_input = launch.initialInput.map(cString)

    var env = launch.environment.map { ghostty_env_var_s(key: cString($0.key), value: cString($0.value)) }
    let created = env.withUnsafeMutableBufferPointer { buffer in
      config.env_vars = buffer.baseAddress
      config.env_var_count = buffer.count
      return ghostty_surface_new(app, &config)
    }
    guard let created else { return nil }
    surface = created
    Self.live[UInt(bitPattern: me)] = WeakTerminal(view: self)
    updateTrackingAreas()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("not used") }

  /// Frees the surface. The process inside lives on in its zmx session.
  func destroy() {
    Self.live[UInt(bitPattern: Unmanaged.passUnretained(self).toOpaque())] = nil
    if let surface { ghostty_surface_free(surface) }
    surface = nil
    removeFromSuperview()
  }

  func perform(_ command: TerminalCommand) {
    onCommand?(command)
  }

  /// A hidden terminal stops drawing; its process keeps running.
  func setVisible(_ visible: Bool) {
    if let surface { ghostty_surface_set_occlusion(surface, visible) }
  }

  private var focusWhenShown = false

  /// Gives the terminal the keyboard, now or once it's on screen.
  func focus() {
    if let window {
      window.makeFirstResponder(self)
    } else {
      focusWhenShown = true
    }
  }

  // MARK: Sizing

  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    updateSurfaceSize()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    updateContentScale()
    updateSurfaceSize()
    if focusWhenShown, let window {
      focusWhenShown = false
      window.makeFirstResponder(self)
    }
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    if let window {
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      layer?.contentsScale = window.backingScaleFactor
      CATransaction.commit()
    }
    updateContentScale()
    updateSurfaceSize()
  }

  private func updateContentScale() {
    guard let surface, frame.width > 0, frame.height > 0 else { return }
    let backing = convertToBacking(frame)
    ghostty_surface_set_content_scale(surface, backing.width / frame.width, backing.height / frame.height)
  }

  private func updateSurfaceSize() {
    guard let surface else { return }
    let size = convertToBacking(bounds.size)
    guard size.width >= 1, size.height >= 1 else { return }
    ghostty_surface_set_size(surface, UInt32(size.width), UInt32(size.height))
  }

  // MARK: Focus

  override var acceptsFirstResponder: Bool { true }

  override func becomeFirstResponder() -> Bool {
    let became = super.becomeFirstResponder()
    if became, let surface {
      ghostty_surface_set_focus(surface, true)
      onFocus?()
    }
    return became
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned, let surface { ghostty_surface_set_focus(surface, false) }
    return resigned
  }

  // MARK: Mouse

  override func updateTrackingAreas() {
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .activeAlways],
      owner: self))
    super.updateTrackingAreas()
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    mouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, event)
  }

  override func mouseUp(with event: NSEvent) {
    mouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, event)
    if let surface { ghostty_surface_mouse_pressure(surface, 0, 0) }
  }

  override func rightMouseDown(with event: NSEvent) {
    mouseButton(GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, event)
  }

  override func rightMouseUp(with event: NSEvent) {
    mouseButton(GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, event)
  }

  override func otherMouseDown(with event: NSEvent) {
    mouseButton(GHOSTTY_MOUSE_PRESS, otherButton(event), event)
  }

  override func otherMouseUp(with event: NSEvent) {
    mouseButton(GHOSTTY_MOUSE_RELEASE, otherButton(event), event)
  }

  override func mouseMoved(with event: NSEvent) {
    guard let surface else { return }
    let point = convert(event.locationInWindow, from: nil)
    // Ghostty's origin is the top left.
    ghostty_surface_mouse_pos(surface, point.x, frame.height - point.y, ghosttyMods(event.modifierFlags))
  }

  override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
  override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
  override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

  override func scrollWheel(with event: NSEvent) {
    guard let surface else { return }
    var x = event.scrollingDeltaX
    var y = event.scrollingDeltaY
    let precise = event.hasPreciseScrollingDeltas
    if precise {
      x *= 2
      y *= 2
    }
    // Bit 0: precise scrolling; bits 1-3: the momentum phase.
    let mods = Int32(precise ? 1 : 0) | (momentum(event.momentumPhase) << 1)
    ghostty_surface_mouse_scroll(surface, x, y, mods)
  }

  private func mouseButton(
    _ state: ghostty_input_mouse_state_e, _ button: ghostty_input_mouse_button_e, _ event: NSEvent
  ) {
    guard let surface else { return }
    _ = ghostty_surface_mouse_button(surface, state, button, ghosttyMods(event.modifierFlags))
  }

  private func otherButton(_ event: NSEvent) -> ghostty_input_mouse_button_e {
    switch event.buttonNumber {
    case 2: GHOSTTY_MOUSE_MIDDLE
    case 3: GHOSTTY_MOUSE_FOUR
    case 4: GHOSTTY_MOUSE_FIVE
    default: GHOSTTY_MOUSE_UNKNOWN
    }
  }

  private func momentum(_ phase: NSEvent.Phase) -> Int32 {
    switch phase {
    case .began: 1
    case .stationary: 2
    case .changed: 3
    case .ended: 4
    case .cancelled: 5
    case .mayBegin: 6
    default: 0
    }
  }

  // MARK: Keyboard

  override func keyDown(with event: NSEvent) {
    guard let surface else {
      interpretKeyEvents([event])
      return
    }

    let translation = translationEvent(for: event, surface: surface)
    let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

    // interpretKeyEvents routes through the input method (accents, CJK...),
    // which hands committed text back through insertText.
    keyTextAccumulator = []
    defer { keyTextAccumulator = nil }
    let hadMarkedText = markedText.length > 0
    interpretKeyEvents([translation])
    syncPreedit(clearIfNeeded: hadMarkedText)
    let composing = markedText.length > 0 || hadMarkedText

    if let texts = keyTextAccumulator, !texts.isEmpty {
      for text in texts {
        _ = keyAction(action, event: event, translation: translation, text: text)
      }
    } else {
      _ = keyAction(action, event: event, translation: translation, text: translation.ghosttyCharacters, composing: composing)
    }
  }

  override func keyUp(with event: NSEvent) {
    _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
  }

  override func flagsChanged(with event: NSEvent) {
    let mod: UInt32
    switch event.keyCode {
    case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
    case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
    case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
    case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
    case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
    default: return
    }
    if hasMarkedText() { return }

    var action = GHOSTTY_ACTION_RELEASE
    if ghosttyMods(event.modifierFlags).rawValue & mod != 0 {
      // Pressed, unless it's the other side's key that's still held.
      let raw = event.modifierFlags.rawValue
      let sidePressed: Bool
      switch event.keyCode {
      case 0x3C: sidePressed = raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0
      case 0x3E: sidePressed = raw & UInt(NX_DEVICERCTLKEYMASK) != 0
      case 0x3D: sidePressed = raw & UInt(NX_DEVICERALTKEYMASK) != 0
      case 0x36: sidePressed = raw & UInt(NX_DEVICERCMDKEYMASK) != 0
      default: sidePressed = true
      }
      if sidePressed { action = GHOSTTY_ACTION_PRESS }
    }
    _ = keyAction(action, event: event)
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard event.type == .keyDown, window?.firstResponder === self, let surface else { return false }

    // Yatty's menus (⌘N, ⌘O, ⌘Q, Edit's ⌘C / ⌘V...) win over terminal keybinds.
    if event.modifierFlags.contains(.command), NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
      return true
    }

    var key = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
    var flags = ghostty_binding_flags_e(0)
    let isBinding = (event.characters ?? "").withCString { pointer in
      key.text = pointer
      return ghostty_surface_key_is_binding(surface, key, &flags)
    }
    if isBinding {
      keyDown(with: event)
      return true
    }

    // AppKit would otherwise eat ctrl+return and beep at ctrl+/.
    if event.modifierFlags.contains(.control), ["\r", "/"].contains(event.charactersIgnoringModifiers ?? "") {
      keyDown(with: event)
      return true
    }
    return false
  }

  /// The event with the modifiers Ghostty translates characters with, so
  /// macos-option-as-alt is honoured.
  private func translationEvent(for event: NSEvent, surface: ghostty_surface_t) -> NSEvent {
    let translated = eventFlags(ghostty_surface_key_translation_mods(surface, ghosttyMods(event.modifierFlags)))
    var mods = event.modifierFlags
    for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
      if translated.contains(flag) { mods.insert(flag) } else { mods.remove(flag) }
    }
    // Reuse the original event when nothing changed: input methods rely on it.
    if mods == event.modifierFlags { return event }
    return NSEvent.keyEvent(
      with: event.type,
      location: event.locationInWindow,
      modifierFlags: mods,
      timestamp: event.timestamp,
      windowNumber: event.windowNumber,
      context: nil,
      characters: event.characters(byApplyingModifiers: mods) ?? "",
      charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
      isARepeat: event.isARepeat,
      keyCode: event.keyCode) ?? event
  }

  private func keyAction(
    _ action: ghostty_input_action_e, event: NSEvent, translation: NSEvent? = nil,
    text: String? = nil, composing: Bool = false
  ) -> Bool {
    guard let surface else { return false }
    var key = event.ghosttyKeyEvent(action, translationMods: translation?.modifierFlags)
    key.composing = composing
    // Control characters are encoded by Ghostty itself, from the key.
    if let text, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7F {
      return text.withCString { pointer in
        key.text = pointer
        return ghostty_surface_key(surface, key)
      }
    }
    return ghostty_surface_key(surface, key)
  }

  private func syncPreedit(clearIfNeeded: Bool = true) {
    guard let surface else { return }
    if markedText.length > 0 {
      let string = markedText.string
      string.withCString { pointer in
        ghostty_surface_preedit(surface, pointer, UInt(string.utf8.count))
      }
    } else if clearIfNeeded {
      ghostty_surface_preedit(surface, nil, 0)
    }
  }

  // MARK: Edit menu

  @objc func copy(_ sender: Any?) { performBinding("copy_to_clipboard") }
  @objc func paste(_ sender: Any?) { performBinding("paste_from_clipboard") }

  private func performBinding(_ action: String) {
    guard let surface else { return }
    _ = ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
  }

  /// Hands clipboard text to a read Ghostty started; nil text refuses it.
  func completeClipboardRead(state: UnsafeMutableRawPointer, text: String?, confirmed: Bool) {
    guard let surface else { return }
    guard let text, !text.isEmpty else {
      ghostty_surface_deny_clipboard_request(surface, state)
      return
    }
    let data = Array(text.utf8)
    "text/plain".withCString { mime in
      data.withUnsafeBufferPointer { bytes in
        bytes.withMemoryRebound(to: CChar.self) { chars in
          var content = ghostty_clipboard_content_s(mime: mime, data: chars.baseAddress!, len: chars.count)
          withUnsafePointer(to: &content) { contents in
            var complete = ghostty_clipboard_complete_s(
              contents: contents, contents_len: 1, available: nil, available_len: 0,
              confirmed: confirmed, remember: false)
            ghostty_surface_complete_clipboard_request(surface, &complete, state)
          }
        }
      }
    }
  }

  // MARK: NSTextInputClient

  func insertText(_ string: Any, replacementRange: NSRange) {
    guard NSApp.currentEvent != nil else { return }
    let chars = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    unmarkText()

    if keyTextAccumulator != nil {
      keyTextAccumulator?.append(chars)
      return
    }

    // Committed outside a key event (dictation, an input method): typed input.
    guard let surface, !chars.isEmpty else { return }
    var key = ghostty_input_key_s()
    key.action = GHOSTTY_ACTION_PRESS
    key.mods = GHOSTTY_MODS_NONE
    key.consumed_mods = GHOSTTY_MODS_NONE
    chars.withCString { pointer in
      key.text = pointer
      _ = ghostty_surface_key(surface, key)
    }
  }

  override func doCommand(by selector: Selector) {
    // Keys AppKit maps to commands (arrows, delete...) were already sent in keyDown.
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if let attributed = string as? NSAttributedString {
      markedText = NSMutableAttributedString(attributedString: attributed)
    } else if let plain = string as? String {
      markedText = NSMutableAttributedString(string: plain)
    }
    if keyTextAccumulator == nil { syncPreedit() }
  }

  func unmarkText() {
    guard markedText.length > 0 else { return }
    markedText.mutableString.setString("")
    syncPreedit()
  }

  func hasMarkedText() -> Bool { markedText.length > 0 }

  func markedRange() -> NSRange {
    markedText.length > 0 ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0)
  }

  func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

  func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
    nil
  }

  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  /// Where the input method's candidate window goes: at the cursor.
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    guard let surface else { return .zero }
    var x = 0.0, y = 0.0, width = 0.0, height = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    let rect = NSRect(x: x, y: frame.height - y, width: width, height: max(height, 1))
    let inWindow = convert(rect, to: nil)
    return window?.convertToScreen(inWindow) ?? inWindow
  }
}

private struct WeakTerminal {
  weak var view: TerminalView?
}

// MARK: Event translation

func ghosttyMods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
  var mods = GHOSTTY_MODS_NONE.rawValue
  if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
  if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
  if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
  if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
  if flags.contains(.capsLock) { mods |= GHOSTTY_MODS_CAPS.rawValue }
  let raw = flags.rawValue
  if raw & UInt(NX_DEVICERSHIFTKEYMASK) != 0 { mods |= GHOSTTY_MODS_SHIFT_RIGHT.rawValue }
  if raw & UInt(NX_DEVICERCTLKEYMASK) != 0 { mods |= GHOSTTY_MODS_CTRL_RIGHT.rawValue }
  if raw & UInt(NX_DEVICERALTKEYMASK) != 0 { mods |= GHOSTTY_MODS_ALT_RIGHT.rawValue }
  if raw & UInt(NX_DEVICERCMDKEYMASK) != 0 { mods |= GHOSTTY_MODS_SUPER_RIGHT.rawValue }
  return ghostty_input_mods_e(mods)
}

func eventFlags(_ mods: ghostty_input_mods_e) -> NSEvent.ModifierFlags {
  var flags = NSEvent.ModifierFlags()
  if mods.rawValue & GHOSTTY_MODS_SHIFT.rawValue != 0 { flags.insert(.shift) }
  if mods.rawValue & GHOSTTY_MODS_CTRL.rawValue != 0 { flags.insert(.control) }
  if mods.rawValue & GHOSTTY_MODS_ALT.rawValue != 0 { flags.insert(.option) }
  if mods.rawValue & GHOSTTY_MODS_SUPER.rawValue != 0 { flags.insert(.command) }
  return flags
}

extension NSEvent {
  /// A Ghostty key event, without text: its C string can't outlive the call.
  func ghosttyKeyEvent(_ action: ghostty_input_action_e, translationMods: NSEvent.ModifierFlags? = nil)
    -> ghostty_input_key_s
  {
    var key = ghostty_input_key_s()
    key.action = action
    key.keycode = UInt32(keyCode)
    key.text = nil
    key.composing = false
    key.mods = ghosttyMods(modifierFlags)
    // Control and command never produce text; assume the rest did.
    key.consumed_mods = ghosttyMods((translationMods ?? modifierFlags).subtracting([.control, .command]))
    key.unshifted_codepoint = 0
    if type == .keyDown || type == .keyUp,
      let scalar = characters(byApplyingModifiers: [])?.unicodeScalars.first
    {
      key.unshifted_codepoint = scalar.value
    }
    return key
  }

  /// The text to send with a key: no control characters (Ghostty encodes
  /// those itself) and no function-key private-use characters.
  var ghosttyCharacters: String? {
    guard let characters else { return nil }
    if characters.count == 1, let scalar = characters.unicodeScalars.first {
      if scalar.value < 0x20 { return self.characters(byApplyingModifiers: modifierFlags.subtracting(.control)) }
      if scalar.value >= 0xF700 && scalar.value <= 0xF8FF { return nil }
    }
    return characters
  }
}
