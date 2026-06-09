import SwiftUI
import Combine

// MARK: - Hex color

private extension Color {
    init(hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            red:   Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8)  & 0xFF) / 255,
            blue:  Double(v         & 0xFF) / 255
        )
    }
}

// MARK: - Pixel art

private let MASCOT_ART: [String] = [
    "...BBBBB...",
    "..BBBBBBB..",
    ".BBBBBBBBB.",
    "BBBBBBBBBBB",
    "BBeeBBBeeBB",
    "BBeeBBBeeBB",
    "BBBBBBBBBBB",
    "BBmBmBmBmBB",
    "BBBBBBBBBBB",
    "B.B.B.B.B.B",
]

private let OCTOPUS_ART: [String] = [
    "...BBBBB...",
    "..BBBBBBB..",
    ".BBBBBBBBB.",
    "BBBBBBBBBBB",
    "BeBBBBBBBeB",
    "BBBBBBBBBBB",
    "BBBBBBBBBBB",
    "B.B.B.B.B.B",
    ".B.B.B.B.B.",
    "B.B.B.B.B.B",
]

// MARK: - Theme

struct WatchTheme {
    let name: String
    let accent: Color
    let sub: Color
    let textColor: Color
    let ring5: Color
    let ring5Track: Color
    let ringW: Color
    let ringWTrack: Color
    let mascotColor: Color
    let mascotEye: Color
    let art: [String]

    static let claude = WatchTheme(
        name:        "Claude",
        accent:      Color(hex: "E0805C"),
        sub:         Color(hex: "8d847a"),
        textColor:   Color(hex: "F3EEE6"),
        ring5:       Color(hex: "FF8A4C"),
        ring5Track:  Color(hex: "FF8A4C").opacity(0.16),
        ringW:       Color(hex: "C75F3E"),
        ringWTrack:  Color(hex: "C75F3E").opacity(0.16),
        mascotColor: Color(hex: "E8623D"),
        mascotEye:   Color(hex: "100805"),
        art: MASCOT_ART
    )

    static let gpt = WatchTheme(
        name:        "ChatGPT",
        accent:      Color(hex: "19C37D"),
        sub:         Color(hex: "7d7d86"),
        textColor:   Color(hex: "ECECEC"),
        ring5:       Color(hex: "1FD18A"),
        ring5Track:  Color(hex: "1FD18A").opacity(0.15),
        ringW:       Color(hex: "0E8F66"),
        ringWTrack:  Color(hex: "0E8F66").opacity(0.16),
        mascotColor: Color(hex: "19C37D"),
        mascotEye:   Color(hex: "04140d"),
        art: OCTOPUS_ART
    )
}

// MARK: - Pixel mascot

private struct PixelMascot: View {
    let art: [String]
    let bodyColor: Color
    let eyeColor: Color
    let cellSize: CGFloat
    @State private var floating = false

    var body: some View {
        let cols = art.first?.count ?? 11
        let rows = art.count
        Canvas { ctx, _ in
            for (r, row) in art.enumerated() {
                for (c, ch) in row.enumerated() {
                    let fill: Color
                    switch ch {
                    case "B":       fill = bodyColor
                    case "e", "m": fill = eyeColor
                    default:        continue
                    }
                    ctx.fill(
                        Path(CGRect(x: CGFloat(c) * cellSize, y: CGFloat(r) * cellSize,
                                    width: cellSize, height: cellSize)),
                        with: .color(fill)
                    )
                }
            }
        }
        .frame(width: CGFloat(cols) * cellSize, height: CGFloat(rows) * cellSize)
        .shadow(color: bodyColor.opacity(0.5), radius: cellSize * 1.4)
        .offset(y: floating ? -7 : 0)
        .animation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true), value: floating)
        .onAppear { floating = true }
    }
}

// MARK: - Activity ring

private struct ActivityRing: View {
    let value: Double
    let color: Color
    let trackColor: Color
    let lineWidth: CGFloat
    @State private var animated: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: animated)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.55), radius: 4)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.15)) { animated = value }
        }
        .onChange(of: value) { _, v in
            withAnimation(.easeInOut(duration: 1.15)) { animated = v }
        }
    }
}

// MARK: - Blinking cursor

private struct BlinkCursor: View {
    let color: Color
    @State private var on = true
    private let timer = Timer.publish(every: 0.55, on: .main, in: .common).autoconnect()

    var body: some View {
        Text("_").foregroundStyle(color).opacity(on ? 1 : 0)
            .onReceive(timer) { _ in on.toggle() }
    }
}

// MARK: - Countdown helpers

private func countdown(to iso: String, from now: Date) -> String {
    let f = ISO8601DateFormatter()
    guard let date = f.date(from: iso) else { return "--" }
    let secs = max(0, Int(date.timeIntervalSince(now)))
    let d = secs / 86400
    let h = (secs % 86400) / 3600
    let m = (secs % 3600) / 60
    let s = secs % 60
    if d > 0 { return "\(d)d \(String(format: "%02d", h))h" }
    if h > 0 { return "\(h)h \(String(format: "%02d", m))m" }
    return "\(m)m \(String(format: "%02d", s))s"
}

// MARK: - Main watch page

struct WatchPageView: View {
    let theme: WatchTheme
    let stats: UsageStats?
    let requests: [ApprovalRequest]
    let error: String?
    let onDecide: () -> Void
    let onRefresh: () -> Void

