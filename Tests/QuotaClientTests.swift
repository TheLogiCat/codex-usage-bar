let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: testRoot) }
let fixture = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
var testCount = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func scenario(_ name: String, attempts: Int, expectedError: String? = nil) throws {
    let file = testRoot.appendingPathComponent(name + ".py")
    try fixture.write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    let startedAt = ProcessInfo.processInfo.systemUptime
    do {
        let limits = try QuotaClient.read(executable: file.path, timeout: name == "timeout" ? 0.25 : 3, retryDelay: 0)
        check(expectedError == nil, "Expected failure: " + name)
        check(limits.buckets.first?.1.primary?.remaining == 67, "Decoded remaining quota")
    } catch {
        check(expectedError != nil && error.localizedDescription.contains(expectedError!), "Unexpected error in " + name + ": " + error.localizedDescription)
    }
    let count = try String(contentsOf: file.deletingPathExtension().appendingPathExtension("count"), encoding: .utf8)
    check(Int(count) == attempts, "Wrong retry count: " + name)
    check(ProcessInfo.processInfo.systemUptime - startedAt < 8, "Query did not stop in time")
    testCount += 1
}
try scenario("success", attempts: 1)
try scenario("recover", attempts: 2)
try scenario("recover-crash", attempts: 2)
try scenario("auth", attempts: 1, expectedError: "重新登录")
try scenario("busy", attempts: 2, expectedError: "过于频繁")
try scenario("crash", attempts: 2, expectedError: "状态 7")
try scenario("timeout", attempts: 2, expectedError: "超时")
try scenario("invalid", attempts: 1, expectedError: "格式无法识别")
print("Passed \(testCount) quota query tests")
