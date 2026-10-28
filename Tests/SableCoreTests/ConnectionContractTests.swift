import XCTest
@testable import SableCore

final class ConnectionContractTests: XCTestCase {
    func testStorageLocationsUseInjectedHomeWithoutAccessingCredentials() {
        let locations = ConnectionStorageLocations.standard(homeDirectory: URL(fileURLWithPath: "/isolated"))

        XCTAssertEqual(locations.directory.path, "/isolated/.config/sable")
        XCTAssertEqual(locations.chatGPTCredentials.lastPathComponent, "chatgpt-credentials.json")
        XCTAssertEqual(locations.hostIdentity.lastPathComponent, "host-identity.json")
        XCTAssertEqual(locations.openRouterKey.lastPathComponent, "openrouter-key")
    }

    func testSecretDescriptionsAndReflectionAreRedacted() {
        let secret = ConnectionSecret("synthetic-test-value")

        XCTAssertEqual(String(describing: secret), "<redacted>")
        XCTAssertEqual(String(reflecting: secret), "<redacted>")
        XCTAssertEqual(Mirror(reflecting: secret).children.count, 0)
    }

    func testPendingSignInCanRetainVerifiedActiveAccount() {
        let account = ConnectionAccount(id: "registration", displayName: "Personal", email: "example@example.com")
        let status = ConnectionStatus(activeAccount: account, isSigningIn: true)

        XCTAssertEqual(status.activeAccount, account)
        XCTAssertTrue(status.isSigningIn)
    }

    func testConnectionPlaceholderDoesNotOpenBrowserOrClaimSuccess() async {
        let connection = UnimplementedChatGPTConnection()
        let status = await connection.status()
        XCTAssertEqual(status, ConnectionStatus())
        do {
            _ = try await connection.signIn { _ in XCTFail("Skeleton must not open a browser") }
            XCTFail("Expected unavailable connection")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .notImplemented)
        }
        await connection.cancelSignIn()
        do {
            try await connection.disconnect()
            XCTFail("Skeleton cannot claim credentials were removed")
        } catch {
            XCTAssertEqual(error as? ConnectionError, .notImplemented)
        }
    }
}
