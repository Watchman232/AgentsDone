// AgentDone — 极轻量多 AI 编码会话「完成提醒」
// 单文件 AppKit + SwiftUI，无第三方依赖，编译：swiftc -O -parse-as-library
import AppKit
import SwiftUI
import Darwin
import SQLite3

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
    private let queue = DispatchQueue(label: "agentdone.server", qos: .userInitiated)
    var onEvent: ((HookEvent) -> Void)?
    var onStatus: (() -> Data)?

    init(path: String) { self.path = path }

    func start() { queue.async { [weak self] in self?.run() } }

    private func run() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { NSLog("AgentDone: socket() failed"); return }
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
        guard bound == 0 else { NSLog("AgentDone: bind failed \(errno)"); close(fd); return }
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
        if let e = ProcessInfo.processInfo.environment["AGENTDONE_CODEX_DB"], !e.isEmpty { return e }
        return NSHomeDirectory() + "/.codex"
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
        if let root { self.root = root }
        else if let env = ProcessInfo.processInfo.environment["AGENTDONE_CODEX_ROOT"] { self.root = env }
        else { self.root = NSString(string: "~/.codex/sessions").expandingTildeInPath }
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
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentdone.codex"))
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
    var onEvent: ((HookEvent) -> Void)?

    init(root: String? = nil) {
        if let root { self.root = root }
        else if let env = ProcessInfo.processInfo.environment["AGENTDONE_DSH_ROOT"] { self.root = env }
        else { self.root = NSHomeDirectory() + "/.dsh/storages/session_projcache/sessions" }
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
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentdone.dsh"))
        FSEventStreamStart(stream)
        scan()
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

        guard emit, previous?.state != state, lastTurn > 0, !blank, !cwd.isEmpty else { return }
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

// MARK: - ZCode 任务监听（读 ~/.zcode 的任务索引 SQLite）

final class ZCodeWatcher {
    private let dir: String
    private let dbPath: String
    private var stream: FSEventStreamRef?
    private var last: [String: String] = [:]
    private var primed = false
    var onEvent: ((HookEvent) -> Void)?

    init(root: String? = nil) {
        let base: String
        if let root { base = root }
        else if let env = ProcessInfo.processInfo.environment["AGENTDONE_ZCODE_ROOT"] { base = env }
        else { base = NSHomeDirectory() + "/.zcode/v2" }
        self.dir = base
        self.dbPath = base + "/tasks-index.sqlite"
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
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentdone.zcode"))
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
            guard emit, primed, previous != state else { continue }
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
        if let root { dir = root }
        else if let env = ProcessInfo.processInfo.environment["AGENTDONE_ANTIGRAVITY_ROOT"], !env.isEmpty { dir = env }
        else { dir = NSHomeDirectory() + "/.gemini/antigravity" }
    }

    func start() {
        guard FileManager.default.fileExists(atPath: dir) else { return }
        scan(emit: false)
        primed = true

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
            FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "agentdone.antigravity"))
            FSEventStreamStart(stream)
        }

        // sqlite 的 WAL 落盘不一定会触发 FSEvent，再兜一层轮询
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "agentdone.antigravity.poll"))
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
            guard emit, primed, previous != state else { continue }
            let title = m.title.isEmpty ? "" : String(m.title.prefix(60))
            let ev = HookEvent(agent: "antigravity", kind: state, sessionId: id, cwd: "",
                               project: "Antigravity", title: title,
                               detail: String(detail.prefix(80)),
                               host: "Antigravity", bundleId: "com.google.antigravity")
            DispatchQueue.main.async { self.onEvent?(ev) }
        }
    }
}

// MARK: - 配置：远程主机（~/.agentdone/config.json）

struct RemoteEntry: Codable, Identifiable, Equatable {
    var host: String
    var enabled: Bool
    var id: String { host }
}

struct AppConfig: Codable {
    var followVSCode: Bool = true
    var hosts: [RemoteEntry] = []
}

