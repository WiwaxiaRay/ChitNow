import SwiftUI
import Combine
import WatchKit
import WidgetKit

struct ContentView: View {
    @State private var requests: [ApprovalRequest] = []
    @State private var usage: UsageResponse? = WatchBrokerClient.loadCachedUsage()
    @State private var usageError: String?
    @State private var selectedTab = 0
    @State private var dismissedIDs: Set<String> = []
    @State private var knownRequestIDs: Set<String> = []
    @Environment(\.scenePhase) private var scenePhase

    private let approvalTimer = Timer.publish(every: 5,  on: .main, in: .common).autoconnect()
    private let usageTimer    = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var claudeRequests: [ApprovalRequest] { requests.filter { !$0.isCodex } }
    var codexRequests:  [ApprovalRequest] { requests.filter {  $0.isCodex } }

    var body: some View {
        if WatchBrokerClient.isPaired {
            TabView(selection: $selectedTab) {
                WatchPageView(
                    theme:    .claude,
                    stats:    usage?.claude,
                    requests: claudeRequests,
                    error:    usageError,
                    onDecide: dismiss,
                    onRefresh: reloadAll
                )
                .tag(0)

                WatchPageView(
                    theme:    .gpt,
                    stats:    usage?.gpt,
                    requests: codexRequests,
                    error:    usageError,
                    onDecide: dismiss,
                    onRefresh: reloadAll
                )
                .tag(1)
            }
            .onAppear {
                reloadAll()
                WidgetCenter.shared.reloadAllTimelines()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    reloadAll()
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
            .onReceive(approvalTimer) { _ in reloadApprovals() }
            .onReceive(usageTimer)    { _ in reloadUsage() }
            .onReceive(NotificationCenter.default.publisher(for: .brokerURLUpdated)) { _ in reloadAll() }
            .onReceive(NotificationCenter.default.publisher(for: .newApprovalRequest)) { _ in reloadApprovals() }
            .onReceive(NotificationCenter.default.publisher(for: .approvalRoutingUpdated)) { _ in reloadApprovals() }
        } else {
            VStack(spacing: 8) {
                Text("Not Paired")
                    .font(.headline)
                Text("Open ChitNow on iPhone to pair")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func dismiss(_ id: String) {
        dismissedIDs.insert(id)
        knownRequestIDs.remove(id)
        requests.removeAll { $0.id == id }
        reloadApprovals()
    }

    private func reloadApprovals() {
        guard WatchBrokerClient.watchApprovalsEnabled else {
            requests = []
            knownRequestIDs = []
            dismissedIDs = []
            return
        }
        Task {
            let fetched = await WatchBrokerClient.fetchPending()
            let active  = fetched.filter { $0.remainingSeconds > 0 && !dismissedIDs.contains($0.id) }
            await MainActor.run {
                let newIDs = Set(active.map { $0.id }).subtracting(knownRequestIDs)
                if !newIDs.isEmpty {
                    // Navigate to the first new request's tab and play haptic.
                    // Runs on main actor so WKInterfaceDevice is always called from main thread.
                    if let first = active.first(where: { newIDs.contains($0.id) }) {
                        withAnimation { selectedTab = first.isCodex ? 1 : 0 }
                    }
                    WKInterfaceDevice.current().play(.notification)
                }
                knownRequestIDs = Set(active.map { $0.id })
                requests = active
            }
        }
    }

    private func reloadUsage() {
        Task {
            let (data, err) = await WatchBrokerClient.fetchUsage()
            await MainActor.run {
                usage = data
                usageError = err
                if data != nil {
                    WidgetCenter.shared.reloadAllTimelines()
                }
            }
        }
    }

    private func reloadAll() {
        reloadApprovals()
        reloadUsage()
    }


}
