import Foundation
import CryptoKit

// MARK: - RelayClient
//
// Handles registration and token updates with the Cloudflare relay Worker.
// The relay Worker stores the APNs device token and forwards generic wake-up
// pushes to the iPhone on behalf of the Mac broker.
//
// Registration flow:
//   1. GET /v1/challenge              → {challenge_id, nonce, expires_at}
//   2. POST /v1/register              → {installation_id, relay_secret}
//   3. Save both to Keychain; send to broker during pairing.
//
// Token refresh flow (APNs token rotated by iOS):
//   POST /v1/update-token  (header-based HMAC auth)
//
// Auth uses canonical message:
//   canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + NONCE + "\n" + SHA256(BODY)
//   signature = HMAC-SHA256(relay_secret, canonical)
// Headers: X-ChitNow-Installation, X-ChitNow-Timestamp, X-ChitNow-Nonce, X-ChitNow-Signature

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
              let chalJSON = try? JSONDecoder().decode([String: AnyCodable].self, from: chalData),
              let challengeId = chalJSON["challenge_id"]?.stringValue,
              let nonce = chalJSON["nonce"]?.stringValue
        else {
            print("[relay] challenge request failed")
            return nil
        }

        // Step 2: register — 201 response with installation_id and relay_secret
        guard let regURL = URL(string: "\(base)/v1/register") else { return nil }
        let body: [String: String] = [
            "apns_device_token": deviceToken,
            "challenge_id":      challengeId,
            "nonce":             nonce,
            "environment":       "production",
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        var req = URLRequest(url: regURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 10

        guard let (regData, regResp) = try? await URLSession.shared.data(for: req),
              (regResp as? HTTPURLResponse)?.statusCode == 201,
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
        guard let url = URL(string: "\(credentials.relayURL)/v1/update-token") else { return false }
        let bodyDict: [String: String] = [
            "apns_device_token": deviceToken,
            "environment":       "production",
        ]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 10

        let authHeaders = buildAuthHeaders(
            method: "POST", path: "/v1/update-token",
            bodyData: bodyData,
            installationId: credentials.installationId,
            relaySecret: credentials.relaySecret
        )
        for (k, v) in authHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }

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
        guard let url = URL(string: "\(creds.relayURL)/v1/revoke") else { return }
        let bodyDict: [String: String] = [:]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: bodyDict) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = bodyData
        req.timeoutInterval = 10

        let authHeaders = buildAuthHeaders(
            method: "POST", path: "/v1/revoke",
            bodyData: bodyData,
            installationId: creds.installationId,
            relaySecret: creds.relaySecret
        )
        for (k, v) in authHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }

        _ = try? await URLSession.shared.data(for: req)
        print("[relay] revoked installation: \(creds.installationId.prefix(8))…")
    }

    // MARK: Canonical auth headers

    /// Build X-ChitNow-* auth headers using the canonical message signature scheme.
    /// canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + NONCE + "\n" + SHA256(BODY)
    static func buildAuthHeaders(
        method: String,
        path: String,
        bodyData: Data,
        installationId: String,
        relaySecret: String
    ) -> [String: String] {
        let timestamp = Int(Date().timeIntervalSince1970)
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let bodyHash = SHA256.hash(data: bodyData).map { String(format: "%02x", $0) }.joined()
        let canonical = "\(method)\n\(path)\n\(timestamp)\n\(nonce)\n\(bodyHash)"
        let sig = hmacSHA256(key: relaySecret, message: canonical)
        return [
            "X-ChitNow-Installation": installationId,
            "X-ChitNow-Timestamp":    String(timestamp),
            "X-ChitNow-Nonce":        nonce,
            "X-ChitNow-Signature":    sig,
        ]
    }

    private static func hmacSHA256(key: String, message: String) -> String {
        let keyData = SymmetricKey(data: Data(key.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: keyData)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - AnyCodable helper for mixed-type JSON decoding

private struct AnyCodable: Codable {
    let value: Any

    var stringValue: String? { value as? String }
    var intValue: Int? { value as? Int }

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let s = try? container.decode(String.self)  { value = s; return }
        if let i = try? container.decode(Int.self)     { value = i; return }
        if let d = try? container.decode(Double.self)  { value = d; return }
        if let b = try? container.decode(Bool.self)    { value = b; return }
        value = NSNull()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let s as String:  try container.encode(s)
        case let i as Int:     try container.encode(i)
        case let d as Double:  try container.encode(d)
        case let b as Bool:    try container.encode(b)
        default:               try container.encodeNil()
        }
    }
}