enum ConfigStore {
    static var dir: String { NSHomeDirectory() + "/.agentdone" }
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
    static let agentDoneRemoteStatus = Notification.Name("agentDone.remote.status")
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
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
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
        for host in want where conns[host]?.proc?.isRunning != true { connect(host) }
        notifyStatus()
    }

    private func notifyStatus() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .agentDoneRemoteStatus, object: nil)
        }
    }

    private func teardown(_ host: String) {
        conns[host]?.proc?.terminate()
        conns[host] = nil
    }

    static func loadScript() -> String? {
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let candidates = [
            NSHomeDirectory() + "/.agentdone/remote/remote_watch.py",
            exe.appendingPathComponent("../remote/remote_watch.py").standardizedFileURL.path,
            exe.appendingPathComponent("remote/remote_watch.py").standardizedFileURL.path,
        ]
        for c in candidates {
            if let t = try? String(contentsOfFile: c, encoding: .utf8), !t.isEmpty { return t }
        }
        return nil
    }

    private func connect(_ host: String) {
        guard let script = RemoteWatcher.loadScript() else { return }
        var conn = Conn()
        conn.state = "connecting"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                       "-o", "ServerAliveInterval=20", "-o", "ServerAliveCountMax=2",
                       "-o", "StrictHostKeyChecking=accept-new", host, "python3 -"]
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
            if var c = self.conns[host] {
                c.state = "error"
                self.conns[host] = c
            }
            self.notifyStatus()
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.refresh() }
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
        let local = NSHomeDirectory() + "/.agentdone/remote/install_hooks.py"
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
        let local = NSHomeDirectory() + "/.agentdone/remote/install_hooks.py"
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
            return
        }
        let cfg = ConfigStore.load()
        followVSCode = cfg.followVSCode
        entries = cfg.hosts
        reload()
    }

    func reload() {
        available = SSHConfig.hosts()
        status = RemoteWatcher.shared.status
    }

    func persist() {
        ConfigStore.save(AppConfig(followVSCode: followVSCode, hosts: entries))
        RemoteWatcher.shared.refresh()
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
            .frame(maxHeight: 216)

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
        }
        .frame(width: 480, height: 516)
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
            w.title = "AgentDone · 远程设置"
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



final class PillController {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ s: Session, onClick: @escaping () -> Void) {
        hide()
        let view = PillView(session: s)
        let host = NSHostingView(rootView: view)
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
        panel.contentView = host
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.maxY - size.height - 12))
        }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.makeKey()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        self.panel = panel
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        _ = onClick
    }

    func hide() {
        hideWork?.cancel(); hideWork = nil
        guard let panel else { return }
        self.panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { panel.orderOut(nil) })
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("AgentDone").font(.system(size: 12, weight: .semibold))
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
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(store.sessions) { s in
                            RowView(session: s).onTapGesture { onJump(s) }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 424)
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let pill = PillController()
    var server: EventServer!
    var codex: CodexWatcher?
    var dsh: DSHWatcher?
    var zcode: ZCodeWatcher?
    var antigravity: AntigravityWatcher?
    var remote: RemoteWatcher?
    var statusItem: NSStatusItem!
    var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp])
        refreshIcon()

        store.onChange = { [weak self] in self?.refreshIcon() }

        if anotherInstanceRunning() {
            NSLog("AgentDone: 已有实例在运行，本次退出")
            NSApp.terminate(nil)
            return
        }

        server = EventServer(path: sockPath())
        server.onEvent = { [weak self] ev in self?.handle(ev) }
        server.onStatus = { [weak self] in self?.store.json() ?? Data("{}".utf8) }
        server.start()

        let w = CodexWatcher()
        w.onEvent = { [weak self] ev in self?.handle(ev) }
        w.start()
        codex = w

        let d = DSHWatcher()
        d.onEvent = { [weak self] ev in self?.handle(ev) }
        d.start()
        dsh = d

        let r = RemoteWatcher.shared
        r.onEvent = { [weak self] ev in self?.handle(ev) }
        r.start()
        remote = r

        let z = ZCodeWatcher()
        z.onEvent = { [weak self] ev in self?.handle(ev) }
        z.start()
        zcode = z

        let ag = AntigravityWatcher()
        ag.onEvent = { [weak self] ev in self?.handle(ev) }
        ag.start()
        antigravity = ag
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
        ProcessInfo.processInfo.environment["AGENTDONE_SOCK"] ?? "/tmp/agentdone-\(getuid()).sock"
    }

    func handle(_ ev: HookEvent) {
        let before = store.sessions
        store.ingest(ev)
        guard ev.kind == "done" || ev.kind == "needs" else { return }
        guard let s = store.sessions.first(where: {
            $0.id == "\(ev.agent):\(ev.sessionId ?? ev.cwd ?? "")"
        }) else { return }
        let isNew = !before.contains { $0.id == s.id && $0.state == s.state }
        if isNew, !store.muted {
            if ev.kind == "done" { NSSound(named: "Glass")?.play() }
            pill.show(s, onClick: { [weak self] in self?.jump(to: s) })
        }
    }

    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let n = store.awaiting
        let symbol = n > 0 ? "bell.badge.fill" : "bell"
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: "AgentDone")
        img?.isTemplate = true
        button.image = img
        button.title = n > 0 ? " \(n)" : ""
        button.toolTip = n > 0 ? "\(n) 个会话等待你" : "AgentDone"
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

