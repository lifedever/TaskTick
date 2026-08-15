import XCTest
@testable import TaskTickApp

final class BarkPushManagerTests: XCTestCase {

    func testEmptyAndWhitespaceRejected() {
        XCTAssertNil(BarkPushManager.normalizedURL(from: ""))
        XCTAssertNil(BarkPushManager.normalizedURL(from: "   "))
        XCTAssertNil(BarkPushManager.normalizedURL(from: "\n\t"))
    }

    func testOfficialDeviceURLAccepted() {
        let url = BarkPushManager.normalizedURL(from: "https://api.day.app/abcdefghijklmnop/")
        XCTAssertEqual(url?.absoluteString, "https://api.day.app/abcdefghijklmnop")
    }

    func testTrailingSlashAndWhitespaceStripped() {
        let url = BarkPushManager.normalizedURL(from: "  https://api.day.app/deviceKey  ")
        XCTAssertEqual(url?.absoluteString, "https://api.day.app/deviceKey")
    }

    func testQueryItemsPreserved() {
        let url = BarkPushManager.normalizedURL(from: "https://api.day.app/deviceKey/?sound=bell")
        XCTAssertEqual(url?.scheme, "https")
        XCTAssertEqual(url?.host, "api.day.app")
        XCTAssertEqual(url?.path, "/deviceKey")
        XCTAssertEqual(url?.query, "sound=bell")
    }

    func testBareDeviceKeyBecomesOfficialURL() {
        let url = BarkPushManager.normalizedURL(from: "AbC_12-xy")
        XCTAssertEqual(url?.absoluteString, "https://api.day.app/AbC_12-xy")
    }

    func testSelfHostedURLAccepted() {
        let url = BarkPushManager.normalizedURL(from: "https://bark.example.com/mykey/")
        XCTAssertEqual(url?.absoluteString, "https://bark.example.com/mykey")
    }

    func testHostOnlyOfficialURLRejected() {
        XCTAssertNil(BarkPushManager.normalizedURL(from: "https://api.day.app"))
        XCTAssertNil(BarkPushManager.normalizedURL(from: "https://api.day.app/"))
    }

    func testUnsupportedSchemeRejected() {
        XCTAssertNil(BarkPushManager.normalizedURL(from: "ftp://api.day.app/key"))
        XCTAssertNil(BarkPushManager.normalizedURL(from: "not a url"))
        XCTAssertNil(BarkPushManager.normalizedURL(from: "key with spaces"))
    }

    func testIsConfiguredReadsDefaults() {
        let suite = "test.bark.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(BarkPushManager.isConfigured(defaults))

        defaults.set("https://api.day.app/deviceKey", forKey: BarkPushManager.urlDefaultsKey)
        XCTAssertTrue(BarkPushManager.isConfigured(defaults))

        defaults.set("   ", forKey: BarkPushManager.urlDefaultsKey)
        XCTAssertFalse(BarkPushManager.isConfigured(defaults))
    }

    func testEmptyURLPostFailsWithoutNetwork() async {
        let suite = "test.bark.empty.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let result = await BarkPushManager.shared.post(title: "t", body: "b", defaults: defaults)
        guard case .failure(let error) = result else {
            return XCTFail("expected failure for empty URL")
        }
        if case .emptyURL = error { return }
        XCTFail("expected emptyURL, got \(error)")
    }

    func testOutputFingerprintIgnoresSurroundingWhitespace() {
        let a = BarkPushManager.outputFingerprint(stdout: "hello\n", stderr: "")
        let b = BarkPushManager.outputFingerprint(stdout: "  hello  ", stderr: "ignored")
        XCTAssertEqual(a, b)
    }

    func testOutputFingerprintChangesWhenStdoutChanges() {
        let a = BarkPushManager.outputFingerprint(stdout: "ok", stderr: "")
        let b = BarkPushManager.outputFingerprint(stdout: "changed", stderr: "")
        XCTAssertNotEqual(a, b)
    }

    func testOutputFingerprintFallsBackToStderrWhenStdoutEmpty() {
        let fromErr = BarkPushManager.outputFingerprint(stdout: "  \n", stderr: "boom")
        let sameErr = BarkPushManager.outputFingerprint(stdout: "", stderr: "boom")
        let fromOut = BarkPushManager.outputFingerprint(stdout: "boom", stderr: "")
        XCTAssertEqual(fromErr, sameErr)
        XCTAssertEqual(fromErr, fromOut)
    }

    func testShouldNotifyOnFirstRunAndOnChangeOnly() {
        let fp1 = BarkPushManager.outputFingerprint(stdout: "v1", stderr: "")
        let fp2 = BarkPushManager.outputFingerprint(stdout: "v2", stderr: "")
        XCTAssertTrue(BarkPushManager.shouldNotifyOnOutputChange(previousFingerprint: nil, currentFingerprint: fp1))
        XCTAssertFalse(BarkPushManager.shouldNotifyOnOutputChange(previousFingerprint: fp1, currentFingerprint: fp1))
        XCTAssertTrue(BarkPushManager.shouldNotifyOnOutputChange(previousFingerprint: fp1, currentFingerprint: fp2))
    }

    func testInvalidURLPostFailsWithoutNetwork() async {
        let suite = "test.bark.invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("https://api.day.app", forKey: BarkPushManager.urlDefaultsKey)
        let result = await BarkPushManager.shared.post(title: "t", body: "b", defaults: defaults)
        guard case .failure(let error) = result else {
            return XCTFail("expected failure for invalid URL")
        }
        if case .invalidURL = error { return }
        XCTFail("expected invalidURL, got \(error)")
    }
}
