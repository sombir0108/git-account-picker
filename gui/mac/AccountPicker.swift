// Native macOS account picker window (SwiftUI), matching the Windows popup.
// install.sh compiles it into "Switch GitHub Account.app" with the Swift
// compiler from the Xcode Command Line Tools; without them the picker
// falls back to the plain osascript dialogs in lib/picker-common.sh.
//
// Modes (--mode):
//   manage  (default; the app): switches, adds and removes accounts itself
//           and stays open until closed.
//   choose  (git / IDE prompts): adding and removing happen in place;
//           Switch prints the chosen account and exits, Cancel prints
//           nothing.
//   login   (sign-in only): runs the browser sign-in, shows the one-time
//           code, and exits when it's done.
// Other options: --host, --accounts a,b,c, --active NAME, --subtitle TEXT,
//   --icon PATH (when not run from the app bundle, which has its own),
//   --render PATH [--theme light|dark] writes a PNG of the window instead
//   of showing it (used by the automatic checks).
import AppKit
import Combine
import SwiftUI

// MARK: - Options

struct Options {
  var mode = "manage"
  var host = "github.com"
  var accounts: [String]?
  var active: String?
  var subtitle: String?
  var render: String?
  var renderTheme: String?
  var icon: String?

  init(_ args: [String]) {
    var i = 1
    func next() -> String {
      i += 1
      return i < args.count ? args[i] : ""
    }
    while i < args.count {
      switch args[i] {
      case "--mode": mode = next()
      case "--host": host = next()
      case "--accounts": accounts = next().split(separator: ",").map(String.init).filter { !$0.isEmpty }
      case "--active": active = next()
      case "--subtitle": subtitle = next()
      case "--render": render = next()
      case "--theme": renderTheme = next()
      case "--icon": icon = next()
      default: break
      }
      i += 1
    }
  }
}

// MARK: - GitHub CLI

enum GH {
  static let devicePage = URL(string: "https://github.com/login/device")!

  /// Apps opened from Finder get a minimal PATH without Homebrew.
  static var environment: [String: String] {
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    return env
  }

  /// gh with its input not on a terminal, so it never asks questions (its
  /// "Authenticate Git with your GitHub credentials?" would replace this
  /// tool's credential helper).
  static func process(_ args: [String]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["gh"] + args
    p.environment = environment
    p.standardInput = FileHandle.nullDevice
    return p
  }

