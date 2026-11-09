import AppKit
import SwiftUI

/// A GitHub user's picture, round. Their initial on a colour of their own
/// stands in while it loads, when it can't, and in snapshots.
struct AvatarView: View {
  let login: String
  var size: CGFloat
  @State private var image: NSImage?

  /// A nil login is a deleted account: GitHub's "ghost".
  init(login: String?, size: CGFloat = 18) {
    self.login = login ?? "ghost"
    self.size = size
  }

  var body: some View {
    Group {
      if let image {
        Image(nsImage: image).resizable().scaledToFill()
      } else {
        ZStack {
          Circle().fill(Self.color(for: login))
          Text(login.prefix(1).uppercased())
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(.white)
        }
      }
    }
    .frame(width: size, height: size)
    .clipShape(Circle())
    .help(login)
    .task(id: login) { image = await Avatars.shared.image(for: login) }
  }

  private static let palette: [Color] = [.indigo, .orange, .teal, .pink, .purple, .green, .blue, .brown]

  /// The same colour for a login every time (not `hashValue`: that changes per launch).
  private static func color(for login: String) -> Color {
    palette[login.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % palette.count]
  }
}

/// Avatars fetched once per login per launch, kept in memory.
@MainActor
final class Avatars {
  static let shared = Avatars()
  private var images: [String: NSImage] = [:]
  private var loading: [String: Task<NSImage?, Never>] = [:]
  private var failed: Set<String> = []

  func image(for login: String) async -> NSImage? {
    if let image = images[login] { return image }
    guard !Snapshot.isActive, login != "ghost", !failed.contains(login),
      let name = login.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
      let url = URL(string: "https://github.com/\(name).png?size=64")
    else { return nil }
    let task =
      loading[login]
      ?? Task {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
          (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return NSImage(data: data)
      }
    loading[login] = task
    let image = await task.value
    loading[login] = nil
    if let image { images[login] = image } else { failed.insert(login) }
    return image
  }
}
