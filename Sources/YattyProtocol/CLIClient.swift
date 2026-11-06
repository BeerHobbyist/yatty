import Foundation

public struct CLIClientError: Error, Equatable, CustomStringConvertible {
  public let description: String
  public init(_ description: String) { self.description = description }
}

/// One request, one answer: a JSON line each way over a Unix socket.
public enum CLIClient {
  public static func send(_ request: CLIRequest, to path: String, timeout: Int = 30) throws -> CLIResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw CLIClientError("can't open a socket") }
    defer { close(fd) }
    // Before connecting: once Yatty has hung up, macOS refuses the option.
    var on: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.utf8.count < capacity else { throw CLIClientError("socket path too long: \(path)") }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: path.utf8)
      buffer[path.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { throw CLIClientError(connectFailure(errno: errno, path: path)) }

    // A tab read waits on zmx; nothing should take longer than this.
    var limit = timeval(tv_sec: timeout, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

    var line = try JSONEncoder().encode(request)
    line.append(UInt8(ascii: "\n"))
    let sent = line.withUnsafeBytes { bytes -> Bool in
      var offset = 0
      while offset < bytes.count {
        let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
        guard written > 0 else { return false }
        offset += written
      }
      return true
    }
    guard sent else { throw CLIClientError("couldn't send the request to Yatty") }

    var answer = Data()
    var buffer = [UInt8](repeating: 0, count: 65536)
    while answer.last != UInt8(ascii: "\n") {
      let count = read(fd, &buffer, buffer.count)
      if count < 0 { throw CLIClientError("no answer from Yatty") }
      if count == 0 { break }
      answer.append(contentsOf: buffer[0..<count])
    }
    guard let response = try? JSONDecoder().decode(CLIResponse.self, from: answer) else {
      throw CLIClientError("Yatty's answer made no sense")
    }
    return response
  }

  /// Why a connection failed, in words. A sandbox that refuses the socket is
  /// not the same as no Yatty behind it.
  public static func connectFailure(errno code: Int32, path: String) -> String {
    switch code {
    case EPERM, EACCES:
      "the sandbox doesn't allow Yatty's socket: add \(path) to fence's network.allowUnixSockets"
    default:
      "Yatty isn't running (nothing listens on \(path))"
    }
  }
}
