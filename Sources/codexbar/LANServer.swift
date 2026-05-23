import Foundation
import Network

// MARK: - 用量快照

/// 喂给看板的不可变数据快照。由 AppDelegate 在主线程组装、再异步交给 server。
struct LANSnapshot: Sendable {
    struct Provider: Sendable {
        var name: String
        var plan: String?
        var fiveHourPercent: Double?
        var fiveHourResetAt: Date?
        var weeklyPercent: Double?
        var weeklyResetAt: Date?
        var error: String?
    }

    /// 某一个自然日（本地时区）的双品牌 token 总量；用来画周/月柱状图。
    struct DailyPoint: Sendable {
        /// 当日 00:00 的时间戳。
        var dayStart: Date
        var claudeTokens: Int
        var codexTokens: Int
        var total: Int { claudeTokens + codexTokens }
    }

    var claude: Provider
    var codex: Provider
    /// DeepSeek 生成的一句俏皮总结，可为 nil。
    var quip: String?
    /// 最近 24 个自然小时的合计 token —— `[0]` 为 23 小时前，`[23]` 为当前小时。
    var hourlyTokens: [Int]
    /// 24 小时 token 的 Claude 细分（与 `hourlyTokens` 长度一致）。
    var hourlyClaudeTokens: [Int]
    /// 24 小时 token 的 Codex 细分。
    var hourlyCodexTokens: [Int]
    /// 最近 30 天每天的双品牌 token，`[0]` 为 29 天前，`[29]` 为今天。
    var dailyPoints: [DailyPoint]
    /// 今日累计 token（本地时区）。
    var todayTokens: Int
    /// 最近 7 天累计 token。
    var weekTokens: Int
    /// 最近一次接口拉取成功的时刻。
    var lastUpdated: Date?
    /// 这份快照的生成时刻 —— 写到页脚里。
    var generatedAt: Date
    /// Claude 每月续费日（用于「下次续费 X 天后」倒计时）。
    var claudeRenewalDay: Int
    /// Codex 每月续费日。
    var codexRenewalDay: Int
    /// 网页端用的小精灵形象 —— 只能是 "chibi" / "flower"（与 `Resources/Pets/` 子目录对应）。
    var petVariant: String

    static let empty = LANSnapshot(
        claude: Provider(name: "Claude Code"),
        codex: Provider(name: "Codex"),
        quip: nil,
        hourlyTokens: [Int](repeating: 0, count: 24),
        hourlyClaudeTokens: [Int](repeating: 0, count: 24),
        hourlyCodexTokens: [Int](repeating: 0, count: 24),
        dailyPoints: [],
        todayTokens: 0, weekTokens: 0,
        lastUpdated: nil, generatedAt: Date(),
        claudeRenewalDay: 3, codexRenewalDay: 19,
        petVariant: "chibi")
}

extension LANSnapshot.Provider {
    init(name: String) {
        self.init(name: name, plan: nil,
                  fiveHourPercent: nil, fiveHourResetAt: nil,
                  weeklyPercent: nil, weeklyResetAt: nil, error: nil)
    }
}

// MARK: - 视图与时间范围

/// 看板有两套渲染：移动端彩色版（默认）、Kindle 墨水屏版。
enum LANView: String, Sendable {
    case mobile, kindle
}

/// Kindle 端可以在 `?range=day|week|month` 之间切换。
enum LANRange: String, Sendable {
    case day, week, month

    var label: String {
        switch self {
        case .day: return "24 小时"
        case .week: return "最近 7 天"
        case .month: return "最近 30 天"
        }
    }
}

// MARK: - 局域网 HTTP 看板

/// 一个极简的 HTTP/1.1 server，专门为局域网内的 Kindle / 手机渲染用量看板。
///
/// 设计上：server 内部不持有任何 MainActor 隔离的字段，所有连接处理都在内部串行 queue 上跑；
/// 唯一会跨线程的事是「读快照」—— 通过 `snapshotProvider` 闭包跳回主线程取一份不可变快照。
final class LANServer: @unchecked Sendable {
    /// 主线程提供的快照拉取闭包。
    var snapshotProvider: (@MainActor @Sendable () -> LANSnapshot)?

