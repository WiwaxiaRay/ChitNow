import WidgetKit
import SwiftUI

// ── 配置 ───────────────────────────────────────────────────────────────────────
import CryptoKit

private let APP_GROUP = "group.com.wangyang.thenow"
private let _shared   = UserDefaults(suiteName: APP_GROUP)

private var BROKER_URL: String {
    #if targetEnvironment(simulator)
    return "https://localhost:8000"
    #else
    return _shared?.string(forKey: "brokerURL") ?? "https://172.30.87.117:8000"
    #endif
}
private var API_KEY: String {
    _shared?.string(forKey: "apiKey") ?? "dev-key"
}
private var CERT_FP: String? {
    _shared?.string(forKey: "certFingerprint")
}

// Cert-pinning URLSession for widget network requests
private func makePinnedSession() -> URLSession {
    guard let fp = CERT_FP, !fp.isEmpty else { return URLSession.shared }
    return URLSession(configuration: .default,
                      delegate: WidgetPinnedDelegate(fingerprint: fp),
                      delegateQueue: nil)
}

private final class WidgetPinnedDelegate: NSObject, URLSessionDelegate {
    private let fp: String
    init(fingerprint: String) { self.fp = fingerprint.lowercased() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf  = chain.first else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        let data = SecCertificateCopyData(leaf) as Data
        let got  = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        completionHandler(got == fp ? .useCredential : .cancelAuthenticationChallenge,
                          got == fp ? URLCredential(trust: trust) : nil)
    }
}

// ── 像素宠物（5×5）B=身体 e=眼睛 .=空 ─────────────────────────────────────────
private let MINI_CLAUDE_ART = [
    ".BBB.",
    "BBBBB",
    "BeBEB",
    "BBBBB",
    ".B.B.",
]

private let MINI_GPT_ART = [
    ".BBB.",
    "BBBBB",
    "BeBEB",
    "BBBBB",
    "B.B.B",
]

// ── Agent 枚举 ─────────────────────────────────────────────────────────────────

enum WidgetAgent { case claude, gpt }

// ── 数据模型 ───────────────────────────────────────────────────────────────────

struct WidgetEntry: TimelineEntry {
    let date: Date
    let claude5hPercent:     Int
    let claudeWeekPercent:   Int
    let claudeCost:          Double
    let claudeResetsIn:      String
    let claudeWeekResetsIn:  String
    let gpt5hPercent:        Int
    let gptWeekPercent:      Int
    let gptCost:             Double
    let gptResetsIn:         String
    let gptWeekResetsIn:     String
    let pendingCount:        Int

    static let placeholder = WidgetEntry(
        date: .now,
        claude5hPercent: 42, claudeWeekPercent: 21, claudeCost: 1.23,
        claudeResetsIn: "2h 30m", claudeWeekResetsIn: "4d 13h",
        gpt5hPercent: 65,    gptWeekPercent: 30,    gptCost: 5.67,
        gptResetsIn: "1h 15m", gptWeekResetsIn: "2d 08h",
        pendingCount: 0
    )
    static let empty = WidgetEntry(
        date: .now,
        claude5hPercent: 0, claudeWeekPercent: 0, claudeCost: 0,
        claudeResetsIn: "--", claudeWeekResetsIn: "--",
        gpt5hPercent: 0,    gptWeekPercent: 0,    gptCost: 0,
        gptResetsIn: "--", gptWeekResetsIn: "--",
        pendingCount: 0
    )
}

private struct UsageResp: Decodable {
    let claude: Stats; let gpt: Stats
    struct Stats: Decodable {
        let todayCost: Double; let quota: Quota?
        enum CodingKeys: String, CodingKey { case todayCost = "today_cost"; case quota }
    }
    struct Quota: Decodable {
        let usedPercent: Int?; let weekUsedPercent: Int?
        let resetsAt: String?; let weekResetsAt: String?
        enum CodingKeys: String, CodingKey {
            case usedPercent     = "used_percent"
            case weekUsedPercent = "week_used_percent"
            case resetsAt        = "resets_at"
            case weekResetsAt    = "week_resets_at"
        }
    }
}
private struct PendingItem: Decodable { let id: String }

