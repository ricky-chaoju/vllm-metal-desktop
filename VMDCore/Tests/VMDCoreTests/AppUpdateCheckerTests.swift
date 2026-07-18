import Foundation
import Testing
@testable import VMDCore

@Suite("AppUpdateChecker")
struct AppUpdateCheckerTests {
    let latest = ReleaseInfo(
        tag: "v1.1.0",
        version: EngineVersion("1.1.0"),
        htmlURL: URL(string: "https://example.com/release"),
        assets: []
    )

    @Test("offers an update only when newer")
    func decides() {
        #expect(AppUpdateChecker.decide(currentVersion: "1.0.0", latest: latest)
            == .updateAvailable(version: "v1.1.0", url: URL(string: "https://example.com/release")))
        #expect(AppUpdateChecker.decide(currentVersion: "1.1.0", latest: latest) == .upToDate)
        #expect(AppUpdateChecker.decide(currentVersion: "1.2.0", latest: latest) == .upToDate)
    }

    @Test("unknown when there is no parseable release")
    func unknown() {
        #expect(AppUpdateChecker.decide(currentVersion: "1.0.0", latest: nil) == .unknown("No parseable release"))
        let badTag = ReleaseInfo(tag: "nightly", version: nil, htmlURL: nil, assets: [])
        #expect(AppUpdateChecker.decide(currentVersion: "1.0.0", latest: badTag) == .unknown("No parseable release"))
    }
}
