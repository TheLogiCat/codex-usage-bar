import AppKit
import SwiftUI

// Report a closed server pipe as a refresh error instead of terminating the UI.
signal(SIGPIPE, SIG_IGN)

struct QuotaWindow: Decodable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?
    var remaining: Double? { usedPercent.flatMap { $0.isFinite ? max(0, min(100, 100 - $0)) : nil } }
    var label: String {
        guard let mins = windowDurationMins else { return "当前周期" }
        if mins == 10080 { return "本周" }
        if mins % 1440 == 0 { return "\(mins / 1440)天" }
        if mins % 60 == 0 { return "\(mins / 60)小时" }
        return "\(mins)分钟"
    }
    var compactLabel: String {
        guard let mins = windowDurationMins else { return "?" }
        if mins == 10080 { return "周" }
        if mins % 1440 == 0 { return "\(mins / 1440)d" }
        if mins % 60 == 0 { return "\(mins / 60)h" }
        return "\(mins)m"
    }
    var resetText: String {
        guard let resetsAt else { return "重置时间暂不可用" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日 HH:mm"
        return "重置于 " + formatter.string(from: Date(timeIntervalSince1970: resetsAt))
    }
}
struct Bucket: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
}
struct Limits: Decodable {
    let rateLimits: Bucket?
    let rateLimitsByLimitId: [String: Bucket]?
    var buckets: [(String, Bucket)] {
        if let all = rateLimitsByLimitId, !all.isEmpty {
            return all.sorted { a, b in
                if a.key == "codex" { return b.key != "codex" }
                if b.key == "codex" { return false }
                return a.key < b.key
            }.map { ($0.key, $0.value) }
        }
        if let single = rateLimits { return [(single.limitId ?? "codex", single)] }
        return []
    }
}
enum QueryError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum QuotaClient {
    static var executable: String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func read() throws -> Limits {
        guard let executable else { throw QueryError.message("找不到 Codex，请先安装并登录 Codex。") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: deadline)
        defer {
            deadline.cancel()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_usage_bar", "title": "Codex Usage Bar", "version": "1.0.0"]]])
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<end)
                buffer.removeSubrange(buffer.startIndex...end)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int else { continue }
                if object["error"] != nil {
                    throw QueryError.message("用量读取失败，请确认 Codex 已登录且网络连接正常。")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2, let result = object["result"] {
                    let data = try JSONSerialization.data(withJSONObject: result)
                    let limits = try JSONDecoder().decode(Limits.self, from: data)
                    guard !limits.buckets.isEmpty else { throw QueryError.message("账户暂未返回可显示的用量。") }
                    return limits
                }
            }
        }
        throw QueryError.message("读取超时或服务未启动，请确认 Codex 已登录，然后刷新。")
    }
}

final class UsageModel: ObservableObject {
    @Published var limits: Limits?
    @Published var updatedAt: Date?
    @Published var error: String?
    @Published var loading = false
    var changed: (() -> Void)?
    func refresh() {
        guard !loading else { return }
        loading = true
        changed?()
        DispatchQueue.global(qos: .utility).async {
            let result = Result { try QuotaClient.read() }
            DispatchQueue.main.async {
                self.loading = false
                switch result {
                case .success(let value):
                    self.limits = value; self.updatedAt = Date(); self.error = nil
                case .failure(let error): self.error = error.localizedDescription
                }
                self.changed?()
            }
        }
    }
    var statusWindows: [QuotaWindow] {
        guard let bucket = limits?.buckets.first?.1 else { return [] }
        return [bucket.primary, bucket.secondary].compactMap { $0 }
    }
    var statusDescription: String {
        var lines = ["Codex 剩余额度"]
        lines += statusWindows.map { w in
            w.label + "剩余 " + (w.remaining.map { String(format: "%.0f%%", $0) } ?? "未知")
        }
        if let updatedAt { lines.append("更新于 " + updatedAt.formatted(date: .omitted, time: .standard)) }
        if let error { lines.append("读取失败：" + error + (limits == nil ? "" : " 当前为上次数据。")) }
        return lines.joined(separator: "\n")
    }
}

// Draw into the native status button. Mouse events stay with the button and its menu.
final class StatusQuotaView: NSView {
    var windows: [QuotaWindow] = []
    var failed = false
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    private let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    var preferredWidth: CGFloat {
        let labelWidth = windows.map { ($0.compactLabel as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 11
        let valueWidth = ("100%" as NSString).size(withAttributes: [.font: valueFont]).width
        return ceil(max(54, labelWidth + valueWidth + 12))
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let highlighted = (superview as? NSStatusBarButton)?.isHighlighted == true
        let foreground: NSColor = highlighted ? .selectedMenuItemTextColor : .labelColor
        let secondary: NSColor = highlighted ? foreground : .secondaryLabelColor
        func drawText(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: color])
        }
        if windows.isEmpty {
            let text = failed ? "额度 !" : "额度 …"
            let size = (text as NSString).size(withAttributes: [.font: valueFont])
            drawText(text, x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, font: valueFont, color: foreground)
            return
        }
        let rowHeight: CGFloat = 11
        let startY = (bounds.height - CGFloat(windows.count) * rowHeight) / 2
        for (index, window) in windows.prefix(2).enumerated() {
            let y = startY + CGFloat(index) * rowHeight
            let text = window.remaining.map { String(format: "%.0f%%", $0) } ?? "—"
            let width = (text as NSString).size(withAttributes: [.font: valueFont]).width
            let color: NSColor = !highlighted && (failed || (window.remaining.map { $0 <= 20 } ?? false)) ? .systemOrange : foreground
            drawText(window.compactLabel, x: 3, y: y + 0.5, font: labelFont, color: secondary)
            drawText(text, x: bounds.width - 7 - width, y: y, font: valueFont, color: color)
        }
        if failed {
            drawText("!", x: bounds.width - 5, y: (bounds.height - 11) / 2, font: labelFont, color: highlighted ? foreground : .systemOrange)
        }
    }
}