// ── 本地缓存 ───────────────────────────────────────────────────────────────────

private struct CachedEntry: Codable {
    let claude5hPercent: Int; let claudeWeekPercent: Int
    let claudeCost: Double;   let claudeResetsIn: String;  let claudeWeekResetsIn: String
    let gpt5hPercent: Int;    let gptWeekPercent: Int
    let gptCost: Double;      let gptResetsIn: String;     let gptWeekResetsIn: String
}

private func saveCache(_ e: WidgetEntry) {
    let c = CachedEntry(
        claude5hPercent: e.claude5hPercent, claudeWeekPercent: e.claudeWeekPercent,
        claudeCost: e.claudeCost,           claudeResetsIn: e.claudeResetsIn,
        claudeWeekResetsIn: e.claudeWeekResetsIn,
        gpt5hPercent: e.gpt5hPercent,       gptWeekPercent: e.gptWeekPercent,
        gptCost: e.gptCost,                 gptResetsIn: e.gptResetsIn,
        gptWeekResetsIn: e.gptWeekResetsIn
    )
    if let d = try? JSONEncoder().encode(c) { UserDefaults.standard.set(d, forKey: "widgetCache") }
}

private func loadCache() -> WidgetEntry? {
    guard let d = UserDefaults.standard.data(forKey: "widgetCache"),
          let c = try? JSONDecoder().decode(CachedEntry.self, from: d) else { return nil }
    return WidgetEntry(
        date: .now,
        claude5hPercent: c.claude5hPercent, claudeWeekPercent: c.claudeWeekPercent,
        claudeCost: c.claudeCost,           claudeResetsIn: c.claudeResetsIn,
        claudeWeekResetsIn: c.claudeWeekResetsIn,
        gpt5hPercent: c.gpt5hPercent,       gptWeekPercent: c.gptWeekPercent,
        gptCost: c.gptCost,                 gptResetsIn: c.gptResetsIn,
        gptWeekResetsIn: c.gptWeekResetsIn,
        pendingCount: 0
    )
}

// ── 网络请求 ───────────────────────────────────────────────────────────────────

private func fetchEntry() async -> WidgetEntry {
    async let u = fetchUsage()
    async let p = fetchPendingCount()
    let (usage, pending) = await (u, p)
    guard let usage else { return loadCache() ?? .empty }
    let entry = WidgetEntry(
        date: .now,
        claude5hPercent:    usage.claude.quota?.usedPercent     ?? 0,
        claudeWeekPercent:  usage.claude.quota?.weekUsedPercent ?? 0,
        claudeCost:         usage.claude.todayCost,
        claudeResetsIn:     resetsInString(usage.claude.quota?.resetsAt),
        claudeWeekResetsIn: resetsInString(usage.claude.quota?.weekResetsAt),
        gpt5hPercent:       usage.gpt.quota?.usedPercent        ?? 0,
        gptWeekPercent:     usage.gpt.quota?.weekUsedPercent    ?? 0,
        gptCost:            usage.gpt.todayCost,
        gptResetsIn:        resetsInString(usage.gpt.quota?.resetsAt),
        gptWeekResetsIn:    resetsInString(usage.gpt.quota?.weekResetsAt),
        pendingCount:       pending
    )
    saveCache(entry)
    return entry
}

private func fetchUsage() async -> UsageResp? {
    guard let url = URL(string: "\(BROKER_URL)/usage") else { return nil }
    var r = URLRequest(url: url); r.setValue(API_KEY, forHTTPHeaderField: "X-API-Key"); r.timeoutInterval = 8
    guard let (data, _) = try? await makePinnedSession().data(for: r) else { return nil }
    return try? JSONDecoder().decode(UsageResp.self, from: data)
}

