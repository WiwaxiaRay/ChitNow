import WidgetKit
import SwiftUI

// ── 配置 ───────────────────────────────────────────────────────────────────────
#if targetEnvironment(simulator)
private let BROKER_BASE = "http://localhost:8000"
#else
private let BROKER_BASE = "http://dacidabeiwushouyehehuadeMacBook-Air.local:8000"
#endif
private let API_KEY = "dev-key"

// ── 像素宠物（5×5） ────────────────────────────────────────────────────────────
// B=身体  e=眼睛  .=空
private let MINI_ART = [
    ".BBB.",
    "BBBBB",
    "BeBEB",
    "BBBBB",
    ".B.B.",
]

// ── 数据模型 ───────────────────────────────────────────────────────────────────

struct WidgetEntry: TimelineEntry {
    let date: Date
    let claude5hPercent:  Int     // 5小时额度
    let claudeWeekPercent: Int    // 周额度
    let todayCost: Double
    let pendingCount: Int
    let resetsIn: String

    static let placeholder = WidgetEntry(date: .now, claude5hPercent: 42, claudeWeekPercent: 21,
                                         todayCost: 1.23, pendingCount: 0, resetsIn: "2h 30m")
    static let empty       = WidgetEntry(date: .now, claude5hPercent: 0, claudeWeekPercent: 0,
                                         todayCost: 0, pendingCount: 0, resetsIn: "--")
}

private struct UsageResp: Decodable {
    let claude: Stats; let gpt: Stats
    struct Stats: Decodable {
        let todayCost: Double; let quota: Quota?
        enum CodingKeys: String, CodingKey { case todayCost = "today_cost"; case quota }
    }
    struct Quota: Decodable {
        let usedPercent: Int?; let weekUsedPercent: Int?; let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case weekUsedPercent = "week_used_percent"
            case resetsAt = "resets_at"
        }
    }
}
private struct PendingItem: Decodable { let id: String }

// ── 本地缓存 ───────────────────────────────────────────────────────────────────

private struct CachedEntry: Codable {
    let claude5hPercent: Int; let claudeWeekPercent: Int
    let todayCost: Double; let resetsIn: String
}

private func saveCache(_ entry: WidgetEntry) {
    let c = CachedEntry(claude5hPercent: entry.claude5hPercent,
                        claudeWeekPercent: entry.claudeWeekPercent,
                        todayCost: entry.todayCost, resetsIn: entry.resetsIn)
    if let d = try? JSONEncoder().encode(c) {
        UserDefaults.standard.set(d, forKey: "widgetCache")
    }
}

private func loadCache() -> WidgetEntry? {
    guard let d = UserDefaults.standard.data(forKey: "widgetCache"),
          let c = try? JSONDecoder().decode(CachedEntry.self, from: d) else { return nil }
    return WidgetEntry(date: .now, claude5hPercent: c.claude5hPercent,
                       claudeWeekPercent: c.claudeWeekPercent,
                       todayCost: c.todayCost, pendingCount: 0, resetsIn: c.resetsIn)
}

// ── 网络请求 ───────────────────────────────────────────────────────────────────

private func fetchEntry() async -> WidgetEntry {
    async let u = fetchUsage()
    async let p = fetchPendingCount()
    let (usage, pending) = await (u, p)
    if usage == nil { return loadCache() ?? .empty }
    let entry = WidgetEntry(
        date:              .now,
        claude5hPercent:   usage?.claude.quota?.usedPercent     ?? 0,
        claudeWeekPercent: usage?.claude.quota?.weekUsedPercent ?? 0,
        todayCost:         (usage?.claude.todayCost ?? 0) + (usage?.gpt.todayCost ?? 0),
        pendingCount:      pending,
        resetsIn:          resetsInString(usage?.claude.quota?.resetsAt)
    )
    saveCache(entry)
    return entry
}

private func fetchUsage() async -> UsageResp? {
    guard let url = URL(string: "\(BROKER_BASE)/usage") else { return nil }
    var r = URLRequest(url: url); r.setValue(API_KEY, forHTTPHeaderField: "X-API-Key"); r.timeoutInterval = 8
    guard let (data, _) = try? await URLSession.shared.data(for: r) else { return nil }
    return try? JSONDecoder().decode(UsageResp.self, from: data)
}

