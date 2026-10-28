import Foundation
import CryptoKit
import Security

/// Injectable HTTP boundary used only by the connection module. Responses and
/// transport errors are translated here; provider payloads never become UI errors.
public protocol ConnectionHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> ConnectionHTTPResponse
}

public struct ConnectionHTTPResponse: Sendable {
    public let statusCode: Int
    public let data: Data
    public init(statusCode: Int, data: Data) { self.statusCode = statusCode; self.data = data }
}

/// A private, uncached session that refuses redirects: OAuth form bodies and
/// retained ID-token hints must never follow a redirect to another origin.
public final class URLSessionConnectionTransport: NSObject, ConnectionHTTPTransport, URLSessionTaskDelegate,
                                                   @unchecked Sendable {
    public override init() { super.init() }

    public func send(_ request: URLRequest) async throws -> ConnectionHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse else { throw ConnectionError.networkUnavailable }
            var data = Data()
            for try await byte in bytes {
                guard data.count < 1_048_576 else { throw ConnectionError.invalidTokenResponse }
                data.append(byte)
            }
            return ConnectionHTTPResponse(statusCode: response.statusCode, data: data)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? ConnectionError { throw error }
            throw ConnectionError.networkUnavailable
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                           completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Time is injected so expiration, retry, and whole-attempt timeout tests need
/// neither real consent nor wall-clock waits. Sleep must honor task cancellation.
public struct ConnectionClock: Sendable {
    public let now: @Sendable () -> Date
    public let sleep: @Sendable (TimeInterval) async throws -> Void

    public init(now: @escaping @Sendable () -> Date = { Date() },
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                    try await Task.sleep(nanoseconds: UInt64(max(0, min($0, 86_400)) * 1_000_000_000))
                }) {
        self.now = now
        self.sleep = sleep
    }
}

/// Discovery remains rooted at OpenAI's pinned issuer. Even a syntactically
/// valid discovery response cannot redirect credentials or JWKS to another host.
struct OpenAIDiscovery: Decodable, Sendable {
    static let issuer = "https://auth.openai.com"
    static let url = URL(string: issuer + "/.well-known/openid-configuration")!
    let issuer: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let jwksURI: URL
    let revocationEndpoint: URL?

    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case jwksURI = "jwks_uri"
        case revocationEndpoint = "revocation_endpoint"
    }

    func validate() throws {
        guard issuer == Self.issuer,
              [authorizationEndpoint, tokenEndpoint, jwksURI].allSatisfy(Self.isTrusted),
              revocationEndpoint.map(Self.isTrusted) ?? true else { throw ConnectionError.invalidDiscovery }
    }

    private static func isTrusted(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "auth.openai.com" && (url.port == nil || url.port == 443)
            && url.user == nil && url.password == nil && url.fragment == nil && url.query == nil
    }
}

enum OAuthEncoding {
    static func random(_ count: Int = 32) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw ConnectionError.authorizationFailed
        }
        return Data(bytes).base64URL
    }

    static func form(_ values: [String: String]) -> Data {
        // URLQueryItem alone does not encode '+' (which form parsers read as a
        // space). Encode the RFC3986 unreserved set only, for every value.
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: unreserved)! + "="
                + $0.value.addingPercentEncoding(withAllowedCharacters: unreserved)!
        }.joined(separator: "&").utf8)
    }

    static func post(_ url: URL, values: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = form(values)
        return request
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        guard !base64URL.isEmpty, base64URL.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
        }) else { return nil }
        let base64 = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4))
    }
}

struct VerifiedOpenAIIdentity: Sendable {
    let subject: String
    let name: String?
    let email: String?
}

/// Verifies the JWS *before* interpreting account claims. Algorithms are fixed
/// locally; untrusted headers cannot select HMAC, supply a key, or fetch a URL.
/// RSA keys use Security's native PKCS#1 verifier; ES256 uses CryptoKit's P-256.
enum OpenAIIdentityVerifier {
    struct JWKS: Decodable {
        let keys: [Key]
        struct Key: Decodable {
            let kty: String
            let kid: String?
            let alg: String?
            let use: String?
            let keyOps: [String]?
            let n: String?
            let e: String?
            let crv: String?
            let x: String?
            let y: String?
            enum CodingKeys: String, CodingKey {
                case kty, kid, alg, use, n, e, crv, x, y
                case keyOps = "key_ops"
            }
        }
    }