private func fetchPendingCount() async -> Int {
    guard let url = URL(string: "\(BROKER_URL)/pending-requests") else { return 0 }
    var r = URLRequest(url: url); r.setValue(API_KEY, forHTTPHeaderField: "X-API-Key"); r.timeoutInterval = 8
    guard let (data, _) = try? await makePinnedSession().data(for: r),
          let items = try? JSONDecoder().decode([PendingItem].self, from: data) else { return 0 }
    return items.count
}

private func resetsInString(_ iso: String?) -> String {
    guard let iso, let date = ISO8601DateFormatter().date(from: iso) else { return "--" }
    let s = max(0, Int(date.timeIntervalSince(.now)))
    let h = s / 3600; let m = (s % 3600) / 60
    return h > 0 ? "\(h)h \(String(format: "%02d", m))m" : "\(m)m"
}

// ── Provider ───────────────────────────────────────────────────────────────────

struct ThenowProvider: TimelineProvider {
    func placeholder(in context: Context) -> WidgetEntry { .placeholder }
    func getSnapshot(in context: Context, completion: @escaping (WidgetEntry) -> Void) {
        if context.isPreview { completion(.placeholder); return }
        Task { completion(await fetchEntry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WidgetEntry>) -> Void) {
        Task {
            let entry = await fetchEntry()
            let next  = Calendar.current.date(byAdding: .minute, value: 15, to: .now)!
            completion(Timeline(entries: [entry], policy: .after(next)))
        }
    }
}

// ── 圆形：双环 + 像素宠物 ──────────────────────────────────────────────────────

private struct CircularView: View {
    let entry: WidgetEntry
    let agent: WidgetAgent

    private static let claudePixels = buildPixels(MINI_CLAUDE_ART)
    private static let gptPixels    = buildPixels(MINI_GPT_ART)

    private static func buildPixels(_ art: [String]) -> [(Int, Int, Bool)] {
        art.enumerated().flatMap { r, row in
            row.enumerated().compactMap { c, ch -> (Int, Int, Bool)? in
                switch ch {
                case "B": return (c, r, false)
                case "e": return (c, r, true)
                default:  return nil
                }
            }
        }
    }

