// agentdone-hook — Claude Code hooks / Codex notify 的采集端（Swift，无 python 依赖）
// 编译：swiftc -O -target arm64-apple-macos12.0 -sdk <SDK> agentdone-hook.swift -o agentdone-hook
import Foundation
import Darwin

@_silgen_name("proc_pidpath")
private func c_proc_pidpath(_ pid: Int32, _ buffer: UnsafeMutableRawPointer?, _ buffersize: UInt32) -> Int32

let ENV = ProcessInfo.processInfo.environment
let SOCK = ENV["AGENTDONE_SOCK"] ?? "/tmp/agentdone-\(getuid()).sock"
/// 安装目录，默认 ~/.agentdone（安装脚本与本程序保持一致）
let AGENTDONE_HOME = ENV["AGENTDONE_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? (NSHomeDirectory() + "/.agentdone")

// MARK: - 宿主识别

let KNOWN: [(prefix: String, name: String)] = [
    ("com.microsoft.VSCode", "VS Code"),
    ("com.googlecode.iterm2", "iTerm"),
    ("com.apple.Terminal", "Terminal"),
    ("dev.warp.Warp", "Warp"),
    ("com.mitchellh.ghostty", "Ghostty"),
    ("com.openai.codex", "Codex 桌面"),
    ("com.anthropic.claudefordesktop", "Claude 桌面"),
    ("ai.opencode.desktop", "OpenCode"),
    ("dev.zcode.app", "ZCode"),
    ("com.todesktop", "Cursor"),
    ("com.cursor", "Cursor"),
    ("com.exafunction.windsurf", "Windsurf"),
    ("com.apple.dt.Xcode", "Xcode"),
]

let TERM_PROGRAMS: [String: (String, String)] = [
    "vscode": ("VS Code", "com.microsoft.VSCode"),
    "iTerm.app": ("iTerm", "com.googlecode.iterm2"),
    "Apple_Terminal": ("Terminal", "com.apple.Terminal"),
    "WarpTerminal": ("Warp", "dev.warp.Warp-Stable"),
    "ghostty": ("Ghostty", "com.mitchellh.ghostty"),
]

func exePath(_ pid: pid_t) -> String? {
    var buf = [CChar](repeating: 0, count: 4096)
    let n = c_proc_pidpath(pid, &buf, UInt32(buf.count))
    guard n > 0 else { return nil }
    return String(cString: buf)
}

func parentPid(_ pid: pid_t) -> pid_t? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

func appInfo(fromExe path: String) -> (name: String, bundle: String)? {
    guard let r = path.range(of: ".app/") else { return nil }
    let bundlePath = String(path[path.startIndex..<r.upperBound].dropLast())
    let bid = Bundle(path: bundlePath)?.bundleIdentifier
    if let bid, let hit = KNOWN.first(where: { bid.hasPrefix($0.prefix) }) {
        return (hit.name, bid)
    }
    let appName = ((bundlePath as NSString).lastPathComponent as NSString).deletingPathExtension
    guard !appName.isEmpty else { return nil }
    return (appName, bid ?? "")
}

func byAncestry() -> (String, String)? {
    var pid = getppid()
    var depth = 0
    while pid > 1 && depth < 16 {
        if let p = exePath(pid), let info = appInfo(fromExe: p) {
            return (info.name, info.bundle)
        }
        guard let next = parentPid(pid) else { break }
        pid = next
        depth += 1
    }
    return nil
}

func ttyName() -> String {
    for fd in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
        if let p = ttyname(fd) { return String(cString: p) }
    }
    return ""
}

func hostInfo() -> (String, String) {
    // Claude Code 自己会标注入口（扩展 / 桌面 / CLI），比进程树可靠
    switch (ProcessInfo.processInfo.environment["CLAUDE_CODE_ENTRYPOINT"] ?? "").lowercased() {
    case "claude-vscode": return ("VS Code", "com.microsoft.VSCode")
    case "claude-desktop": return ("Claude 桌面", "com.anthropic.claudefordesktop")
    default: break
    }

    // 1) 终端自己声明的（VS Code / iTerm / Warp / Ghostty 的集成终端最可靠）
    if let term = ProcessInfo.processInfo.environment["TERM_PROGRAM"], let hit = TERM_PROGRAMS[term] {
        return hit
    }
    // 2) 进程祖先链里第一个 .app（覆盖 VS Code 扩展宿主、Codex 桌面等无终端场景）
    if let hit = byAncestry() { return hit }
    // 3) LaunchServices 注入的 bundle id
    if let bid = ProcessInfo.processInfo.environment["__CFBundleIdentifier"],
       let hit = KNOWN.first(where: { bid.hasPrefix($0.prefix) }) {
        return (hit.name, bid)
    }
    return ("终端", "")
}