struct QuotaRow: View {
    let window: QuotaWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(window.label + "剩余").font(.system(size: 14, weight: .medium))
                Spacer()
                Text(window.remaining.map { String(format: "%.0f%%", $0) } ?? "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            if let remaining = window.remaining {
                ProgressView(value: remaining, total: 100)
                    .tint(remaining <= 10 ? .red : remaining <= 25 ? .orange : .green)
            }
            Text(window.resetText).font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(14).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}
struct UsageView: View {
    @ObservedObject var model: UsageModel
    @State var floating = true
    var setFloating: (Bool) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Codex 剩余额度").font(.system(size: 21, weight: .semibold))
                    Text("每 60 秒自动刷新").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: { model.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }.disabled(model.loading).help("立即刷新")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let limits = model.limits {
                        ForEach(limits.buckets, id: \.0) { id, bucket in
                            if limits.buckets.count > 1 {
                                Text(bucket.limitName ?? id).font(.headline)
                            }
                            if let window = bucket.primary { QuotaRow(window: window) }
                            if let window = bucket.secondary { QuotaRow(window: window) }
                        }
                    } else if model.loading { ProgressView("正在读取用量…").padding() }
                    if let error = model.error {
                        Text(error + (model.limits == nil ? "" : " 当前显示上次成功读取的数据。"))
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                if let date = model.updatedAt {
                    Text("更新于 " + date.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("置顶", isOn: $floating).toggleStyle(.checkbox)
                    .onChange(of: floating) { value in setFloating(value) }
            }
        }.padding(20).frame(width: 350, height: 360)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = UsageModel()
    var status: NSStatusItem!
    var window: NSWindow?
    var timer: Timer?
    let statusView = StatusQuotaView(frame: .zero)
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: 54)
        if let button = status.button {
            button.title = ""
            statusView.frame = button.bounds
            statusView.autoresizingMask = [.width, .height]
            button.addSubview(statusView)
        }
        let menu = NSMenu()
        menu.delegate = self
        status.menu = menu
        model.changed = { [weak self] in self?.update() }
        update()
        model.refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.model.refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }
    func update() {
        statusView.windows = model.statusWindows
        statusView.failed = model.error != nil
        status.length = statusView.preferredWidth
        statusView.needsDisplay = true
        status.button?.toolTip = model.statusDescription
        status.button?.setAccessibilityLabel(model.statusDescription)
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        if let limits = model.limits {
            for (id, bucket) in limits.buckets {
                let heading = NSMenuItem(title: bucket.limitName ?? (id == "codex" ? "Codex 剩余额度" : id), action: nil, keyEquivalent: "")
                menu.addItem(heading)
                for w in [bucket.primary, bucket.secondary].compactMap({ $0 }) {
                    menu.addItem(NSMenuItem(title: w.label + "剩余 " + (w.remaining.map { String(format: "%.0f%%", $0) } ?? "—"), action: nil, keyEquivalent: ""))
                    menu.addItem(NSMenuItem(title: w.resetText, action: nil, keyEquivalent: ""))
                }
            }
        }
        if let error = model.error { menu.addItem(NSMenuItem(title: error, action: nil, keyEquivalent: "")) }
        if let date = model.updatedAt { menu.addItem(NSMenuItem(title: "更新于 " + date.formatted(date: .omitted, time: .standard), action: nil, keyEquivalent: "")) }
        menu.addItem(.separator())
        for (title, selector, key) in [("显示独立窗口", #selector(showWindow), ""), ("立即刷新", #selector(refresh), "r"), ("退出", #selector(quit), "q")] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.target = self
            menu.addItem(item)
        }
    }
    @objc func showWindow() {
        if window == nil {
            let view = UsageView(model: model) { [weak self] floating in self?.window?.level = floating ? .floating : .normal }
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 350, height: 360), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            w.title = "Codex 剩余额度"
            w.contentView = NSHostingView(rootView: view)
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func refresh() { model.refresh() }
    @objc func woke() { model.refresh() }
    @objc func quit() { NSApp.terminate(nil) }
}

if CommandLine.arguments.contains("--check") {
    do {
        let limits = try QuotaClient.read()
        for (id, bucket) in limits.buckets {
            for w in [bucket.primary, bucket.secondary].compactMap({ $0 }) {
                print("\(id) \(w.label)剩余 \(w.remaining.map { String(format: "%.0f%%", $0) } ?? "—") \(w.resetText)")
            }
        }
    } catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
