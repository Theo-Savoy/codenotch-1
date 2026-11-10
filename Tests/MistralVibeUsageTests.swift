import XCTest
@testable import Codenotch

/// The billing reads behind Vibe's footer gauge, in the shapes
/// `mistral-vibe` 3.1 validates them against (`vibe/app_server/_billing.py`).
final class MistralVibeUsageTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testReadsThePercentageAsAFractionWithItsReset() throws {
        let budget = try MistralVibeUsage.budget(fromJSON: data(
            #"{"vibe_budget":{"usage_percentage":40,"initial_budget":15.0,"reset_at":"2026-12-01T00:00:00Z","payg_enabled":false}}"#))
        XCTAssertEqual(budget.window.id, "monthly")
        XCTAssertEqual(budget.window.usedFraction ?? -1, 0.40, accuracy: 1e-9)
        XCTAssertEqual(budget.window.resetsAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
        XCTAssertNil(budget.window.duration)
        XCTAssertEqual(budget.paygEnabled, false)
    }

    func testPayAsYouGoCanCarryUsagePastTheAllowance() throws {
        let budget = try MistralVibeUsage.budget(fromJSON: data(
            #"{"vibe_budget":{"usage_percentage":112.5,"initial_budget":15,"payg_enabled":true}}"#))
        XCTAssertEqual(budget.window.usedFraction ?? -1, 1.125, accuracy: 1e-9)
        XCTAssertEqual(budget.paygEnabled, true)
    }

    func testANegativePercentageIsHeldAtZero() throws {
        let budget = try MistralVibeUsage.budget(fromJSON: data(
            #"{"vibe_budget":{"usage_percentage":-3,"initial_budget":15}}"#))
        XCTAssertEqual(budget.window.usedFraction, 0)
        XCTAssertNil(budget.paygEnabled)
    }

    func testReadsPythonsZonelessTimestampsAsUTC() throws {
        let budget = try MistralVibeUsage.budget(fromJSON: data(
            #"{"vibe_budget":{"usage_percentage":1,"initial_budget":15,"reset_at":"2026-12-01T00:00:00.000000"}}"#))
        XCTAssertEqual(budget.window.resetsAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testNoBudgetOrNoAllowanceMetersNothing() {
        for json in [#"{}"#, #"{"vibe_budget":null}"#,
                     #"{"vibe_budget":{"usage_percentage":0,"initial_budget":0}}"#] {
            XCTAssertThrowsError(try MistralVibeUsage.budget(fromJSON: data(json))) { error in
                guard case UsageProviderError.nothingMetered = error else {
                    return XCTFail("\(json): expected nothingMetered, got \(error)")
                }
            }
        }
    }

    func testGarbageIsABadResponse() {
        XCTAssertThrowsError(try MistralVibeUsage.budget(fromJSON: data("not json"))) { error in
            guard case UsageProviderError.badResponse = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try MistralVibeUsage.budget(fromJSON: data(
            #"{"vibe_budget":{"initial_budget":15}}"#))) { error in
            guard case UsageProviderError.badResponse = error else { return XCTFail("\(error)") }
        }
    }

    func testNamesPlansTheWayVibeDoes() {
        XCTAssertEqual(MistralVibeUsage.subscription(fromJSON: data(
            #"{"plan_name":"INDIVIDUAL","vibe_payg_enabled":true}"#)),
            .init(plan: "Pro", paygEnabled: true))
        XCTAssertEqual(MistralVibeUsage.planTitle("team"), "Team")
        XCTAssertEqual(MistralVibeUsage.planTitle("EDU"), "Student")
        XCTAssertEqual(MistralVibeUsage.planTitle("ENTERPRISE"), "Enterprise")
        XCTAssertNil(MistralVibeUsage.planTitle("  "))
    }
}

final class MistralVibeCredentialsTests: XCTestCase {
    private func envFile(_ text: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vibe-env-\(UUID().uuidString)")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private let missing = URL(fileURLWithPath: "/nonexistent/vibe/.env")

    func testTheEnvironmentWinsOverEverythingElse() throws {
        let file = try envFile("MISTRAL_API_KEY=from-file\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let credentials = try MistralVibeCredentials.load(
            environment: ["MISTRAL_API_KEY": "from-env"], envFile: file, keychain: { "from-keychain" })
        XCTAssertEqual(credentials, .init(apiKey: "from-env", source: .environment))
    }

    func testTheEnvFileWinsOverTheKeychain() throws {
        let file = try envFile("# vibe\nOTHER=1\nMISTRAL_API_KEY='from-file'\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let credentials = try MistralVibeCredentials.load(
            environment: [:], envFile: file, keychain: { "from-keychain" })
        XCTAssertEqual(credentials, .init(apiKey: "from-file", source: .envFile))
    }

    func testFallsBackToTheKeychain() throws {
        let credentials = try MistralVibeCredentials.load(
            environment: [:], envFile: missing, keychain: { "from-keychain\n" })
        XCTAssertEqual(credentials, .init(apiKey: "from-keychain", source: .keychain))
    }

    func testTheOIDCMarkerIsNotAKey() {
        XCTAssertThrowsError(try MistralVibeCredentials.load(
            environment: ["MISTRAL_API_KEY": "vibe-cli-oidc"], envFile: missing,
            keychain: { "vibe-cli-oidc" })) { error in
            guard case UsageProviderError.needsAuth = error else { return XCTFail("\(error)") }
        }
    }

    func testNothingAnywhereIsNeedsAuth() {
        XCTAssertThrowsError(try MistralVibeCredentials.load(
            environment: [:], envFile: missing, keychain: { nil })) { error in
            guard case UsageProviderError.needsAuth = error else { return XCTFail("\(error)") }
        }
    }

    func testVibeHomeMovesTheEnvFile() {
        XCTAssertEqual(MistralVibeCredentials.envFileURL(environment: ["VIBE_HOME": "/tmp/vh"]).path,
                       "/tmp/vh/.env")
    }

    func testDotenvParsing() {
        let text = """
        export MISTRAL_API_KEY="quoted"
        MISTRAL_API_KEY_OLD=nope
        # MISTRAL_API_KEY=commented
        MISTRAL_API_KEY = last # trailing comment
        """
        XCTAssertEqual(MistralVibeCredentials.dotenvValue("MISTRAL_API_KEY", in: text), "last")
        XCTAssertNil(MistralVibeCredentials.dotenvValue("MISSING", in: text))
    }
}

final class MistralVibeProviderTests: XCTestCase {
    private func provider(_ handler: @escaping (URLRequest) throws -> (Int, Data)) -> MistralVibeProvider {
        MistralVibeStubProtocol.handler = handler
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MistralVibeStubProtocol.self]
        return MistralVibeProvider(session: URLSession(configuration: config),
                                   loadCredentials: { .init(apiKey: "sk-test", source: .keychain) },
                                   credentialsModifiedAt: { nil })
    }

    private func budget(_ percent: Double, payg: Bool = false) -> Data {
        Data(#"{"vibe_budget":{"usage_percentage":\#(percent),"initial_budget":15,"payg_enabled":\#(payg)}}"#.utf8)
    }

    func testANewKeyIsPickedUpWhenTheKeychainItemChanges() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MistralVibeStubProtocol.self]
        var key = "sk-old"
        var stamp = Date(timeIntervalSince1970: 1)
        var sent: [String] = []
        MistralVibeStubProtocol.handler = { request in
            sent.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
            return (200, self.budget(10))
        }
        let provider = MistralVibeProvider(session: URLSession(configuration: config),
                                           loadCredentials: { .init(apiKey: key, source: .keychain) },
                                           credentialsModifiedAt: { stamp })
        _ = try await provider.fetchSnapshot()
        key = "sk-new"
        _ = try await provider.fetchSnapshot()   // same stamp: the held key
        stamp = Date(timeIntervalSince1970: 2)
        _ = try await provider.fetchSnapshot()   // `vibe --setup` rewrote the item
        // Each fetch sends the budget and subscription reads with one key.
        XCTAssertEqual(sent, Array(repeating: "Bearer sk-old", count: 4)
                           + Array(repeating: "Bearer sk-new", count: 2))
    }

    func testARefusedKeyIsDroppedSoTheNextFetchRereadsIt() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MistralVibeStubProtocol.self]
        var key = "sk-revoked"
        MistralVibeStubProtocol.handler = { request in
            request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-revoked"
                ? (401, Data()) : (200, self.budget(10))
        }
        let provider = MistralVibeProvider(session: URLSession(configuration: config),
                                           loadCredentials: { .init(apiKey: key, source: .keychain) },
                                           credentialsModifiedAt: { nil })
        do { _ = try await provider.fetchSnapshot(); XCTFail("401 should throw") } catch {}
        key = "sk-valid"
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.headline?.usedFraction ?? -1, 0.10, accuracy: 1e-9)
    }

    func testPayAsYouGoPastTheAllowanceIsCriticalNotExhausted() async throws {
        let over = try await provider { _ in (200, self.budget(112, payg: true)) }.fetchSnapshot()
        XCTAssertEqual(over.headline?.bandOverride, .critical)
        let under = try await provider { _ in (200, self.budget(50, payg: true)) }.fetchSnapshot()
        XCTAssertNil(under.headline?.bandOverride)
        let stopped = try await provider { _ in (200, self.budget(100)) }.fetchSnapshot()
        XCTAssertNil(stopped.headline?.bandOverride)
    }

    func testBuildsAMonthlySnapshotWithThePlan() async throws {
        let snapshot = try await provider { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
            switch request.url?.path {
            case "/v1/billing/budget":
                return (200, Data(#"{"vibe_budget":{"usage_percentage":62,"initial_budget":15,"payg_enabled":true}}"#.utf8))
            case "/v1/billing/subscription":
                return (200, Data(#"{"plan_name":"INDIVIDUAL"}"#.utf8))
            default:
                return (500, Data())
            }
        }.fetchSnapshot()
        XCTAssertEqual(snapshot.id, "mistral-vibe")
        XCTAssertEqual(snapshot.fidelity, .official)
        XCTAssertEqual(snapshot.plan, "Pro")
        XCTAssertEqual(snapshot.headline?.usedFraction ?? -1, 0.62, accuracy: 1e-9)
        XCTAssertNotNil(snapshot.headline?.detail)
    }

    func testAFailedSubscriptionReadStillGivesTheBudget() async throws {
        let snapshot = try await provider { request in
            request.url?.path == "/v1/billing/budget"
                ? (200, Data(#"{"vibe_budget":{"usage_percentage":5,"initial_budget":15}}"#.utf8))
                : (404, Data())
        }.fetchSnapshot()
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.headline?.detail)
    }

    func testStatusCodesMapToHonestStates() async {
        let cases: [(Int, (UsageProviderError) -> Bool)] = [
            (401, { if case .needsAuth = $0 { return true }; return false }),
            (403, { if case .nothingMetered = $0 { return true }; return false }),
            (404, { if case .nothingMetered = $0 { return true }; return false }),
            (429, { if case .rateLimited = $0 { return true }; return false }),
            (500, { if case .badResponse(500) = $0 { return true }; return false }),
        ]
        for (status, matches) in cases {
            do {
                _ = try await provider { _ in (status, Data()) }.fetchSnapshot()
                XCTFail("\(status) should have thrown")
            } catch let error as UsageProviderError {
                XCTAssertTrue(matches(error), "\(status) -> \(error)")
            } catch {
                XCTFail("\(status) -> \(error)")
            }
        }
    }
}

private final class MistralVibeStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!,
                statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
