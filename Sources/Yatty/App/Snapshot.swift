import AppKit
import WebKit

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

  /// The pictures of the windows' web pages (the diff tab, the code), which
  /// draw out of process where the window capture can't see them. None
  /// under a sandbox that stops WebKit's page process.
  @MainActor private static func webPictures() async -> [(view: WKWebView, image: NSImage)] {
    func pages(in view: NSView) -> [WKWebView] {
      if let page = view as? WKWebView { return page.isHiddenOrHasHiddenAncestor ? [] : [page] }
      return view.subviews.flatMap(pages)
    }
    var pictures: [(view: WKWebView, image: NSImage)] = []
    for page in NSApp.windows.filter(\.isVisible).flatMap({ $0.contentView.map(pages) ?? [] }) {
      do {
        pictures.append((page, try await page.takeSnapshot(configuration: nil)))
      } catch {
        note("page picture failed: \(error.localizedDescription)")
      }
    }
    return pictures
  }

  /// Where a page at `frame` in a view of `bounds` goes in that view's
  /// picture: in the picture's units (`scale` of the view's), from the
  /// bottom left.
  static func drawingRect(of frame: CGRect, in bounds: CGSize, flipped: Bool, scale: CGFloat) -> CGRect {
    let y = flipped ? bounds.height - frame.maxY : frame.minY
    return CGRect(x: frame.minX * scale, y: y * scale, width: frame.width * scale, height: frame.height * scale)
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
    // Not NSApp.terminate: it waits while a sheet is open.
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      Task { @MainActor in
        write(to: path, pages: await webPictures())
        exit(0)
      }
    }
    // A page whose process died may never answer: go without it.
    DispatchQueue.main.asyncAfter(deadline: .now() + delay + 10) {
      MainActor.assumeIsolated {
        note("page pictures didn't come")
        write(to: path, pages: [])
        exit(0)
      }
    }
  }

  /// Renders the view's layer tree, which (unlike `cacheDisplay`) includes
  /// the sidebar's contents. Blur and Metal content still come out empty.
  @MainActor private static func capture(_ view: NSView) -> NSBitmapImageRep? {
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    // On a 2x display the layer render below comes out blank; AppKit's own
    // display caching draws it.
    if (view.window?.backingScaleFactor ?? 1) > 1 {
      view.cacheDisplay(in: view.bounds, to: rep)
      return rep
    }
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

  /// Paints the pages' pictures onto `image`, the picture of `view`.
  @MainActor private static func paint(
    _ pages: [(view: WKWebView, image: NSImage)], onto image: NSBitmapImageRep, of view: NSView
  ) {
    guard !pages.isEmpty, view.bounds.width > 0, let context = NSGraphicsContext(bitmapImageRep: image) else { return }
    // The context counts in the picture's size, which may be points or pixels.
    let scale = image.size.width / view.bounds.width
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    for page in pages {
      let frame = page.view.convert(page.view.bounds, to: view)
      page.image.draw(in: drawingRect(of: frame, in: view.bounds.size, flipped: view.isFlipped, scale: scale))
    }
    NSGraphicsContext.restoreGraphicsState()
  }

  @MainActor private static func write(to path: String, pages: [(view: WKWebView, image: NSImage)]) {
    // Under a sandbox that blocks the window server there are none: say so.
    FileHandle.standardError.write(Data("snapshot: \(NSApp.windows.filter(\.isVisible).count) visible windows\n".utf8))
    // The frame view includes the title bar and toolbar; sheets are windows of their own.
    let images: [NSBitmapImageRep] = NSApp.windows.filter(\.isVisible).compactMap { window in
      guard let view = window.contentView?.superview ?? window.contentView, let image = capture(view) else { return nil }
      paint(pages.filter { $0.view.window === window }, onto: image, of: view)
      return image
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