private func fetchPendingCount() async -> Int {
    guard let url = URL(string: "\(BROKER_BASE)/pending-requests") else { return 0 }
    var r = URLRequest(url: url); r.setValue(API_KEY, forHTTPHeaderField: "X-API-Key"); r.timeoutInterval = 8
    guard let (data, _) = try? await URLSession.shared.data(for: r),
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

// ── 圆形：双层圆环 + 像素宠物 ─────────────────────────────────────────────────

private struct CircularView: View {
    let entry: WidgetEntry

    // 预计算像素坐标 (col, row, isEye)
    private static let pixels: [(Int, Int, Bool)] = {
        var result: [(Int, Int, Bool)] = []
        for (r, row) in MINI_ART.enumerated() {
            for (c, ch) in row.enumerated() {
                if ch == "B"      { result.append((c, r, false)) }
                else if ch == "e" { result.append((c, r, true))  }
            }
        }
        return result
    }()

    var body: some View {
        if entry.pendingCount > 0 {
            VStack(spacing: 1) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.orange)
                Text("\(entry.pendingCount)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(.orange)
            }
        } else {
            GeometryReader { geo in
                let s      = min(geo.size.width, geo.size.height)
                let lw     = s * 0.10          // 环线宽
                let outerD = s * 0.90          // 外环（5h）直径
                let innerD = s * 0.60          // 内环（周）直径
                let mascotD = s * 0.36         // 宠物区直径
                let cell   = mascotD / CGFloat(MINI_ART[0].count)   // 每格像素大小

                ZStack {
                    // 外环轨道 - 5小时
                    Circle()
                        .stroke(Color(hex: "FF8A4C").opacity(0.18), lineWidth: lw)
                        .frame(width: outerD, height: outerD)
                    // 外环进度 - 5小时
                    Circle()
                        .trim(from: 0, to: CGFloat(entry.claude5hPercent) / 100)
                        .stroke(Color(hex: "FF8A4C"),
                                style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: outerD, height: outerD)

                    // 内环轨道 - 本周
                    Circle()
                        .stroke(Color(hex: "C75F3E").opacity(0.18), lineWidth: lw)
                        .frame(width: innerD, height: innerD)
                    // 内环进度 - 本周
                    Circle()
                        .trim(from: 0, to: CGFloat(entry.claudeWeekPercent) / 100)
                        .stroke(Color(hex: "C75F3E"),
                                style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: innerD, height: innerD)

                    // 像素宠物
                    Canvas { ctx, _ in
                        for (c, r, isEye) in Self.pixels {
                            ctx.fill(
                                Path(CGRect(x: CGFloat(c) * cell,
                                           y: CGFloat(r) * cell,
                                           width: cell, height: cell)),
                                with: .color(isEye ? Color(hex: "100805") : Color(hex: "E8623D"))
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

// ── 长条形 ─────────────────────────────────────────────────────────────────────

private struct RectView: View {
    let entry: WidgetEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Claude")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(hex: "E0805C"))
                Spacer()
                if entry.pendingCount > 0 {
                    Label("\(entry.pendingCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.orange)
                }
            }
            Gauge(value: Double(entry.claude5hPercent) / 100.0) {
                EmptyView()
            } currentValueLabel: {
                Text("\(entry.claude5hPercent)%")
                    .font(.system(size: 9, design: .monospaced))
            }
            .gaugeStyle(.accessoryLinear)
            .tint(Gradient(colors: [Color(hex: "FF8A4C"), Color(hex: "C75F3E")]))
            HStack {
                Text("重置 \(entry.resetsIn)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("$\(String(format: "%.2f", entry.todayCost))")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(hex: "F3EEE6"))
            }
        }
        .padding(.horizontal, 2)
    }
}

// ── Widget 主体 ────────────────────────────────────────────────────────────────

struct ThenowWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: WidgetEntry
    var body: some View {
        switch family {
        case .accessoryCircular:    CircularView(entry: entry)
        case .accessoryRectangular: RectView(entry: entry)
        default:                    CircularView(entry: entry)
        }
    }
}

struct ThenowWidget: Widget {
    let kind = "ThenowWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: ThenowProvider()) { entry in
            ThenowWidgetEntryView(entry: entry)
                .containerBackground(.black, for: .widget)
        }
        .configurationDisplayName("thenow")
        .description("Claude 额度 & 审批提醒")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

@main
struct ThenowWidgetBundle: WidgetBundle {
    var body: some Widget { ThenowWidget() }
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
