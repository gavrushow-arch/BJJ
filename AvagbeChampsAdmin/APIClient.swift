import Foundation
import Security

struct APIError: LocalizedError {
    let code: String
    let message: String
    init(_ code: String, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

struct APIClient {
    static let defaultEndpoint = "https://script.google.com/macros/s/AKfycbyVbd5ox_mZzVhatbRNUlU9AQQ3n7ZN1ITx7wwq1iDrwiwoi12mBVP0WsHUG4mndTgr/exec"
    let endpoint: String
    static func validatedURL(_ endpoint: String) throws -> URL {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host == "script.google.com", url.path.hasPrefix("/macros/s/"), url.path.hasSuffix("/exec"), url.query == nil, url.fragment == nil, url.user == nil, url.password == nil else {
            throw APIError("URL", "Укажите опубликованный HTTPS-адрес Apps Script, заканчивающийся на /exec, без параметров")
        }
        return url
    }
    func post(_ object: [String:J]) async throws -> J {
        let url = try Self.validatedURL(endpoint)
        var body = object; body["apiVersion"] = .n(1)
        var req = URLRequest(url: url); req.httpMethod = "POST"; req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type"); req.httpBody = try J.object(body).data()
        // URLSession follows ContentService redirects to Google's one-time response URL.
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw APIError("HTTP", "Apps Script недоступен. Проверьте публикацию приложения") }
        guard let value = try? JSONDecoder().decode(J.self, from: data) else { throw APIError("FORMAT", "Ожидался JSON API. Проверьте установленную версию скрипта") }
        guard value["ok"].flag else { throw APIError(value["error"]["code"].str, value["error"]["message"].str) }
        return value
    }
}

enum SessionKeychain {
    private static var query: [String:Any] { [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:"AvagbeChampsAdmin", kSecAttrAccount as String:"session"] }
    static func load() -> AdminSession? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(AdminSession.self, from: data)
    }
    static func save(_ session: AdminSession) throws {
        let data = try JSONEncoder().encode(session)
        let update = [kSecValueData as String:data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query; q[kSecValueData as String] = data; q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIError("KEYCHAIN", "Не удалось сохранить сессию в Keychain") }
    }
    static func clear() { SecItemDelete(query as CFDictionary) }
}
