import XCTest
import Foundation
import Security
import Darwin
@testable import SableCore

final class ConnectionSecurityTests: XCTestCase {
    func testOpenRouterKeySaveReplaceAndRemoveArePrivateAndIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sable-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = ConnectionStorageLocations(directory: directory)
        let store = FileOpenRouterKeyStore(locations: locations)
        let empty = try await store.hasKey()
        XCTAssertFalse(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        try await store.saveKey(ConnectionSecret("synthetic-first-key"))
        let saved = try await store.hasKey()
        XCTAssertTrue(saved)
        let first = try await store.loadKey()
        XCTAssertEqual(first?.rawValue, "synthetic-first-key")
        XCTAssertEqual(try permissions(directory), 0o700)
        XCTAssertEqual(try permissions(locations.openRouterKey), 0o600)
        try await store.saveKey(ConnectionSecret("synthetic-replacement-key"))
        let replacement = try await store.loadKey()
        XCTAssertEqual(replacement?.rawValue, "synthetic-replacement-key")
        XCTAssertEqual(try permissions(locations.openRouterKey), 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["openrouter-key"])
        for invalid in ["", "   ", "key\nvalue", "key\r", "key\u{0}"] {
            do { try await store.saveKey(ConnectionSecret(invalid)); XCTFail("Expected invalid key") }
            catch { XCTAssertEqual(error as? ConnectionError, .invalidKey) }
        }
        let retained = try await store.loadKey()
        XCTAssertEqual(retained?.rawValue, "synthetic-replacement-key")
        try await store.removeKey()
        try await store.removeKey()
        let removed = try await store.hasKey()
        XCTAssertFalse(removed)
    }

    func testProtectedFilesRejectSymlinkReadsAndKeepReplacementPrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sable-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let locations = ConnectionStorageLocations(directory: directory.appendingPathComponent("private"))
        let files = ProtectedConnectionFiles(locations: locations)
        try files.prepareDirectory()
        let target = directory.appendingPathComponent("external")
        try Data("untouched".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: locations.openRouterKey, withDestinationURL: target)
        XCTAssertThrowsError(try files.read(locations.openRouterKey)) { XCTAssertEqual($0 as? ConnectionError, .storageUnavailable) }
        try files.write(Data("private-new-value".utf8), to: locations.openRouterKey)
        XCTAssertEqual(try String(contentsOf: target), "untouched")
        XCTAssertEqual(try permissions(locations.openRouterKey), 0o600)
        XCTAssertEqual(try files.read(locations.openRouterKey), Data("private-new-value".utf8))

