import Foundation
import YattyProtocol

// `yatty`: drives the tabs of the Yatty terminal it runs in, through the app.

// A hung-up socket or a closed pipe is an error to report, not a reason to die.
signal(SIGPIPE, SIG_IGN)

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("yatty: \(message)\n".utf8))
  exit(1)
}

if arguments.isEmpty || ["--help", "-h", "help"].contains(arguments[0]) {
  print(CLIUsage.text)
  exit(arguments.isEmpty ? 1 : 0)
}

if arguments[0] == "skill" {
  exit(Skill.run(Array(arguments.dropFirst()), environment: environment))
}

var request: CLIRequest
do {
  request = try CLIArguments.parse(arguments, env: environment)
} catch {
  fail("\(error)")
}
// A relative --cwd means from here, as it would in a shell.
if let cwd = request.cwd, !cwd.hasPrefix("/") {
  request.cwd = (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(cwd)
}

// Inside fence only the sandbox's socket is reachable, and the app holds
// requests from it to the sandbox's terms.
let socketPath = environment["FENCE_SANDBOX"] != nil ? CLIPaths.sandboxSocket(environment) : CLIPaths.appSocket(environment)
let response: CLIResponse
do {
  response = try CLIClient.send(request, to: socketPath)
} catch {
  fail("\(error)")
}
if !response.output.isEmpty {
  print(response.output, terminator: response.output.hasSuffix("\n") ? "" : "\n")
}
if let error = response.error { fail(error) }
exit(response.ok ? 0 : 1)
