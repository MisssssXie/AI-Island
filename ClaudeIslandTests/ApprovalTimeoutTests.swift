import XCTest
@testable import AI_Island

final class ApprovalTimeoutTests: XCTestCase {
    func testGivenPendingApprovalWhenItTimesOutThenActionsHideAndRecoveryMessageMatchesSource() {
        for source in AgentSource.allCases {
            let permission = PermissionContext(toolUseId: "tool-\(source.rawValue)",
                                               toolName: "exec_command",
                                               toolInput: nil,
                                               receivedAt: Date())

            // Given: Allow / Deny are visible while approval is pending.
            var session = SessionState(sessionId: "bdd-timeout-\(source.rawValue)",
                                       cwd: "/tmp/bdd-timeout-\(source.rawValue)",
                                       source: source,
                                       phase: .waitingForApproval(permission))
            XCTAssertTrue(session.phase.isWaitingForApproval)
            XCTAssertNil(session.approvalTimeoutMessage)

            // When: the existing timeout transition runs.
            session.applyApprovalTimeout()

            // Then: approval actions hide and the matching recovery text appears.
            XCTAssertFalse(session.phase.isWaitingForApproval)
            XCTAssertEqual(session.phase, .idle)
            XCTAssertEqual(session.approvalTimeoutMessage,
                           "核准要求已逾時，請回 \(source.displayName) 操作")
        }
    }
}