        let linkedDirectory = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: locations.directory)
        let linked = ProtectedConnectionFiles(locations: ConnectionStorageLocations(directory: linkedDirectory))
        XCTAssertThrowsError(try linked.write(Data("rejected".utf8), to: linked.locations.openRouterKey))
    }

    func testNativeRS256VerificationAndTamperedSignature() throws {
        let attributes: [String: Any] = [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
        let privateKey = try XCTUnwrap(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try XCTUnwrap(SecKeyCopyPublicKey(privateKey))
        let encoded = try XCTUnwrap(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        // Security exports an RSA public key as PKCS#1 (sequence of n and e).
        var offset = 0
        let sequence = try readDER(encoded, offset: &offset, tag: 0x30)
        var position = 0
        let n = try readDER(sequence, offset: &position, tag: 0x02).drop(while: { $0 == 0 })
        let e = try readDER(sequence, offset: &position, tag: 0x02).drop(while: { $0 == 0 })
        let jwks = try JSONSerialization.data(withJSONObject: ["keys": [["kid": "rsa-test", "kty": "RSA", "alg": "RS256",
                                                                         "n": Data(n).base64URL, "e": Data(e).base64URL]]])
        let now = Date()
        let header = try JSONSerialization.data(withJSONObject: ["alg": "RS256", "kid": "rsa-test"]).base64URL
        let payload = try JSONSerialization.data(withJSONObject: ["iss": OpenAIDiscovery.issuer, "aud": ["oaiapp_test"],
                                                                  "sub": "verified-sub", "nonce": "nonce",
                                                                  "iat": now.timeIntervalSince1970,
                                                                  "exp": now.timeIntervalSince1970 + 3600]).base64URL
        let input = header + "." + payload
        var signature = try XCTUnwrap(SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256,
                                                           Data(input.utf8) as CFData, nil)) as Data
        let valid = try OpenAIIdentityVerifier.verify(input + "." + signature.base64URL, jwks: jwks,
                                                     issuer: OpenAIDiscovery.issuer, clientID: "oaiapp_test", nonce: "nonce", now: now)
        XCTAssertEqual(valid.subject, "verified-sub")
        signature[0] ^= 1
        XCTAssertThrowsError(try OpenAIIdentityVerifier.verify(input + "." + signature.base64URL, jwks: jwks,
                                                              issuer: OpenAIDiscovery.issuer, clientID: "oaiapp_test",
                                                              nonce: "nonce", now: now)) {
            XCTAssertEqual($0 as? ConnectionError, .invalidIdentity)
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
    }

    private func readDER(_ data: Data, offset: inout Int, tag: UInt8) throws -> Data {
        guard offset + 2 <= data.count, data[offset] == tag else { throw ConnectionError.invalidIdentity }
        offset += 1
        var size = Int(data[offset]); offset += 1
        if size & 0x80 != 0 {
            let count = size & 0x7f
            guard count > 0, count <= 4, offset + count <= data.count else { throw ConnectionError.invalidIdentity }
            size = 0
            for _ in 0..<count { size = (size << 8) | Int(data[offset]); offset += 1 }
        }
        guard offset + size <= data.count else { throw ConnectionError.invalidIdentity }
        defer { offset += size }
        return Data(data[offset..<(offset + size)])
    }
}

/// Exercise the actual native TCP listener on an ephemeral IPv4 loopback port.
/// Raw HTTP lets malformed/oversized requests be tested without involving a browser.
final class ConnectionListenerTests: XCTestCase {
    func testMalformedUnrelatedAndWrongStateDoNotConsumeRealAttempt() async throws {
        let listener = LoopbackConnectionListener()
        defer { listener.cancel() }
        let callback = try await listener.start(state: "expected-state")
        XCTAssertEqual(callback.host, "127.0.0.1")
        XCTAssertEqual(callback.path, "/auth/callback")
        let port = try XCTUnwrap(callback.port)
        let result = Task { try await listener.callback() }
        for target in ["/favicon.ico", "/auth/callback?state=wrong&code=fake", "/auth/callback?state=expected-state",
                       "/auth/callback?state=expected-state&state=expected-state&code=fake"] {
            let response = try await rawRequest(port: port, target: target)
            XCTAssertTrue(response.hasPrefix("HTTP/1.1 400"))
        }
        let oversized = "GET /" + String(repeating: "x", count: 17_000) + " HTTP/1.1\r\n\r\n"
        let rejected = try await rawRequest(port: port, raw: oversized)
        XCTAssertTrue(rejected.hasPrefix("HTTP/1.1 400"))
        let response = try await rawRequest(port: port, target: "/auth/callback?state=expected-state&code=a%2Bb&client_id=oaiapp_test")
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"))
        let value = try await result.value
        XCTAssertEqual(value.code, "a+b")
        XCTAssertEqual(value.clientID, "oaiapp_test")
        listener.cancel() // Idempotent after success.
        do { _ = try await rawRequest(port: port, target: "/"); XCTFail("Listener should have closed") } catch {}
    }

    func testCancellationClosesListenerAndResumesWaiterExactlyOnce() async throws {
        let listener = LoopbackConnectionListener()
        defer { listener.cancel() }
        let url = try await listener.start(state: "cancel-state")
        let result = Task { try await listener.callback() }
        result.cancel()
        do { _ = try await result.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
        listener.cancel()
        do { _ = try await rawRequest(port: url.port!, target: "/"); XCTFail("Listener should have closed") } catch {}
        let neverStarted = LoopbackConnectionListener()
        neverStarted.cancel()
        do { _ = try await neverStarted.start(state: "unused"); XCTFail("Expected cancelled start") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testMatchingDeniedAuthorizationIsReturnedWithoutACode() async throws {
        let listener = LoopbackConnectionListener()
        defer { listener.cancel() }
        let url = try await listener.start(state: "denied-state")
        let result = Task { try await listener.callback() }
        _ = try await rawRequest(port: url.port!, target: "/auth/callback?state=denied-state&error=access_denied")
        let value = try await result.value
        XCTAssertNil(value.code)
        XCTAssertEqual(value.error, "access_denied")
    }
}

private func rawRequest(port: Int, target: String = "/", raw: String? = nil) async throws -> String {
    try await Task.detached {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectionError.listenerUnavailable }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { throw ConnectionError.listenerUnavailable }
        let request = Data((raw ?? "GET \(target) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n").utf8)
        try request.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw ConnectionError.listenerUnavailable }
                offset += count
            }
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == ECONNRESET && !data.isEmpty { break }
            guard count >= 0 else { throw SocketTestError(operation: "receive", code: errno) }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return String(data: data, encoding: .utf8) ?? ""
    }.value
}

private struct SocketTestError: Error { let operation: String; let code: Int32 }
