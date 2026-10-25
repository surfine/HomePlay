// 2.0: search_web——DeepSeek 與 LM Studio 查世界知識用（Anthropic 用它自己的 web_search 伺服器工具）。
// DeepSeek 官方 Search API：POST https://api.deepseek.com/v1/tools/search，Bearer＝使用者自己的 DeepSeek 金鑰（鑰匙圈），
// 內文 {query, count, need_content:false}；結果有 title、url、snippet、summary、date、rerank_score、authority。
// 摘要交給模型、標題與網址留作出處（卡片底下「来自网页」）；金鑰與查詢內容都不寫日誌。
// 回應 JSON 形狀沒有官方範例可對：寬鬆解析（results／data／data.results／最外層陣列都收）。

import Foundation

struct ClioSearchHit: Equatable {
    var title: String
    var url: String
    var text: String           // summary 優先，沒有就用 snippet
    var date: String?
    var score: Double?
}

enum ClioWebSearch {
    static let endpoint = URL(string: "https://api.deepseek.com/v1/tools/search")!

    static let spec = ClioToolSpec(
        name: "search_web",
        description: "Search the web for current or factual information you do not already know (news, prices, sports, opening hours, recent events). Returns a few results with short summaries and sources. Summarise them in one or two spoken sentences; never read out URLs.",
        schema: #"{"type":"object","properties":{"query":{"type":"string","description":"Search query, in the language most likely to find good sources"},"count":{"type":"integer","minimum":1,"maximum":10}},"required":["query"]}"#)

    /// 這一輪該不該送 search_web：非 Anthropic、不是裝置端，而且有 DeepSeek 金鑰
    static func offered(provider: ClioProviderID, hasKey: Bool) -> Bool {
        provider != .anthropic && provider != .onDevice && hasKey
    }

    static func requestBody(query: String, count: Int) -> [String: Any] {
        ["query": query, "count": max(1, min(10, count)), "need_content": false]
    }

    static func request(query: String, count: Int, key: String) -> URLRequest {
        var r = URLRequest(url: endpoint)
        r.httpMethod = "POST"
        r.timeoutInterval = 20
        r.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = ClioHTTP.json(requestBody(query: query, count: count))
        return r
    }

    /// 寬鬆解析：找出結果陣列；有 rerank_score 就由高到低（沒有的維持原順序）
    static func parse(_ data: Data) -> [ClioSearchHit] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }
        func items(_ o: Any?) -> [[String: Any]]? {
            if let a = o as? [[String: Any]] { return a }
            if let d = o as? [String: Any] {
                for k in ["results", "data", "items", "web", "search_results"] { if let a = items(d[k]) { return a } }
            }
            return nil
        }
        guard let arr = items(root) else { return [] }
        func str(_ v: Any?) -> String? {
            guard let s = v as? String else { return nil }
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        var hits: [ClioSearchHit] = arr.compactMap { it in
            let title = str(it["title"]) ?? ""
            let url = str(it["url"]) ?? str(it["link"]) ?? ""
            let text = str(it["summary"]) ?? str(it["snippet"]) ?? str(it["content"]) ?? ""
            guard !(title.isEmpty && text.isEmpty) else { return nil }
            return ClioSearchHit(title: title, url: url, text: text, date: str(it["date"]) ?? str(it["published_date"]),
                                 score: (it["rerank_score"] as? NSNumber)?.doubleValue)
        }
        if hits.contains(where: { $0.score != nil }) {
            hits = hits.enumerated().sorted { a, b in
                let sa = a.element.score ?? -1, sb = b.element.score ?? -1
                return sa != sb ? sa > sb : a.offset < b.offset
            }.map(\.element)
        }
        return hits
    }

    static func host(_ url: String) -> String {
        URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
    }

    /// 給模型看的：編號、標題（網站）、日期、摘要（每則最多 400 字）
    static func format(_ hits: [ClioSearchHit], limit: Int = 5) -> String {
        hits.prefix(limit).enumerated().map { i, h in
            let meta = [host(h.url), h.date].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
            let text = h.text.count > 400 ? String(h.text.prefix(400)) + "…" : h.text
            return "[\(i + 1)] \(h.title)" + (meta.isEmpty ? "" : " (\(meta))") + (text.isEmpty ? "" : ": " + text)
        }.joined(separator: "\n")
    }

    static func run(input: [String: Any], key: String?, session: URLSession = .shared) async -> ClioToolResult {
        func fail(_ s: String) -> ClioToolResult { ClioToolResult(content: s, isError: true, source: .webSearch) }
        let query = (input["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return fail("query is required") }
        guard let key, !key.isEmpty else { return fail("Web search needs a DeepSeek key in HomePlay Settings. Tell the user you cannot look it up online.") }
        let count = (input["count"] as? NSNumber)?.intValue ?? 5
        do {
            let (data, resp) = try await session.data(for: request(query: query, count: count, key: key))
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            log("ClioTalk search: HTTP \(status)")
            switch status {
            case 200: break
            case 401: return fail("Web search failed: the DeepSeek key was rejected. Tell the user to check it in HomePlay Settings.")
            case 402: return fail("Web search failed: the DeepSeek balance is used up.")
            case 429: return fail("Web search is rate limited right now. Try again in a moment.")
            default: return fail("Web search failed (HTTP \(status)). Say you could not look it up.")
            }
            let hits = parse(data)
            if hits.isEmpty { return ClioToolResult(content: "No results.", source: .webSearch) }
            return ClioToolResult(content: format(hits, limit: max(1, min(10, count))), source: .webSearch)
        } catch {
            return fail("Web search could not connect. Say you could not look it up.")
        }
    }
}
