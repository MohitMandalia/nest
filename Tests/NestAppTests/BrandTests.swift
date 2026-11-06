import XCTest
@testable import Nest

@MainActor
final class BrandTests: XCTestCase {
    func testSidebarLogoLoadsBundledArtworkInFullColor() {
        let logo = NestBrand.logo
        XCTAssertFalse(logo.isTemplate)
        XCTAssertGreaterThan(logo.size.width, 0)
        XCTAssertGreaterThan(logo.size.height, 0)
        XCTAssertTrue(logo.representations.contains { $0.pixelsWide >= 1024 && $0.pixelsHigh >= 1024 })
    }
}
