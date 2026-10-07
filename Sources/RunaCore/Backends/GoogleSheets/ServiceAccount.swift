import _CryptoExtras
import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A Google Cloud service account key, the JSON file downloaded from the Cloud console.
public struct ServiceAccountCredentials: Codable, Sendable, Hashable {
    public var type: String
    public var projectID: String?
    public var privateKeyID: String?
    public var privateKey: String
    public var clientEmail: String
    public var tokenURI: String

    enum CodingKeys: String, CodingKey {
        case type
        case projectID = "project_id"
        case privateKeyID = "private_key_id"
        case privateKey = "private_key"
        case clientEmail = "client_email"
        case tokenURI = "token_uri"
    }

    public init(type: String = "service_account", projectID: String? = nil, privateKeyID: String? = nil, privateKey: String,
                clientEmail: String, tokenURI: String = "https://oauth2.googleapis.com/token")
    {
        self.type = type
        self.projectID = projectID
        self.privateKeyID = privateKeyID
        self.privateKey = privateKey
        self.clientEmail = clientEmail
        self.tokenURI = tokenURI
    }

    /// Parses and validates a key file.
    public init(json: Data) throws {
        let decoded: ServiceAccountCredentials
        do {
            decoded = try JSONDecoder().decode(ServiceAccountCredentials.self, from: json)
        } catch {
            throw BackendError.invalidData("This is not a Google service account key. Download a JSON key from the Google Cloud console.")
        }
        guard decoded.type == "service_account" else {
            throw BackendError.invalidData("The key's type is \"\(decoded.type)\"; a service account key is needed.")
        }
        guard (try? _RSA.Signing.PrivateKey(pemRepresentation: decoded.privateKey)) != nil else {
            throw BackendError.invalidData("The key file's private key could not be read.")
        }
        self = decoded
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public protocol AccessTokenProvider: Sendable {
    func accessToken() async throws -> String
}

/// Exchanges a signed JWT for an OAuth access token (the "two-legged" service account flow)
/// and caches it until shortly before it expires.
public actor ServiceAccountTokenProvider: AccessTokenProvider {
    public static let spreadsheetsScope = "https://www.googleapis.com/auth/spreadsheets"

    let credentials: ServiceAccountCredentials
    let scopes: [String]
    let http: HTTPClient
    private var cached: (token: String, expiry: Date)?
    private var refresh: Task<(String, Date), Error>?

    public init(credentials: ServiceAccountCredentials, scopes: [String] = [spreadsheetsScope], http: HTTPClient = URLSessionHTTPClient()) {
        self.credentials = credentials
        self.scopes = scopes
        self.http = http
    }

    public func accessToken() async throws -> String {
        if let cached, cached.expiry > Date().addingTimeInterval(60) { return cached.token }
        if let refresh { return try await refresh.value.0 }
        let task = Task { try await self.fetchToken() }
        refresh = task
        defer { refresh = nil }
        let (token, expiry) = try await task.value
        cached = (token, expiry)
        return token
    }

    private func fetchToken() async throws -> (String, Date) {
        let assertion = try Self.assertion(credentials: credentials, scopes: scopes, now: Date())
        guard let url = URL(string: credentials.tokenURI) else { throw BackendError.authenticationFailed("Invalid token URI") }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(assertion)"
        request.httpBody = Data(body.utf8)
        let (data, response) = try await http.send(request)
        let json = try? JSONValue.parse(data)
        guard response.statusCode == 200, let token = json?["access_token"]?.stringValue else {
            let description = json?["error_description"]?.stringValue ?? json?["error"]?.stringValue ?? "HTTP \(response.statusCode)"
            throw BackendError.authenticationFailed(description)
        }
        var lifetime: Double = 3600
        if case .number(let seconds)? = json?["expires_in"] { lifetime = seconds }
        return (token, Date().addingTimeInterval(lifetime))
    }

    /// A signed RS256 JWT asserting the service account's identity.
    static func assertion(credentials: ServiceAccountCredentials, scopes: [String], now: Date) throws -> String {
        let issuedAt = Int(now.timeIntervalSince1970)
        var header: [(String, JSONValue)] = [("alg", .string("RS256")), ("typ", .string("JWT"))]
        if let keyID = credentials.privateKeyID { header.append(("kid", .string(keyID))) }
        let claims = JSONValue.object([
            ("iss", .string(credentials.clientEmail)),
            ("scope", .string(scopes.joined(separator: " "))),
            ("aud", .string(credentials.tokenURI)),
            ("iat", .number(Double(issuedAt))),
            ("exp", .number(Double(issuedAt + 3600))),
        ])
        let signingInput = compact(.object(header)) + "." + compact(claims)
        let key: _RSA.Signing.PrivateKey
        do {
            key = try _RSA.Signing.PrivateKey(pemRepresentation: credentials.privateKey)
        } catch {
            throw BackendError.authenticationFailed("The service account's private key could not be read")
        }
        let signature = try key.signature(for: Data(signingInput.utf8), padding: .insecurePKCS1v1_5)
        return signingInput + "." + signature.rawRepresentation.base64URLEncodedString()
    }

    private static func compact(_ value: JSONValue) -> String {
        let json = value.serialized(style: .standard)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
        return Data(json.utf8).base64URLEncodedString()
    }
}
