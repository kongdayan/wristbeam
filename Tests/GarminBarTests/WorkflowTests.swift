import XCTest
@testable import GarminBar

final class WorkflowTests: XCTestCase {
    func testLocalModeNeverPromptsForCloudRegardlessOfRetainedAccountOrPendingQueue() {
        for authenticated in [false, true] {
            for pending in [0, 4] {
                let state = WorkflowPresentation(connected: true, connecting: false, receiving: false, cloudEnabled: false,
                    authenticated: authenticated, uploading: true, pendingFiles: pending, hasLocalData: true, storageFailed: false)
                XCTAssertEqual(state.accountTitle, "仅本地")
                XCTAssertEqual(state.transferTitle, "已保存到本机")
                XCTAssertEqual(state.summary, "已保存到本机")
                XCTAssertFalse(state.cloudActive)
            }
        }
    }
    func testSavedStatusRequiresDataAndStorageFailureTakesPriority() {
        var state = WorkflowPresentation(connected: false, connecting: false, receiving: false, cloudEnabled: false,
            authenticated: false, uploading: false, pendingFiles: 0, hasLocalData: false, storageFailed: false)
        XCTAssertEqual(state.summary, "等待接收数据")
        state.hasLocalData = true
        XCTAssertEqual(state.summary, "已保存到本机")
        state.storageFailed = true; state.receiving = true
        XCTAssertEqual(state.summary, "本地保存或读取异常")
        state.cloudEnabled = true; state.authenticated = true
        XCTAssertEqual(state.accountTitle, "云账号已连接")
        XCTAssertTrue(state.cloudActive)
    }
    func testActivityEmptyStatesOfferTheAppropriateRecovery() {
        func state(_ total: Int = 0, _ matches: Int = 0, busy: Bool = false, failed: Bool = false, cloud: Bool = true, online: Bool = true) -> ActivityListState {
            .resolve(total: total, matches: matches, busy: busy, failed: failed, cloudEnabled: cloud, online: online)
        }
        XCTAssertEqual(state(cloud: false, online: false), .localOnly)
        XCTAssertEqual(state(online: false), .signedOut)
        XCTAssertEqual(state(busy: true), .loading)
        XCTAssertEqual(state(failed: true), .failed)
        XCTAssertEqual(state(), .empty)
        XCTAssertEqual(state(5, 0), .noMatches)
        XCTAssertEqual(state(5, 2, failed: true, cloud: false, online: false), .content)
        XCTAssertEqual(state(5, 2, busy: true), .content)
    }
    func testBrowsingKeepsSearchAndPageAndClampsAfterRecordsDisappear() {
        let rows = (0..<45).map { GarminActivity(id: String($0), name: "Morning run \($0)", type: "running", statistics: [:], fetchedAt: Date()) }
        var browsing = ActivityBrowsingState(search: " MORNING ", page: 1)
        XCTAssertEqual(browsing.visible(rows).map(\.id), (20..<40).map(String.init))
        XCTAssertEqual(browsing.search, " MORNING ")
        XCTAssertEqual(browsing.page, 1)
        XCTAssertEqual(browsing.visible(Array(rows.prefix(3))).map(\.id), ["0", "1", "2"])
        browsing.search = "no match"
        XCTAssertTrue(browsing.visible(rows).isEmpty)
        XCTAssertEqual(browsing.validPage(count: 0), 0)
    }
    @MainActor func testAccountChangeClearsOnlyActivityOffsets() {
        let positions = ScrollPositions()
        positions.offsets = ["page.activities": 300, "activity.1001": 250, "page.overview": 400]
        positions.clearActivities()
        XCTAssertEqual(positions.offsets, ["page.overview": 400])
    }
}
