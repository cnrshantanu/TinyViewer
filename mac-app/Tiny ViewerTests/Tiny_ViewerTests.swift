import XCTest
@testable import Tiny_Viewer

final class Tiny_ViewerTests: XCTestCase {

    // MARK: - StreamQuality

    func testStreamQualityPresets() {
        XCTAssertEqual(StreamQuality.low.maxWidth,    640)
        XCTAssertEqual(StreamQuality.medium.maxWidth, 960)
        XCTAssertEqual(StreamQuality.high.maxWidth,   1920)
        XCTAssertEqual(StreamQuality.low.fps,    10)
        XCTAssertEqual(StreamQuality.medium.fps, 15)
        XCTAssertEqual(StreamQuality.high.fps,   20)
        XCTAssertLessThan(StreamQuality.low.jpegQuality,    StreamQuality.medium.jpegQuality)
        XCTAssertLessThan(StreamQuality.medium.jpegQuality, StreamQuality.high.jpegQuality)
    }

    // MARK: - TunnelStatus

    func testTunnelStatusURL() {
        XCTAssertNil(TunnelStatus.stopped.url)
        XCTAssertNil(TunnelStatus.starting.url)
        XCTAssertNil(TunnelStatus.failed("err").url)
        XCTAssertEqual(
            TunnelStatus.running(url: "https://example.trycloudflare.com").url,
            "https://example.trycloudflare.com"
        )
    }

    func testTunnelStatusIsRunning() {
        XCTAssertFalse(TunnelStatus.stopped.isRunning)
        XCTAssertFalse(TunnelStatus.starting.isRunning)
        XCTAssertFalse(TunnelStatus.failed("err").isRunning)
        XCTAssertTrue(TunnelStatus.running(url: "https://x.trycloudflare.com").isRunning)
    }

    func testTunnelStatusLabel() {
        XCTAssertEqual(TunnelStatus.stopped.label,  "Stopped")
        XCTAssertEqual(TunnelStatus.starting.label, "Starting…")
        XCTAssertEqual(TunnelStatus.failed("oops").label, "Error: oops")
        XCTAssertEqual(
            TunnelStatus.running(url: "https://x.trycloudflare.com").label,
            "https://x.trycloudflare.com"
        )
    }

    // MARK: - TunnelManager URL extraction

    @MainActor func testExtractURLFromCloudflaredLog() {
        let log = "2026-03-27T12:00:00Z INF |  https://safari-hollow-test.trycloudflare.com  |"
        XCTAssertEqual(
            TunnelManager().extractURL(from: log),
            "https://safari-hollow-test.trycloudflare.com"
        )
    }

    @MainActor func testExtractURLReturnsNilWhenMissing() {
        XCTAssertNil(TunnelManager().extractURL(from: "no url here"))
    }

    // MARK: - LicenseManager

    func testLicenseManagerAlwaysFree() {
        let lm = LicenseManager.shared
        XCTAssertTrue(lm.isAllowed)
        XCTAssertNil(lm.daysRemainingInTrial)
        XCTAssertEqual(lm.state, .licensed)
    }
}
