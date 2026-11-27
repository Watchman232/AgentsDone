// AgentsDone — 极轻量多 AI 编码会话「完成提醒」
// 单文件 AppKit + SwiftUI，无第三方依赖，编译：swiftc -O -parse-as-library
import AppKit
import SwiftUI
import Darwin
import SQLite3
import Carbon.HIToolbox

// MARK: - 事件与状态

struct HookEvent: Codable {
    var agent: String = "claude"
    var kind: String = "done"          // working | done | needs | gone
    var sessionId: String?
    var cwd: String?
    var project: String?
    var title: String?
    var detail: String?
    var host: String?
    var bundleId: String?
    var tty: String?
    var ts: Double?
}

enum SState: String, Codable { case working, done, needs }

struct Session: Identifiable {
    var id: String
    var agent: String
    var project: String
    var title: String? = nil
    var cwd: String
    var host: String
    var bundleId: String?
    var tty: String?
    var state: SState
    var detail: String
    var updated: Date
}

func agentLabel(_ a: String) -> String {
    switch a {
    case "claude": return "Claude"
    case "codex": return "Codex"
    case "opencode": return "OpenCode"
    case "dsh": return "DeepSeek Harness"
    case "zcode": return "ZCode"
    case "antigravity": return "Antigravity"
    default: return a.capitalized
    }
}

func agentInitial(_ a: String) -> String {
    switch a {
    case "claude": return "C"
    case "codex": return "X"
    case "dsh": return "D"
    case "zcode": return "Z"
    case "antigravity": return "A"
    default: return String(agentLabel(a).prefix(1))
    }
}

func agentColor(_ a: String) -> Color {
    switch a {
    case "claude": return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "codex": return Color(red: 0.30, green: 0.55, blue: 0.95)
    case "dsh": return Color(red: 0.30, green: 0.42, blue: 0.98)
    case "zcode": return Color(red: 0.10, green: 0.60, blue: 0.55)
    case "antigravity": return Color(red: 0.35, green: 0.62, blue: 0.86)
    default: return Color(red: 0.45, green: 0.45, blue: 0.50)
    }
}

// MARK: - Store

final class Store: ObservableObject {
    @Published var sessions: [Session] = [] { didSet { onChange?() } }
    @Published var muted = false { didSet { onChange?() } }
    /// 静音到什么时候；nil 表示没在静音
    @Published var snoozeUntil: Date? = nil { didSet { onChange?() } }

    var snoozed: Bool {
        guard let t = snoozeUntil else { return false }
        return t > Date()
    }
    /// 现在该不该出声
    var quiet: Bool { muted || snoozed }
    var onChange: (() -> Void)?

    var awaiting: Int { sessions.filter { $0.state != .working }.count }

    /// 列表显示全部会话（运行中 / 已完成 / 待批准），排序见 ingest
    var pending: [Session] { sessions }

    var running: Int { sessions.filter { $0.state == .working }.count }

    func ingest(_ ev: HookEvent, source: String = "hook") {
        let cwd = ev.cwd ?? ""
        let project = ev.project ?? (cwd.isEmpty ? agentLabel(ev.agent) : (cwd as NSString).lastPathComponent)
        let title = (ev.title?.isEmpty == false) ? ev.title : nil
        let key = "\(ev.agent):\(ev.sessionId ?? cwd)"
        let host = ev.host ?? "终端"

        if ev.kind == "gone" {
            // 会话结束时有结论（完成/需要你）就保留 —— 尤其是 -p 这类一次跑完立刻退出的场景，
            // Stop 和 SessionEnd 只隔几十毫秒，删掉用户就永远看不到了
            if let i = sessions.firstIndex(where: { $0.id == key }), sessions[i].state != .working {
                return
            }
            sessions.removeAll { $0.id == key }
            return
        }

        var state: SState = .done
        switch ev.kind {
        case "working": state = .working
        case "needs": state = .needs
        default: state = .done
        }

        if let i = sessions.firstIndex(where: { $0.id == key }) {
            sessions[i].state = state
            sessions[i].updated = Date()
            sessions[i].detail = ev.detail ?? sessions[i].detail
            sessions[i].host = host
            sessions[i].cwd = cwd.isEmpty ? sessions[i].cwd : cwd
            if let b = ev.bundleId { sessions[i].bundleId = b }
            if let t = ev.tty { sessions[i].tty = t }
            if let ti = title { sessions[i].title = ti }
        } else {
            sessions.append(Session(id: key, agent: ev.agent, project: project, title: title, cwd: cwd,
                                    host: host, bundleId: ev.bundleId, tty: ev.tty,
                                    state: state, detail: ev.detail ?? "", updated: Date()))
        }
        sessions.sort { a, b in
            func rank(_ s: SState) -> Int { s == .needs ? 0 : (s == .done ? 1 : 2) }
            if rank(a.state) != rank(b.state) { return rank(a.state) < rank(b.state) }
            return a.updated > b.updated
        }
        prune()
    }

    func ack(_ id: String) { sessions.removeAll { $0.id == id } }
    func clearDone() { sessions.removeAll { $0.state != .working } }
    func prune() {
        // 现在运行中也显示，所以它同样要过期：6 小时没有任何动静的会话不该一直占着
        let cutoff = Date().addingTimeInterval(-6 * 3600)
        sessions.removeAll { $0.updated < cutoff }
    }

    func json() -> Data {
        let arr: [[String: Any]] = sessions.map {
            ["agent": $0.agent, "project": $0.project, "title": $0.title ?? "", "host": $0.host,
             "state": $0.state.rawValue, "detail": $0.detail,
             "cwd": $0.cwd, "id": $0.id]
        }
        let obj: [String: Any] = ["ok": true, "count": awaiting, "sessions": arr]
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }
}

// MARK: - Unix socket server

final class EventServer {
    private let path: String
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "agentsdone.server", qos: .userInitiated)
    var onEvent: ((HookEvent) -> Void)?
    var onStatus: (() -> Data)?

    init(path: String) { self.path = path }

    func start() { queue.async { [weak self] in self?.run() } }

    private func run() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("AgentsDone: socket() failed"); return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.utf8CString.withUnsafeBufferPointer { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: capacity) { d in
                    memcpy(d, src.baseAddress!, min(capacity, src.count))
                }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0 else { NSLog("AgentsDone: bind failed \(errno)"); close(fd); return }
        chmod(path, 0o600)
        guard listen(fd, 32) == 0 else { close(fd); return }
        listenFD = fd
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            DispatchQueue.global(qos: .utility).async { [weak self] in self?.handle(client) }
        }
    }

    private func handle(_ client: Int32) {
        defer { close(client) }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        var data = Data()
        while data.count < (1 << 20) {
            let n = read(client, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if data.last == 0x0A { break }
        }
        guard !data.isEmpty else { return }
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           (obj["cmd"] as? String) == "status" {
            let resp = DispatchQueue.main.sync { self.onStatus?() } ?? Data("{}".utf8)
            _ = resp.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
            return
        }
        guard let ev = try? JSONDecoder().decode(HookEvent.self, from: data) else { return }
        DispatchQueue.main.async { self.onEvent?(ev) }
    }
}

// MARK: - Codex rollout 监听（无需任何配置，覆盖 CLI / VS Code 扩展 / 桌面 App）


// MARK: - Codex 会话名

/// Codex 的"会话名"有两处来源：
/// 1) `~/.codex/state_*.sqlite` 的 threads 表 —— VS Code 扩展里显示的就是这个（会话被重命名/自动起名后也会更新）
/// 2) rollout 里第一条**真实的**用户输入 —— 扩展常把「引用别的会话」写成首条消息，
///    直接取会得到一个满屏 UUID 的链接，所以要先剥链接再判断值不值得用
enum CodexTitle {
    static var home: String {
        if let e = ProcessInfo.processInfo.environment["AGENTSDONE_CODEX_DB"], !e.isEmpty { return e }
        return AgentPaths.base("codex")
    }

