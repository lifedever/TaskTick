import CryptoKit
import Foundation
import TaskTickCore

/// Sends task-completion pushes to a user-configured Bark endpoint.
///
/// Architecture mirrors `NotificationManager`: one shared sender, fire-and-forget
/// from `ScriptExecutor`. The device URL lives in app Settings (`barkServerURL`);
/// each task opts in via `ScheduledTask.barkPushEnabled`. An empty / invalid URL
/// disables Bark globally without touching the per-task switches.
final class BarkPushManager: @unchecked Sendable {

    static let shared = BarkPushManager()
    static let urlDefaultsKey = "barkServerURL"

    private init() {}

    // MARK: - URL

    /// Accepts the URL copied from the Bark app (`https://api.day.app/<key>/`)
    /// or a bare device key. Trailing slashes are stripped; query items kept.
    static func normalizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate: String
        if let scheme = URL(string: trimmed)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            candidate = trimmed
        } else if trimmed.contains("://") {
            return nil
        } else {
            let key = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard key.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
                return nil
            }
            candidate = "https://api.day.app/\(key)"
        }

        guard var components = URLComponents(string: candidate) else { return nil }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }

        while components.path.hasSuffix("/") && components.path.count > 1 {
            components.path.removeLast()
        }
        // Official Bark URLs always carry the device key as the first path
        // component. A host-only URL (https://api.day.app) cannot push.
        if components.path.isEmpty || components.path == "/" {
            return nil
        }
        return components.url
    }

    static func isConfigured(_ defaults: UserDefaults = .standard) -> Bool {
        let raw = defaults.string(forKey: urlDefaultsKey) ?? ""
        return normalizedURL(from: raw) != nil
    }

    // MARK: - Output change

    /// Stable fingerprint of the script's "output content".
    /// Prefers trimmed stdout; falls back to stderr when stdout is empty so
    /// failed runs still de-dupe on the error text.
    static func outputFingerprint(stdout: String, stderr: String) -> String {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = out.isEmpty ? err : out
        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// First run (`previous == nil`) always notifies. Later runs notify only
    /// when the fingerprint changed.
    static func shouldNotifyOnOutputChange(previousFingerprint: String?, currentFingerprint: String) -> Bool {
        previousFingerprint != currentFingerprint
    }

    // MARK: - Send

    /// Fire-and-forget push used after a task finishes.
    func send(title: String, body: String, defaults: UserDefaults = .standard) {
        let rawURL = defaults.string(forKey: Self.urlDefaultsKey) ?? ""
        Task {
            let result = await post(title: title, body: body, rawURL: rawURL)
            if case .failure(let error) = result {
                NSLog("⚠️ Bark push failed: \(error.localizedDescription)")
            }
        }
    }

    /// Settings "Send Test" — waits for the HTTP response so the UI can report it.
    func sendTest(defaults: UserDefaults = .standard) async -> Result<Void, BarkPushError> {
        let rawURL = defaults.string(forKey: Self.urlDefaultsKey) ?? ""
        return await post(
            title: L10n.tr("settings.bark.test.title"),
            body: L10n.tr("settings.bark.test.body"),
            rawURL: rawURL
        )
    }

    func post(title: String, body: String, defaults: UserDefaults = .standard) async -> Result<Void, BarkPushError> {
        let rawURL = defaults.string(forKey: Self.urlDefaultsKey) ?? ""
        return await post(title: title, body: body, rawURL: rawURL)
    }

    func post(title: String, body: String, rawURL: String) async -> Result<Void, BarkPushError> {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyURL) }
        guard let url = Self.normalizedURL(from: rawURL) else { return .failure(.invalidURL) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let payload: [String: String] = [
            "title": title,
            "body": body,
            "group": "TaskTick"
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            return .failure(.network(error.localizedDescription))
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if let server = try? JSONDecoder().decode(BarkAPIResponse.self, from: data),
               let code = server.code, code != 200 {
                return .failure(.serverMessage(server.message ?? "code \(code)"))
            }
            if status >= 400 {
                return .failure(.httpStatus(status))
            }
            return .success(())
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }
}

enum BarkPushError: LocalizedError {
    case emptyURL
    case invalidURL
    case httpStatus(Int)
    case serverMessage(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .emptyURL:
            return L10n.tr("settings.bark.test.failed.empty")
        case .invalidURL:
            return L10n.tr("settings.bark.test.failed.invalid")
        case .httpStatus(let code):
            return L10n.tr("settings.bark.test.failed.http", code)
        case .serverMessage(let message):
            return message
        case .network(let message):
            return message
        }
    }
}

private struct BarkAPIResponse: Decodable {
    let code: Int?
    let message: String?
}
