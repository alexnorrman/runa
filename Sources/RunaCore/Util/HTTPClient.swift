import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The one seam to the network, so backends and AI providers can be tested without it.
public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw BackendError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw BackendError.network("Not an HTTP response") }
        return (data, http)
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension Date {
    /// `2026-10-07T09:30:00Z`
    var isoString: String { formatted(.iso8601) }

    init?(isoString: String) {
        guard !isoString.isEmpty, let date = try? Date(isoString, strategy: .iso8601) else { return nil }
        self = date
    }
}
