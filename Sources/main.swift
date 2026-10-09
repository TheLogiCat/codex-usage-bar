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
    case timeout
    case stopped(Int32)
    case rpc(Int?, String)
    case invalidResponse

    var retryable: Bool {
        switch self {
        case .timeout, .stopped: return true
        case .rpc(let code, let message):
            let text = message.lowercased()
            if code == -32600 || code == -32601 || code == -32602 { return false }
            if text.contains("401") || text.contains("403") || text.contains("not logged in") || text.contains("unauthorized") { return false }
            return true
        case .message, .invalidResponse: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .timeout: return "额度查询超时，已自动重试；稍后会继续刷新。"
        case .stopped(let code): return "本地 Codex 查询服务退出（状态 \(code)），已自动重试。"
        case .invalidResponse: return "Codex 返回的额度格式无法识别，请检查 Codex 是否需要更新。"
        case .rpc(let code, let message):
            let text = message.lowercased()
            if text.contains("401") || text.contains("not logged in") || text.contains("unauthorized") {
                return "Codex 登录状态失效，请在 Codex 中重新登录。"
            }
            if text.contains("403") { return "账户额度查询被拒绝（403），请检查 Codex 账户状态。" }
            if text.contains("429") { return "额度服务请求过于频繁，已自动重试；稍后会继续刷新。" }
            if code == -32600 || code == -32601 || code == -32602 {
                return "本机 Codex 接口不兼容（代码 \(code!)），请更新 Codex。"
            }
            if text.contains("timed out") || text.contains("timeout") {
                return "额度服务响应超时，已自动重试；稍后会继续刷新。"
            }
            if text.contains("error sending request") || text.contains("connection") || text.contains("network") {
                return "额度服务网络请求失败，已自动重试；稍后会继续刷新。"
            }
            return "额度查询失败" + (code.map { "（代码 \($0)）" } ?? "") + "，稍后会继续刷新。"
        }
    }
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
    // A fresh connection on retry also recovers a crashed local query server.
    static func read(executable: String? = QuotaClient.executable, timeout: TimeInterval = 25, retryDelay: TimeInterval = 2) throws -> Limits {
        do { return try readOnce(executable: executable, timeout: timeout) }
        catch let error as QueryError where error.retryable {
            Thread.sleep(forTimeInterval: retryDelay)
            return try readOnce(executable: executable, timeout: timeout)
        }
    }
    private static func readOnce(executable: String?, timeout: TimeInterval) throws -> Limits {
        guard let executable else { throw QueryError.message("找不到 Codex，请先安装并登录 Codex。") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server", "--listen", "stdio://"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        do { try process.run() }
        catch { throw QueryError.message("本地 Codex 查询服务无法启动，请检查 Codex 安装。") }
        let deadline = DispatchWorkItem { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer {
            deadline.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                }
            }
            try? output.fileHandleForReading.close()
        }
        func stoppedError() -> QueryError {
            if ProcessInfo.processInfo.systemUptime - startedAt >= timeout { return .timeout }
            process.waitUntilExit()
            return .stopped(process.terminationStatus)
        }
        func send(_ value: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: value)
            data.append(10)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch {
                // Do not wait on a still-running server that closed only stdin.
                if process.isRunning { process.terminate() }
                throw stoppedError()
            }
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "codex_usage_bar", "title": "Codex Usage Bar", "version": "1.2.2"]]])
        var buffer = Data()
        while true {
            let chunk = output.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let end = buffer.firstIndex(of: 10) {
                let line = buffer.subdata(in: buffer.startIndex..<end)
                buffer.removeSubrange(buffer.startIndex...end)
                guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      let id = object["id"] as? Int, id == 1 || id == 2 else { continue }
                if let error = object["error"] as? [String: Any] {
                    throw QueryError.rpc(error["code"] as? Int, error["message"] as? String ?? "")
                }
                if id == 1 {
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if let result = object["result"] {
                    guard let data = try? JSONSerialization.data(withJSONObject: result),
                          let limits = try? JSONDecoder().decode(Limits.self, from: data) else {
                        throw QueryError.invalidResponse
                    }
                    guard !limits.buckets.isEmpty else { throw QueryError.message("账户暂未返回可显示的用量。") }
                    return limits
                } else { throw QueryError.invalidResponse }
            }
        }
        throw stoppedError()
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

// A template image lets macOS tint every mark for wallpaper contrast and menu selection.
final class StatusQuotaRenderer {
    var windows: [QuotaWindow] = []
    var failed = false
    private let labelFont = NSFont.systemFont(ofSize: 9, weight: .medium)
    private let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
    var preferredWidth: CGFloat {
        let labelWidth = windows.map { ($0.compactLabel as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 11
        let valueWidth = ("100%" as NSString).size(withAttributes: [.font: valueFont]).width
        return ceil(max(54, labelWidth + valueWidth + 12))
    }
    func image() -> NSImage {
        let bounds = NSRect(x: 0, y: 0, width: preferredWidth, height: 22)
        let image = NSImage(size: bounds.size, flipped: true) { [windows = self.windows, failed = self.failed, labelFont = self.labelFont, valueFont = self.valueFont] _ in
        func drawText(_ text: String, x: CGFloat, y: CGFloat, font: NSFont) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: NSColor.black])
        }
        if windows.isEmpty {
            let text = failed ? "额度 !" : "额度 …"
            let size = (text as NSString).size(withAttributes: [.font: valueFont])
            drawText(text, x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, font: valueFont)
        } else {
            let rowHeight: CGFloat = 11
            let rows = Array(windows.prefix(2))
            let startY = (bounds.height - CGFloat(rows.count) * rowHeight) / 2
            for (index, window) in rows.enumerated() {
                let y = startY + CGFloat(index) * rowHeight
                let text = window.remaining.map { String(format: "%.0f%%", $0) } ?? "—"
                let width = (text as NSString).size(withAttributes: [.font: valueFont]).width
                drawText(window.compactLabel, x: 3, y: y, font: labelFont)
                drawText(text, x: bounds.width - 7 - width, y: y, font: valueFont)
                if let remaining = window.remaining {
                    let track = NSRect(x: bounds.width - 37, y: y + 10.25, width: 30, height: 0.75)
                    NSColor.black.withAlphaComponent(0.18).setFill()
                    NSBezierPath(roundedRect: track, xRadius: 0.375, yRadius: 0.375).fill()
                    if remaining > 0 {
                        NSColor.black.setFill()
                        let fill = NSRect(x: track.minX, y: track.minY, width: track.width * remaining / 100, height: track.height)
                        NSBezierPath(roundedRect: fill, xRadius: 0.375, yRadius: 0.375).fill()
                    }
                }
            }
            if failed { drawText("!", x: bounds.width - 5, y: 5.5, font: labelFont) }
        }
        return true
        }
        image.isTemplate = true
        return image
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
// Informational content uses a custom menu view so macOS does not dim it as disabled commands.
struct MenuQuotaCard: View {
    let window: QuotaWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(window.label + "额度")
                    .font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(window.remaining.map { String(format: "%.0f%%", $0) } ?? "—")
                        .font(.system(size: 21, weight: .semibold)).monospacedDigit()
                    Text("剩余").font(.system(size: 11))
                }
            }
            HStack(spacing: 5) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .medium))
                Text(window.resetText).font(.system(size: 12)).monospacedDigit()
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