// MARK: - transcript 摘要

func lastAssistantText(_ path: String?) -> String {
    guard let path, !path.isEmpty, let fh = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let window: UInt64 = 96 * 1024
    try? fh.seek(toOffset: size > window ? size - window : 0)
    guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return "" }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    while let line = lines.popLast() {
        guard line.hasPrefix("{"),
              let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
              obj["type"] as? String == "assistant",
              (obj["isSidechain"] as? Bool) != true else { continue }
        var raw = ""
        if let msg = obj["message"] as? [String: Any] {
            if let blocks = msg["content"] as? [[String: Any]] {
                for b in blocks where (b["type"] as? String) == "text" {
                    raw = (b["text"] as? String) ?? ""
                    break
                }
            } else if let s = msg["content"] as? String {
                raw = s
            }
        }
        let collapsed = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        if !collapsed.isEmpty {
            return String(collapsed.prefix(80))
        }
    }
    return ""
}

// MARK: - 发送

func send(_ payload: [String: Any], timeout: TimeInterval = 0.35) -> Int32? {
    guard let blob = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let cap = MemoryLayout.size(ofValue: addr.sun_path)
    _ = SOCK.utf8CString.withUnsafeBufferPointer { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            dst.withMemoryRebound(to: CChar.self, capacity: cap) { d in
                memcpy(d, src.baseAddress!, min(cap, src.count))
            }
        }
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let ok = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    guard ok == 0 else { close(fd); return nil }
    var line = blob
    line.append(0x0A)
    _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    return fd
}

// MARK: - 事件映射

func readStdin() -> [String: Any] {
    guard isatty(STDIN_FILENO) == 0 else { return [:] }
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while data.count < (1 << 22) {
        let n = read(STDIN_FILENO, &buf, buf.count)
        if n <= 0 { break }
        data.append(buf, count: n)
    }
    guard !data.isEmpty,
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
    return obj
}

/// 会话名：Claude Code 把标题写成 transcript 里的 custom-title 行（最后一行为准）
func sessionTitle(_ path: String?) -> String {
    guard let path, !path.isEmpty,
          let fh = FileHandle(forReadingAtPath: path) else { return "" }
    defer { try? fh.close() }
    let size = (try? fh.seekToEnd()) ?? 0
    let window: UInt64 = 96 * 1024
    try? fh.seek(toOffset: size > window ? size - window : 0)
    guard let data = fh.readDataToEndOfFile() as Data?,
          let text = String(data: data, encoding: .utf8) else { return "" }
    var title = ""
    for line in text.split(separator: "\n") where line.contains("\"custom-title\"") {
        guard let d = line.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              (obj["type"] as? String) == "custom-title",
              let t = obj["customTitle"] as? String, !t.isEmpty else { continue }
        title = t
    }
    return String(title.prefix(60))
}

/// 「等待批准：Bash · git push origin main」——替你省掉一次切窗口才知道批什么
func approvalDetail(_ input: [String: Any]) -> String {
    let tool = (input["tool_name"] as? String) ?? "工具"
    let args = (input["tool_input"] as? [String: Any]) ?? [:]
    var what = ""
    if let cmd = args["command"] as? String {
        what = cmd
    } else if let q = args["question"] as? String {
        what = q
    } else if let fp = args["file_path"] as? String {
        what = (fp as NSString).lastPathComponent
    } else if let plan = args["plan"] as? String {
        what = plan
    } else if let pattern = args["pattern"] as? String {
        what = pattern
    } else if let url = args["url"] as? String {
        what = url
    }
    what = what.replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if what.isEmpty { return "等待批准：\(tool)" }
    return String(("等待批准：\(tool) · \(what)").prefix(80))
}

func claudeEvent(_ input: [String: Any]) -> [String: Any]? {
    let event = (input["hook_event_name"] as? String) ?? ""
    let kind: String
    switch event {
    case "Stop": kind = "done"
    case "Notification", "PermissionRequest": kind = "needs"
    case "SessionStart", "UserPromptSubmit", "PostToolUse": kind = "working"
    case "SessionEnd": kind = "gone"
    default: return nil
    }
    let (host, bundle) = hostInfo()
    var detail = ""
    if event == "Stop" {
        detail = lastAssistantText(input["transcript_path"] as? String)
    } else if event == "Notification" {
        detail = String(((input["message"] as? String) ?? "").prefix(80))
    } else if event == "PermissionRequest" {
        detail = approvalDetail(input)
    }
    return [
        "v": 1, "agent": "claude", "kind": kind,
        // PostToolUse 每个工具调用都会触发，没必要每次都读 96KB transcript 取名字
        "title": event == "PostToolUse" ? "" : sessionTitle(input["transcript_path"] as? String),
        "sessionId": (input["session_id"] as? String) ?? "",
        "cwd": (input["cwd"] as? String) ?? FileManager.default.currentDirectoryPath,
        "detail": detail, "host": host, "bundleId": bundle, "tty": ttyName(),
    ]
}

