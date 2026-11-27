import XCTest
@testable import HomeDrive

final class TokenStoreTests: XCTestCase {
    let account = "http://test.invalid:8090-\(UUID().uuidString)"

    override func tearDown() { TokenStore.delete(account: account) }

    func testSaveLoadDelete() throws {
        XCTAssertNil(TokenStore.load(account: account))
        TokenStore.save("abc123", account: account)
        XCTAssertEqual(TokenStore.load(account: account), "abc123")
        TokenStore.save("new", account: account)
        XCTAssertEqual(TokenStore.load(account: account), "new")
        TokenStore.delete(account: account)
        XCTAssertNil(TokenStore.load(account: account))
    }

    func testFileIsPrivate() throws {
        TokenStore.save("secret", account: account)
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("HomeDrive/Login")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let mine = try XCTUnwrap(files.first { $0.contains("test_invalid") && $0.hasSuffix(".token") && $0.contains(account.suffix(8)) })
        let perms = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(mine).path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }
}

final class OfflineNamesTests: XCTestCase {
    func testIgnoredNames() {
        XCTAssertTrue(OfflineStore.isIgnored(".DS_Store"))
        XCTAssertTrue(OfflineStore.isIgnored("~$Report.docx"))
        XCTAssertFalse(OfflineStore.isIgnored("Report.docx"))
        XCTAssertFalse(OfflineStore.isIgnored("my~$file.txt"))
    }
}
