import Foundation

struct ApprovalRequest: Identifiable, Codable, Equatable {
    let id: String
    let agent: String
    let title: String
    let summary: String
    let command: String
    let risk: String
    let remainingSeconds: Int

    enum CodingKeys: String, CodingKey {
        case id, agent, title, summary, command, risk
        case remainingSeconds = "remaining_seconds"
    }

    var isCodex: Bool { agent == "codex" }
}

struct QuotaInfo: Codable {
    let usedPercent: Int?
    let resetsAt: String?
    let resetsDescription: String?
    let weekUsedPercent: Int?
    let weekResetsAt: String?
    let creditsRemaining: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent       = "used_percent"
        case resetsAt          = "resets_at"
        case resetsDescription = "resets_description"
        case weekUsedPercent   = "week_used_percent"
        case weekResetsAt      = "week_resets_at"
        case creditsRemaining  = "credits_remaining"
    }
}

struct UsageStats: Codable {
    let todayCost: Double
    let todayInput: Int
    let todayOutput: Int
    let todayCacheRead: Int
    let todayCacheWrite: Int?
    let quota: QuotaInfo?

    enum CodingKeys: String, CodingKey {
        case todayCost      = "today_cost"
        case todayInput     = "today_input"
        case todayOutput    = "today_output"
        case todayCacheRead = "today_cache_read"
        case todayCacheWrite = "today_cache_write"
        case quota
    }
}

struct UsageResponse: Codable {
    let claude: UsageStats
    let gpt: UsageStats
}

func formatTokens(_ n: Int) -> String {
    switch n {
    case 0..<1_000:       return "\(n)"
    case 0..<1_000_000:   return "\(n / 1_000)k"
    default:              return String(format: "%.1fm", Double(n) / 1_000_000)
    }
}
