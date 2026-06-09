import SwiftUI
import Combine

struct ContentView: View {
    @State private var requests: [ApprovalRequest] = []
    @State private var usage: UsageResponse? = WatchBrokerClient.loadCachedUsage()
    @State private var usageError: String?
    @State private var selectedTab = 0

    private let approvalTimer = Timer.publish(every: 5,  on: .main, in: .common).autoconnect()
    private let usageTimer    = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var claudeRequests: [ApprovalRequest] { requests.filter { !$0.isCodex } }
    var codexRequests:  [ApprovalRequest] { requests.filter {  $0.isCodex } }

    var body: some View {
        TabView(selection: $selectedTab) {
            WatchPageView(
                theme:    .claude,
                stats:    usage?.claude,
                requests: claudeRequests,
                error:    usageError,
                onDecide: reloadApprovals,
                onRefresh: reloadAll
            )
            .tag(0)

            WatchPageView(
                theme:    .gpt,
                stats:    usage?.gpt,
                requests: codexRequests,
                error:    usageError,
                onDecide: reloadApprovals,
                onRefresh: reloadAll
            )
            .tag(1)
        }
        .onAppear {
            reloadAll()
        }
        .onReceive(approvalTimer) { _ in reloadApprovals() }
        .onReceive(usageTimer)    { _ in reloadUsage() }
        .onReceive(NotificationCenter.default.publisher(for: .brokerURLUpdated)) { _ in reloadAll() }
        .onChange(of: requests) { oldVal, newVal in
            autoNavigate(newVal, previous: oldVal)
        }
    }

    private func reloadApprovals() {
        Task {
            let fetched = await WatchBrokerClient.fetchPending()
            let active  = fetched.filter { $0.remainingSeconds > 0 }
            await MainActor.run { requests = active }
        }
    }

    private func reloadUsage() {
        Task {
            let (data, err) = await WatchBrokerClient.fetchUsage()
            await MainActor.run {
                usage = data
                usageError = err
            }
        }
    }

    private func reloadAll() {
        reloadApprovals()
        reloadUsage()
    }

    // 只在有新 ID 出现时跳转，避免每次轮询都打断用户
    private func autoNavigate(_ reqs: [ApprovalRequest], previous: [ApprovalRequest]) {
        let previousIds = Set(previous.map { $0.id })
        if let first = reqs.first(where: { !previousIds.contains($0.id) }) {
            withAnimation { selectedTab = first.isCodex ? 1 : 0 }
        }
    }
}
