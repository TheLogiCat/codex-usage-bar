import AppKit

final class CodexLifecycle {
    static let bundleID = "com.openai.codex"
    let isCodexRunning: () -> Bool
    let start: () -> Void
    let stop: () -> Void
    init(isCodexRunning: @escaping () -> Bool, start: @escaping () -> Void, stop: @escaping () -> Void) {
        self.isCodexRunning = isCodexRunning; self.start = start; self.stop = stop
    }
    func synchronize() { if isCodexRunning() { start() } else { stop() } }
    func launched(_ bundleID: String?) { if bundleID == Self.bundleID { start() } }
    func terminated(_ bundleID: String?) {
        if bundleID == Self.bundleID && !isCodexRunning() { stop() }
    }
}

// Runtime: this launchd-owned process stays idle between application events.
let workspace = NSWorkspace.shared
let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let usageBundleID = "local.codex.usagebar"

func startUsageBar() {
    guard !workspace.runningApplications.contains(where: { $0.bundleIdentifier == usageBundleID && !$0.isTerminated }) else { return }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.createsNewApplicationInstance = false
    workspace.openApplication(at: appURL, configuration: configuration) { app, error in
        if let error { fputs("无法启动额度工具：" + error.localizedDescription + "\n", stderr) }
        // Codex may quit while LaunchServices is still opening the quota app.
        if let app, !workspace.runningApplications.contains(where: { $0.bundleIdentifier == CodexLifecycle.bundleID && !$0.isTerminated }) {
            _ = app.terminate()
        }
    }
}
func stopUsageBar() {
    for app in workspace.runningApplications where app.bundleIdentifier == usageBundleID && !app.isTerminated {
        _ = app.terminate()
    }
}

if CommandLine.arguments.contains("--check") {
    guard FileManager.default.isExecutableFile(atPath: appURL.appendingPathComponent("Contents/MacOS/CodexUsageBar").path),
          Bundle(url: appURL)?.bundleIdentifier == usageBundleID else {
        fputs("找不到额度工具应用。\n", stderr); exit(1)
    }
    print("启停助手就绪；监听 " + CodexLifecycle.bundleID)
    exit(0)
}
let lifecycle = CodexLifecycle(
    isCodexRunning: { workspace.runningApplications.contains { $0.bundleIdentifier == CodexLifecycle.bundleID && !$0.isTerminated } },
    start: startUsageBar, stop: stopUsageBar
)
let launchObserver = workspace.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { notification in
    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    lifecycle.launched(app?.bundleIdentifier)
}
let quitObserver = workspace.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { notification in
    let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
    lifecycle.terminated(app?.bundleIdentifier)
}
lifecycle.synchronize()
RunLoop.main.run()