enum Snapshot {
    static func renderEmpty(path: String) {
        let store = Store()
        let view = NSHostingView(rootView: PanelView(store: store, onJump: { _ in }, onClear: {}, onMute: {}))
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 160)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: CGSize(width: 340, height: max(size.height, 150)))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot -> \(path)")
    }

    static func render(path: String) {
        let store = Store()
        let now = Date()
        let samples: [HookEvent] = [
            HookEvent(agent: "claude", kind: "needs", sessionId: "a", cwd: "/Users/me/work/api-server",
                      project: "api-server", title: "复盘上周的权限模型改造",
                      detail: "Claude needs your permission to use Bash", host: "VS Code", bundleId: "com.microsoft.VSCode"),
            HookEvent(agent: "claude", kind: "done", sessionId: "c", cwd: "/Users/me/work/infra",
                      project: "infra", title: "Helm chart 升到 1.4",
                      detail: "Helm chart 已更新", host: "iTerm", bundleId: "com.googlecode.iterm2"),
            HookEvent(agent: "codex", kind: "done", sessionId: "g", cwd: "/Users/me/work/mf-duplexDemo",
                      project: "mf-duplexDemo", title: "修复训练管道的重试逻辑",
                      detail: "远端跑完了：修好了数据管道的重试逻辑", host: "VS Code（远程）",
                      bundleId: "com.microsoft.VSCode"),
            HookEvent(agent: "dsh", kind: "done", sessionId: "e", cwd: "/Users/me/work/agent-core",
                      project: "agent-core", title: "把重试逻辑挪到适配层",
                      detail: "把重试逻辑挪到适配层，补了 4 个用例", host: "DeepSeek Harness",
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
        _ = now
        let view = NSHostingView(rootView: PanelView(store: store, onJump: { _ in }, onClear: {}, onMute: {}))
        view.frame = NSRect(x: 0, y: 0, width: 340, height: 300)
        view.layoutSubtreeIfNeeded()
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: CGSize(width: 340, height: max(size.height, 220)))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("snapshot -> \(path)")
    }
}

extension Snapshot {
    static func renderSettings(path: String) {
        let model = SettingsModel(demo: true)
        let view = SettingsView(model: model).background(Color(NSColor.windowBackgroundColor))
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 516)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("settings -> \(path)")
    }

    static func renderPill(path: String) {
        let s = Session(id: "x", agent: "codex", project: "web-client",
                        title: "重构订单页的数据层", cwd: "/tmp",
                        host: "VS Code", bundleId: "com.microsoft.VSCode", tty: "",
                        state: .done, detail: "重构完成，12 个测试全部通过", updated: Date())
        let view = NSHostingView(rootView: PillView(session: s))
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
        print("pill -> \(path)")
    }
}

// MARK: - main

@main
struct AgentDoneMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            Snapshot.render(path: args[i + 1]); exit(0)
        }
        if let i = args.firstIndex(of: "--snapshot-settings"), i + 1 < args.count {
            Snapshot.renderSettings(path: args[i + 1])
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
