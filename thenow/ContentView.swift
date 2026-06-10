import SwiftUI

struct ContentView: View {
    @State private var isPaired = KeychainHelper.isConfigured

    var body: some View {
        if isPaired {
            ActiveView(onUnpair: {
                KeychainHelper.clear()
                isPaired = false
            })
        } else {
            PairingView(onPaired: { isPaired = true })
        }
    }
}

private struct ActiveView: View {
    var onUnpair: () -> Void
    @State private var showUnpairConfirm = false

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)

            Text("thenow")
                .font(.title2.bold())

            Text("Agent approval guard active")
                .foregroundStyle(.secondary)

            if let url = KeychainHelper.brokerURL {
                Text(url)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Button("Unpair", role: .destructive) {
                showUnpairConfirm = true
            }
            .font(.footnote)
            .padding(.top, 8)
        }
        .padding()
        .confirmationDialog("Remove pairing?", isPresented: $showUnpairConfirm, titleVisibility: .visible) {
            Button("Unpair", role: .destructive, action: onUnpair)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You will need to scan the QR code again to reconnect.")
        }
    }
}

#Preview {
    ContentView()
}
