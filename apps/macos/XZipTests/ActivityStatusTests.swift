import XCTest
@testable import XZip

/// Unit tests for `ActivityStatus`, the pure logic behind the inline
/// activity bar shown in the main window while operations run.
final class ActivityStatusTests: XCTestCase {

    private func op(_ state: OperationState, progress: Double = 0) -> ArchiveOperation {
        ArchiveOperation(title: "op", kind: .compress, state: state,
                         progress: progress, currentItem: "", detail: "")
    }

    // MARK: - active

    func testActiveKeepsOnlyUnfinishedStates() {
        let ops = [op(.queued), op(.running), op(.paused),
                   op(.completed), op(.failed), op(.cancelled)]
        XCTAssertEqual(ActivityStatus.active(in: ops).map(\.state),
                       [.queued, .running, .paused])
    }

    func testActiveEmptyWhenAllFinished() {
        XCTAssertTrue(ActivityStatus.active(in: [op(.completed), op(.failed)]).isEmpty)
    }

    // MARK: - overallProgress

    func testOverallProgressAveragesOps() {
        let ops = [op(.running, progress: 0.2), op(.running, progress: 0.6)]
        XCTAssertEqual(ActivityStatus.overallProgress(of: ops), 0.4, accuracy: 0.0001)
    }

    func testOverallProgressEmptyIsZero() {
        XCTAssertEqual(ActivityStatus.overallProgress(of: []), 0)
    }
}
