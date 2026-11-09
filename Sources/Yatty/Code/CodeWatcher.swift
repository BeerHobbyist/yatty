import CoreServices
import Foundation

/// The file that changed last in a worktree, for the code views to follow.
struct CodeChangeEvent: Equatable, Sendable {
  /// Relative to the worktree.
  var path: String
  /// Every file in the same batch of changes.
  var paths: [String]
  /// Counts the changes, so the same file changing again is a new event.
  var serial: Int
}

/// Tells when files change under a worktree (FSEvents), git's own excepted.
final class CodeWatcher: @unchecked Sendable {
  private var stream: FSEventStreamRef?
  private let queue = DispatchQueue(label: "yatty.code-watcher")
  private let onChange: @Sendable ([String]) -> Void
  /// The worktree's path with symlinks resolved, as FSEvents reports paths.
  let root: String

  init(root: String, onChange: @escaping @Sendable ([String]) -> Void) {
    self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    self.onChange = onChange
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
      guard let info else { return }
      let watcher = Unmanaged<CodeWatcher>.fromOpaque(info).takeUnretainedValue()
      let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
      watcher.onChange(Array(list.prefix(count)))
    }
    stream = FSEventStreamCreate(
      nil, callback, &context, [self.root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
      FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer))
    if let stream {
      FSEventStreamSetDispatchQueue(stream, queue)
      FSEventStreamStart(stream)
    }
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }

  deinit { stop() }
}