  static func run(_ args: [String]) -> (status: Int32, output: String) {
    let p = process(args)
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (127, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
  }

  static var installed: Bool { run(["--version"]).status == 0 }

  static func accounts(_ host: String) -> [String] {
    matches(#"Logged in to \S+ account (\S+)"#, in: run(["auth", "status", "--hostname", host]).output)
  }

  static func active(_ host: String) -> String {
    run(["config", "get", "-h", host, "user"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Newer gh: "One-time code (ABCD-1234) copied"; older: "one-time code: ABCD-1234".
  static func loginCode(in text: String) -> String? {
    matches(#"code[^A-Z0-9]*([A-Z0-9]{4}-[A-Z0-9]{4})"#, in: text).first
  }

  static func matches(_ pattern: String, in text: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = text as NSString
    return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
  }
}

// MARK: - Settings (shared with the Windows popup)

enum Config {
  static var dir: URL {
    let env = ProcessInfo.processInfo.environment
    if let d = env["GIT_ACCOUNT_PICKER_CONFIG_DIR"], !d.isEmpty { return URL(fileURLWithPath: d) }
    if let x = env["XDG_CONFIG_HOME"], !x.isEmpty { return URL(fileURLWithPath: x).appendingPathComponent("git-account-picker") }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/git-account-picker")
  }

  /// Forgets repo owners remembered for an account that was removed.
  static func forgetOwners(of account: String) {
    let file = dir.appendingPathComponent("owners")
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
    let kept = text.split(whereSeparator: \.isNewline).filter {
      let parts = $0.split(separator: " ")
      return parts.count < 2 || String(parts[1]) != account
    }
    try? (kept.joined(separator: "\n") + (kept.isEmpty ? "" : "\n")).write(to: file, atomically: true, encoding: .utf8)
  }
}

final class Settings: ObservableObject {
  @Published var topMost = true { didSet { changed() } }
  @Published var opacity: Double = 100 { didSet { changed() } }
  @Published var theme = "auto" { didSet { changed() } }
  var persist = true
  var onChange: (() -> Void)?
  private let file = Config.dir.appendingPathComponent("ui-settings")

  init() {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
    for line in text.split(whereSeparator: \.isNewline) {
      let kv = line.split(separator: "=", maxSplits: 1).map(String.init)
      guard kv.count == 2 else { continue }
      switch kv[0] {
      case "topmost": topMost = kv[1] == "true"
      case "opacity": if let v = Double(kv[1]) { opacity = min(100, max(40, v)) }
      case "theme": if ["auto", "light", "dark"].contains(kv[1]) { theme = kv[1] }
      default: break
      }
    }
  }

  private func changed() {
    onChange?()
    guard persist else { return }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? "topmost=\(topMost)\nopacity=\(Int(opacity))\ntheme=\(theme)\n".write(to: file, atomically: true, encoding: .utf8)
  }
}

// MARK: - State and actions

enum BannerKind { case info, success, warning }

struct Banner: Equatable {
  var kind: BannerKind
  var text: String
}

struct LoginCode: Identifiable {
  let id = UUID()
  let code: String
}

final class Store: ObservableObject {
  let opts: Options
  @Published var accounts: [String]
  @Published var active: String
  @Published var selected: String?
  @Published var banner: Banner?
  @Published var loginCode: LoginCode?
  @Published var removing: String?
  @Published var busy = false
  private var loginProcess: Process?
  private var loginOutput = ""
  private var loginCancelled = false
  private var accountsBeforeLogin: [String] = []

  init(_ opts: Options) {
    self.opts = opts
    accounts = opts.accounts ?? []
    active = opts.active ?? ""
    selected = accounts.contains(active) ? active : accounts.first
  }

  var manage: Bool { opts.mode == "manage" }
  var host: String { opts.host }

  private func background(_ work: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async(execute: work)
  }

  private func main(_ work: @escaping () -> Void) {
    DispatchQueue.main.async(execute: work)
  }

  func say(_ kind: BannerKind, _ text: String) { banner = Banner(kind: kind, text: text) }

  func welcome() {
    if accounts.isEmpty {
      say(.info, "No GitHub account is signed in here yet. Click Add account to sign in.")
    } else if manage {
      say(.info, active.isEmpty ? "Pick an account and press Switch."
        : "git is using \(active) right now. Pick an account and press Switch.")
    }
  }

  func load() {
    busy = true
    let host = self.host
    background {
      let installed = GH.installed
      let accounts = installed ? GH.accounts(host) : []
      let active = installed ? GH.active(host) : ""
      self.main {
        self.busy = false
        guard installed else {
          self.say(.warning, "The GitHub CLI (gh) isn't installed. Install it with \"brew install gh\", then open this again.")
          return
        }
        self.accounts = accounts
        self.active = active
        if self.selected == nil || !accounts.contains(self.selected!) {
          self.selected = accounts.contains(active) ? active : accounts.first
        }
        self.welcome()
      }
    }
  }

  func switchSelected() {
    guard let target = selected, !busy else { return }
    if !manage {
      // Choose mode: the caller switches; just answer.
      print(target)
      fflush(stdout)
      NSApp.terminate(nil)
      return
    }
    if target == active {
      say(.info, "\(target) is already the active account.")
      return
    }
    say(.info, "Switching to \(target)…")
    busy = true
    let host = self.host
    background {
      let switched = GH.run(["auth", "switch", "--hostname", host, "--user", target]).status == 0
      let valid = switched && GH.run(["api", "user", "--hostname", host]).status == 0
      self.main {
        self.busy = false
        if !switched {
          self.say(.warning, "Couldn't switch to \(target). Try removing it and adding it again.")
          return
        }
        self.active = target
        if valid {
          self.say(.success, "Switched. git now uses \(target).")
        } else {
          self.say(.warning, "Switched to \(target), but its sign-in has expired. Remove it and add it again to sign in.")
        }
      }
    }
  }

  // Browser sign-in: gh prints a one-time code and waits; we open the page,
  // copy the code and show it until gh finishes.
  func addAccount() {
    guard loginProcess == nil else { return }
    let p = GH.process(["auth", "login", "--hostname", host, "--git-protocol", "https", "--web", "--scopes", "workflow"])
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    loginOutput = ""
    loginCancelled = false
    accountsBeforeLogin = accounts
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      let text = String(decoding: data, as: UTF8.self)
      self.main {
        self.loginOutput += text
        if self.loginCode == nil, let code = GH.loginCode(in: self.loginOutput) { self.showCode(code) }
      }
    }
    p.terminationHandler = { _ in
      pipe.fileHandleForReading.readabilityHandler = nil
      self.main { self.loginFinished() }
    }
    do {
      try p.run()
    } catch {
      say(.warning, "Couldn't start the GitHub sign-in. Is the GitHub CLI (gh) installed?")
      return
    }
    loginProcess = p
    say(.info, "Starting the GitHub sign-in…")
  }

  private func showCode(_ code: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(code, forType: .string)
    openDevicePage()
    loginCode = LoginCode(code: code)
  }

  func openDevicePage() { NSWorkspace.shared.open(GH.devicePage) }

  func cancelLogin() {
    loginCancelled = true
    loginProcess?.terminate()
  }

  private func loginFinished() {
    let hadCode = loginCode != nil
    loginProcess = nil
    loginCode = nil
    if opts.mode == "login" {
      NSApp.terminate(nil)
      return
    }
    let before = accountsBeforeLogin
    let output = loginOutput
    let cancelled = loginCancelled
    let host = self.host
    busy = true
    background {
      let accounts = GH.accounts(host)
      let active = GH.active(host)
      self.main {
        self.busy = false
        self.accounts = accounts
        self.active = active
        if let added = accounts.first(where: { !before.contains($0) }) {
          self.selected = added
          self.say(.success, "Added \(added). Press Switch to start using it.")
        } else if cancelled {
          self.say(.info, "Sign-in cancelled.")
        } else if !hadCode {
          let last = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
          self.say(.warning, "Couldn't start the GitHub sign-in. \(last)")
        } else {
          self.say(.warning, "No new account was added. If the browser used an account that's already here, sign out of GitHub there or use a private window, then try again.")
        }
      }
    }
  }

  func remove(_ target: String) {
    busy = true
    let host = self.host
    background {
      _ = GH.run(["auth", "logout", "--hostname", host, "--user", target])
      Config.forgetOwners(of: target)
      let accounts = GH.accounts(host)
      let active = GH.active(host)
      self.main {
        self.busy = false
        self.accounts = accounts
        self.active = active
        self.selected = accounts.contains(active) ? active : accounts.first
        if accounts.isEmpty {
          self.say(.warning, "Signed out of \(target). No accounts are left; use Add account to sign in.")
        } else {
          self.say(.success, "Signed out of \(target) on this computer.")
        }
      }
    }
  }
}

// MARK: - Views

let avatarPalette: [Color] = [
  Color(red: 0.035, green: 0.412, blue: 0.855), Color(red: 0.510, green: 0.314, blue: 0.875),
  Color(red: 0.737, green: 0.298, blue: 0.000), Color(red: 0.102, green: 0.498, blue: 0.216),
  Color(red: 0.749, green: 0.224, blue: 0.537), Color(red: 0.106, green: 0.486, blue: 0.514),
  Color(red: 0.604, green: 0.404, blue: 0.000), Color(red: 0.812, green: 0.133, blue: 0.180),
]

struct AccountRow: View {
  let name: String
  let index: Int
  let isActive: Bool
  let isSelected: Bool
  @State private var hover = false

  var body: some View {
    HStack(spacing: 12) {
      ZStack {
        Circle().fill(avatarPalette[index % avatarPalette.count])
        Text(String(name.prefix(1)).uppercased())
          .font(.system(size: 14, weight: .semibold))
          .foregroundColor(.white)
      }
      .frame(width: 34, height: 34)
      VStack(alignment: .leading, spacing: 3) {
        Text(name).font(.system(size: 13, weight: .semibold))
        if isActive {
          HStack(spacing: 5) {
            Circle().fill(Color.green).frame(width: 7, height: 7)
            Text("Active now").font(.system(size: 11)).foregroundColor(.green)
          }
        } else {
          Text("Signed in").font(.system(size: 11)).foregroundColor(.secondary)
        }
      }
      Spacer()
    }
    .padding(.horizontal, 12)
    .frame(height: 52)
    .background(
      RoundedRectangle(cornerRadius: 8)
        .fill(isSelected ? Color.accentColor.opacity(0.15) : (hover ? Color.primary.opacity(0.06) : Color.clear))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 8)
        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
    )
    .contentShape(Rectangle())
    .onHover { hover = $0 }
  }
}

struct BannerView: View {
  let banner: Banner

  var body: some View {
    let tint: Color = banner.kind == .success ? .green : (banner.kind == .warning ? .orange : .accentColor)
    let symbol = banner.kind == .success ? "checkmark.circle.fill"
      : (banner.kind == .warning ? "exclamationmark.triangle.fill" : "info.circle.fill")
    return HStack(alignment: .top, spacing: 8) {
      Image(systemName: symbol).foregroundColor(tint)
      Text(banner.text)
        .font(.system(size: 12))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(10)
    .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.13)))
  }
}

struct CodeView: View {
  let code: String
  @ObservedObject var store: Store

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: "key.fill").font(.system(size: 26)).foregroundColor(.accentColor)
      Text("Enter this code on GitHub").font(.system(size: 15, weight: .semibold))
      Text(code)
        .font(.system(size: 30, weight: .bold, design: .monospaced))
        .textSelection(.enabled)
      Text("It's copied to your clipboard, and your browser opened github.com/login/device. Paste the code there, sign in as the account you want to add, and approve. This closes by itself when you're done.")
        .font(.system(size: 12))
        .foregroundColor(.secondary)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Cancel sign-in") { store.cancelLogin() }
        Button("Open GitHub again") { store.openDevicePage() }
          .buttonStyle(.borderedProminent)
      }
      .controlSize(.large)
    }
    .padding(24)
    .frame(width: 380)
  }
}

