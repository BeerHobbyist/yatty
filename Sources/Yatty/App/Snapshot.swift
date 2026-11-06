import AppKit

/// With `YATTY_SNAPSHOT=<png path>`, draws the app's windows into one PNG once
/// they've settled, then quits: how visual checks see the app. Terminals draw
/// through Metal and come out blank. Started by `scripts/snapshot.sh`.
enum Snapshot {
  static var isActive: Bool {
    !(ProcessInfo.processInfo.environment["YATTY_SNAPSHOT"] ?? "").isEmpty
  }

  @MainActor private static var scheduled = false

  @MainActor static func scheduleIfRequested() {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["YATTY_SNAPSHOT"], !path.isEmpty, !scheduled else { return }
    scheduled = true
    let delay = Double(environment["YATTY_SNAPSHOT_DELAY"] ?? "") ?? 3
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      MainActor.assumeIsolated {
        write(to: path)
        NSApp.terminate(nil)
      }
    }
  }

  @MainActor private static func write(to path: String) {
    // Under a sandbox that blocks the window server there are none: say so.
    FileHandle.standardError.write(Data("snapshot: \(NSApp.windows.filter(\.isVisible).count) visible windows\n".utf8))
    // The frame view includes the title bar and toolbar; sheets are windows of their own.
    let images: [NSBitmapImageRep] = NSApp.windows.filter(\.isVisible).compactMap { window in
      guard let view = window.contentView?.superview ?? window.contentView,
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
      else { return nil }
      view.cacheDisplay(in: view.bounds, to: rep)
      return rep
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
