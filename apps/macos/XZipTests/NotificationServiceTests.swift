import XCTest
@testable import XZip

final class NotificationServiceTests: XCTestCase {
    func testAuthorizationCompletionCanRunOffMainActor() async {
        let completion = NotificationService.authorizationCompletion

        await Task.detached {
            completion(false, nil)
        }.value
    }
}
