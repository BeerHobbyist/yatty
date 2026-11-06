import Foundation

extension ConfigFiles {
  /// Writes the settings into `config.json`, keeping whatever else the file
  /// holds (keys a newer Yatty, or the user, put there). A blank clone
  /// directory or sandbox command is left out, so the default applies; a
  /// blank agent command stays: no agent.
  static func saveConfig(_ settings: YattyConfig, to url: URL = config) throws {
    var object: [String: Any] = [:]
    if let data = try? Data(contentsOf: url) {
      if let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        object = existing
      } else {
        // Not JSON Yatty can read: kept aside rather than lost.
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
      }
    }
    object["agentCommand"] = settings.agentCommand
    object["notifications"] = settings.notifications
    let clone = settings.cloneDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    object["cloneDirectory"] = clone.isEmpty ? nil : clone
    let sandbox = settings.sandboxCommand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    object["sandboxCommand"] = sandbox.isEmpty ? nil : sandbox
    let data = try JSONSerialization.data(
      withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
  }
}
