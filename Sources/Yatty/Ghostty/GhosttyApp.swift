import AppKit
import GhosttyKit

/// The process-wide libghostty app: the user's Ghostty config, the runtime
/// callbacks libghostty calls into, and the tick that drives it.
@MainActor
final class GhosttyApp {
  static let shared = GhosttyApp()

  private(set) var app: ghostty_app_t?
  private var config: ghostty_config_t?

  private init() {
    guard let config = ghostty_config_new() else { return }
    // The user's own ~/.config/ghostty/config: fonts, theme, keybinds.
    ghostty_config_load_default_files(config)
    ghostty_config_load_recursive_files(config)
    ghostty_config_finalize(config)
    self.config = config

    var runtime = Self.runtimeConfig()
    app = ghostty_app_new(&runtime, config)
    if let app { ghostty_app_set_focus(app, NSApp.isActive) }

    let center = NotificationCenter.default
    center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { GhosttyApp.shared.setFocus(true) }
    }
    center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { GhosttyApp.shared.setFocus(false) }
    }
  }

  private func setFocus(_ focused: Bool) {
    if let app { ghostty_app_set_focus(app, focused) }
  }

  fileprivate func tick() {
    if let app { ghostty_app_tick(app) }
  }

  // MARK: Runtime callbacks. libghostty may call these off the main thread.

  /// Built outside the main actor: closures written in main-actor code get a
  /// runtime check that traps when libghostty calls them from its own threads.
  nonisolated private static func runtimeConfig() -> ghostty_runtime_config_s {
    ghostty_runtime_config_s(
      userdata: nil,
      supports_selection_clipboard: false,
      wakeup_cb: { _ in GhosttyApp.wakeup() },
      action_cb: { _, target, action in GhosttyApp.perform(action, on: target) },
      read_clipboard_cb: { userdata, location, state, _, _, _ in
        GhosttyApp.readClipboard(userdata: userdata, location: location, state: state)
      },
      confirm_read_clipboard_cb: { userdata, confirm, state, request in
        GhosttyApp.confirmReadClipboard(userdata: userdata, confirm: confirm, state: state, request: request)
      },
      write_clipboard_cb: { _, location, content, count, confirm in
        GhosttyApp.writeClipboard(location: location, content: content, count: count, confirm: confirm)
      },
      close_surface_cb: { userdata, processAlive in GhosttyApp.closeSurface(userdata: userdata, processAlive: processAlive) }
    )
  }

  nonisolated private static func wakeup() {
    DispatchQueue.main.async {
      MainActor.assumeIsolated { GhosttyApp.shared.tick() }
    }
  }

  nonisolated private static func perform(_ action: ghostty_action_s, on target: ghostty_target_s) -> Bool {
    switch action.tag {
    case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
      // libghostty keeps a terminal whose command exited open, waiting for a
      // key. In Yatty the pane closes, as a tmux pane did in agentree; a
      // remote one whose connection dropped waits to reconnect.
      return deliver(.childExited, to: target)
    case GHOSTTY_ACTION_NEW_TAB:
      return deliver(.newTab, to: target)
    case GHOSTTY_ACTION_TOGGLE_COMMAND_PALETTE:
      return deliver(.togglePalette, to: target)
    case GHOSTTY_ACTION_NEW_SPLIT:
      let command: TerminalCommand =
        switch action.action.new_split {
        case GHOSTTY_SPLIT_DIRECTION_LEFT: .split(.horizontal, newFirst: true)
        case GHOSTTY_SPLIT_DIRECTION_UP: .split(.vertical, newFirst: true)
        case GHOSTTY_SPLIT_DIRECTION_DOWN: .split(.vertical, newFirst: false)
        default: .split(.horizontal, newFirst: false)
        }
      return deliver(command, to: target)
    case GHOSTTY_ACTION_GOTO_SPLIT:
      let goto: GotoSplit =
        switch action.action.goto_split {
        case GHOSTTY_GOTO_SPLIT_PREVIOUS: .previous
        case GHOSTTY_GOTO_SPLIT_UP: .toward(.up)
        case GHOSTTY_GOTO_SPLIT_LEFT: .toward(.left)
        case GHOSTTY_GOTO_SPLIT_DOWN: .toward(.down)
        case GHOSTTY_GOTO_SPLIT_RIGHT: .toward(.right)
        default: .next
        }
      return deliver(.gotoSplit(goto), to: target)
    case GHOSTTY_ACTION_GOTO_TAB:
      let raw = action.action.goto_tab.rawValue
      let goto: GotoTab =
        switch raw {
        case GHOSTTY_GOTO_TAB_PREVIOUS.rawValue: .previous
        case GHOSTTY_GOTO_TAB_NEXT.rawValue: .next
        case GHOSTTY_GOTO_TAB_LAST.rawValue: .last
        default: .index(Int(raw))
        }
      return deliver(.gotoTab(goto), to: target)
    case GHOSTTY_ACTION_CLOSE_TAB:
      guard action.action.close_tab_mode == GHOSTTY_ACTION_CLOSE_TAB_MODE_THIS else { return false }
      return deliver(.closeTab, to: target)
    case GHOSTTY_ACTION_EQUALIZE_SPLITS:
      return deliver(.equalize, to: target)
    case GHOSTTY_ACTION_SET_TITLE:
      return deliver(.title(String(cString: action.action.set_title.title)), to: target)
    case GHOSTTY_ACTION_OPEN_URL:
      let payload = action.action.open_url
      let string = String(decoding: Data(bytes: payload.url, count: Int(payload.len)), as: UTF8.self)
      guard let url = URL(string: string).flatMap({ $0.scheme == nil ? nil : $0 })
        ?? (string.hasPrefix("/") ? URL(fileURLWithPath: string) : nil)
      else { return false }
      DispatchQueue.main.async { NSWorkspace.shared.open(url) }
      return true
    default:
      return false
    }
  }

  nonisolated private static func readClipboard(
    userdata: UnsafeMutableRawPointer?, location: ghostty_clipboard_e, state: UnsafeMutableRawPointer?
  ) -> ghostty_clipboard_read_result_e {
    guard location == GHOSTTY_CLIPBOARD_STANDARD, let view = TerminalRef(userdata), let state else {
      return GHOSTTY_CLIPBOARD_READ_UNSUPPORTED
    }
    let request = UInt(bitPattern: state)
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        view.resolve()?.completeClipboardRead(
          state: UnsafeMutableRawPointer(bitPattern: request)!,
          text: NSPasteboard.general.string(forType: .string),
          confirmed: false)
      }
    }
    return GHOSTTY_CLIPBOARD_READ_STARTED
  }

  /// Ghostty asks before an unsafe paste (newlines, say) or a program reading
  /// the clipboard (OSC 52). For now a paste the user started goes through and
  /// programs are refused.
  nonisolated private static func confirmReadClipboard(
    userdata: UnsafeMutableRawPointer?,
    confirm: UnsafePointer<ghostty_clipboard_confirm_s>?,
    state: UnsafeMutableRawPointer?,
    request: ghostty_clipboard_request_e
  ) {
    guard let view = TerminalRef(userdata), let state else { return }
    var text: String?
    if request == GHOSTTY_CLIPBOARD_REQUEST_PASTE, let confirm {
      text = plainText(confirm.pointee.contents, count: confirm.pointee.contents_len)
    }
    let pending = UInt(bitPattern: state)
    let paste = text
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        view.resolve()?.completeClipboardRead(
          state: UnsafeMutableRawPointer(bitPattern: pending)!, text: paste, confirmed: true)
      }
    }
  }

  nonisolated private static func writeClipboard(
    location: ghostty_clipboard_e,
    content: UnsafePointer<ghostty_clipboard_content_s>?,
    count: Int,
    confirm: Bool
  ) {
    // A program writing the clipboard when the config says to ask: refused for now.
    guard location == GHOSTTY_CLIPBOARD_STANDARD, !confirm,
      let text = plainText(content, count: count)
    else { return }
    DispatchQueue.main.async {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }
  }

  /// A `close_surface` keybind (⌘W) closes the pane. With the process
  /// gone, it's a key pressed on a terminal whose command ended.
  nonisolated private static func closeSurface(userdata: UnsafeMutableRawPointer?, processAlive: Bool) {
    guard let view = TerminalRef(userdata) else { return }
    DispatchQueue.main.async {
      MainActor.assumeIsolated { view.resolve()?.perform(processAlive ? .close : .closeAfterExit) }
    }
  }

  /// Hands `command` to the terminal an action targets, on the main thread.
  nonisolated private static func deliver(_ command: TerminalCommand, to target: ghostty_target_s) -> Bool {
    guard target.tag == GHOSTTY_TARGET_SURFACE, let surface = target.target.surface,
      let view = TerminalRef(ghostty_surface_userdata(surface))
    else { return false }
    DispatchQueue.main.async {
      MainActor.assumeIsolated { view.resolve()?.perform(command) }
    }
    return true
  }

  nonisolated private static func plainText(
    _ contents: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
  ) -> String? {
    guard let contents else { return nil }
    for i in 0..<count {
      let entry = contents[i]
      guard String(cString: entry.mime) == "text/plain" else { continue }
      return String(decoding: Data(bytes: entry.data, count: entry.len), as: UTF8.self)
    }
    return nil
  }
}

/// A surface's userdata pointer (its TerminalView), carried across threads
/// as a plain address and turned back into the view on the main thread.
private struct TerminalRef: Sendable {
  let address: UInt

  init?(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return nil }
    address = UInt(bitPattern: pointer)
  }

  @MainActor func resolve() -> TerminalView? {
    guard let pointer = UnsafeRawPointer(bitPattern: address) else { return nil }
    return TerminalView.live(at: pointer)
  }
}
