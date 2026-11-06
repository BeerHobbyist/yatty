import Foundation
import YattyProtocol

/// Where the `yatty` CLI reaches the app: a Unix socket taking one JSON
/// request line per connection and answering with one JSON line. There are
/// two: `app.sock`, for anything, and `sandbox.sock`, the only one a fenced
/// agent may be let onto, whose requests follow the sandbox's rules
/// whatever they say.
final class CLIServer: @unchecked Sendable {
  typealias Handler = @Sendable (_ request: CLIRequest, _ sandboxed: Bool) async -> CLIResponse

  /// Longest request read: a `tab send` of a long prompt fits many times over.
  static let maxRequest = 1 << 20

  let path: String
  private let fd: Int32
  private let source: DispatchSourceRead

  /// Listens on `path`, unless another Yatty already does.
  init?(path: String, sandboxed: Bool, handler: @escaping Handler) {
    let directory = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(
      atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    guard !CLIServer.isListening(path), var address = CLIServer.address(path) else { return nil }
    // Only a socket is ever replaced: a stale one from a Yatty that crashed.
    var info = stat()
    if lstat(path, &info) == 0 {
      guard info.st_mode & S_IFMT == S_IFSOCK else { return nil }
      unlink(path)
    }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    // Inherited by every connection: set on one whose client already hung
    // up, macOS refuses it, and the reply's write would kill the app.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    let bound = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
      close(fd)
      return nil
    }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    self.path = path
    self.fd = fd
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "yatty.cli.accept"))
    source.setEventHandler {
      while true {
        let connection = accept(fd, nil, nil)
        guard connection >= 0 else { return }
        DispatchQueue.global(qos: .userInitiated).async {
          CLIServer.serve(connection, sandboxed: sandboxed, handler: handler)
        }
      }
    }
    source.setCancelHandler { close(fd) }
    source.resume()
  }

  deinit { stop() }

  func stop() {
    guard !source.isCancelled else { return }
    source.cancel()
    unlink(path)
  }

  // MARK: Connections

  private static func serve(_ connection: Int32, sandboxed: Bool, handler: @escaping Handler) {
    _ = fcntl(connection, F_SETFL, fcntl(connection, F_GETFL) & ~O_NONBLOCK)
    // A client that connects and says nothing doesn't hold a thread for long.
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    guard let line = readLine(connection) else {
      reply(.failure("bad request"), to: connection)
      return
    }
    guard let request = try? JSONDecoder().decode(CLIRequest.self, from: line) else {
      reply(.failure("bad request"), to: connection)
      return
    }
    Task {
      let response = await handler(request, sandboxed)
      reply(response, to: connection)
    }
  }

  private static func readLine(_ connection: Int32) -> Data? {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while data.count <= maxRequest {
      let count = read(connection, &buffer, buffer.count)
      guard count > 0 else { return nil }
      if let end = buffer[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
        data.append(contentsOf: buffer[0..<end])
        return data
      }
      data.append(contentsOf: buffer[0..<count])
    }
    return nil
  }

  private static func reply(_ response: CLIResponse, to connection: Int32) {
    defer { close(connection) }
    guard var data = try? JSONEncoder().encode(response) else { return }
    data.append(UInt8(ascii: "\n"))
    data.withUnsafeBytes { bytes in
      var offset = 0
      while offset < bytes.count {
        let written = write(connection, bytes.baseAddress! + offset, bytes.count - offset)
        guard written > 0 else { return }
        offset += written
      }
    }
  }

  // MARK: Paths

  static func address(_ path: String) -> sockaddr_un? {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: path.utf8)
      buffer[path.utf8.count] = 0
    }
    return address
  }

  /// Whether a live Yatty answers on `path`.
  static func isListening(_ path: String) -> Bool {
    guard var address = address(path) else { return false }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    return withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
      }
    }
  }

  // MARK: Terminals

  /// The CLI in the app bundle, `Contents/Resources/bin/yatty`.
  static var cli: URL? {
    guard let url = Bundle.main.resourceURL?.appendingPathComponent("bin/yatty"),
      FileManager.default.isExecutableFile(atPath: url.path)
    else { return nil }
    return url
  }

  /// What every terminal gets so its programs find the CLI and the CLI finds
  /// this app: `$YATTY_CLI`, its directory on `PATH` (in front of `path`, or
  /// the app's own), and the app's state directory.
  static func paneEnvironment(path: String?) -> [String: String] {
    var environment = ["YATTY_STATE_DIR": CLIPaths.directory().path]
    let base = path ?? ProcessInfo.processInfo.environment["PATH"] ?? Run.searchPath
    if let cli {
      environment["YATTY_CLI"] = cli.path
      environment["PATH"] = cli.deletingLastPathComponent().path + ":" + base
    } else if let path {
      environment["PATH"] = path
    }
    return environment
  }
}
