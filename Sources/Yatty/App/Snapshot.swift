import AppKit

/// With `YATTY_SNAPSHOT=<png path>`, draws the app's windows into one PNG once
/// they've settled, then quits: how visual checks see the app. Terminals draw
/// through Metal and come out blank. Started by `scripts/snapshot.sh`.
enum Snapshot {
  static var isActive: Bool {
    !(ProcessInfo.processInfo.environment["YATTY_SNAPSHOT"] ?? "").isEmpty
  }

  /// `YATTY_SNAPSHOT_SHEET`: a sheet to open before the snapshot is taken.
  static var sheet: String? {
    guard isActive else { return nil }
    let value = ProcessInfo.processInfo.environment["YATTY_SNAPSHOT_SHEET"] ?? ""
    return value.isEmpty ? nil : value
  }

  /// `YATTY_SNAPSHOT_HOVER`: a worktree id whose sidebar row draws as hovered.
  static var hover: String? { value("YATTY_SNAPSHOT_HOVER") }

  /// `YATTY_SNAPSHOT_PR_TAB`: the PR panel's tab (conversation, checks, description).
  static var prTab: PullRequestTab? { value("YATTY_SNAPSHOT_PR_TAB").flatMap(PullRequestTab.init(rawValue:)) }

  /// `YATTY_SNAPSHOT_FILTER`: text already in the sidebar's filter.
  static var filter: String? { value("YATTY_SNAPSHOT_FILTER") }

  private static func value(_ name: String) -> String? {
    guard isActive else { return nil }
    let value = ProcessInfo.processInfo.environment[name] ?? ""
    return value.isEmpty ? nil : value
  }

  @MainActor private static var scheduled = false

  /// A line for the snapshot script's log; nothing outside snapshot mode.
  static func note(_ message: String) {
    guard isActive else { return }
    FileHandle.standardError.write(Data("snapshot: \(message)\n".utf8))
  }

  @MainActor static func scheduleIfRequested() {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["YATTY_SNAPSHOT"], !path.isEmpty, !scheduled else { return }
    scheduled = true
    let delay = Double(environment["YATTY_SNAPSHOT_DELAY"] ?? "") ?? 3
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      MainActor.assumeIsolated {
        write(to: path)
        // Not NSApp.terminate: it waits while a sheet is open.
        exit(0)
      }
    }
  }

  /// Renders the view's layer tree, which (unlike `cacheDisplay`) includes
  /// the sidebar's contents. Blur and Metal content still come out empty.
  @MainActor private static func capture(_ view: NSView) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    guard let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: rep) else {
      view.cacheDisplay(in: view.bounds, to: rep)
      return rep
    }
    let cg = context.cgContext
    cg.setFillColor(NSColor.windowBackgroundColor.cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
    cg.scaleBy(x: CGFloat(rep.pixelsWide) / view.bounds.width, y: CGFloat(rep.pixelsHigh) / view.bounds.height)
    if layer.isGeometryFlipped || view.isFlipped {
      cg.translateBy(x: 0, y: view.bounds.height)
      cg.scaleBy(x: 1, y: -1)
    }
    layer.render(in: cg)
    return rep
  }

  @MainActor private static func write(to path: String) {
    // Under a sandbox that blocks the window server there are none: say so.
    FileHandle.standardError.write(Data("snapshot: \(NSApp.windows.filter(\.isVisible).count) visible windows\n".utf8))
    // The frame view includes the title bar and toolbar; sheets are windows of their own.
    let images: [NSBitmapImageRep] = NSApp.windows.filter(\.isVisible).compactMap { window in
      guard let view = window.contentView?.superview ?? window.contentView else { return nil }
      return capture(view)
    }
    guard !images.isEmpty else { return }

    let width = images.map(\.pixelsWide).max() ?? 0
    let height = images.map(\.pixelsHigh).reduce(0, +)
    guard let canvas = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0),
      let context = NSGraphicsContext(bitmapImageRep: canvas)
    else { return }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    var top = height
    for image in images {
      top -= image.pixelsHigh
      image.draw(in: NSRect(x: 0, y: top, width: image.pixelsWide, height: image.pixelsHigh))
    }
    NSGraphicsContext.restoreGraphicsState()

    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? canvas.representation(using: .png, properties: [:])?.write(to: url)
  }
}
