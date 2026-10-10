var codexRunning = false
var actions: [String] = []
let follower = CodexLifecycle(isCodexRunning: { codexRunning }, start: { actions.append("start") }, stop: { actions.append("stop") })
func expect(_ expected: [String], _ message: String) {
    precondition(actions == expected, message)
    actions.removeAll()
}
follower.synchronize()
expect(["stop"], "No Codex at login: stop a stale quota app")
codexRunning = true
follower.synchronize()
expect(["start"], "Codex already running at login: start quota app")
follower.launched("com.example.unrelated")
follower.terminated(nil)
follower.terminated("com.example.unrelated")
expect([], "Other apps must not affect quota app")
follower.launched(CodexLifecycle.bundleID)
expect(["start"], "Codex launch starts quota app")
follower.terminated(CodexLifecycle.bundleID)
expect([], "Another Codex process is still running: keep quota app")
codexRunning = false
follower.terminated(CodexLifecycle.bundleID)
expect(["stop"], "Last Codex process exiting stops quota app")
print("Passed 6 Codex lifecycle scenarios")
