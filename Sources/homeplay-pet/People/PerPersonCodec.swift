// 每人一份的存檔（{人 id: 那個人的資料}）：逐人解碼，一份讀不懂（例如將來版本多了新的模組或選項）不影響其他人；
// 讀不懂的那份原樣留著，存檔時照寫回去，不覆寫掉。跟 SBStore.load 同一個作法，控制中心版面與家人偏好共用。

import Foundation

enum PerPersonCodec {
    /// 逐人解碼：讀得懂的放 ok，讀不懂的原樣（JSON 物件）放 unreadable
    static func decode<T: Decodable>(_ raw: Data?, as: T.Type) -> (ok: [String: T], unreadable: [String: Any]) {
        guard let raw, let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return ([:], [:]) }
        var ok: [String: T] = [:], bad: [String: Any] = [:]
        for (id, v) in obj {
            if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]), let t = try? JSONDecoder().decode(T.self, from: d) { ok[id] = t }
            else { bad[id] = v }
        }
        return (ok, bad)
    }
    /// 存檔：讀得懂的照編，讀不懂的那幾份（同一個人沒有新的那份時）原樣寫回
    static func encode<T: Encodable>(_ values: [String: T], keeping unreadable: [String: Any]) -> Data? {
        guard let raw = try? JSONEncoder().encode(values), var obj = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any] else { return nil }
        for (id, v) in unreadable where obj[id] == nil { obj[id] = v }
        return try? JSONSerialization.data(withJSONObject: obj)
    }
}