struct LoginView: View {
  @ObservedObject var store: Store

  var body: some View {
    if let login = store.loginCode {
      CodeView(code: login.code, store: store)
    } else {
      VStack(spacing: 12) {
        ProgressView()
        Text(store.banner?.text ?? "Starting the GitHub sign-in…").font(.system(size: 12))
      }
      .padding(30)
      .frame(width: 380)
    }
  }
}

struct PickerView: View {
  @ObservedObject var store: Store
  @ObservedObject var settings: Settings

  private var themeLabel: String {
    ["light": "Light", "dark": "Dark"][settings.theme] ?? "Auto"
  }

  private var themeSymbol: String {
    ["light": "sun.max", "dark": "moon"][settings.theme] ?? "circle.lefthalf.filled"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(nsImage: NSApp.applicationIconImage)
          .resizable()
          .frame(width: 44, height: 44)
        VStack(alignment: .leading, spacing: 2) {
          Text("GitHub accounts").font(.system(size: 17, weight: .semibold))
          Text(store.opts.subtitle ?? (store.manage ? "Switch the account git uses for \(store.host)"
            : "Choose the account git uses for \(store.host)"))
            .font(.system(size: 12))
            .foregroundColor(.secondary)
        }
        Spacer()
        Button {
          settings.theme = ["auto": "light", "light": "dark"][settings.theme] ?? "auto"
        } label: {
          Label(themeLabel, systemImage: themeSymbol)
        }
        .controlSize(.small)
        .help("Theme: Auto follows macOS. Click to switch between Auto, Light and Dark.")
      }