    var body: some View {
        if entry.pendingCount > 0 {
            VStack(spacing: 1) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.orange)
                Text("\(entry.pendingCount)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(.orange)
            }
        } else {
            let art        = agent == .claude ? MINI_CLAUDE_ART : MINI_GPT_ART
            let pixels     = agent == .claude ? Self.claudePixels : Self.gptPixels
            let ring5Color = agent == .claude ? Color(hex: "FF8A4C") : Color(hex: "1FD18A")
            let ringWColor = agent == .claude ? Color(hex: "C75F3E") : Color(hex: "0E8F66")
            let bodyColor  = agent == .claude ? Color(hex: "E8623D") : Color(hex: "19C37D")
            let eyeColor   = agent == .claude ? Color(hex: "100805") : Color(hex: "04140d")
            let ring5Pct   = agent == .claude ? entry.claude5hPercent   : entry.gpt5hPercent
            let ringWPct   = agent == .claude ? entry.claudeWeekPercent : entry.gptWeekPercent

            GeometryReader { geo in
                let s       = min(geo.size.width, geo.size.height)
                let lw      = s * 0.10
                let outerD  = s * 0.90
                let innerD  = s * 0.60
                let mascotD = s * 0.36
                let cell    = mascotD / CGFloat(art[0].count)

                ZStack {
                    Circle().stroke(ring5Color.opacity(0.18), lineWidth: lw).frame(width: outerD, height: outerD)
                    Circle()
                        .trim(from: 0, to: CGFloat(ring5Pct) / 100)
                        .stroke(ring5Color, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: outerD, height: outerD)

                    Circle().stroke(ringWColor.opacity(0.18), lineWidth: lw).frame(width: innerD, height: innerD)
                    Circle()
                        .trim(from: 0, to: CGFloat(ringWPct) / 100)
                        .stroke(ringWColor, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: innerD, height: innerD)

                    Canvas { ctx, _ in
                        for (c, r, isEye) in pixels {
                            ctx.fill(
                                Path(CGRect(x: CGFloat(c) * cell, y: CGFloat(r) * cell,
                                           width: cell, height: cell)),
                                with: .color(isEye ? eyeColor : bodyColor)
                            )
                        }
                    }
                    .frame(width: mascotD, height: mascotD)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }
}

// ── 长条形（terminal 风格，与 Watch App 圆环下方一致） ──────────────────────────

private struct RectView: View {
    let entry: WidgetEntry
    let agent: WidgetAgent

    var body: some View {
        if entry.pendingCount > 0 {
            VStack(spacing: 2) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold)).foregroundStyle(.orange)
                Text("\(entry.pendingCount) pending")
                    .font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.orange)
            }
        } else {
            let accent   = agent == .claude ? Color(hex: "E0805C") : Color(hex: "19C37D")
            let ring5    = agent == .claude ? Color(hex: "FF8A4C") : Color(hex: "1FD18A")
            let ringW    = agent == .claude ? Color(hex: "C75F3E") : Color(hex: "0E8F66")
            let sub      = agent == .claude ? Color(hex: "8d847a") : Color(hex: "7d7d86")
            let textCol  = agent == .claude ? Color(hex: "F3EEE6") : Color(hex: "ECECEC")

            let resetsIn     = agent == .claude ? entry.claudeResetsIn     : entry.gptResetsIn
            let weekResetsIn = agent == .claude ? entry.claudeWeekResetsIn : entry.gptWeekResetsIn
            let cost         = agent == .claude ? entry.claudeCost         : entry.gptCost

            let rows: [(key: String, val: String, col: Color)] = [
                ("5-HR", resetsIn,                              ring5),
                ("WEEK", weekResetsIn,                          ringW),
                ("COST", "~$\(String(format: "%.2f", cost))",  sub),
            ]

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text("> ")
                            .foregroundStyle(accent)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                        Text(row.key + "  ")
                            .foregroundStyle(row.col)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        Text(row.val)
                            .foregroundStyle(textCol)
                            .font(.system(size: 11, weight: .semibold, design: .monospaced).monospacedDigit())
                        if i == rows.count - 1 {
                            Text("_")
                                .foregroundStyle(accent)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(accent.opacity(0.18), lineWidth: 1))
            )
        }
    }
}

// ── 入口 View ──────────────────────────────────────────────────────────────────

struct ThenowWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: WidgetEntry
    let agent: WidgetAgent

    var body: some View {
        switch family {
        case .accessoryCircular:    CircularView(entry: entry, agent: agent)
        case .accessoryRectangular: RectView(entry: entry, agent: agent)
        default:                    CircularView(entry: entry, agent: agent)
        }
    }
}

// ── Widget 定义 ────────────────────────────────────────────────────────────────

struct ClaudeWidget: Widget {
    let kind = "ClaudeWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ThenowProvider()) { entry in
            ThenowWidgetEntryView(entry: entry, agent: .claude)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("Claude 额度")
        .description("Claude 5小时 & 本周配额")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct GPTWidget: Widget {
    let kind = "GPTWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ThenowProvider()) { entry in
            ThenowWidgetEntryView(entry: entry, agent: .gpt)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("ChatGPT 额度")
        .description("ChatGPT 5小时 & 本周配额")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

@main
struct ThenowWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClaudeWidget()
        GPTWidget()
    }
}

// ── Color 工具 ─────────────────────────────────────────────────────────────────
private extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0; Scanner(string: s).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}