    static func verify(_ jwt: String, jwks: Data, issuer: String, clientID: String,
                       nonce: String?, now: Date, accessToken: String? = nil) throws -> VerifiedOpenAIIdentity {
        do {
            let parts = jwt.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard jwt.utf8.count <= 65_536, parts.count == 3,
                  let headerData = Data(base64URL: parts[0]), let payload = Data(base64URL: parts[1]),
                  let signature = Data(base64URL: parts[2]),
                  let header = try JSONSerialization.jsonObject(with: headerData) as? [String: Any],
                  let algorithm = header["alg"] as? String, ["RS256", "ES256"].contains(algorithm),
                  let kid = header["kid"] as? String, !kid.isEmpty,
                  header["crit"] == nil, header["b64"] == nil else { throw ConnectionError.invalidIdentity }
            let keys = try JSONDecoder().decode(JWKS.self, from: jwks).keys.filter {
                $0.kid == kid && ($0.alg == nil || $0.alg == algorithm)
                    && ($0.use == nil || $0.use == "sig") && ($0.keyOps == nil || $0.keyOps!.contains("verify"))
                    && $0.kty == (algorithm == "RS256" ? "RSA" : "EC")
            }
            guard keys.count == 1 else { throw ConnectionError.invalidIdentity }
            let key = keys[0]
            let message = Data((parts[0] + "." + parts[1]).utf8)
            if algorithm == "RS256" {
                guard let n = key.n.flatMap({ Data(base64URL: $0) }), n.count >= 256, n.count <= 1024,
                      let e = key.e.flatMap({ Data(base64URL: $0) }), e.count <= 8 else {
                    throw ConnectionError.invalidIdentity
                }
                let representation = der(0x30, derInteger(n) + derInteger(e))
                let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                                                kSecAttrKeyClass as String: kSecAttrKeyClassPublic]
                guard let publicKey = SecKeyCreateWithData(representation as CFData, attributes as CFDictionary, nil),
                      SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                            message as CFData, signature as CFData, nil) else {
                    throw ConnectionError.invalidIdentity
                }
            } else {
                guard key.crv == "P-256", let x = key.x.flatMap({ Data(base64URL: $0) }), x.count == 32,
                      let y = key.y.flatMap({ Data(base64URL: $0) }), y.count == 32 else {
                    throw ConnectionError.invalidIdentity
                }
                let publicKey = try P256.Signing.PublicKey(x963Representation: Data([4]) + x + y)
                guard publicKey.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signature),
                                                 for: message) else { throw ConnectionError.invalidIdentity }
            }

            // Claims become identity only after signature verification against
            // trusted discovery keys. Arrays require azp when audiences multiply.
            guard let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
                  claims["iss"] as? String == issuer,
                  let subject = claims["sub"] as? String, !subject.isEmpty, subject.utf8.count <= 1024,
                  let expiry = numeric(claims["exp"]), expiry > now.timeIntervalSince1970,
                  let issued = numeric(claims["iat"]), issued <= now.timeIntervalSince1970 + 5 else {
                throw ConnectionError.invalidIdentity
            }
            let audiences = (claims["aud"] as? [String]) ?? (claims["aud"] as? String).map { [$0] } ?? []
            guard audiences.contains(clientID),
                  (audiences.count <= 1 || claims["azp"] as? String == clientID),
                  (claims["azp"] == nil || claims["azp"] as? String == clientID),
                  (nonce == nil || claims["nonce"] as? String == nonce) else { throw ConnectionError.invalidIdentity }
            if let notBefore = claims["nbf"] {
                guard let value = numeric(notBefore), value <= now.timeIntervalSince1970 + 5 else {
                    throw ConnectionError.invalidIdentity
                }
            }
            if let hash = claims["at_hash"] {
                guard let accessToken, let hash = hash as? String,
                      Data(SHA256.hash(data: Data(accessToken.utf8)).prefix(16)).base64URL == hash else {
                    throw ConnectionError.invalidIdentity
                }
            }
            return VerifiedOpenAIIdentity(subject: subject, name: (claims["name"] as? String).map { String($0.prefix(256)) },
                                          email: (claims["email"] as? String).map { String($0.prefix(320)) })
        } catch { throw ConnectionError.invalidIdentity }
    }

    private static func numeric(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }

    private static func derInteger(_ data: Data) -> Data {
        var bytes = Data(data.drop(while: { $0 == 0 }))
        if bytes.isEmpty { bytes = Data([0]) }
        if bytes.first! & 0x80 != 0 { bytes.insert(0, at: 0) }
        return der(0x02, bytes)
    }

    private static func der(_ tag: UInt8, _ data: Data) -> Data {
        let count = data.count
        let length: [UInt8] = count < 128 ? [UInt8(count)]
            : count < 256 ? [0x81, UInt8(count)] : [0x82, UInt8(count >> 8), UInt8(count & 255)]
        return Data([tag] + length) + data
    }
}
