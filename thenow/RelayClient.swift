import Foundation
import CryptoKit

// MARK: - RelayClient
//
// Handles registration and token updates with the Cloudflare relay Worker.
// The relay Worker stores the APNs device token and forwards generic wake-up
// pushes to the iPhone on behalf of the Mac broker.
//
// Registration flow:
//   1. GET /v1/challenge              → nonce + challenge_id
//   2. POST /v1/installations/register → installation_id + relay_secret
//   3. Save both to Keychain; send to broker during pairing.
//
// Token refresh flow (APNs token rotated by iOS):
//   POST /v1/installations/update-token  (HMAC-authenticated)

enum RelayClient {

    struct Credentials {
        let relayURL:       String
        let installationId: String
        let relaySecret:    String
    }

    // MARK: Register

    /// Registers the given APNs device token with the relay Worker.
    /// If already registered (Keychain has credentials for this relay URL), updates the token instead.
    /// Returns credentials on success, nil if relay URL is empty or any step fails.
    static func registerOrUpdate(deviceToken: String, relayURL: String) async -> Credentials? {
        guard !relayURL.isEmpty else { return nil }
        let base = relayURL.hasSuffix("/") ? String(relayURL.dropLast()) : relayURL

        // If already registered for this relay URL, just update the token.
        if let existing = storedCredentials(for: base) {
            let ok = await updateToken(deviceToken: deviceToken, credentials: existing)
            return ok ? existing : nil
        }

        return await register(deviceToken: deviceToken, base: base)
    }

    private static func storedCredentials(for base: String) -> Credentials? {
        guard let storedURL = KeychainHelper.relayURL,
              let id        = KeychainHelper.relayInstallationId,
              let secret    = KeychainHelper.relaySecret,
              storedURL == base else { return nil }
        return Credentials(relayURL: storedURL, installationId: id, relaySecret: secret)
    }

    private static func register(deviceToken: String, base: String) async -> Credentials? {
        // Step 1: get challenge
        guard let challengeURL = URL(string: "\(base)/v1/challenge") else { return nil }
        guard let (chalData, chalResp) = try? await URLSession.shared.data(from: challengeURL),
              (chalResp as? HTTPURLResponse)?.statusCode == 200,
              let chalJSON = try? JSONDecoder().decode([String: String].self, from: chalData),
              let nonce = chalJSON["nonce"],
              let challengeId = chalJSON["challenge_id"]
        else {
            print("[relay] challenge request failed")
            return nil
        }

        // Step 2: register
        guard let regURL = URL(string: "\(base)/v1/installations/register") else { return nil }
        let body: [String: String] = [
            "device_token": deviceToken,
            "nonce":        nonce,
            "challenge_id": challengeId,
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: regURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 10

        guard let (regData, regResp) = try? await URLSession.shared.data(for: req),
              (regResp as? HTTPURLResponse)?.statusCode == 200,
              let regJSON = try? JSONDecoder().decode([String: String].self, from: regData),
              let installationId = regJSON["installation_id"],
              let relaySecret    = regJSON["relay_secret"]
        else {
            print("[relay] register request failed")
            return nil
        }

        let creds = Credentials(relayURL: base, installationId: installationId, relaySecret: relaySecret)
        KeychainHelper.saveRelay(url: base, installationId: installationId, secret: relaySecret)
        print("[relay] registered installation: \(installationId.prefix(8))…")
        return creds
    }

    // MARK: Update token

    private static func updateToken(deviceToken: String, credentials: Credentials) async -> Bool {
        guard let url = URL(string: "\(credentials.relayURL)/v1/installations/update-token") else { return false }
        let auth = buildHmacPayload(installationId: credentials.installationId,
                                    relaySecret: credentials.relaySecret)
        var body = auth
        body["device_token"] = deviceToken
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 10
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else {
            print("[relay] update-token failed")
            return false
        }
        print("[relay] token updated for \(credentials.installationId.prefix(8))…")
        return true
    }

    // MARK: Revoke

    /// Revoke relay credentials (called on unpair / data delete).
    static func revoke() async {
        guard let creds = storedCredentials(for: KeychainHelper.relayURL ?? "") else { return }
        guard let url = URL(string: "\(creds.relayURL)/v1/installations/revoke") else { return }
        var body = buildHmacPayload(installationId: creds.installationId,
                                    relaySecret: creds.relaySecret)
        body["installation_id"] = creds.installationId
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 10
        _ = try? await URLSession.shared.data(for: req)
        print("[relay] revoked installation: \(creds.installationId.prefix(8))…")
    }

    // MARK: HMAC auth payload

    private static func buildHmacPayload(installationId: String, relaySecret: String) -> [String: Any] {
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let message = "\(installationId):\(timestamp):\(nonce)"
        let sig = hmacSHA256(key: relaySecret, message: message)
        return [
            "installation_id": installationId,
            "timestamp":       timestamp,
            "nonce":           nonce,
            "hmac":            sig,
        ]
    }

    private static func hmacSHA256(key: String, message: String) -> String {
        let keyData = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: keyData)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}
