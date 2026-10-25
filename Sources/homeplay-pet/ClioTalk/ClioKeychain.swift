// BYOK 金鑰：只放鑰匙圈（kSecClassGenericPassword），不放 UserDefaults、不進日誌。
// service 固定，account＝供應商 id。優先用 Data Protection keychain；這份簽名拿不到權利（-34018）就退回登入鑰匙圈，
// 日誌只記狀態碼。檢查金鑰打最便宜的唯讀端點：Anthropic GET /v1/models?limit=1、DeepSeek GET /user/balance。

import Foundation
import Security

enum ClioKeychain {
    static let service = "me.aaronlau.homeplay.cliotalk"
    /// 這次執行已經知道 Data Protection keychain 用不了（ad hoc 簽名常見）：之後直接走登入鑰匙圈
    nonisolated(unsafe) private static var legacyOnly = false

    private static func base(_ p: ClioProviderID, dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: p.rawValue]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// 先試 Data Protection，-34018 才退回登入鑰匙圈
    private static func run(_ body: (Bool) -> OSStatus) -> OSStatus {
        if !legacyOnly {
            let s = body(true)
            if s != errSecMissingEntitlement { return s }
            legacyOnly = true
            log("ClioTalk keychain: data protection keychain status \(s), using login keychain")
        }
        return body(false)
    }

    @discardableResult
    static func save(_ key: String, for p: ClioProviderID) -> Bool {
        let data = Data(key.utf8)
        let status = run { dp in
            var add = base(p, dataProtection: dp)
            add[kSecValueData as String] = data
            if dp { add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }   // 桌寵在背景也要能讀；不隨備份搬家
            add[kSecAttrLabel as String] = "HomePlay ClioTalk (\(p.rawValue))"
            var s = SecItemAdd(add as CFDictionary, nil)
            if s == errSecDuplicateItem {
                s = SecItemUpdate(base(p, dataProtection: dp) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            }
            return s
        }
        if status != errSecSuccess { log("ClioTalk keychain save status \(status)") }
        return status == errSecSuccess
    }

    static func load(_ p: ClioProviderID) -> String? {
        var out: CFTypeRef?
        let status = run { dp in
            var q = base(p, dataProtection: dp)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(q as CFDictionary, &out)
        }
        guard status == errSecSuccess, let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty else {
            if status != errSecSuccess && status != errSecItemNotFound { log("ClioTalk keychain load status \(status)") }
            return nil
        }
        return s
    }

    @discardableResult
    static func delete(_ p: ClioProviderID) -> Bool {
        let status = run { dp in SecItemDelete(base(p, dataProtection: dp) as CFDictionary) }
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 設定頁只顯示末四碼
    static func masked(_ key: String) -> String { "••••" + key.suffix(4) }
}

// MARK: - 檢查金鑰

enum ClioKeyCheck: Equatable {
    case ok(detail: String?)       // DeepSeek 順便帶回餘額
    case invalid
    case network
    case other(String)
}

enum ClioKeyChecker {
    static func request(_ p: ClioProviderID, key: String) -> URLRequest? {
        switch p {
        case .anthropic:
            var r = URLRequest(url: URL(string: "https://api.anthropic.com/v1/models?limit=1")!)
            for (k, v) in AnthropicProvider.headers(key: key) { r.setValue(v, forHTTPHeaderField: k) }
            r.timeoutInterval = 15
            return r
        case .deepseek:
            var r = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
            r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            r.setValue("application/json", forHTTPHeaderField: "Accept")
            r.timeoutInterval = 15
            return r
        case .onDevice, .lmStudio:
            return nil
        }
    }

    /// 狀態碼＋內文 → 結果（純函式，selftest 用）
    static func interpret(_ p: ClioProviderID, status: Int, body: Data) -> ClioKeyCheck {
        switch status {
        case 200:
            guard p == .deepseek, let o = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .ok(detail: nil) }
            let info = (o["balance_infos"] as? [[String: Any]])?.first
            let bal = info.map { "\($0["currency"] as? String ?? "") \($0["total_balance"] as? String ?? "")".trimmingCharacters(in: .whitespaces) }
            if (o["is_available"] as? Bool) == false {
                return .other(L("clio.key.noBalance", "密钥有效，但余额不足"))
            }
            return .ok(detail: bal)
        case 401: return .invalid
        case 400:
            if p == .anthropic { return .other(L("clio.key.workspace", "这个密钥需要指定 workspace")) }
            return .invalid
        case 402: return .other(L("clio.key.noBalance", "密钥有效，但余额不足"))
        case 403: return .other(L("clio.key.forbidden", "这个密钥没有权限"))
        default: return .other(String(format: L("clio.key.http", "服务器回应 %d"), status))
        }
    }

    static func check(_ p: ClioProviderID, key: String) async -> ClioKeyCheck {
        guard let req = request(p, key: key) else { return ClioOnDevice.available ? .ok(detail: nil) : .other(ClioOnDevice.status) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            log("ClioTalk key check \(p.rawValue): HTTP \(status)")
            return interpret(p, status: status, body: data)
        } catch {
            return .network
        }
    }
}