func codexEvent(_ raw: String) -> [String: Any]? {
    guard let data = raw.data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    if let t = obj["type"] as? String, t != "agent-turn-complete" { return nil }
    let (host, bundle) = hostInfo()
    let msg = ((obj["last-assistant-message"] as? String) ?? "")
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return [
        "v": 1, "agent": "codex", "kind": "done",
        "sessionId": (obj["turn-id"] as? String) ?? "",
        "cwd": (obj["cwd"] as? String) ?? FileManager.default.currentDirectoryPath,
        "detail": String(msg.prefix(80)), "host": host, "bundleId": bundle, "tty": ttyName(),
    ]
}

// MARK: - 安装 / 移除 Claude Code hooks（用 Swift 做，避免依赖 python3）

let HOOK_EVENTS = ["Stop", "Notification", "PermissionRequest", "SessionStart", "PostToolUse", "SessionEnd"]

func homeDir() -> String {
    // NSHomeDirectory() 不认 $HOME，测试/多用户场景要显式优先
    ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
}

/// ~/.agentdone/config.json 里的 paths（数据目录可配置）
func configPaths() -> [String: String] {
    guard let d = FileManager.default.contents(atPath: homeDir() + "/.agentdone/config.json"),
          let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let paths = obj["paths"] as? [String: String] else { return [:] }
    return paths
}

func expand(_ p: String) -> String {
    if p == "~" { return homeDir() }
    if p.hasPrefix("~/") { return homeDir() + String(p.dropFirst(1)) }
    return p
}

/// Claude 的配置目录：CLAUDE_CONFIG_DIR > config.json 的 paths.claude > ~/.claude
func claudeDir() -> String {
    if let e = ProcessInfo.processInfo.environment["AGENTDONE_CLAUDE_ROOT"], !e.isEmpty { return expand(e) }
    if let e = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !e.isEmpty { return expand(e) }
    if let d = configPaths()["claude"], !d.isEmpty { return expand(d) }
    return homeDir() + "/.claude"
}

func settingsPath() -> String {
    claudeDir() + "/settings.json"
}

func readSettings(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path) else { return [:] }
    if data.isEmpty { return [:] }
    guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return obj
}

func backup(_ path: String) {
    let ts = Int(Date().timeIntervalSince1970)
    let dst = "\(path).agentdone-backup-\(ts)"
    do {
        try FileManager.default.copyItem(atPath: path, toPath: dst)
        print("    备份: \(dst)")
    } catch {
        print("    ! 备份失败（继续，但不改原文件更安全）: \(error.localizedDescription)")
    }
}

func writeSettings(_ obj: [String: Any], to path: String) -> Bool {
    guard let data = try? JSONSerialization.data(withJSONObject: obj,
                                                 options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        return false
    }
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return true
    } catch {
        print("    ! 写入失败：\(error.localizedDescription)")
        return false
    }
}

func installHooks() -> Int32 {
    let path = settingsPath()
    let hookBin = AGENTDONE_HOME + "/agentdone-hook"
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                             withIntermediateDirectories: true)
    guard var root = readSettings(path) else {
        print("    ! 现有 settings.json 不是合法 JSON，已跳过（未做任何修改）")
        return 1
    }
    if FileManager.default.fileExists(atPath: path), !(root.isEmpty) { backup(path) }
    var hooks = (root["hooks"] as? [String: Any]) ?? [:]
    let cmd = hookBin + " claude"
    var added: [String] = []
    for event in HOOK_EVENTS {
        var entries = (hooks[event] as? [[String: Any]]) ?? []
        let already = entries.contains { e in
            guard let inner = e["hooks"] as? [[String: Any]] else { return false }
            return inner.contains { (($0["command"] as? String) ?? "").contains("agentdone-hook") }
        }
        if already { continue }
        entries.append(["hooks": [["type": "command", "command": cmd, "timeout": 5]]])
        hooks[event] = entries
        added.append(event)
    }
    if added.isEmpty {
        print("    Claude Code hooks 已存在，无需改动")
        return 0
    }
    root["hooks"] = hooks
    guard writeSettings(root, to: path) else { return 1 }
    print("    \(path) 已加入: \(added.joined(separator: ", "))")
    return 0
}

