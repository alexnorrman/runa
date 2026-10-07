import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Shared request plumbing for AI providers.
struct ProviderHTTP {
    let http: HTTPClient

    func post(_ url: URL, headers: [String: String], body: JSONValue, timeout: TimeInterval = 300) async throws -> JSONValue {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.serialized(style: .standard).utf8)
        return try await send(request)
    }

    func get(_ url: URL, headers: [String: String]) async throws -> JSONValue {
        var request = URLRequest(url: url, timeoutInterval: 30)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await send(request)
    }

    private func send(_ request: URLRequest) async throws -> JSONValue {
        var attempt = 0
        while true {
            let data: Data
            let response: HTTPURLResponse
            do {
                (data, response) = try await http.send(request)
            } catch let error as BackendError {
                throw TranslationError.network(error.localizedDescription)
            }
            // Retry rate limits and overloads with backoff, honoring retry-after when present.
            if [429, 500, 502, 503, 504, 529].contains(response.statusCode), attempt < 3 {
                attempt += 1
                let retryAfter = response.value(forHTTPHeaderField: "retry-after").flatMap(Double.init) ?? pow(2, Double(attempt))
                try await Task.sleep(nanoseconds: UInt64(min(retryAfter, 30) * 1_000_000_000))
                continue
            }
            let json = (try? JSONValue.parse(data)) ?? .null
            guard (200..<300).contains(response.statusCode) else {
                let message = json["error"]?["message"]?.stringValue ?? json["error"]?.stringValue
                    ?? String(decoding: data.prefix(300), as: UTF8.self)
                throw TranslationError.http(response.statusCode, message)
            }
            return json
        }
    }

    static func int(_ value: JSONValue?) -> Int {
        if case .number(let number)? = value { return Int(number) }
        return 0
    }
}