    /// state_N.sqlite 会随版本升级，取编号最大的那个
    static func dbPath() -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: home) else { return nil }
        let dbs = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite") else { return nil }
            let digits = name.dropFirst(6).dropLast(7)
            guard let n = Int(digits) else { return nil }
            return (n, home + "/" + name)
        }
        return dbs.max { $0.0 < $1.0 }?.1
    }

    /// rollout 文件名末尾是会话 UUID：rollout-2026-11-23T15-53-03-01a2091c-....jsonl
    static func sessionId(from path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let pattern = "[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        guard let m = re.matches(in: name, options: [], range: range).last,
              let r = Range(m.range, in: name) else { return nil }
        return String(name[r])
    }

    static func name(id: String) -> String? {
        guard let dbPath = dbPath() else { return nil }
        let sql = "select coalesce(nullif(name,''), nullif(title,'')) from threads where id = ? limit 1;"
        for uri in ["file:\(dbPath)?mode=ro", "file:\(dbPath)?immutable=1"] {
            var db: OpaquePointer?
            let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI
            guard sqlite3_open_v2(uri, &db, flags, nil) == SQLITE_OK, let db else { continue }
            defer { sqlite3_close(db) }
            sqlite3_busy_timeout(db, 200)
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            let raw = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
            let cleaned = clean(raw)
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    /// 去掉「引用会话」这类噪声，只留下人能看懂的部分
    static func clean(_ raw: String) -> String {
        var text = raw
        // [Chat thread](codex://threads/<uuid>) —— 引用别的会话，整个丢掉
        if let re = try? NSRegularExpression(pattern: "\\[[^\\]]*\\]\\(codex://[^)]*\\)") {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        // [label](http…) -> label（label 为空或与目标相同则保留目标）
        if let re = try? NSRegularExpression(pattern: "\\[([^\\]]*)\\]\\(([^)]+)\\)") {
            let ns = text as NSString
            var out = ""
            var last = 0
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let label = m.range(at: 1).location == NSNotFound ? "" : ns.substring(with: m.range(at: 1))
                let target = m.range(at: 2).location == NSNotFound ? "" : ns.substring(with: m.range(at: 2))
                out += label.isEmpty ? target : label
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            text = out
        }
        // 剩下的裸 codex:// 链接
        if let re = try? NSRegularExpression(pattern: "codex://\\S*") {
            text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        text = text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "，,。.、:：;；-—~·…"))
        return text.count >= 2 ? String(text.prefix(60)) : ""
    }
}

/// Codex 的「等你批准 / 等你回答」事件 → 一行摘要
enum CodexNeeds {
    static let requestKinds: Set<String> = [
        "exec_approval_request", "apply_patch_approval_request",
        "request_user_input", "request_permissions", "elicitation_request",
    ]

    static func detail(kind: String, payload: [String: Any]) -> String {
        func str(_ v: Any?) -> String {
            if let s = v as? String { return s }
            if let a = v as? [String] { return a.joined(separator: " ") }
            if let a = v as? [[String: Any]] { return a.compactMap { $0["text"] as? String }.joined(separator: " ") }
            return ""
        }
        func clean(_ raw: String) -> String {
            var t = raw.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
            return String(t.prefix(56))
        }

        switch kind {
        case "exec_approval_request":
            let cmd = clean(str(payload["command"]))
            return cmd.isEmpty ? "等待批准：执行命令" : "等待批准：\(cmd)"
        case "apply_patch_approval_request":
            let target = clean(str(payload["grant_root"]).isEmpty ? str(payload["path"]) : str(payload["grant_root"]))
            let reason = clean(str(payload["reason"]))
            if !target.isEmpty { return "等待批准：修改 \(target)" }
            return reason.isEmpty ? "等待批准：修改文件" : "等待批准：\(reason)"
        case "request_user_input":
            // questions[0].question
            if let qs = payload["questions"] as? [[String: Any]], let q = qs.first,
               case let text = clean(str(q["question"])), !text.isEmpty {
                return "等待回答：\(text)"
            }
            let q = clean(str(payload["question"]))
            return q.isEmpty ? "等待回答" : "等待回答：\(q)"
        case "request_permissions":
            let r = clean(str(payload["reason"]))
            return r.isEmpty ? "等待授权" : "等待授权：\(r)"
        default:
            let r = clean(str(payload["reason"]))
            return r.isEmpty ? "等待你的确认" : "等待你的确认：\(r)"
        }
    }
}

final class CodexWatcher {
    private let root: String
    private var stream: FSEventStreamRef?
    private var offsets: [String: Int] = [:]
    private var meta: [String: (cwd: String, host: String, bundle: String, title: String)] = [:]
    /// 已经发过「等你批准」，等后续事件把它翻回运行中
    private var waiting: [String: Bool] = [:]
    var onEvent: ((HookEvent) -> Void)?

    init(root: String? = nil) {
        if let root { self.root = root } else { self.root = AgentPaths.codexSessions() }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    func start() {
        guard FileManager.default.fileExists(atPath: root) else { return }
        for f in recentFiles() { prime(f) }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            let me = Unmanaged<CodexWatcher>.fromOpaque(info).takeUnretainedValue()
            me.scan()
        }, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentsdone.codex"))
        FSEventStreamStart(stream)
        scan()
    }

    private func recentFiles() -> [String] {
        var out: [String] = []
        let cut = Date().addingTimeInterval(-12 * 3600)
        guard let en = FileManager.default.enumerator(atPath: root) else { return out }
        for case let rel as String in en {
            guard rel.hasSuffix(".jsonl") else { continue }
            let full = root + "/" + rel
            if let attrs = try? FileManager.default.attributesOfItem(atPath: full),
               let m = attrs[.modificationDate] as? Date, m > cut {
                out.append(full)
            }
            if out.count > 400 { break }
        }
        return out
    }

    private func prime(_ path: String) {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        offsets[path] = size
        loadMeta(path)
        // 历史事件不补发，但"正在跑"的会话要立刻出现在列表里（working 不响铃）
        guard tailState(path) == "working" else { return }
        let info = meta[path] ?? ("", "终端", "", "")
        let sid = URL(fileURLWithPath: path).lastPathComponent
            .replacingOccurrences(of: "rollout-", with: "")
            .replacingOccurrences(of: ".jsonl", with: "")
        let title = CodexTitle.sessionId(from: path)
            .flatMap { CodexTitle.name(id: $0) } ?? info.3
        emit(HookEvent(agent: "codex", kind: "working", sessionId: sid, cwd: info.cwd,
                       title: title, detail: "", host: info.host, bundleId: info.bundle), path)
    }

    /// 从文件尾部推断状态：进行中 / 已完成 / 等你批准（token_count、response_item 之类跳过）
    private func tailState(_ path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        try? fh.seek(toOffset: UInt64(max(0, size - 200_000)))
        let data = fh.readDataToEndOfFile()
        var st: String?
        for line in data.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  let kind = payload["type"] as? String else { continue }
            if kind == "task_complete" { st = "done" }
            else if kind == "task_started" { st = "working" }
            else if CodexNeeds.requestKinds.contains(kind) { st = "needs" }
            else if kind == "turn_aborted" || kind == "error" { st = "done" }
        }
        return st ?? "working"
    }

    private func loadMeta(_ path: String) {
        guard meta[path] == nil else { return }
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let head = fh.readData(ofLength: 200_000)
        guard let line = head.split(separator: 0x0A).first,
              let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return }
        let cwd = payload["cwd"] as? String ?? ""
        // originator 才是"谁在跑"（Codex Desktop / codex_work_desktop / codex_vscode / CLI），
        // source 是另一个维度（同一份日志里 source 恒为 vscode 也可能来自桌面 App），所以 originator 优先
        let originator = (payload["originator"] as? String)?.lowercased() ?? ""
        let source = (payload["source"] as? String)?.lowercased() ?? ""
        var host = "终端", bundle = ""
        switch (originator, source) {
        case let (o, _) where o.contains("vscode"): host = "VS Code"; bundle = "com.microsoft.VSCode"
        case let (o, _) where o.contains("desktop"): host = "Codex 桌面"; bundle = "com.openai.codex"
        case let (o, _) where o.contains("cli"): host = "终端"; bundle = ""
        case let (o, s) where o.isEmpty && s.contains("vscode"): host = "VS Code"; bundle = "com.microsoft.VSCode"
        default: break
        }
        meta[path] = (cwd, host, bundle, CodexWatcher.title(fromHead: head))
    }

    /// 会话名：rollout 里第一条真实用户输入（跳过 <environment_context> 这类系统包装）
    static func title(fromHead head: Data) -> String {
        for raw in head.split(separator: 0x0A) {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(raw))) as? [String: Any],
                  obj["type"] as? String == "response_item",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  payload["role"] as? String == "user",
                  let content = payload["content"] as? [[String: Any]] else { continue }
            let raw = content.compactMap { $0["text"] as? String }.joined()
            let text = CodexTitle.clean(raw)
            // <environment_context> / "# AGENTS.md instructions" 这类是系统注入，不是用户问的
            if text.isEmpty || text.hasPrefix("<") || text.hasPrefix("#") { continue }
            return text
        }
        return ""
    }

    private func scan() {
        for path in recentFiles() {
            if offsets[path] == nil { prime(path); continue }
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int, size > (offsets[path] ?? 0) else { continue }
            let start = UInt64(offsets[path] ?? 0)
            guard let fh = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? fh.close() }
            try? fh.seek(toOffset: start)
            let data = fh.readDataToEndOfFile()
            // 只消费到最后一个换行，避免读到半行
            guard let lastNL = data.lastIndex(of: 0x0A) else { continue }
            let usable = data.prefix(through: lastNL)
            offsets[path] = Int(start) + usable.count
            loadMeta(path)
            let info = meta[path] ?? ("", "终端", "", "")
            for line in usable.split(separator: 0x0A) {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      obj["type"] as? String == "event_msg",
                      let payload = obj["payload"] as? [String: Any],
                      let kind = payload["type"] as? String else { continue }
                let sid = URL(fileURLWithPath: path).lastPathComponent
                    .replacingOccurrences(of: "rollout-", with: "")
                    .replacingOccurrences(of: ".jsonl", with: "")
                // 扩展会重命名会话，库里的是最新最准的；拿不到再用 rollout 首条真实输入
                let title = CodexTitle.sessionId(from: path)
                    .flatMap { CodexTitle.name(id: $0) } ?? info.3
                switch kind {
                case "task_started":
                    waiting.removeValue(forKey: path)
                    emit(HookEvent(agent: "codex", kind: "working", sessionId: sid, cwd: info.cwd,
                                   title: title, detail: "", host: info.host, bundleId: info.bundle), path)
                case "task_complete":
                    waiting.removeValue(forKey: path)
                    let msg = (payload["last_agent_message"] as? String ?? "")
                        .replacingOccurrences(of: "\n", with: " ")
                    emit(HookEvent(agent: "codex", kind: "done", sessionId: sid, cwd: info.cwd,
                                   title: title, detail: String(msg.prefix(80)),
                                   host: info.host, bundleId: info.bundle), path)
                default:
                    // 审批 / 提问：等你 → 需要你
                    if CodexNeeds.requestKinds.contains(kind) {
                        waiting[path] = true
                        emit(HookEvent(agent: "codex", kind: "needs", sessionId: sid, cwd: info.cwd,
                                       title: title, detail: CodexNeeds.detail(kind: kind, payload: payload),
                                       host: info.host, bundleId: info.bundle), path)
                    } else if waiting[path] == true {
                        // 批准后接着跑（exec_command_begin / patch_apply_begin / item_completed…）
                        waiting.removeValue(forKey: path)
                        emit(HookEvent(agent: "codex", kind: "working", sessionId: sid, cwd: info.cwd,
                                       title: title, detail: "", host: info.host, bundleId: info.bundle), path)
                    }
                }
            }
        }
    }

    private func emit(_ ev: HookEvent, _ path: String) {
        DispatchQueue.main.async { self.onEvent?(ev) }
    }
}


// MARK: - DeepSeek Harness 会话监听（读 ~/.dsh 的 session projcache）

final class DSHWatcher {
    private let root: String
    private var stream: FSEventStreamRef?
    private var last: [String: (state: String, lastTurn: Int, mtime: Date, size: Int)] = [:]
    private var logOffsets: [String: Int] = [:]
    private var logTimer: DispatchSourceTimer?
    var onEvent: ((HookEvent) -> Void)?

    init(root: String? = nil) {
        if let root { self.root = root } else { self.root = AgentPaths.dshSessions() }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        logTimer?.cancel(); logTimer = nil
    }