func removeHooks() -> Int32 {
    let path = settingsPath()
    guard FileManager.default.fileExists(atPath: path) else { return 0 }
    guard var root = readSettings(path) else {
        print("    ! settings.json 不是合法 JSON，跳过")
        return 1
    }
    var hooks = (root["hooks"] as? [String: Any]) ?? [:]
    var changed = false
    for event in Array(hooks.keys) {
        guard let entries = hooks[event] as? [[String: Any]] else { continue }
        let kept = entries.filter { e in
            guard let inner = e["hooks"] as? [[String: Any]] else { return true }
            return !inner.contains { (($0["command"] as? String) ?? "").contains("agentdone-hook") }
        }
        if kept.count != entries.count {
            changed = true
            if kept.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = kept }
        }
    }
    if !changed { return 0 }
    backup(path)
    if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
    guard writeSettings(root, to: path) else { return 1 }
    print("    已从 \(path) 移除 AgentDone hooks")
    return 0
}

// MARK: - 远端（VS Code Remote / devspace）安装

func discoverRemoteHost() -> String? {
    if let r = ProcessInfo.processInfo.environment["AGENTDONE_REMOTE"], !r.isEmpty { return r }
    let list = homeDir() + "/.agentdone/remotes"
    if let txt = try? String(contentsOfFile: list, encoding: .utf8) {
        for raw in txt.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty && !line.hasPrefix("#") { return line }
        }
    }
    let p = homeDir() + "/Library/Application Support/Code/User/globalStorage/storage.json"
    guard let data = FileManager.default.contents(atPath: p),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let ws = obj["windowsState"] as? [String: Any],
          let win = ws["lastActiveWindow"] as? [String: Any],
          let auth = win["remoteAuthority"] as? String,
          auth.hasPrefix("ssh-remote+") else { return nil }
    return String(auth.dropFirst("ssh-remote+".count))
}

@discardableResult
func runCmd(_ path: String, _ arguments: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = arguments
    p.standardInput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return -1 }
    p.waitUntilExit()
    return p.terminationStatus
}

func remoteHooks(remove: Bool) -> Int32 {
    guard let host = discoverRemoteHost() else {
        print("    未发现远程主机（没有 VS Code Remote 连接，也没有 ~/.agentdone/remotes）")
        return 0
    }
    let opts = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "StrictHostKeyChecking=accept-new"]
    guard runCmd("/usr/bin/ssh", opts + [host, "true"]) == 0 else {
        print("    ! 连不上 \(host)，跳过")
        return 0
    }

    guard let script = try? String(contentsOfFile: homeDir() + "/.agentdone/remote/install_hooks.py",
                                   encoding: .utf8) else {
        print("    ! 缺少 ~/.agentdone/remote/install_hooks.py")
        return 0
    }

    // 脚本从 stdin 送进去，远端不落地任何脚本文件
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    p.arguments = opts + [host, remove ? "python3 - --remove" : "python3 - --install"]
    let inp = Pipe(), out = Pipe()
    p.standardInput = inp
    p.standardOutput = out
    p.standardError = out
    do { try p.run() } catch { return 0 }
    inp.fileHandleForWriting.write(script.data(using: .utf8) ?? Data())
    try? inp.fileHandleForWriting.close()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    print(String(data: data, encoding: .utf8) ?? "")
    return 0
}

// MARK: - main


func printStatus() -> Int32 {
    guard let fd = send(["cmd": "status"], timeout: 1.0) else {
        print("AgentDone 没有在运行（或 socket 不存在）")
        return 1
    }
    defer { close(fd) }
    var out = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        out.append(buf, count: n)
    }
    if out.isEmpty { print("{}"); return 0 }
    print(String(data: out, encoding: .utf8) ?? "{}")
    return 0
}

let args = Array(CommandLine.arguments.dropFirst())

if args.contains("--status") {
    exit(printStatus())
}
if args.contains("--install-hooks") {
    exit(installHooks())
}
if args.contains("--remove-hooks") {
    exit(removeHooks())
}
if args.contains("--install-remote") {
    exit(remoteHooks(remove: false))
}
if args.contains("--remove-remote") {
    exit(remoteHooks(remove: true))
}

let mode = args.first ?? "claude"
var payload: [String: Any]?

switch mode {
case "claude":
    payload = claudeEvent(readStdin())
case "codex":
    payload = codexEvent(args.dropFirst().first ?? "{}")
case "demo":
    let kind = args.dropFirst().first ?? "done"
    let (host, bundle) = hostInfo()
    payload = [
        "v": 1, "agent": args.count > 2 ? args[2] : "claude", "kind": kind,
        "sessionId": "demo-\(getpid())",
        "cwd": FileManager.default.currentDirectoryPath,
        "detail": "这是一条演示提醒", "host": host, "bundleId": bundle, "tty": ttyName(),
    ]
default:
    break
}

if let payload, let fd = send(payload) {
    close(fd)
}
exit(0)
