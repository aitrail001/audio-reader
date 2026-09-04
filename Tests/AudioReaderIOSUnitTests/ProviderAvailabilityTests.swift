#if os(iOS)
import XCTest
@testable import AudioReader

final class ProviderAvailabilityTests: XCTestCase {
    func testIPadOffersOnlySupportedAIConnections() {
        XCTAssertEqual(LLMConnectionChoice.availableOnCurrentPlatform, [
            .managedQwen,
            .grokAPIKey,
            .qwenAPIKey,
            .openAIAPIKey,
            .appleFoundation,
        ])
        XCTAssertFalse(LLMConnectionChoice.availableOnCurrentPlatform.contains(.grokBuild))
        XCTAssertFalse(LLMConnectionChoice.availableOnCurrentPlatform.contains(.chatGPTPlan))
    }
}
#endif