      ScrollView {
        VStack(spacing: 4) {
          ForEach(Array(store.accounts.enumerated()), id: \.element) { index, name in
            AccountRow(name: name, index: index, isActive: name == store.active, isSelected: name == store.selected)
              .onTapGesture(count: 2) {
                store.selected = name
                store.switchSelected()
              }
              .onTapGesture { store.selected = name }
          }
        }
      }
      .frame(height: CGFloat(min(5, max(1, store.accounts.count))) * 56)

      if let banner = store.banner {
        BannerView(banner: banner)
      }

      HStack(spacing: 8) {
        Button {
          store.addAccount()
        } label: {
          Label("Add account", systemImage: "plus")
        }
        Button("Remove…") { store.removing = store.selected }
          .foregroundColor(.red)
          .disabled(store.selected == nil || store.busy)
        Spacer()
        Button(store.manage ? "Close" : "Cancel") { NSApp.terminate(nil) }
          .keyboardShortcut(.cancelAction)
        Button("Switch") { store.switchSelected() }
          .keyboardShortcut(.defaultAction)
          .buttonStyle(.borderedProminent)
          .tint(.green)
          .disabled(store.selected == nil || store.busy)
      }
      .controlSize(.large)

      Divider()

      HStack(spacing: 8) {
        Toggle("Always on top", isOn: $settings.topMost)
          .toggleStyle(.switch)
          .controlSize(.small)
        Spacer()
        Text("Opacity").foregroundColor(.secondary)
        Slider(value: $settings.opacity, in: 40...100)
          .controlSize(.small)
          .frame(width: 110)
        Text("\(Int(settings.opacity))%")
          .font(.system(size: 12).monospacedDigit())
          .frame(width: 38, alignment: .trailing)
      }
      .font(.system(size: 12))
    }
    .padding(20)
    .frame(width: 440)
    .sheet(item: $store.loginCode) { login in
      CodeView(code: login.code, store: store)
    }
    .alert(
      "Sign out of \(store.removing ?? "") on this computer?",
      isPresented: Binding(get: { store.removing != nil }, set: { if !$0 { store.removing = nil } })
    ) {
      Button("Remove", role: .destructive) {
        if let target = store.removing { store.remove(target) }
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("It is removed from this list and git stops using it. Your GitHub account itself is not deleted, and you can add it back with Add account.")
    }
  }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
  let opts: Options
  let settings = Settings()
  let store: Store
  var window: NSWindow!
  var hosting: NSView!
  var watch: AnyCancellable?

  init(_ opts: Options) {
    self.opts = opts
    store = Store(opts)
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    if opts.render != nil {
      settings.persist = false
      if let theme = opts.renderTheme { settings.theme = theme }
    }

    let root: AnyView = opts.mode == "login"
      ? AnyView(LoginView(store: store))
      : AnyView(PickerView(store: store, settings: settings))
    hosting = NSHostingView(rootView: root)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
      styleMask: [.titled, .closable],
      backing: .buffered, defer: false)
    window.title = opts.mode == "login" ? "Add GitHub account" : "GitHub Account Picker"
    window.contentView = hosting
    window.isReleasedWhenClosed = false

    settings.onChange = { [weak self] in self?.applySettings() }
    applySettings()
    // Keep the window fitted to its content (banner, list size, ...).
    watch = store.objectWillChange.sink { [weak self] _ in
      DispatchQueue.main.async { self?.fit() }
    }
    fit()
    window.center()

    if let path = opts.render {
      store.welcome()
      fit()
      window.orderFrontRegardless()
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        self.render(to: path)
        NSApp.terminate(nil)
      }
      return
    }

    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    switch opts.mode {
    case "login": store.addAccount()
    case "choose" where opts.accounts != nil: store.welcome()
    default: store.load()
    }
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationWillTerminate(_ notification: Notification) { store.cancelLogin() }

  private func applySettings() {
    window?.level = settings.topMost ? .floating : .normal
    window?.alphaValue = CGFloat(settings.opacity / 100)
    switch settings.theme {
    case "light": NSApp.appearance = NSAppearance(named: .aqua)
    case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
    default: NSApp.appearance = nil
    }
  }

  private func fit() {
    guard let window = window, let hosting = hosting else { return }
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    guard size.width > 0, size.height > 0, size != window.contentLayoutRect.size else { return }
    var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
    window.setFrame(frame, display: true)
  }

  private func render(to path: String) {
    guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
    view.cacheDisplay(in: view.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
  }
}

@main
enum AccountPickerApp {
  static var delegate: AppDelegate!

  static func main() {
    let opts = Options(CommandLine.arguments)
    let app = NSApplication.shared
    delegate = AppDelegate(opts)
    app.delegate = delegate
    if let path = opts.icon, let image = NSImage(contentsOfFile: path) { app.applicationIconImage = image }
    // The app (manage) gets a Dock icon; prompts from git just show a window.
    app.setActivationPolicy(opts.mode == "manage" ? .regular : .accessory)
    app.run()
  }
}