    /// 当 server 状态变化（启动成功 / 端口占用等），通过此回调把可读文本送到主线程。
    var onStatus: (@Sendable (String) -> Void)?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "heycc.lan-server", qos: .utility)
    private var token: String = ""
    private(set) var port: Int = 0
    private(set) var isRunning = false

    func start(port: Int, token: String) {
        stop()
        self.token = token
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            onStatus?("端口 \(port) 不合法（应在 1024..65535）")
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        do {
            let listener = try NWListener(using: params, on: nwPort)
            self.listener = listener
            self.port = port
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.isRunning = true
                    self.onStatus?("局域网看板已启动：端口 \(self.port)")
                case let .failed(error):
                    self.isRunning = false
                    self.onStatus?("局域网看板启动失败：\(error.localizedDescription)")
                case .cancelled:
                    self.isRunning = false
                default:
                    break
                }
            }
            listener.start(queue: queue)
        } catch {
            onStatus?("局域网看板启动失败：\(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - 连接处理

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn) { [weak self] rawHead in
            guard let self else { conn.cancel(); return }
            guard let head = rawHead else {
                Self.sendStatic(conn, status: 400, reason: "Bad Request", body: nil)
                return
            }
            self.route(head: head, conn: conn)
        }
    }

    /// 读到 `\r\n\r\n` 为止；超过 8KB 仍未读完则视为非法请求，直接断开。
    private func readRequest(_ conn: NWConnection,
                             accumulated: Data = Data(),
                             completion: @escaping @Sendable (String?) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            if error != nil { completion(nil); return }
            var combined = accumulated
            if let data { combined.append(data) }
            if let range = combined.range(of: Data("\r\n\r\n".utf8)) {
                let head = combined.subdata(in: 0 ..< range.lowerBound)
                completion(String(data: head, encoding: .utf8))
                return
            }
            if combined.count > 8192 || isComplete {
                completion(nil)
                return
            }
            self?.readRequest(conn, accumulated: combined, completion: completion)
        }
    }

    private func route(head: String, conn: NWConnection) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let first = lines.first else {
            Self.sendStatic(conn, status: 400, reason: "Bad Request", body: nil); return
        }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            Self.sendStatic(conn, status: 400, reason: "Bad Request", body: nil); return
        }
        let method = String(parts[0])
        let target = String(parts[1])
        guard method == "GET" else {
            Self.sendStatic(conn, status: 405, reason: "Method Not Allowed", body: nil); return
        }

        let (path, query) = splitTarget(target)
        let suppliedToken = query["t"] ?? ""
        let userAgent = parseUserAgent(lines: lines.dropFirst())
        let expectedToken = token

        switch path {
        case "/":
            guard tokensMatch(supplied: suppliedToken, expected: expectedToken) else {
                Self.sendUnauthorized(conn); return
            }
            let view = pickView(query: query, userAgent: userAgent)
            let range = LANRange(rawValue: query["range"] ?? "") ?? .day
            let provider = snapshotProvider
            Task { @MainActor in
                let snapshot = provider?() ?? .empty
                let html: String
                switch view {
                case .kindle: html = renderKindlePage(snapshot, range: range, token: expectedToken)
                case .mobile: html = renderMobilePage(snapshot, token: expectedToken)
                }
                Self.sendStatic(conn, status: 200, reason: "OK",
                                body: Data(html.utf8),
                                contentType: "text/html; charset=utf-8")
            }

        case "/api/snapshot.json":
            guard tokensMatch(supplied: suppliedToken, expected: expectedToken) else {
                Self.sendUnauthorized(conn); return
            }
            let provider = snapshotProvider
            Task { @MainActor in
                let snapshot = provider?() ?? .empty
                let json = renderSnapshotJSON(snapshot)
                Self.sendStatic(conn, status: 200, reason: "OK",
                                body: json,
                                contentType: "application/json; charset=utf-8")
            }

        case "/healthz":
            Self.sendStatic(conn, status: 200, reason: "OK",
                            body: Data("ok".utf8),
                            contentType: "text/plain; charset=utf-8")

        case "/favicon.ico":
            Self.sendStatic(conn, status: 204, reason: "No Content", body: nil)

        case let p where p.hasPrefix("/pets/"):
            guard tokensMatch(supplied: suppliedToken, expected: expectedToken) else {
                Self.sendUnauthorized(conn); return
            }
            Self.servePetImage(conn, path: p)

        default:
            Self.sendStatic(conn, status: 404, reason: "Not Found", body: nil)
        }
    }

    /// 路由 `GET /pets/<variant>/<frame>.png` —— 从 Bundle 直接读图。双白名单防 path traversal。
    private static func servePetImage(_ conn: NWConnection, path: String) {
        let trimmed = path.dropFirst("/pets/".count)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2, parts[1].hasSuffix(".png") else {
            sendStatic(conn, status: 404, reason: "Not Found", body: nil); return
        }
        let variant = String(parts[0])
        let frame = String(parts[1].dropLast(4))
        let allowedVariants: Set<String> = ["chibi", "flower"]
        let allowedFrames: Set<String> = [
            "idle", "blink", "look_left", "look_right",
            "happy", "thinking", "worried", "sleepy", "celebrate",
        ]
        guard allowedVariants.contains(variant), allowedFrames.contains(frame) else {
            sendStatic(conn, status: 404, reason: "Not Found", body: nil); return
        }
        let subdir = "Pets/\(variant)_pet_frames"
        guard let url = Bundle.main.url(
            forResource: frame, withExtension: "png", subdirectory: subdir),
            let data = try? Data(contentsOf: url)
        else {
            sendStatic(conn, status: 404, reason: "Not Found", body: nil); return
        }
        sendStatic(conn, status: 200, reason: "OK",
                   body: data, contentType: "image/png",
                   cacheControl: "public, max-age=86400")
    }

    private static func sendUnauthorized(_ conn: NWConnection) {
        sendStatic(conn, status: 401, reason: "Unauthorized",
                   body: Data("缺少或无效的访问令牌（URL 应带 ?t=<token>）。".utf8),
                   contentType: "text/plain; charset=utf-8")
    }

    /// 写一份完整的 HTTP/1.1 响应并关闭连接。`NWConnection.send` 自身线程安全。
    nonisolated static func sendStatic(_ conn: NWConnection,
                                       status: Int, reason: String,
                                       body: Data?,
                                       contentType: String = "text/plain; charset=utf-8",
                                       cacheControl: String = "no-store") {
        let payload = body ?? Data()
        var headers = "HTTP/1.1 \(status) \(reason)\r\n"
        headers += "Content-Type: \(contentType)\r\n"
        headers += "Content-Length: \(payload.count)\r\n"
        headers += "Cache-Control: \(cacheControl)\r\n"
        headers += "Connection: close\r\n"
        headers += "\r\n"
        var data = Data(headers.utf8)
        data.append(payload)
        conn.send(content: data, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

// MARK: - 请求解析辅助

/// "/foo?bar=baz&t=x" → ("/foo", ["bar":"baz", "t":"x"])
private func splitTarget(_ target: String) -> (String, [String: String]) {
    guard let mark = target.firstIndex(of: "?") else { return (target, [:]) }
    let path = String(target[..<mark])
    let queryString = target[target.index(after: mark)...]
    var pairs: [String: String] = [:]
    for chunk in queryString.split(separator: "&", omittingEmptySubsequences: true) {
        let kv = chunk.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
        let value = kv.count > 1
            ? (String(kv[1]).removingPercentEncoding ?? String(kv[1]))
            : ""
        pairs[key] = value
    }
    return (path, pairs)
}

/// 从请求头里挑出 User-Agent。
private func parseUserAgent<S: Sequence>(lines: S) -> String where S.Element == Substring {
    for line in lines {
        guard let colonIdx = line.firstIndex(of: ":") else { continue }
        let name = line[..<colonIdx].lowercased()
        if name == "user-agent" {
            return String(line[line.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)
        }
    }
    return ""
}

/// 选择渲染哪一套：query.view 显式覆盖 > UA 嗅探 > 默认 mobile。
func pickView(query: [String: String], userAgent: String) -> LANView {
    if let explicit = query["view"], let view = LANView(rawValue: explicit.lowercased()) {
        return view
    }
    let ua = userAgent.lowercased()
    let kindleHints = ["kindle", "silk", "netfront"]
    if kindleHints.contains(where: { ua.contains($0) }) {
        return .kindle
    }
    return .mobile
}

/// 等长 + 逐字节对比，避免极弱的时序差泄露 token 长度信息。
private func tokensMatch(supplied: String, expected: String) -> Bool {
    let a = Array(supplied.utf8)
    let b = Array(expected.utf8)
    guard !expected.isEmpty, a.count == b.count else { return false }
    var diff: UInt8 = 0
    for i in 0 ..< b.count {
        diff |= a[i] ^ b[i]
    }
    return diff == 0
}

// MARK: - 共享渲染工具

/// HTML 安全转义。
func htmlEscape(_ text: String) -> String {
    var out = ""
    out.reserveCapacity(text.count)
    for ch in text {
        switch ch {
        case "&": out += "&amp;"
        case "<": out += "&lt;"
        case ">": out += "&gt;"
        case "\"": out += "&quot;"
        case "'": out += "&#39;"
        default: out.append(ch)
        }
    }
    return out
}

/// 中文日期，例如「5 月 23 日 周六」。
func dayMonthText(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M 月 d 日 EEE"
    return formatter.string(from: date)
}

/// 距离下个月某「续费日」还有几天（含同月还没到、跨月两种情况）。
/// 当天就是续费日时返回 0。
func daysUntilRenewal(day: Int, from now: Date = Date()) -> Int {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: now)
    var components = calendar.dateComponents([.year, .month], from: today)
    let monthRange = calendar.range(of: .day, in: .month, for: today)?.count ?? 28
    let clamped = min(max(day, 1), monthRange)
    components.day = clamped
    guard var target = calendar.date(from: components) else { return -1 }
    if target < today {
        // 今天已过本月续费日 → 看下个月
        components.month = (components.month ?? 1) + 1
        let nextMonthRange: Int = {
            guard let nextMonthDate = calendar.date(from: components) else { return 28 }
            return calendar.range(of: .day, in: .month, for: nextMonthDate)?.count ?? 28
        }()
        components.day = min(max(day, 1), nextMonthRange)
        target = calendar.date(from: components) ?? target
    }
    return calendar.dateComponents([.day], from: today, to: target).day ?? -1
}

// MARK: - 本机 IP 探测

/// 列出本机所有 IPv4 地址（剔除回环），优先 en0/en1 这种物理网卡的会排到前面。
func localIPv4Addresses() -> [String] {
    var addresses: [(name: String, ip: String)] = []
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return [] }
    defer { freeifaddrs(ifaddr) }

    var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
    while let cur = ptr {
        defer { ptr = cur.pointee.ifa_next }
        let flags = Int32(cur.pointee.ifa_flags)
        guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else { continue }
        guard let sa = cur.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(sa, socklen_t(cur.pointee.ifa_addr.pointee.sa_len),
                                 &host, socklen_t(host.count),
                                 nil, 0, NI_NUMERICHOST)
        if result == 0 {
            let name = String(decoding: nameBytes(cur.pointee.ifa_name), as: UTF8.self)
            let ip = String(decoding: trimmingNull(host), as: UTF8.self)
            addresses.append((name: name, ip: ip))
        }
    }

    func rank(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name.hasPrefix("en") { return 1 }
        if name.hasPrefix("bridge") { return 3 }
        if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") { return 9 }
        return 2
    }
    return addresses.sorted { rank($0.name) < rank($1.name) }.map(\.ip)
}

private func trimmingNull(_ buffer: [CChar]) -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(buffer.count)
    for c in buffer {
        if c == 0 { break }
        bytes.append(UInt8(bitPattern: c))
    }
    return bytes
}

private func nameBytes(_ pointer: UnsafeMutablePointer<CChar>?) -> [UInt8] {
    guard let pointer else { return [] }
    var bytes: [UInt8] = []
    var index = 0
    while pointer[index] != 0 {
        bytes.append(UInt8(bitPattern: pointer[index]))
        index += 1
    }
    return bytes
}
