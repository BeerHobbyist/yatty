import SwiftUI

/// A directory on another machine, added after a check that it's there and
/// zmx is too. A host that wants a password gets a field for it; the
/// password logs in once and is never kept.
struct AddHostSheet: View {
  let request: AddHostRequest
  @Environment(AppStore.self) private var store
  @Environment(\.dismiss) private var dismiss
  @State private var host = ""
  @State private var path = "~"
  @State private var password = ""
  @State private var asksPassword = false
  @State private var message: String?
  @State private var connecting = false
  @FocusState private var focus: Field?
  private let suggestions = SSH.configuredHosts()

  private enum Field { case host, path, password }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Add SSH Host").font(.headline)
      Text("A directory on another machine. Its terminals run there, in zmx, so they outlive the connection.")
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Form {
        HStack(spacing: 4) {
          TextField("Host", text: $host, prompt: Text("user@host, or a ~/.ssh/config alias"))
            .focused($focus, equals: .host)
          if !suggestions.isEmpty {
            Menu {
              ForEach(suggestions, id: \.self) { name in Button(name) { host = name } }
            } label: {
              Image(systemName: "chevron.down")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Hosts in ~/.ssh/config")
          }
        }
        TextField("Directory", text: $path, prompt: Text("~/src/app"))
          .focused($focus, equals: .path)
        if asksPassword {
          SecureField("Password", text: $password, prompt: Text("or your key's passphrase"))
            .focused($focus, equals: .password)
        }
      }
      .onSubmit(add)
      .disabled(connecting)
      // A password typed for one host is never sent to another.
      .onChange(of: host) {
        asksPassword = false
        password = ""
        message = nil
      }

      if let message {
        Text(message).font(.callout).foregroundStyle(.red)
          .fixedSize(horizontal: false, vertical: true)
          .textSelection(.enabled)
      }

      HStack {
        if connecting {
          ProgressView().controlSize(.small)
          Text("Connecting to \(host)…").font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Add", action: add)
          .keyboardShortcut(.defaultAction)
          .disabled(!canAdd)
      }
    }
    .padding(20)
    .frame(width: 480)
    .onAppear {
      host = request.host
      focus = request.host.isEmpty ? .host : .path
    }
  }

  private var canAdd: Bool {
    SSH.isValidHost(host.trimmingCharacters(in: .whitespaces)) && !connecting && (!asksPassword || !password.isEmpty)
  }

  private func add() {
    guard canAdd else { return }
    connecting = true
    message = nil
    let secret = asksPassword ? password : nil
    Task {
      let failure = await store.addRemoteDirectory(host: host, path: path, password: secret)
      connecting = false
      password = ""
      switch failure {
      case nil:
        dismiss()
      case .needsPassword(let why):
        message = asksPassword ? "That didn't log in: \(why)" : "\(host) asks for a password, or your key's passphrase."
        asksPassword = true
        focus = .password
      case .failed(let why):
        message = why
      }
    }
  }
}