struct QuotaMenuSummary: View {
    let limits: Limits?
    let updatedAt: Date?
    let error: String?
    let loading: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Codex 剩余额度").font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 2).padding(.bottom, 2)
            if let limits {
                ForEach(limits.buckets, id: \.0) { id, bucket in
                    if limits.buckets.count > 1 {
                        Text(bucket.limitName ?? id).font(.system(size: 12, weight: .semibold))
                    }
                    if let window = bucket.primary { MenuQuotaCard(window: window) }
                    if let window = bucket.secondary { MenuQuotaCard(window: window) }
                }
            } else {
                Text(loading ? "正在读取用量…" : "暂时没有额度数据")
                    .font(.system(size: 12))
            }
            if let error {
                Text(error + (limits == nil ? "" : " 当前显示上次成功数据。"))
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
            if let date = updatedAt {
                Text("上次更新 " + date.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.horizontal, 2).padding(.top, 2)
            }
        }
        .foregroundStyle(.primary).padding(12).frame(width: 288)
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
    let statusRenderer = StatusQuotaRenderer()
    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: 54)
        if let button = status.button {
            button.title = ""
            button.imagePosition = .imageOnly
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
        statusRenderer.windows = model.statusWindows
        statusRenderer.failed = model.error != nil
        status.length = statusRenderer.preferredWidth
        status.button?.image = statusRenderer.image()
        status.button?.toolTip = model.statusDescription
        status.button?.setAccessibilityLabel(model.statusDescription)
    }
    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let summary = QuotaMenuSummary(limits: model.limits, updatedAt: model.updatedAt, error: model.error, loading: model.loading)
        let view = NSHostingView(rootView: summary)
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let info = NSMenuItem()
        info.view = view
        menu.addItem(info)
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