    func start() {
        guard FileManager.default.fileExists(atPath: root) else { return }
        for f in files() { evaluate(f, emit: false) }
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<DSHWatcher>.fromOpaque(info).takeUnretainedValue().scan()
        }, &ctx, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.4, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentsdone.dsh"))
        FSEventStreamStart(stream)
        scan()
        startLogTail()
    }

    /// 会话日志（session.v4.jsonl.zstd）里才有审批事件，2 秒看一次文件大小
    private func startLogTail() {
        guard DSHLogReader.nodePath != nil else { return }
        scanLogs(emit: false)
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "agentsdone.dsh.log"))
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.scanLogs(emit: true) }
        t.resume()
        logTimer = t
    }

    private func logsRoot() -> String { AgentPaths.dshLogs() }

    private func scanLogs(emit: Bool) {
        let root = logsRoot()
        guard let en = FileManager.default.enumerator(atPath: root) else { return }
        for case let rel as String in en {
            guard rel.hasSuffix("session.v4.jsonl.zstd") else { continue }
            let full = root + "/" + rel
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: full),
                  let size = attrs[.size] as? Int else { continue }
            if logOffsets[full] == nil {
                logOffsets[full] = size          // 打底：历史不补发
                continue
            }
            guard size > (logOffsets[full] ?? 0) else { continue }
            guard let (lines, next) = DSHLogReader.read(path: full, from: logOffsets[full] ?? 0) else { return }
            logOffsets[full] = next
            guard emit else { continue }
            handleLog(lines, path: full)
        }
    }

    /// `approval/asked` → 等你批准；`approval/decided` → 继续跑
    private func handleLog(_ lines: [String], path: String) {
        let sid = (path as NSString).deletingLastPathComponent.components(separatedBy: "/").last ?? ""
        guard sid.hasPrefix("session-") else { return }
        var cwd = "", title = ""
        if let d = FileManager.default.contents(atPath: root + "/" + sid + ".json"),
           let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
           let record = obj["record"] as? [String: Any] {
            cwd = ((record["identity"] as? [String: Any])?["cwd"] as? String) ?? ""
            if let rows = record["rows"] as? [String: Any] {
                title = ((rows["title"] as? [String: Any])?["val"] as? String) ?? ""
            }
        }
        let project = cwd.isEmpty ? "DSH" : (cwd as NSString).lastPathComponent
        for line in lines {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let type = obj["type"] as? String,
                  let data = obj["data"] as? [String: Any] else { continue }
            switch type {
            case "approval/asked":
                let tool = (data["toolName"] as? String) ?? "工具"
                let reason = ((data["reason"] as? String) ?? "")
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                let detail = reason.isEmpty ? "等待批准：\(tool)" : "等待批准：\(tool) · \(reason)"
                emit(HookEvent(agent: "dsh", kind: "needs", sessionId: sid, cwd: cwd,
                               project: project, title: title,
                               detail: String(detail.prefix(80)), host: "DeepSeek Harness", bundleId: ""))
            case "approval/decided":
                // 批了/拒了都算继续（拒绝后通常跟着 turn/end，缓存那边会给 done）
                emit(HookEvent(agent: "dsh", kind: "working", sessionId: sid, cwd: cwd,
                               project: project, title: title, detail: "",
                               host: "DeepSeek Harness", bundleId: ""))
            default:
                break
            }
        }
    }

    private func emit(_ ev: HookEvent) {
        DispatchQueue.main.async { self.onEvent?(ev) }
    }

    private func files() -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.map { root + "/" + $0 }
    }

    private func scan() { for f in files() { evaluate(f, emit: true) } }

    private func evaluate(_ path: String, emit: Bool) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? Int else { return }
        if let prev = last[path], prev.mtime == mtime, prev.size == size { return }

        guard let data = FileManager.default.contents(atPath: path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let record = obj["record"] as? [String: Any],
              let identity = record["identity"] as? [String: Any],
              let rows = record["rows"] as? [String: Any] else { return }

        let cwd = (identity["cwd"] as? String) ?? ""
        let title = ((rows["title"] as? [String: Any])?["val"] as? String) ?? ""
        let boundary = ((rows["turnBoundary"] as? [String: Any])?["val"] as? [String: Any])
        let lastTurn = (boundary?["lastTurn"] as? Int) ?? 0
        let openRaw = boundary?["openTurnStartSeq"]
        let isOpen = !(openRaw is NSNull) && openRaw != nil

        var activeQuestions = false
        if let q = ((rows["userQuestions"] as? [String: Any])?["val"] as? [String: Any])?["questions"] as? [String: Any],
           let active = q["active"] as? [Any] {
            activeQuestions = !active.isEmpty
        }
        let blank = ((rows["sessionListMetadata"] as? [String: Any])?["val"] as? [String: Any])?["blank"] as? Bool ?? false

        let turns = ((rows["turnOutline"] as? [String: Any])?["val"] as? [String: Any])?["turns"] as? [[String: Any]]
        let lastResponse = (turns?.last {
            !((($0["response"] as? String) ?? "").isEmpty)
        }?["response"] as? String) ?? ""
        let state = activeQuestions ? "needs" : (isOpen ? "working" : "done")
        let previous = last[path]
        last[path] = (state, lastTurn, mtime, size)

        guard emit || (previous == nil && state == "working"), previous?.state != state, lastTurn > 0, !blank, !cwd.isEmpty else { return }
        let sid = (path as NSString).lastPathComponent.replacingOccurrences(of: ".json", with: "")
        let project = cwd.isEmpty ? "DSH" : (cwd as NSString).lastPathComponent
        DispatchQueue.main.async {
            self.onEvent?(HookEvent(agent: "dsh", kind: state, sessionId: sid, cwd: cwd,
                                    project: project, title: title,
                                    detail: String(lastResponse
                                        .replacingOccurrences(of: "\n", with: " ")
                                        .prefix(80)),
                                    host: "DeepSeek Harness", bundleId: "com.deepseek.dsh"))
        }
    }
}

/// 给远端命令用的单引号转义
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

// MARK: - 读 DSH 的会话日志（zstd 多帧，借 DSH 自带 node 解压）

/// DSH 把每个事件单独压成一个 zstd 帧、追加进 `session.v4.jsonl.zstd`，
/// 所以可以只读新增字节、只解新帧 —— 不用把整个日志解一遍。
/// Swift 没有 zstd，借 DSH 桌面版自带的 Electron（ELECTRON_RUN_AS_NODE=1）来解，
/// 一次调用约 60ms，且只在日志真的增长时才调用。
enum DSHLogReader {
    private static let script = """
    const fs=require("fs"),z=require("zlib");
    const p=process.argv[1],start=+process.argv[2]||0;
    const out={lines:[],next:start};
    try{
      const b=fs.readFileSync(p);
      const M=Buffer.from([0x28,0xB5,0x2F,0xFD]);
      let pos=[],i=start;
      while(i<b.length){const k=b.indexOf(M,i);if(k<0)break;pos.push(k);i=k+4;}
      for(let j=0;j<pos.length;j++){
        const end=j+1<pos.length?pos[j+1]:b.length;
        try{
          const s=z.zstdDecompressSync(b.subarray(pos[j],end)).toString("utf8");
          for(const l of s.split("\\n")) if(l) out.lines.push(l);
          out.next=end;
        }catch(e){break;}   // 末尾半帧：留着下次再解
      }
    }catch(e){}
    console.log(JSON.stringify(out));
    """

    /// DSH 桌面版自带 node（就是它的主二进制），可用性决定 DSH 审批提醒开不开。
    /// 查找顺序：环境变量 → 配置文件 dshNode → 常见安装位置。
    static var nodePath: String? {
        func usable(_ p: String?) -> String? {
            guard let p, !p.isEmpty else { return nil }
            let full = AgentPaths.expand(p)
            return FileManager.default.isExecutableFile(atPath: full) ? full : nil
        }
        if let p = usable(ProcessInfo.processInfo.environment["AGENTSDONE_DSH_NODE"]) { return p }
        if let p = usable(ProcessInfo.processInfo.environment["DSH_DESKTOP_NODE_EXECUTABLE"]) { return p }
        if let p = usable(ConfigStore.load().dshNode) { return p }
        let home = NSHomeDirectory()
        let candidates = [
            "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness",
            home + "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// 读 offset 之后的新帧，返回解出的 JSONL 行和下次该读的位置
    static func read(path: String, from offset: Int) -> (lines: [String], next: Int)? {
        guard let node = nodePath else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: node)
        p.arguments = ["-e", script, path, String(offset)]
        var env = ProcessInfo.processInfo.environment
        env["ELECTRON_RUN_AS_NODE"] = "1"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let lines = (obj["lines"] as? [String]) ?? []
        let next = (obj["next"] as? Int) ?? offset
        return (lines, next)
    }
}

// MARK: - ZCode 任务监听（读 ~/.zcode 的任务索引 SQLite）

final class ZCodeWatcher {
    private let dir: String
    private let dbPath: String
    private var stream: FSEventStreamRef?
    private var last: [String: String] = [:]
    private var primed = false
    var onEvent: ((HookEvent) -> Void)?

    init(root: String? = nil) {
        let base = root ?? AgentPaths.base("zcode")
        self.dir = base
        self.dbPath = base + "/tasks-index.sqlite"
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
        self.stream = nil
    }

