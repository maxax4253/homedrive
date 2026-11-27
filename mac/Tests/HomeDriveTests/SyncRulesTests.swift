import XCTest
@testable import HomeDrive

/// The offline sync decision table: every combination of server copy, Mac copy
/// and "last time they were in sync".
final class SyncRulesTests: XCTestCase {
    typealias S = SyncRules.FileState
    let now = 1_000_000.0
    let old = 900_000.0          // long before `now`, so nothing counts as "still being written"

    func base(server: Double = 900_000, serverSize: Int64 = 10,
              local: Double = 900_000, localSize: Int64 = 10) -> OfflineStore.Baseline {
        .init(serverModified: server, serverSize: serverSize, localModified: local, localSize: localSize)
    }

    func decide(_ r: S?, _ l: S?, _ b: OfflineStore.Baseline?, safetyNet: Bool = false) -> SyncRules.Action {
        SyncRules.decide(remote: r, local: l, baseline: b, now: now, safetyNet: safetyNet)
    }

    func testUnchangedDoesNothing() {
        XCTAssertEqual(decide(S(modified: old, size: 10), S(modified: old, size: 10), base()), .nothing)
    }

    func testTinyClockDifferencesDontCount() {
        XCTAssertEqual(decide(S(modified: old + 0.4, size: 10), S(modified: old - 0.4, size: 10), base()), .nothing)
    }

    func testOnlyServerChangedDownloads() {
        XCTAssertEqual(decide(S(modified: old + 60, size: 10), S(modified: old, size: 10), base()), .download)
        XCTAssertEqual(decide(S(modified: old, size: 11), S(modified: old, size: 10), base()), .download)
    }

    func testOnlyMacChangedUploads() {
        XCTAssertEqual(decide(S(modified: old, size: 10), S(modified: old + 60, size: 12), base()), .uploadEdit)
    }

    func testBothChangedKeepsBoth() {
        XCTAssertEqual(decide(S(modified: old + 60, size: 10), S(modified: old + 90, size: 10), base()),
                       .keepBoth(reason: SyncRules.bothChanged))
    }

    func testFileStillBeingSavedWaits() {
        XCTAssertEqual(decide(S(modified: old, size: 10), S(modified: now - 1, size: 10), base()), .waitStillWriting)
        XCTAssertEqual(decide(nil, S(modified: now - 0.5, size: 3), nil), .waitStillWriting)
    }

    func testFirstSyncComparesSameSizedFiles() {
        XCTAssertEqual(decide(S(modified: old, size: 10), S(modified: old, size: 10), nil), .compareContents)
        XCTAssertEqual(decide(S(modified: old, size: 10), S(modified: old, size: 99), nil),
                       .keepBoth(reason: SyncRules.differentCopies))
    }

    func testDeletedOnMacDeletesOnServer() {
        XCTAssertEqual(decide(S(modified: old, size: 10), nil, base()), .deleteOnServer)
    }

    func testDeletedOnMacButChangedOnServerComesBack() {
        XCTAssertEqual(decide(S(modified: old + 60, size: 10), nil, base()), .download)
    }

    func testSafetyNetNeverDeletesOnServer() {
        XCTAssertEqual(decide(S(modified: old, size: 10), nil, base(), safetyNet: true), .download)
    }

    func testNewOnServerDownloads() {
        XCTAssertEqual(decide(S(modified: old, size: 10), nil, nil), .download)
    }

    func testNewOnMacUploads() {
        XCTAssertEqual(decide(nil, S(modified: old, size: 10), nil), .uploadNew(note: SyncRules.addedLocally))
    }

    func testDeletedOnServerRemovesUneditedCopy() {
        XCTAssertEqual(decide(nil, S(modified: old, size: 10), base()), .removeLocal)
    }

    func testDeletedOnServerButEditedOnMacUploadsAgain() {
        XCTAssertEqual(decide(nil, S(modified: old + 60, size: 10), base()), .uploadNew(note: SyncRules.reuploaded))
    }

    func testGoneEverywhereForgets() {
        XCTAssertEqual(decide(nil, nil, base()), .forgetBaseline)
        XCTAssertEqual(decide(nil, nil, nil), .nothing)
    }

    func testMassDeletionThreshold() {
        XCTAssertFalse(SyncRules.tooManyDeletions(10, knownFiles: 20))     // small folders: up to 10 is fine
        XCTAssertTrue(SyncRules.tooManyDeletions(11, knownFiles: 20))
        XCTAssertFalse(SyncRules.tooManyDeletions(300, knownFiles: 1000))  // big folders: up to 30%
        XCTAssertTrue(SyncRules.tooManyDeletions(301, knownFiles: 1000))
    }

    func testLocalDeletionDetection() {
        let r = S(modified: old, size: 10)
        XCTAssertTrue(SyncRules.isLocalDeletion(remote: r, local: nil, baseline: base()))
        XCTAssertFalse(SyncRules.isLocalDeletion(remote: r, local: r, baseline: base()))
        XCTAssertFalse(SyncRules.isLocalDeletion(remote: S(modified: old + 60, size: 10), local: nil, baseline: base()))
        XCTAssertFalse(SyncRules.isLocalDeletion(remote: r, local: nil, baseline: nil))
    }
}