    @State private var now = Date()
    @State private var mascotBouncing = false
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var ring5Value: Double {
        guard let p = stats?.quota?.usedPercent else { return 0 }
        return min(Double(p) / 100.0, 1.0)
    }
    private var ringWValue: Double {
        guard let p = stats?.quota?.weekUsedPercent else { return 0 }
        return min(Double(p) / 100.0, 1.0)
    }
    private var fiveHrLabel: String {
        if let iso = stats?.quota?.resetsAt { return countdown(to: iso, from: now) }
        if let desc = stats?.quota?.resetsDescription { return desc }
        return "--"
    }
    private var weekLabel: String {
        if let iso = stats?.quota?.weekResetsAt { return countdown(to: iso, from: now) }
        return "--"
    }
    private var tknLabel: String {
        guard let s = stats else { return "--" }
        let total = s.todayInput + s.todayOutput + s.todayCacheRead + (s.todayCacheWrite ?? 0)
        return "\(formatTokens(total))  ~$\(String(format: "%.2f", s.todayCost))"
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                // 底层：圆环 + 终端
                VStack(spacing: 0) {
                    ringsView(width: geo.size.width)
                        .frame(maxWidth: .infinity)
                    Spacer(minLength: 2)
                    terminal
                        .padding(.horizontal, 8)
                        .padding(.bottom, 14)
                }
                .offset(y: -35)

                // 审批卡片悬浮在圆环上方
                if !requests.isEmpty {
                    VStack(spacing: 4) {
                        ForEach(requests) { req in
                            PendingRequestCard(request: req, accent: theme.accent, onDecide: onDecide)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 6)
                }
            }
        }
        .onReceive(ticker) { _ in now = Date() }
        .simultaneousGesture(refreshGesture)
    }

    private var refreshGesture: some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let isDownSwipe = value.translation.height > 35
                    && abs(value.translation.width) < value.translation.height
                if isDownSwipe {
                    onRefresh()
                }
            }
    }

    // MARK: Rings + mascot

    @ViewBuilder
    private func ringsView(width: CGFloat) -> some View {
        // Design proportions: SVG 310px, outer r=135 w=16, inner r=112 w=16
        let rs = width * 0.78
        let rw = rs * 0.052
        let outerFrame = rs * 0.871   // 2*135/310
        let innerFrame = rs * 0.723   // 2*112/310
        let cellSize   = width * 0.034

        ZStack {
            ActivityRing(value: ring5Value, color: theme.ring5,
                         trackColor: theme.ring5Track, lineWidth: rw)
                .frame(width: outerFrame, height: outerFrame)

            ActivityRing(value: ringWValue, color: theme.ringW,
                         trackColor: theme.ringWTrack, lineWidth: rw)
                .frame(width: innerFrame, height: innerFrame)

            PixelMascot(art: theme.art, bodyColor: theme.mascotColor,
                        eyeColor: theme.mascotEye, cellSize: cellSize)
                .scaleEffect(mascotBouncing ? 1.4 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.4), value: mascotBouncing)
                .onTapGesture(count: 2) {
                    mascotBouncing = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { mascotBouncing = false }
                    onRefresh()
                }
        }
        .frame(width: rs, height: rs)
    }

    // MARK: Terminal block

    private var terminal: some View {
        let rows: [(key: String, val: String, col: Color)]
        if let _ = stats {
            rows = [
                ("5-HR", fiveHrLabel, theme.ring5),
                ("WEEK", weekLabel,   theme.ringW),
                ("TKN ", tknLabel,    theme.sub),
            ]
        } else {
            rows = [("···", error ?? "connecting…", theme.sub)]
        }

        return VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("> ")
                        .foregroundStyle(theme.accent)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                    Text(row.key + "  ")
                        .foregroundStyle(row.col)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    Text(row.val)
                        .foregroundStyle(theme.textColor)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced).monospacedDigit())
                    if i == rows.count - 1 {
                        BlinkCursor(color: theme.accent)
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(theme.accent.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(theme.accent.opacity(0.18), lineWidth: 1)
                )
        )
    }
}

// MARK: - Pending request card

struct PendingRequestCard: View {
    let request: ApprovalRequest
    let accent: Color
    let onDecide: () -> Void

    @State private var deciding = false
    @State private var done = false
    @State private var failed = false
    @State private var remaining: Int
    private let countdown = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(request: ApprovalRequest, accent: Color, onDecide: @escaping () -> Void) {
        self.request  = request
        self.accent   = accent
        self.onDecide = onDecide
        _remaining    = State(initialValue: request.remainingSeconds)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2).foregroundStyle(.orange)
                Text("\(remaining)s").font(.caption2.monospacedDigit()).foregroundStyle(.orange)
                Spacer()
            }
            Text(request.command)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(3)
            if done {
                Text("Sent ✓").font(.caption2).foregroundStyle(.secondary)
            } else if failed {
                Button { retry() } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).tint(.orange)
                .font(.caption2)
            } else {
                HStack(spacing: 6) {
                    Button { decide(true) } label: { Text("✓").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.green)
                        .disabled(deciding || remaining == 0)
                    Button { decide(false) } label: { Text("✕").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).tint(.red)
                        .disabled(deciding || remaining == 0)
                }
            }
        }
        .padding(7)
        .background(Color.white.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onReceive(countdown) { _ in if remaining > 0 { remaining -= 1 } }
    }

    private func decide(_ approved: Bool) {
        deciding = true
        failed = false
        Task {
            let ok = await WatchBrokerClient.decide(request.id, approved: approved)
            await MainActor.run {
                deciding = false
                if ok { done = true; onDecide() } else { failed = true }
            }
        }
    }

    private func retry() {
        failed = false
    }
}

// MARK: - Helpers

func formatResetTime(_ iso: String) -> String {
    let f = ISO8601DateFormatter()
    guard let date = f.date(from: iso) else { return iso }
    let rel = RelativeDateTimeFormatter()
    rel.unitsStyle = .abbreviated
    return rel.localizedString(for: date, relativeTo: Date())
}