    func start() {
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        scan(emit: false)
        primed = true
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ZCodeWatcher>.fromOpaque(info).takeUnretainedValue().scan(emit: true)
        }, &ctx, [dir] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.6, flags)
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentsdone.zcode"))
        FSEventStreamStart(stream)
    }

    private func scan(emit: Bool) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let cutoff = Int64((Date().timeIntervalSince1970 - 6 * 3600) * 1000)
        let sql = """
        select task_id, coalesce(task_status,''), coalesce(title,''), coalesce(workspace_path,''), coalesce(updated_at,0)
        from tasks where deleted = 0 and archived = 0 and updated_at > ? order by updated_at desc limit 60;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)

        var fresh: [(String, String, String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            fresh.append((col(0), col(1), col(2), col(3)))
        }

        for (taskId, status, title, workspace) in fresh {
            let state: String
            switch status {
            case "completed": state = "done"
            case "error", "failed": state = "needs"
            default: state = "working"
            }
            let previous = last[taskId]
            last[taskId] = state
            guard emit || (previous == nil && state == "working"), previous != state else { continue }
            let project = workspace.isEmpty ? "ZCode" : (workspace as NSString).lastPathComponent
            let detail = (status == "error" || status == "failed") ? "任务出错" : ""
            let ev = HookEvent(agent: "zcode", kind: state, sessionId: taskId, cwd: workspace,
                               project: project, title: title,
                               detail: String(detail.prefix(80)),
                               host: "ZCode", bundleId: "dev.zcode.app")
            DispatchQueue.main.async { self.onEvent?(ev) }
            _ = project
        }
    }
}


// MARK: - Antigravity 监听（读 ~/.gemini/antigravity 的会话索引）

/// Antigravity（Google 的 agent IDE）把每个会话写成 `conversations/<id>.db`，
/// 索引在 `conversation_summaries.db`。状态的数字是 protobuf 枚举：
/// 1 PENDING / 2 RUNNING / 3 DONE / 6 CANCELED / 7 ERROR / 8 GENERATING / 9 WAITING / 11 QUEUED / 12 INTERRUPTED
/// 其中 **WAITING(9) 就是"等你批准/回答"**。
final class AntigravityWatcher {
    private let dir: String
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var last: [String: String] = [:]
    private var primed = false
    var onEvent: ((HookEvent) -> Void)?

    init(root: String? = nil) {
        dir = root ?? AgentPaths.base("antigravity")
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream)
            self.stream = nil
        }
        timer?.cancel(); timer = nil
    }

    func start() {
        guard FileManager.default.fileExists(atPath: dir) else { return }
        scan(emit: false)
        // 库里一条都读不到，说明当时被 Antigravity 占着；等下一轮再算打底完成，
        // 否则会把老会话当成"刚刚完成"弹出来
        primed = !last.isEmpty

        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        stream = FSEventStreamCreate(nil, { _, info, numEvents, paths, _, _ in
            guard let info else { return }
            // App 会频繁写 cache/cookie，那些跟会话无关；只看 sqlite
            var relevant = false
            let list = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            for i in 0..<Int(numEvents) {
                guard let cstr = list[i] else { continue }
                let p = String(cString: cstr)
                if p.hasSuffix(".db") || p.hasSuffix(".db-wal") || p.hasSuffix(".db-shm") {
                    relevant = true; break
                }
            }
            guard relevant else { return }
            Unmanaged<AntigravityWatcher>.fromOpaque(info).takeUnretainedValue().scan(emit: true)
        }, &ctx, [dir] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5, flags)
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentsdone.antigravity"))
            FSEventStreamStart(stream)
        }

        // sqlite 的 WAL 落盘不一定会触发 FSEvent，再兜一层轮询
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "agentsdone.antigravity.poll"))
        t.schedule(deadline: .now() + 2, repeating: 3)
        t.setEventHandler { [weak self] in
            guard let self, self.touched() else { return }
            self.scan(emit: true)
        }
        t.resume()
        timer = t
    }

    private var stamps: [String: String] = [:]

    /// 库文件有没有变（比每次都开库便宜得多）
    private func touched() -> Bool {
        var paths = [dir + "/conversation_summaries.db"]
        if let names = try? FileManager.default.contentsOfDirectory(atPath: dir + "/conversations") {
            for n in names where n.hasSuffix(".db") { paths.append(dir + "/conversations/" + n) }
        }
        var changed = false
        for path in paths {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let size = (attrs?[.size] as? Int) ?? -1
            let mt = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let sig = "\(size)@\(mt)"
            if stamps[path] != sig { stamps[path] = sig; changed = true }
        }
        return changed
    }

    /// mode=ro 在 WAL 库上可能失败，退回 immutable
    private func openRO(_ path: String) -> OpaquePointer? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        for uri in ["file:\(path)?mode=ro", "file:\(path)?immutable=1"] {
            var db: OpaquePointer?
            if sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db {
                sqlite3_busy_timeout(db, 200)
                return db
            }
            if let db { sqlite3_close(db) }
        }
        return nil
    }

    private struct Meta {
        var title = ""
        var status = ""
        var killed = false
        var mtime = Date.distantPast
    }

    private func summaries() -> [String: Meta] {
        var out: [String: Meta] = [:]
        guard let db = openRO(dir + "/conversation_summaries.db") else { return out }
        defer { sqlite3_close(db) }
        let sql = """
        select conversation_id, coalesce(nullif(title,''), coalesce(preview,'')), coalesce(status,''),
               coalesce(killed,0), coalesce(last_modified_time,'')
        from conversation_summaries;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return out }
        defer { sqlite3_finalize(stmt) }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fmt2 = ISO8601DateFormatter()
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            let id = col(0)
            guard !id.isEmpty else { continue }
            var m = Meta()
            m.title = col(1).replacingOccurrences(of: "\n", with: " ")
            m.status = col(2)
            m.killed = sqlite3_column_int(stmt, 3) != 0
            let ts = col(4)
            m.mtime = fmt.date(from: ts) ?? fmt2.date(from: ts) ?? Date.distantPast
            out[id] = m
        }
        return out
    }

    /// 最后一步的状态：3=DONE 7=ERROR 9=WAITING …
    private func lastStep(_ id: String) -> (status: Int32, error: String) {
        let path = dir + "/conversations/" + id + ".db"
        guard let db = openRO(path) else { return (-1, "") }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select status, coalesce(error_details,'') from steps order by idx desc limit 1;",
                                 -1, &stmt, nil) == SQLITE_OK else { return (-1, "") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (-1, "") }
        let err = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        return (sqlite3_column_int(stmt, 0), err)
    }

    /// 最后一轮 agent 说了什么（FTS 里存的是可读文本）
    private func detailTail(_ id: String) -> String {
        guard let db = openRO(dir + "/conversation_summaries.db") else { return "" }
        defer { sqlite3_close(db) }
        let sql = """
        select agent_body from conversations_fts
        where conversation_id = ? and chunk_index >= 0 order by chunk_index desc limit 1;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, id, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cstr = sqlite3_column_text(stmt, 0) else { return "" }
        let body = String(cString: cstr)
        let lines = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("*") && !$0.hasPrefix("#") && !$0.hasPrefix("|") }
        guard let tail = lines.last else { return "" }
        let plain = tail.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: ">", with: "")
            .trimmingCharacters(in: .whitespaces)
        return String(plain.prefix(80))
    }

    private func scan(emit: Bool) {
        let all = summaries()
        if !primed && !all.isEmpty { primed = true }
        for (id, m) in all {
            // 会话级状态：优先看最后一步
            let (stepStatus, err) = lastStep(id)
            let running = m.status.contains("RUNNING") || m.status.contains("BUSY")

            var state = "done"
            var detail = ""
            switch stepStatus {
            case 9:                       // WAITING：等你批准或回答
                state = "needs"
                detail = "等待你在 Antigravity 里确认"
            case 1, 2, 8, 11:             // PENDING / RUNNING / GENERATING / QUEUED
                state = "working"
            case 7:                       // ERROR
                state = "needs"
                let e = err.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                detail = e.isEmpty ? "任务出错" : String(e.prefix(80))
            case 6, 12:                   // CANCELED / INTERRUPTED
                state = "done"
                detail = "已中断"
            default:                      // DONE / 未知
                state = running ? "working" : "done"
                if state == "done" { detail = detailTail(id) }
            }
            if m.killed { continue }
            if running && state == "done" { state = "working" }   // 索引说还在跑就别报完成

            let previous = last[id]
            last[id] = state
            guard emit || (previous == nil && state == "working"), previous != state else { continue }
            let title = m.title.isEmpty ? "" : String(m.title.prefix(60))
            let ev = HookEvent(agent: "antigravity", kind: state, sessionId: id, cwd: "",
                               project: "Antigravity", title: title,
                               detail: String(detail.prefix(80)),
                               host: "Antigravity", bundleId: "com.google.antigravity")
            DispatchQueue.main.async { self.onEvent?(ev) }
        }
    }
}

// MARK: - 配置：远程主机（~/.agentsdone/config.json）

struct RemoteEntry: Codable, Identifiable, Equatable {
    var host: String
    var enabled: Bool
    /// 这台机器上非默认的数据目录，键：codex（AGENTSDONE_CODEX_ROOT）、claude（CLAUDE_CONFIG_DIR）
    var paths: [String: String] = [:]
    var id: String { host }

    init(host: String, enabled: Bool, paths: [String: String] = [:]) {
        self.host = host
        self.enabled = enabled
        self.paths = paths
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        host = try c.decode(String.self, forKey: .host)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        paths = try c.decodeIfPresent([String: String].self, forKey: .paths) ?? [:]
    }
}

struct AppConfig: Codable {
    var followVSCode: Bool = true
    var hosts: [RemoteEntry] = []
    /// 各 Agent 的数据目录，键：claude / codex / dsh / zcode / antigravity
    var paths: [String: String] = [:]
    /// DSH 桌面版的可执行文件；用来解压它的 zstd 会话日志（读审批事件）。
    /// 留空就按常见安装位置自动找。
    var dshNode: String = ""
    /// 提示音名（NSSound 的名字）；空字符串表示不响
    var sound: String = "Glass"
    /// 全局快捷键 ⌥⌘A 打开面板
    var hotkey: Bool = true

    init() {}

    init(followVSCode: Bool, hosts: [RemoteEntry], paths: [String: String] = [:],
         dshNode: String = "", sound: String = "Glass", hotkey: Bool = true) {
        self.followVSCode = followVSCode
        self.hosts = hosts
        self.paths = paths
        self.dshNode = dshNode
        self.sound = sound
        self.hotkey = hotkey
    }

    /// 手写解码：允许只写想要的那几个键（合成的 decoder 遇到缺键会整体失败）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        followVSCode = try c.decodeIfPresent(Bool.self, forKey: .followVSCode) ?? true
        hosts = try c.decodeIfPresent([RemoteEntry].self, forKey: .hosts) ?? []
        paths = try c.decodeIfPresent([String: String].self, forKey: .paths) ?? [:]
        dshNode = try c.decodeIfPresent(String.self, forKey: .dshNode) ?? ""
        sound = try c.decodeIfPresent(String.self, forKey: .sound) ?? "Glass"
        hotkey = try c.decodeIfPresent(Bool.self, forKey: .hotkey) ?? true
    }
}

enum ConfigStore {
    static var dir: String {
        if let e = ProcessInfo.processInfo.environment["AGENTSDONE_CONFIG_DIR"], !e.isEmpty {
            return AgentPaths.expand(e)
        }
        return NSHomeDirectory() + "/.agentsdone"
    }
    static var path: String { dir + "/config.json" }

    static func load() -> AppConfig {
        guard let d = FileManager.default.contents(atPath: path),
              let c = try? JSONDecoder().decode(AppConfig.self, from: d) else { return AppConfig() }
        return c
    }

    static func save(_ c: AppConfig) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(c) else { return }
        try? d.write(to: URL(fileURLWithPath: path))
    }
}

/// 各 Agent 数据目录：环境变量（测试用）> config.json 的 paths > 默认值
enum AgentPaths {
    static let defaults: [String: String] = [
        "claude": "~/.claude",
        "codex": "~/.codex",
        "dsh": "~/.dsh",
        "zcode": "~/.zcode/v2",
        "antigravity": "~/.gemini/antigravity",
    ]

    static var labels: [(key: String, title: String)] {
        [("claude", "Claude Code"), ("codex", "Codex"), ("dsh", "DeepSeek Harness"),
         ("zcode", "ZCode"), ("antigravity", "Antigravity")]
    }

    static func expand(_ p: String) -> String {
        if p == "~" { return NSHomeDirectory() }
        if p.hasPrefix("~/") { return NSHomeDirectory() + String(p.dropFirst(1)) }
        return p
    }

    /// 显示用：把 home 缩成 ~
    static func pretty(_ p: String) -> String {
        p.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    static func envKey(_ key: String) -> String {
        switch key {
        case "claude": return "AGENTSDONE_CLAUDE_ROOT"
        case "codex": return "AGENTSDONE_CODEX_HOME"
        case "dsh": return "AGENTSDONE_DSH_HOME"
        case "zcode": return "AGENTSDONE_ZCODE_ROOT"
        default: return "AGENTSDONE_ANTIGRAVITY_ROOT"
        }
    }

    static func base(_ key: String) -> String {
        if let e = ProcessInfo.processInfo.environment[envKey(key)], !e.isEmpty { return expand(e) }
        if let c = ConfigStore.load().paths[key], !c.isEmpty { return expand(c) }
        return expand(defaults[key] ?? "~")
    }

    /// Codex 的 sessions 目录（测试可以直接指到 sessions）
    static func codexSessions() -> String {
        if let e = ProcessInfo.processInfo.environment["AGENTSDONE_CODEX_ROOT"], !e.isEmpty { return expand(e) }
        return base("codex") + "/sessions"
    }

    /// DSH 的会话日志目录（审批事件在里面）
    static func dshLogs() -> String {
        if let e = ProcessInfo.processInfo.environment["AGENTSDONE_DSH_LOGS"], !e.isEmpty {
            return expand(e)
        }
        return base("dsh") + "/sessions"
    }

    static func dshSessions() -> String {
        if let e = ProcessInfo.processInfo.environment["AGENTSDONE_DSH_ROOT"], !e.isEmpty { return expand(e) }
        return base("dsh") + "/storages/session_projcache/sessions"
    }
}

// MARK: - 读 VS Code 自己的配置（SSH config 路径 / 当前远程主机）

enum VSCodeConfig {
    static var userDir: String { NSHomeDirectory() + "/Library/Application Support/Code/User" }

    private static var settingsJSON: [String: Any] {
        guard let d = FileManager.default.contents(atPath: userDir + "/settings.json"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return [:] }
        return o
    }

    /// VS Code 的 remote.SSH.configFile（默认 ~/.ssh/config）
    static var sshConfigFile: String {
        if let p = settingsJSON["remote.SSH.configFile"] as? String, !p.isEmpty {
            return (p as NSString).expandingTildeInPath
        }
        return NSHomeDirectory() + "/.ssh/config"
    }

    /// 当前窗口挂着的远程主机（ssh-remote+xxx）
    static var currentRemoteHost: String? {
        guard let d = FileManager.default.contents(atPath: userDir + "/globalStorage/storage.json"),
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let ws = o["windowsState"] as? [String: Any],
              let win = ws["lastActiveWindow"] as? [String: Any],
              let auth = win["remoteAuthority"] as? String,
              auth.hasPrefix("ssh-remote+") else { return nil }
        return String(auth.dropFirst("ssh-remote+".count))
    }
}

// MARK: - 解析 ssh config 里的主机（支持 Include）

enum SSHConfig {
    static func hosts() -> [String] {
        var out: [String] = []
        var seen = Set<String>()

        func parse(_ path: String, depth: Int) {
            guard depth < 4, let txt = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            for raw in txt.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard let key = parts.first?.lowercased() else { continue }
                if key == "include" {
                    for pattern in parts.dropFirst() {
                        let expanded = (pattern as NSString).expandingTildeInPath
                        if expanded.contains("*") || expanded.contains("?") {
                            let dir = (expanded as NSString).deletingLastPathComponent
                            let base = (expanded as NSString).lastPathComponent
                            let regex = NSRegularExpression.escapedPattern(for: base)
                                .replacingOccurrences(of: "\\*", with: ".*")
                                .replacingOccurrences(of: "\\?", with: ".")
                            if let items = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                                for item in items.sorted() where item.range(of: "^" + regex + "$", options: .regularExpression) != nil {
                                    parse(dir + "/" + item, depth: depth + 1)
                                }
                            }
                        } else {
                            parse(expanded, depth: depth + 1)
                        }
                    }
                    continue
                }
                if key == "host" {
                    for h in parts.dropFirst()
                    where !h.contains("*") && !h.contains("?") && !h.hasPrefix("!") {
                        if seen.insert(h).inserted { out.append(h) }
                    }
                }
            }
        }

        parse(VSCodeConfig.sshConfigFile, depth: 0)
        return out
    }
}

extension Notification.Name {
    static let agentsDoneRemoteStatus = Notification.Name("agentsDone.remote.status")
    static let agentsDoneTestPill = Notification.Name("agentsDone.test.pill")
    /// 静音一段时间：userInfo["minutes"]，0 表示取消静音
    static let agentsDoneSnooze = Notification.Name("agentsDone.snooze")
    /// 配置改过了（设置页保存后发一下，让热键等跟着变）
    static let agentsDoneConfigChanged = Notification.Name("agentsDone.config.changed")
}

// MARK: - 远程监听（每个主机一条持久 ssh 流，只读增量字节）

final class RemoteWatcher {
    static let shared = RemoteWatcher()

    struct Conn {
        var proc: Process?
        var buf = Data()
        var state = "idle"          // idle | connecting | connected | error
    }

    private var conns: [String: Conn] = [:]
    private var timer: Timer?
    var onEvent: ((HookEvent) -> Void)?

    var status: [String: String] {
        conns.mapValues { $0.state }
    }

    func start() {
        cleanupStale()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    /// 上一个实例被强杀时留在这里的 ssh（父进程已经是 1），顺手收掉。
    /// 只认 /usr/bin/ssh 且带我们独有参数（ServerAliveCountMax=2）的进程，
    /// 不碰 VS Code / 用户自己的连接。
    private func cleanupStale() {
        let sig = "ServerAliveCountMax=2"
        let pg = Process()
        pg.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pg.arguments = ["-f", sig]
        let out = Pipe()
        pg.standardOutput = out
        pg.standardError = FileHandle.nullDevice
        guard (try? pg.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        pg.waitUntilExit()
        for line in String(data: data, encoding: .utf8)?.split(separator: "\n") ?? [] {
            guard let pid = pid_t(line.trimmingCharacters(in: .whitespaces)), pid > 0 else { continue }
            var buf = [CChar](repeating: 0, count: 4096)
            let n = proc_pidpath(pid, &buf, UInt32(buf.count))
            guard n > 0, String(cString: buf).hasSuffix("/ssh") else { continue }
            kill(pid, SIGTERM)
        }
    }

    func targets() -> [String] {
        var out: [String] = []
        let cfg = ConfigStore.load()
        if cfg.followVSCode, let h = VSCodeConfig.currentRemoteHost { out.append(h) }
        out += cfg.hosts.filter { $0.enabled }.map { $0.host }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    func refresh() {
        let want = Set(targets())
        for host in conns.keys where !want.contains(host) { teardown(host) }
        for host in want where conns[host] == nil { connect(host) }
        notifyStatus()
    }

    private func notifyStatus() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .agentsDoneRemoteStatus, object: nil)
        }
    }

    /// 退出前收掉子进程，别把 ssh 留成孤儿
    func shutdown() {
        timer?.invalidate(); timer = nil
        for host in conns.keys { teardown(host) }
    }

    private func teardown(_ host: String) {
        conns[host]?.proc?.terminate()
        conns[host] = nil
    }

    static func loadScript() -> String? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            NSHomeDirectory() + "/.agentsdone/remote/remote_watch.py",
            exe.appendingPathComponent("../remote/remote_watch.py").standardizedFileURL.path,
            exe.appendingPathComponent("remote/remote_watch.py").standardizedFileURL.path,
        ]
        for c in candidates {
            if let t = try? String(contentsOfFile: c, encoding: .utf8), !t.isEmpty { return t }
        }
        return nil
    }

    private func connect(_ host: String) {
        // 已经有一条（含正在连接的）就不再起第二条，否则每 15 秒刷新会漏出重复 ssh
        guard conns[host] == nil else { return }
        guard let script = RemoteWatcher.loadScript() else { return }
        var conn = Conn()
        conn.state = "connecting"
        conns[host] = conn          // 先占位，堵住重入

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                    "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=2",
                    "-o", "StrictHostKeyChecking=accept-new", host]
        // 非默认目录：作为环境变量缀在远端命令前面（远端脚本里再 expanduser）
        if let entry = ConfigStore.load().hosts.first(where: { $0.host == host }) {
            if let c = entry.paths["codex"], !c.isEmpty { args.append("AGENTSDONE_CODEX_ROOT=\(shellQuote(c))") }
            if let c = entry.paths["claude"], !c.isEmpty { args.append("CLAUDE_CONFIG_DIR=\(shellQuote(c))") }
        }
        args += ["python3", "-"]
        p.arguments = args
        let stdinPipe = Pipe(), stdoutPipe = Pipe()
        p.standardInput = stdinPipe
        p.standardOutput = stdoutPipe
        p.standardError = FileHandle.nullDevice

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let d = fh.availableData
            guard !d.isEmpty else { return }
            // conns 只在主线程改，避免和定时刷新打架
            DispatchQueue.main.async { self?.consume(host: host, data: d) }
        }
        p.terminationHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                self.conns[host] = nil      // 清掉占位，refresh 才会重连
                self.notifyStatus()
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.refresh() }
            }
        }

        do { try p.run() } catch {
            conn.state = "error"
            conns[host] = conn
            notifyStatus()
            return
        }
        stdinPipe.fileHandleForWriting.write(script.data(using: .utf8) ?? Data())
        try? stdinPipe.fileHandleForWriting.close()
        conn.proc = p
        conn.state = "connected"
        conns[host] = conn
        notifyStatus()
    }

    private func consume(host: String, data: Data) {
        guard var conn = conns[host] else { return }
        conn.buf.append(data)
        while let nl = conn.buf.firstIndex(of: 0x0A) {
            let line = conn.buf[conn.buf.startIndex..<nl]
            conn.buf = conn.buf[conn.buf.index(after: nl)...]
            guard !line.isEmpty,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any] else { continue }
            handle(obj)
        }
        conns[host] = conn
    }

    private func handle(_ obj: [String: Any]) {
        guard let agent = obj["agent"] as? String, let kind = obj["kind"] as? String else { return }
        let cwd = (obj["cwd"] as? String) ?? ""
        let session = (obj["session"] as? String) ?? cwd
        guard !session.isEmpty else { return }

        var host = "终端（远程）", bundle = ""
        if agent == "codex" {
            let o = ((obj["originator"] as? String) ?? "").lowercased()
            if o.contains("vscode") { host = "VS Code（远程）"; bundle = "com.microsoft.VSCode" }
            else if o.contains("desktop") { host = "Codex 桌面"; bundle = "com.openai.codex" }
        } else {
            let tp = ((obj["tp"] as? String) ?? "").lowercased()
            if tp.contains("vscode") { host = "VS Code（远程）"; bundle = "com.microsoft.VSCode" }
        }

        let ev = HookEvent(agent: agent, kind: kind, sessionId: session, cwd: cwd,
                           title: (obj["title"] as? String) ?? "",
                           detail: (obj["detail"] as? String) ?? "",
                           host: host, bundleId: bundle)
        DispatchQueue.main.async { self.onEvent?(ev) }
    }

    // MARK: 供设置页调用的动作

    @discardableResult
    static func ssh(_ host: String, _ args: [String], stdin: String? = nil) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                       "-o", "StrictHostKeyChecking=accept-new", host] + args
        let out = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = inp
        do { try p.run() } catch { return (-1, "无法启动 ssh") }
        if let stdin { inp.fileHandleForWriting.write(stdin.data(using: .utf8) ?? Data()) }
        try? inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    static func test(_ host: String) -> Bool {
        ssh(host, ["echo ok"]).0 == 0
    }

    /// 安装远端 Claude hooks：脚本经 stdin 送入，远端不落地任何文件
    static func installHooks(_ host: String) -> String {
        let local = NSHomeDirectory() + "/.agentsdone/remote/install_hooks.py"
        let fallback = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../remote/install_hooks.py").standardizedFileURL.path
        guard let src = (try? String(contentsOfFile: local, encoding: .utf8))
                ?? (try? String(contentsOfFile: fallback, encoding: .utf8)) else {
            return "找不到 install_hooks.py"
        }
        let (rc, out) = ssh(host, ["python3 - --install"], stdin: src)
        return rc == 0 ? out : "失败：\(out)"
    }

    static func removeHooks(_ host: String) -> String {
        let local = NSHomeDirectory() + "/.agentsdone/remote/install_hooks.py"
        let fallback = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
            .appendingPathComponent("../remote/install_hooks.py").standardizedFileURL.path
        guard let src = (try? String(contentsOfFile: local, encoding: .utf8))
                ?? (try? String(contentsOfFile: fallback, encoding: .utf8)) else {
            return "找不到 install_hooks.py"
        }
        let (rc, out) = ssh(host, ["python3 - --remove"], stdin: src)
        return rc == 0 ? out : "失败：\(out)"
    }
}

// MARK: - 设置页

final class SettingsModel: ObservableObject {
    @Published var followVSCode: Bool
    @Published var entries: [RemoteEntry]
    @Published var available: [String] = []
    @Published var status: [String: String] = [:]
    @Published var message: String = ""
    @Published var busy: String = ""
    @Published var customHost: String = ""
    @Published var sound: String = "Glass"
    @Published var hotkey: Bool = true
    /// 「静音 30 分钟」按下后按钮变成「取消静音」
    @Published var snoozing: Bool = false
    var currentRemoteOverride: String?

    var currentRemote: String? {
        currentRemoteOverride ?? VSCodeConfig.currentRemoteHost
    }

    /// 演示用：文档截图不该暴露真实的 ssh 主机名
    init(demo: Bool = false) {
        if demo {
            followVSCode = true
            available = ["dev-cluster", "gpu-box-1", "gpu-box-2", "staging"]
            entries = [RemoteEntry(host: "dev-cluster", enabled: true)]
            status = ["dev-cluster": "connected", "gpu-box-1": "idle", "gpu-box-2": "idle"]
            currentRemoteOverride = "dev-cluster"
            sound = "Glass"
            hotkey = true
            return
        }
        let cfg = ConfigStore.load()
        followVSCode = cfg.followVSCode
        entries = cfg.hosts
        sound = cfg.sound
        hotkey = cfg.hotkey
        reload()
    }

    func reload() {
        available = SSHConfig.hosts()
        status = RemoteWatcher.shared.status
    }

    func persist() {
        // 保存时把用户自己配的 paths / dshNode 带上，别被设置页覆盖掉
        let old = ConfigStore.load()
        ConfigStore.save(AppConfig(followVSCode: followVSCode, hosts: entries,
                                   paths: old.paths, dshNode: old.dshNode,
                                   sound: sound, hotkey: hotkey))
        RemoteWatcher.shared.refresh()
        NotificationCenter.default.post(name: .agentsDoneConfigChanged, object: nil)
    }

    func isEnabled(_ host: String) -> Bool { entries.first { $0.host == host }?.enabled ?? false }

    func setEnabled(_ host: String, _ on: Bool) {
        if let i = entries.firstIndex(where: { $0.host == host }) {
            entries[i].enabled = on
        } else {
            entries.append(RemoteEntry(host: host, enabled: on))
        }
        persist()
    }

    func addCustom() {
        let h = customHost.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        if !entries.contains(where: { $0.host == h }) {
            entries.append(RemoteEntry(host: h, enabled: true))
        }
        customHost = ""
        persist()
    }

    var allHosts: [String] {
        var out = available
        for e in entries where !out.contains(e.host) { out.append(e.host) }
        return out
    }

    var selected: [String] {
        var out: [String] = []
        if followVSCode, let h = currentRemote { out.append(h) }
        out += entries.filter { $0.enabled }.map { $0.host }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    func run(_ label: String, _ work: @escaping () -> String) {
        busy = label
        message = ""
        DispatchQueue.global(qos: .userInitiated).async {
            let result = work()
            DispatchQueue.main.async {
                self.busy = ""
                self.message = result
                self.status = RemoteWatcher.shared.status
            }
        }
    }

    func testAll() {
        let hosts = selected
        guard !hosts.isEmpty else { message = "还没有选中任何主机"; return }
        run("测试中…") {
            hosts.map { h in RemoteWatcher.test(h) ? "\(h): 可连接" : "\(h): 连不上" }.joined(separator: "\n")
        }
    }

    func installAll() {
        let hosts = selected
        guard !hosts.isEmpty else { message = "还没有选中任何主机"; return }
        run("安装中…") {
            hosts.map { h in "\(h)\n" + RemoteWatcher.installHooks(h) }.joined(separator: "\n")
        }
    }

    func removeAll() {
        let hosts = selected
        guard !hosts.isEmpty else { message = "还没有选中任何主机"; return }
        run("移除中…") {
            hosts.map { h in "\(h)\n" + RemoteWatcher.removeHooks(h) }.joined(separator: "\n")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    private func dot(_ host: String) -> Color {
        switch model.status[host] {
        case "connected": return .green
        case "connecting": return .orange
        case "error": return .red
        default: return Color(white: 0.6)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("提醒").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: {
                    NotificationCenter.default.post(name: .agentsDoneTestPill, object: nil)
                }) {
                    Text("试一下提醒").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .help("弹出两条示例提醒，确认声音和浮窗是否正常")
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

            Text("会依次弹出两条示例（完成 + 待批准），用来确认提醒是否正常；点一下浮窗会跳到对应会话。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 8)

            HStack(spacing: 8) {
                Text("提示音").font(.system(size: 12))
                Picker("", selection: $model.sound) {
                    Text("Glass").tag("Glass")
                    Text("Ping").tag("Ping")
                    Text("Tink").tag("Tink")
                    Text("Submarine").tag("Submarine")
                    Text("无（静音）").tag("")
                }
                .labelsHidden().frame(width: 116)
                .onChange(of: model.sound) { v in
                    model.persist()
                    NSSound(named: v)?.play()
                }
                Spacer()
                if model.snoozing {
                    Button("取消静音") {
                        NotificationCenter.default.post(name: .agentsDoneSnooze, object: nil,
                                                        userInfo: ["minutes": 0])
                        model.snoozing = false
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                } else {
                    Button("静音 30 分钟") {
                        NotificationCenter.default.post(name: .agentsDoneSnooze, object: nil,
                                                        userInfo: ["minutes": 30])
                        model.snoozing = true
                    }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 6)

            Toggle(isOn: $model.hotkey) {
                Text("全局快捷键 Option+Command+A 打开列表").font(.system(size: 12))
            }
            .toggleStyle(.switch).controlSize(.mini)
            .onChange(of: model.hotkey) { _ in model.persist() }
            .padding(.horizontal, 16).padding(.bottom, 10)

            Divider()

            HStack(spacing: 6) {
                Text("远程（SSH）").font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)

            Text("只增量读取远端的会话日志（每轮几百字节），不会下载任何文件；安装 hooks 时脚本经 stdin 送入，远端不落地脚本。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)

            Toggle(isOn: Binding(get: { model.followVSCode },
                                 set: { model.followVSCode = $0; model.persist() })) {
                Text("自动跟随 VS Code 当前远程连接").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .padding(.horizontal, 16).padding(.top, 10)

            HStack(spacing: 8) {
                Text("主机（来自 \(VSCodeConfig.sshConfigFile.replacingOccurrences(of: NSHomeDirectory(), with: "~"))）")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { model.reload() }.buttonStyle(.plain)
                    .font(.system(size: 11)).foregroundStyle(.blue)
                Button("编辑配置") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: VSCodeConfig.sshConfigFile))
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue)
            }
            .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)

            ScrollView {
                VStack(spacing: 0) {
                    if model.available.isEmpty {
                        Text("没读到主机。检查上面的配置文件，或用下面的手动添加。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16).padding(.vertical, 8)
                    }
                    ForEach(model.allHosts, id: \.self) { host in
                        HStack(spacing: 7) {
                            Circle().fill(dot(host)).frame(width: 6, height: 6)
                            Toggle(isOn: Binding(get: { model.isEnabled(host) },
                                                 set: { model.setEnabled(host, $0) })) {
                                Text(host).font(.system(size: 11.5)).lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                            if host == model.currentRemote {
                                Text("当前 VS Code")
                                    .font(.system(size: 9)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 150)

            HStack(spacing: 6) {
                TextField("手动添加主机（ssh 别名）", text: $model.customHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { model.addCustom() }
                Button("添加") { model.addCustom() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)

            Divider()

            HStack(spacing: 8) {
                Button("测试连接") { model.testAll() }.buttonStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(.blue)
                Button("安装 Claude hooks") { model.installAll() }.buttonStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(.blue)
                Button("移除") { model.removeAll() }.buttonStyle(.plain)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Spacer()
                if !model.busy.isEmpty {
                    Text(model.busy).font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)

            if !model.message.isEmpty {
                ScrollView {
                    Text(model.message)
                        .font(.system(size: 10.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 90)
                .padding(.horizontal, 16).padding(.bottom, 12)
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("数据目录").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Button("诊断") { DiagnosticsWindowController.shared.show() }
                        .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.blue)
                    Button("打开配置文件") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: ConfigStore.path))
                    }
                    .buttonStyle(.plain).font(.system(size: 10.5)).foregroundStyle(.blue)
                }
                ForEach(AgentPaths.labels, id: \.key) { item in
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .frame(width: 116, alignment: .leading)
                        Text(AgentPaths.pretty(AgentPaths.base(item.key)))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                    }
                }
                HStack(spacing: 6) {
                    Text("DSH 解释器")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .frame(width: 116, alignment: .leading)
                    if let node = DSHLogReader.nodePath {
                        Text(AgentPaths.pretty(node))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    } else {
                        Text("未找到 · 只影响 DSH 审批提醒")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                Text("改完保存即生效，不用重启；写错路径会当作没有该 Agent。")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 480, height: 640)
    }
}

/// 诊断：每个 Agent 到底能不能读到、读到多少。用户说「没提醒」时先看这里。
enum Diagnostics {
    struct Row {
        let title: String
        let ok: Bool
        let detail: String
    }

    private static func count(_ dir: String, suffix: String) -> Int {
        guard let en = FileManager.default.enumerator(atPath: dir) else { return 0 }
        var n = 0
        for case let p as String in en where p.hasSuffix(suffix) {
            n += 1
            if n > 9999 { break }
        }
        return n
    }

    private static func fileSize(_ path: String) -> String? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path),
              let n = a[.size] as? Int64 else { return nil }
        if n > 1_048_576 { return String(format: "%.1f MB", Double(n) / 1_048_576) }
        if n > 1024 { return "\(n / 1024) KB" }
        return "\(n) B"
    }

    static func rows() -> [Row] {
        var out: [Row] = []
        let fm = FileManager.default

        // Claude Code：看 hooks 有没有真的写进去
        let claudeDir = AgentPaths.base("claude")
        let settingsPath = claudeDir + "/settings.json"
        var claudeOK = false
        var claudeNote = "没找到 settings.json"
        if let text = try? String(contentsOfFile: settingsPath, encoding: .utf8) {
            claudeOK = text.contains("agentsdone-hook")
            claudeNote = claudeOK ? "hooks 已写入，新开会话后生效" : "settings.json 里没有 agentsdone-hook，重跑 install.sh"
        }
        out.append(Row(title: "Claude Code", ok: claudeOK, detail: claudeNote))

        // Codex
        let codexDir = AgentPaths.base("codex")
        if fm.fileExists(atPath: codexDir) {
            let n = count(AgentPaths.codexSessions(), suffix: ".jsonl")
            out.append(Row(title: "Codex", ok: n > 0,
                           detail: n > 0 ? "\(n) 个会话日志" : "目录在，但没有会话日志（还没跑过？）"))
        } else {
            out.append(Row(title: "Codex", ok: false, detail: "目录不存在，没装或改过 CODEX_HOME"))
        }

        // DeepSeek Harness
        let dshDir = AgentPaths.base("dsh")
        if fm.fileExists(atPath: dshDir) {
            let n = count(AgentPaths.dshSessions(), suffix: ".json")
            let node = DSHLogReader.nodePath != nil
            out.append(Row(title: "DeepSeek Harness", ok: n > 0,
                           detail: "\(n) 个会话缓存" + (node ? " · 解释器已找到" : " · 找不到 DSH 解释器，审批提醒不可用")))
        } else {
            out.append(Row(title: "DeepSeek Harness", ok: false, detail: "目录不存在"))
        }

        // ZCode
        let zcodeDir = AgentPaths.base("zcode")
        let zcodeDB = zcodeDir + "/tasks-index.sqlite"
        if let size = fileSize(zcodeDB) {
            out.append(Row(title: "ZCode", ok: true, detail: "任务索引 \(size)"))
        } else {
            out.append(Row(title: "ZCode", ok: false, detail: "没找到 tasks-index.sqlite"))
        }

        // Antigravity
        let agDir = AgentPaths.base("antigravity")
        let agDB = agDir + "/conversation_summaries.db"
        if let size = fileSize(agDB) {
            out.append(Row(title: "Antigravity", ok: true, detail: "会话库 \(size)"))
        } else {
            out.append(Row(title: "Antigravity", ok: false, detail: "没找到 conversation_summaries.db"))
        }
        return out
    }

    static let demoRows: [Row] = [
        Row(title: "Claude Code", ok: true, detail: "hooks 已写入，新开会话后生效"),
        Row(title: "Codex", ok: true, detail: "27 个会话日志"),
        Row(title: "DeepSeek Harness", ok: true, detail: "69 个会话缓存 · 解释器已找到"),
        Row(title: "ZCode", ok: true, detail: "任务索引 2.1 MB"),
        Row(title: "Antigravity", ok: false, detail: "没找到 conversation_summaries.db"),
    ]

    /// 一键复制的纯文本，方便贴出来排查
    static func text() -> String {
        let ver = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        var lines = ["AgentsDone 诊断", "版本 \(ver)",
                     "配置 \(ConfigStore.path)"]
        for r in rows() {
            lines.append("\(r.ok ? "✓" : "✗")  \(r.title)：\(r.detail)")
        }
        lines.append("—— 路径 ——")
        for item in AgentPaths.labels {
            lines.append("\(item.title)：\(AgentPaths.pretty(AgentPaths.base(item.key)))")
        }
        lines.append("DSH 解释器：\(DSHLogReader.nodePath.map { AgentPaths.pretty($0) } ?? "未找到")")
        let cfgHosts = ConfigStore.load().hosts
        lines.append("远端主机（配置）：" + (cfgHosts.isEmpty ? "无"
            : cfgHosts.map { "\($0.host)\($0.enabled ? "" : "(停用)")" }.joined(separator: ", ")))
        let live = RemoteWatcher.shared.status
        if !live.isEmpty {
            lines.append("远端状态：" + live.keys.sorted().map { "\($0)=\(live[$0] ?? "?")" }.joined(separator: ", "))
        }
        return lines.joined(separator: "\n")
    }
}

struct DiagnosticsView: View {
    var demo = false
    @State private var rows: [Diagnostics.Row] = []
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("诊断").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(copied ? "已复制" : "复制诊断信息") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Diagnostics.text(), forType: .string)
                    copied = true
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 4)

            Text("显示本机实际能不能读到每个 Agent 的数据。说「没提醒」时先看这里。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16).padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 9) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(r.ok ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                                .padding(.top, 4)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.title).font(.system(size: 11.5, weight: .medium))
                                Text(r.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                    Divider().padding(.vertical, 2)
                    ForEach(AgentPaths.labels, id: \.key) { item in
                        HStack(spacing: 6) {
                            Text(item.title)
                                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                .frame(width: 120, alignment: .leading)
                            Text(AgentPaths.pretty(AgentPaths.base(item.key)))
                                .font(.system(size: 10.5, design: .monospaced))
                                .lineLimit(1).truncationMode(.middle)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
            }

            Divider()
            HStack {
                Button("重新检查") { rows = Diagnostics.rows() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.blue)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .frame(width: 420, height: 460)
        .onAppear { if rows.isEmpty { rows = demo ? Diagnostics.demoRows : Diagnostics.rows() } }
    }
}

final class DiagnosticsWindowController {
    static let shared = DiagnosticsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "AgentsDone · 诊断"
            w.contentViewController = NSHostingController(rootView: DiagnosticsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 516),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "AgentsDone · 远程设置"
            w.contentViewController = NSHostingController(rootView: SettingsView(model: SettingsModel()))
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - 悬浮胶囊
// MARK: - 悬浮胶囊



/// 非激活面板第一次点击会被"激活窗口"吃掉，导致要点两下才有反应
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class PillController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?
    private var queue: [(Session, () -> Void)] = []
    private var tapAction: (() -> Void)?

    /// 排队显示：几个会话同时跑完时依次出现，不再互相覆盖
    func enqueue(_ s: Session, onClick: @escaping () -> Void) {
        queue.append((s, onClick))
        if queue.count > 5 { queue.removeFirst(queue.count - 5) }   // 极端刷屏时只留最近的
        if panel == nil { showNext() }
    }

    private func showNext() {
        guard panel == nil, !queue.isEmpty else { return }
        let (s, action) = queue.removeFirst()
        show(s, onClick: action)
    }

    /// 点胶囊 → 跳回那个会话，并接着显示下一条
    private func handleTap() {
        let action = tapAction
        tapAction = nil
        hide()
        action?()
    }

    func show(_ s: Session, onClick: @escaping () -> Void) {
        hide()
        tapAction = onClick
        let root = PillView(session: s)
            .contentShape(Rectangle())
            .onTapGesture { [weak self] in self?.handleTap() }
        let host = FirstMouseHostingView(rootView: root)
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        // 后面还排着队就缩短停留，避免一次弹太久
        let stay: Double = queue.isEmpty ? 4.0 : 2.2
        let work = DispatchWorkItem { [weak self] in
            self?.tapAction = nil
            self?.hide()
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + stay, execute: work)
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            self?.showNext()
        })
    }
}

// MARK: - UI

struct PillView: View {
    let session: Session

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.state == .needs ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(session.title ?? session.project)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 260, alignment: .leading)
            Text(agentLabel(session.agent)).font(.system(size: 11)).foregroundStyle(.secondary)
            if !session.host.isEmpty, session.host != agentLabel(session.agent), session.host != "终端" {
                Text(session.host).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(session.state == .needs ? "需要你" : "已完成")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(session.state == .needs ? Color.orange : Color.green)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(Color(nsColor: .windowBackgroundColor).opacity(0.97))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        )
        .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

struct PanelView: View {
    @ObservedObject var store: Store
    var onJump: (Session) -> Void
    var onClear: () -> Void
    var onMute: () -> Void

    /// 头部：有待处理的就先报待处理，否则报运行中
    var headerSummary: String {
        if store.awaiting > 0 { return "\(store.awaiting) 个待处理" }
        if store.running > 0 { return "\(store.running) 个运行中" }
        return "无会话"
    }

    private var sessionList: some View {
        VStack(spacing: 4) {
            ForEach(store.sessions) { s in
                RowView(session: s).onTapGesture { onJump(s) }
            }
        }
        .padding(8)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("AgentsDone").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(headerSummary)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.top, 11).padding(.bottom, 9)

            Divider()

            if store.sessions.isEmpty {
                VStack(spacing: 6) {
                    Text("今日宜休息")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                    Text("没有会话在跑，喝口水吧")
                        .font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            } else {
                if SnapshotFlag.active {
                    sessionList
                } else {
                    ScrollView { sessionList }.frame(maxHeight: 424)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(action: onClear) {
                    Text("清除").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Button(action: { SettingsWindowController.shared.show() }) {
                    Text("设置").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button(action: onMute) {
                    Text(store.muted ? "已静音" : "静音").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                Button(action: { NSApp.terminate(nil) }) {
                    Text("退出").font(.system(size: 11))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
        }
        .frame(width: 340)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct RowView: View {
    let session: Session

    var stateColor: Color {
        switch session.state {
        case .needs: return .orange
        case .done: return .green
        case .working: return Color.secondary
        }
    }

    var stateText: String {
        switch session.state {
        case .needs:
            // 「需要你」的具体原因很多，挑最准的那个词
            if session.detail.hasPrefix("等待批准") { return "待批准" }
            if session.detail.hasPrefix("等待回答") { return "待回答" }
            if session.detail.hasPrefix("等待授权") { return "待授权" }
            if session.detail.hasPrefix("等待你的确认") { return "待确认" }
            return "需要你"
        case .done: return "已完成"
        case .working: return "运行中"
        }
    }

    var hostShort: String {
        let label = agentLabel(session.agent)
        if session.host.hasPrefix(label) {
            let rest = String(session.host.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? "" : rest
        }
        return session.host == "终端" ? "" : session.host
    }

    var subtitle: String {
        var parts = [agentLabel(session.agent)]
        if !hostShort.isEmpty { parts.append(hostShort) }
        parts.append(stateText)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 5)
                .fill(agentColor(session.agent).opacity(0.16))
                .frame(width: 22, height: 22)
                .overlay(Text(agentInitial(session.agent))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(agentColor(session.agent)))
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title ?? session.project)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    Circle().fill(stateColor).frame(width: 5, height: 5)
                    Text(subtitle)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !session.detail.isEmpty {
                    Text(session.detail).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(relTime(session.updated)).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }

    func relTime(_ d: Date) -> String {
        let s = Int(-d.timeIntervalSinceNow)
        if s < 60 { return "\(max(s, 1))s" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }
}


/// 全局快捷键（默认 ⌥⌘A）。Carbon 热键不需要辅助功能权限。
private var hotKeyAction: (() -> Void)?

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private(set) var registered = false

    @discardableResult
    func install(_ action: @escaping () -> Void) -> Bool {
        hotKeyAction = action
        if hotKeyRef != nil { registered = true; return true }
        guard handlerRef == nil else { return registered }

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            hotKeyAction?()
            return noErr
        }, 1, &spec, nil, &handlerRef)

        let id = EventHotKeyID(signature: OSType(0x4144_4E45), id: 1)   // 'ADNE'
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(optionKey | cmdKey),
                                         id, GetApplicationEventTarget(), 0, &hotKeyRef)
        registered = (status == noErr)
        return registered
    }

    func remove() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        registered = false
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let pill = PillController()
    var server: EventServer!
    var codex: CodexWatcher?
    var dsh: DSHWatcher?
    var zcode: ZCodeWatcher?
    var antigravity: AntigravityWatcher?
    private var configTimer: Timer?
    private var configSig = ""
    var remote: RemoteWatcher?
    var statusItem: NSStatusItem!
    var popover: NSPopover?

    /// 设置页「试一下提醒」：用两条假会话演示排队和点击
    func playTestPill() {
        if !store.muted { NSSound(named: "Glass")?.play() }
        let demo = [
            Session(id: "demo-done", agent: "codex", project: "checkout-service",
                    title: "重构订单页的数据层", cwd: "", host: "VS Code",
                    bundleId: "com.microsoft.VSCode", tty: "", state: .done,
                    detail: "12 个测试全部通过", updated: Date()),
            Session(id: "demo-needs", agent: "claude", project: "api-server",
                    title: "把限流挪到网关层", cwd: "", host: "iTerm",
                    bundleId: "com.googlecode.iterm2", tty: "", state: .needs,
                    detail: "等待批准：Bash · git push origin main", updated: Date()),
        ]
        for s in demo { pill.enqueue(s, onClick: {}) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(forName: .agentsDoneTestPill, object: nil,
                                               queue: .main) { [weak self] _ in
            self?.playTestPill()
        }
        // 测试用：启动就进入静音 N 分钟
        if let m = ProcessInfo.processInfo.environment["AGENTSDONE_SNOOZE_MINUTES"], let mins = Int(m), mins > 0 {
            store.snoozeUntil = Date().addingTimeInterval(Double(mins) * 60)
        }
        NotificationCenter.default.addObserver(forName: .agentsDoneSnooze, object: nil,
                                               queue: .main) { [weak self] note in
            let minutes = (note.userInfo?["minutes"] as? Int) ?? 0
            self?.store.snoozeUntil = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
            self?.refreshIcon()
        }
        NotificationCenter.default.addObserver(forName: .agentsDoneConfigChanged, object: nil,
                                               queue: .main) { _ in
            let cfg = ConfigStore.load()
            if cfg.hotkey { HotKeyManager.shared.install { [weak self] in self?.togglePopover() } }
            else { HotKeyManager.shared.remove() }
        }
        if ConfigStore.load().hotkey {
            let ok = HotKeyManager.shared.install { [weak self] in self?.togglePopover() }
            NSLog("AgentsDone: 全局快捷键 ⌥⌘A %@", ok ? "已注册" : "注册失败（可能被别的 App 占用）")
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp])
        refreshIcon()

        store.onChange = { [weak self] in self?.refreshIcon() }

        if anotherInstanceRunning() {
            NSLog("AgentsDone: 已有实例在运行，本次退出")
            NSApp.terminate(nil)
            return
        }

        server = EventServer(path: sockPath())
        server.onEvent = { [weak self] ev in self?.handle(ev) }
        server.onStatus = { [weak self] in self?.store.json() ?? Data("{}".utf8) }
        server.start()

        let r = RemoteWatcher.shared
        r.onEvent = { [weak self] ev in self?.handle(ev) }
        r.start()
        remote = r

        startLocalWatchers()
        watchConfig()
    }

    /// 数据目录可能写在 ~/.agentsdone/config.json，改了要能生效
    private func startLocalWatchers() {
        let w = CodexWatcher()
        w.onEvent = { [weak self] ev in self?.handle(ev) }
        w.start()
        codex = w

        let d = DSHWatcher()
        d.onEvent = { [weak self] ev in self?.handle(ev) }
        d.start()
        dsh = d

        let z = ZCodeWatcher()
        z.onEvent = { [weak self] ev in self?.handle(ev) }
        z.start()
        zcode = z

        let ag = AntigravityWatcher()
        ag.onEvent = { [weak self] ev in self?.handle(ev) }
        ag.start()
        antigravity = ag
    }

    private func stopLocalWatchers() {
        codex?.stop(); codex = nil
        dsh?.stop(); dsh = nil
        zcode?.stop(); zcode = nil
        antigravity?.stop(); antigravity = nil
    }

    private func watchConfig() {
        configTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let attrs = try? FileManager.default.attributesOfItem(atPath: ConfigStore.path)
            let sig = "\((attrs?[.size] as? Int) ?? -1)@\((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            if self.configSig.isEmpty { self.configSig = sig; return }
            guard sig != self.configSig else { return }
            self.configSig = sig
            NSLog("AgentsDone: 配置变了，重载数据目录")
            self.stopLocalWatchers()
            // 目录可能刚建好，隔一下再起，避免拿到半截状态
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.startLocalWatchers() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        remote?.shutdown()
        stopLocalWatchers()
    }

    func anotherInstanceRunning() -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cap = MemoryLayout.size(ofValue: addr.sun_path)
        let path = sockPath()
        _ = path.utf8CString.withUnsafeBufferPointer { src in
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
        return ok == 0
    }

    func sockPath() -> String {
        ProcessInfo.processInfo.environment["AGENTSDONE_SOCK"] ?? "/tmp/agentsdone-\(getuid()).sock"
    }

    func handle(_ ev: HookEvent) {
        let before = store.sessions
        store.ingest(ev)
        guard ev.kind == "done" || ev.kind == "needs" else { return }
        guard let s = store.sessions.first(where: {
            $0.id == "\(ev.agent):\(ev.sessionId ?? ev.cwd ?? "")"
        }) else { return }
        let isNew = !before.contains { $0.id == s.id && $0.state == s.state }
        guard isNew else { return }
        // 锁屏、静音、静音时段内都不弹；会话照样进列表，解锁后能补看
        if screenIsLocked() || store.quiet { return }
        if ev.kind == "done" { playSound(ConfigStore.load().sound) }
        pill.enqueue(s, onClick: { [weak self] in self?.jump(to: s) })
    }

    /// 锁屏/熄屏时别打扰
    func screenIsLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    /// 播提示音；名字为空就静音
    func playSound(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }

    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let n = store.awaiting
        let symbol = n > 0 ? "bell.badge.fill" : "bell"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AgentsDone")
        img?.isTemplate = true
        button.image = img
        button.title = n > 0 ? " \(n)" : ""
        button.toolTip = n > 0 ? "\(n) 个会话等待你" : "AgentsDone"
    }

    @objc func togglePopover() {
        if let p = popover, p.isShown {
            p.performClose(nil); popover = nil; return
        }
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = NSHostingController(rootView: PanelView(
            store: store,
            onJump: { [weak self] s in self?.jump(to: s) },
            onClear: { [weak self] in self?.store.clearDone() },
            onMute: { [weak self] in self?.store.muted.toggle() }
        ))
        p.show(relativeTo: statusItem.button!.bounds, of: statusItem.button!, preferredEdge: .minY)
        popover = p
        NSApp.activate(ignoringOtherApps: true)
    }

    func jump(to s: Session) {
        store.ack(s.id)
        popover?.performClose(nil); popover = nil
        guard let bid = s.bundleId, !bid.isEmpty,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: bid).first
        else { return }
        app.activate(options: [.activateAllWindows])
        let vscodeLike = ["com.microsoft.VSCode", "com.googlecode.iterm2", "com.apple.Terminal",
                          "dev.warp.Warp-Stable", "com.mitchellh.ghostty"]
        if vscodeLike.contains(bid), !s.cwd.isEmpty,
           FileManager.default.fileExists(atPath: s.cwd), let appURL = app.bundleURL {
            NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)],
                                    withApplicationAt: appURL,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }
}

// MARK: - 预览图渲染（--snapshot）

/// 出预览图时置 true：ScrollView 在 ImageRenderer 里渲染不出内容，改用普通 VStack
enum SnapshotFlag {
    nonisolated(unsafe) static var active = false
}

enum Snapshot {
    /// 用 SwiftUI 的 ImageRenderer 按 scale 倍重绘。
    /// 离屏 NSHostingView 走 cacheDisplay 只在 1 倍下栅格化、再被放大填进大位图 —— 文字就是那样发虚的。
    @MainActor
    @available(macOS 13.0, *)
    static func render<V: View>(_ content: V, size: CGSize, to path: String, scale: CGFloat = 3) {
        let renderer = ImageRenderer(content: content.frame(width: size.width, height: size.height))
        renderer.scale = scale
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot -> \(path) (\(cg.width)x\(cg.height))")
    }

    /// 兜底：含 AppKit 控件（Toggle / TextField）的视图 ImageRenderer 画不出来，
    /// 只能走离屏 cacheDisplay。它按视图自身 backing scale 栅格化（本机 2 倍）。
    @MainActor
    static func legacyPNG<V: View>(_ content: V, size: CGSize, to path: String) {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot -> \(path) (\(rep.pixelsWide)x\(rep.pixelsHigh))")
    }

    /// 量出 SwiftUI 视图在给定宽度下的自然高度
    @MainActor
    static func measure<V: View>(_ content: V, width: CGFloat, minHeight: CGFloat) -> CGSize {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: width > 0 ? width : 10, height: 200)
        host.layoutSubtreeIfNeeded()
        let fit = host.fittingSize
        let w = width > 0 ? width : fit.width          // width 传 0 表示按内容自然宽度
        return CGSize(width: ceil(w), height: ceil(max(fit.height, minHeight)))
    }

    @MainActor
    static func renderEmpty(path: String) {
        SnapshotFlag.active = true
        let store = Store()
        let content = PanelView(store: store, onJump: { _ in }, onClear: {}, onMute: {})
        let size = measure(content, width: 340, minHeight: 150)
        if #available(macOS 13.0, *) { render(content, size: size, to: path) }
    }

    @MainActor
    static func render(path: String) {
        SnapshotFlag.active = true
        let store = Store()
        let samples: [HookEvent] = [
            HookEvent(agent: "claude", kind: "needs", sessionId: "a", cwd: "/Users/me/work/api-server",
                      project: "api-server", title: "复盘上周的权限模型改造",
                      detail: "Claude needs your permission to use Bash", host: "VS Code", bundleId: "com.microsoft.VSCode"),
            HookEvent(agent: "claude", kind: "done", sessionId: "c", cwd: "/Users/me/work/infra",
                      project: "infra", title: "Helm chart 升到 1.4",
                      detail: "Helm chart 已更新", host: "iTerm", bundleId: "com.googlecode.iterm2"),
            HookEvent(agent: "codex", kind: "done", sessionId: "g", cwd: "/Users/me/work/checkout-service",
                      project: "checkout-service", title: "修复训练管道的重试逻辑",
                      detail: "远端跑完了：修好了数据管道的重试逻辑", host: "VS Code（远程）",
                      bundleId: "com.microsoft.VSCode"),
            HookEvent(agent: "dsh", kind: "needs", sessionId: "e", cwd: "/Users/me/work/agent-core",
                      project: "agent-core", title: "把重试逻辑挪到适配层",
                      detail: "等待批准：bash · 安装依赖到系统目录", host: "DeepSeek Harness",
                      bundleId: "com.deepseek.dsh"),
            HookEvent(agent: "zcode", kind: "needs", sessionId: "f", cwd: "/Users/me/work/admin-panel",
                      project: "admin-panel", title: "实现登录页",
                      detail: "任务出错", host: "ZCode", bundleId: "dev.zcode.app"),
            HookEvent(agent: "claude", kind: "needs", sessionId: "h", cwd: "/Users/me/work/api-server",
                      project: "api-server", title: "把限流挪到网关层",
                      detail: "等待批准：Bash · git push origin main",
                      host: "iTerm", bundleId: "com.googlecode.iterm2"),
            HookEvent(agent: "antigravity", kind: "needs", sessionId: "k", cwd: "",
                      project: "Antigravity", title: "把 CertMem 的权限模型讲清楚",
                      detail: "等待你在 Antigravity 里确认", host: "Antigravity",
                      bundleId: "com.google.antigravity"),
            HookEvent(agent: "codex", kind: "working", sessionId: "i", cwd: "/Users/me/work/agent-core",
                      project: "agent-core", title: "重写评测脚本支持多卡并行",
                      detail: "", host: "VS Code（远程）", bundleId: "com.microsoft.VSCode"),
        ]
        for e in samples { store.ingest(e) }
        let content = PanelView(store: store, onJump: { _ in }, onClear: {}, onMute: {})
        let size = measure(content, width: 340, minHeight: 220)
        if #available(macOS 13.0, *) { render(content, size: size, to: path) }
    }

    @MainActor
    static func renderDiag(path: String) {
        SnapshotFlag.active = true
        let content = DiagnosticsView(demo: true).background(Color(NSColor.windowBackgroundColor))
        legacyPNG(content, size: CGSize(width: 420, height: 460), to: path)
    }

    @MainActor
    static func renderSettings(path: String) {
        let model = SettingsModel(demo: true)
        let content = SettingsView(model: model).background(Color(NSColor.windowBackgroundColor))
        legacyPNG(content, size: CGSize(width: 480, height: 640), to: path)
    }

    @MainActor
    static func renderPill(path: String) {
        let s = Session(id: "x", agent: "codex", project: "web-client",
                        title: "重构订单页的数据层", cwd: "/tmp",
                        host: "VS Code", bundleId: "com.microsoft.VSCode", tty: "",
                        state: .done, detail: "重构完成，12 个测试全部通过", updated: Date())
        // 真机上胶囊靠系统材质透出背景，导出图里垫一层不透明底色，免得在深色主题下看不清
        let content = PillView(session: s)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        let size = measure(content, width: 0, minHeight: 1)   // 胶囊按自然宽度
        if #available(macOS 13.0, *) {
            render(content, size: CGSize(width: size.width, height: size.height), to: path)
        }
    }
}

// MARK: - main

@main
struct AgentsDoneMain {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(path: args[i + 1]); exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            Snapshot.renderSettings(path: args[i + 1])
            exit(0)
        }
        if args.contains("--test-pill") {
            // 自测：起 App 后弹两条示例提醒，8 秒后退出，用来确认排队与点击行为
            let app = NSApplication.shared
            let delegate = AppDelegate()
            app.delegate = delegate
            app.setActivationPolicy(.accessory)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                delegate.playTestPill()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) { exit(0) }
            app.run()
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-diag"), i + 1 < args.count {
            Snapshot.renderDiag(path: args[i + 1])
            exit(0)
        }
        if args.contains("--diagnose") {
            print(Diagnostics.text())
            exit(0)
        }
        if args.contains("--paths") {
            print("config: \(ConfigStore.path)")
            for item in AgentPaths.labels {
                print("\(item.key.padding(toLength: 12, withPad: " ", startingAt: 0)) \(AgentPaths.base(item.key))")
            }
            print("codex sessions: \(AgentPaths.codexSessions())")
            print("dsh sessions:   \(AgentPaths.dshSessions())")
            print("dsh logs:       \(AgentPaths.dshLogs())")
            print("dsh node:       \(DSHLogReader.nodePath ?? "未找到（DSH 审批提醒不可用）")")
            exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-empty"), i + 1 < args.count {
            Snapshot.renderEmpty(path: args[i + 1]); exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-pill"), i + 1 < args.count {
            Snapshot.renderPill(path: args[i + 1]); exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
