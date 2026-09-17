import XCTest
@testable import OpenCode_Bar

final class OpenCodeGoProviderTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

        override static func canInit(with request: URLRequest) -> Bool {
            true
        }

        override static func canonicalRequest(for request: URLRequest) -> URLRequest {
            request
        }

        override func startLoading() {
            guard let handler = MockURLProtocol.requestHandler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            do {
                let (response, data) = try handler(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testProviderIdentifier() {
        let provider = OpenCodeGoProvider()
        XCTAssertEqual(provider.identifier, .openCodeGo)
    }

    func testProviderType() {
        let provider = OpenCodeGoProvider()
        XCTAssertEqual(provider.type, .quotaBased)
    }

    func testDashboardUsageParserReadsEscapedUsageWindows() throws {
        let html = #"""
        <script>
        self.__next_f.push([1,"{\"rollingUsage\":{\"usagePercent\":12.5,\"resetInSec\":3600},\"weeklyUsage\":{\"usagePercent\":\"25\",\"resetInSec\":\"7200\"},\"monthlyUsage\":{\"usagePercent\":50,\"resetInSec\":10800}}"])
        </script>
        """#
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let usage = try OpenCodeGoProvider.parseDashboardUsageHTML(html, now: now)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 25.0, accuracy: 0.001)
        XCTAssertEqual(usage.monthly?.usagePercent ?? -1, 50.0, accuracy: 0.001)
        XCTAssertEqual(usage.rolling?.resetDate, now.addingTimeInterval(3_600))
        XCTAssertEqual(usage.weekly?.resetDate, now.addingTimeInterval(7_200))
        XCTAssertEqual(usage.monthly?.resetDate, now.addingTimeInterval(10_800))
    }

    func testDashboardUsageParserReadsSolidResourceReferences() throws {
        let html = #"""
        <script>
        $R[24]($R[18],$R[30]={mine:!0,useBalance:!0,rollingUsage:$R[31]={status:"ok",resetInSec:18000,usagePercent:0},weeklyUsage:$R[32]={status:"ok",resetInSec:162822,usagePercent:31},monthlyUsage:$R[33]={status:"ok",resetInSec:1404782,usagePercent:21}});
        </script>
        """#

        let usage = try OpenCodeGoProvider.parseDashboardUsageHTML(html)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 31, accuracy: 0.001)
        XCTAssertEqual(usage.monthly?.usagePercent ?? -1, 21, accuracy: 0.001)
        XCTAssertNotNil(usage.rolling?.resetDate)
    }

    func testDashboardUsageParserKeepsPartialUsageWindows() throws {
        let html = #"""
        <script>
        self.__next_f.push([1,"{\"rollingUsage\":{\"usagePercent\":64,\"resetInSec\":900}}"])
        </script>
        """#

        let usage = try OpenCodeGoProvider.parseDashboardUsageHTML(html)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 64, accuracy: 0.001)
        XCTAssertNil(usage.weekly)
        XCTAssertNil(usage.monthly)
        XCTAssertEqual(usage.missingWindowNames, ["weeklyUsage", "monthlyUsage"])
    }

    func testUsageAPIParserReadsRollingWeeklyMonthlyWindows() throws {
        let json = """
        {"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-09-17T05:42:46.182Z"},"weekly":{"status":"ok","percent":"8","resetsAt":"2026-09-21T00:00:00Z"},"monthly":{"status":"ok","percent":2}}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let usage = try OpenCodeGoProvider.parseUsageAPIJSON(data)

        XCTAssertEqual(usage.rolling?.usagePercent ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(usage.monthly?.usagePercent ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(
            usage.rolling?.resetDate,
            APIValueParser.parseDate(from: "2026-09-17T05:42:46.182Z")
        )
        XCTAssertEqual(
            usage.weekly?.resetDate,
            APIValueParser.parseDate(from: "2026-09-21T00:00:00Z")
        )
        XCTAssertNil(usage.monthly?.resetDate)
        XCTAssertEqual(usage.missingWindowNames, [])
    }

    func testUsageAPIParserThrowsWhenNoWindows() {
        let json = """
        {"usage":{}}
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try OpenCodeGoProvider.parseUsageAPIJSON(data))
    }

    func testUsageAPIParserSkipsNonOkWindows() throws {
        let json = """
        {"usage":{"rolling":{"status":"expired","percent":99,"resetsAt":"2026-09-17T05:42:46Z"},"weekly":{"status":"ok","percent":8,"resetsAt":"2026-09-21T00:00:00Z"}}}
        """
        let data = try XCTUnwrap(json.data(using: .utf8))

        let usage = try OpenCodeGoProvider.parseUsageAPIJSON(data)

        XCTAssertNil(usage.rolling)
        XCTAssertEqual(usage.weekly?.usagePercent ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(usage.missingWindowNames, ["rollingUsage", "monthlyUsage"])
    }

    func testUsageAPIParserThrowsWhenAllWindowsNonOk() {
        let json = """
        {"usage":{"rolling":{"status":"expired","percent":99,"resetsAt":"2026-09-17T05:42:46Z"}}}
        """
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try OpenCodeGoProvider.parseUsageAPIJSON(data))
    }

    func testFetchUsesUsageAPIAndLabelsSource() async throws {
        let session = makeSession()
        let provider = OpenCodeGoProvider(session: session, apiKeyOverride: "test-key")
        let modelsJSON = """
        {"data":[{},{},{}]}
        """
        let usageJSON = """
        {"usage":{"rolling":{"status":"ok","percent":4,"resetsAt":"2026-09-17T05:42:46.182Z"},"weekly":{"status":"ok","percent":8,"resetsAt":"2026-09-21T00:00:00Z"},"monthly":{"status":"ok","percent":2,"resetsAt":"2026-10-15T12:50:56Z"}}}
        """

        MockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer "))
            let body: String
            if url == "https://opencode.ai/zen/go/v1/usage" {
                body = usageJSON
            } else {
                XCTAssertEqual(url, "https://opencode.ai/zen/go/v1/models")
                body = modelsJSON
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let result = try await provider.fetch()

        switch result.usage {
        case .quotaBased(let remaining, let entitlement, let overagePermitted):
            XCTAssertEqual(remaining, 92)
            XCTAssertEqual(entitlement, 100)
            XCTAssertFalse(overagePermitted)
        default:
            XCTFail("Expected quota-based usage")
        }

        XCTAssertEqual(result.details?.fiveHourUsage ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 8, accuracy: 0.001)
        XCTAssertEqual(result.details?.openCodeGoMonthlyUsage ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(result.details?.openCodeGoModelCount, 3)
        XCTAssertEqual(result.details?.authUsageSummary, "OpenCode Go API (zen/go/v1/usage)")
    }

    func testFetchFallsBackToDashboardOnUsageAuthFailure() async throws {
        let session = makeSession()
        let provider = OpenCodeGoProvider(
            session: session,
            apiKeyOverride: "test-key",
            dashboardCandidatesOverride: [
                OpenCodeGoDashboardCredentials(
                    workspaceID: "wrk_TEST",
                    authCookie: "test-cookie",
                    source: "Test Cookies"
                )
            ]
        )
        let dashboardHTML = """
        <script>
        self.__next_f.push([1,"{\\"rollingUsage\\":{\\"usagePercent\\":12,\\"resetInSec\\":3600},\\"weeklyUsage\\":{\\"usagePercent\\":34,\\"resetInSec\\":7200},\\"monthlyUsage\\":{\\"usagePercent\\":56,\\"resetInSec\\":10800}}"])
        </script>
        """

        MockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            let statusCode: Int
            let body: String
            if url == "https://opencode.ai/zen/go/v1/usage" {
                statusCode = 401
                body = """
                {"type":"error","error":{"type":"AuthError","message":"Unauthorized"}}
                """
            } else if url.contains("/workspace/") {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=test-cookie")
                statusCode = 200
                body = dashboardHTML
            } else {
                statusCode = 200
                body = """
                {"data":[{}]}
                """
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        let result = try await provider.fetch()

        XCTAssertEqual(result.details?.fiveHourUsage ?? -1, 12, accuracy: 0.001)
        XCTAssertEqual(result.details?.sevenDayUsage ?? -1, 34, accuracy: 0.001)
        XCTAssertEqual(result.details?.openCodeGoMonthlyUsage ?? -1, 56, accuracy: 0.001)
        XCTAssertEqual(result.details?.authUsageSummary, "Test Cookies")
    }

    func testFetchChainsApiAndFallbackErrors() async throws {
        let session = makeSession()
        let provider = OpenCodeGoProvider(
            session: session,
            apiKeyOverride: "test-key",
            dashboardCandidatesOverride: []
        )

        MockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            let statusCode = url == "https://opencode.ai/zen/go/v1/usage" ? 500 : 200
            let body = statusCode == 500 ? "Internal Server Error" : """
            {"data":[{}]}
            """
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }

        do {
            _ = try await provider.fetch()
            XCTFail("Expected provider error")
        } catch let error as ProviderError {
            guard case .providerError(let message) = error else {
                XCTFail("Expected providerError, got \(error)")
                return
            }
            XCTAssertTrue(message.contains("usage API failed"), "API failure must be visible: \(message)")
            XCTAssertTrue(message.contains("Dashboard fallback"), "Fallback state must be visible: \(message)")
        }
    }

    func testWorkspaceIDExtractionKeepsRecentOrderAndDeduplicates() {
        let urls = [
            "https://opencode.ai/workspace/wrk_01ABCDEF0123456789ABCDEFG/go",
            "https://opencode.ai/workspace/wrk_01SECOND0123456789ABCDEF/usage",
            "https://opencode.ai/workspace/wrk_01ABCDEF0123456789ABCDEFG/keys",
            "https://opencode.ai/go"
        ]

        XCTAssertEqual(
            OpenCodeGoProvider.extractWorkspaceIDs(from: urls),
            [
                "wrk_01ABCDEF0123456789ABCDEFG",
                "wrk_01SECOND0123456789ABCDEF"
            ]
        )
    }

    func testOpenCodeGoAPIKeyDecodes() throws {
        let json = """
        {
            "opencode-go": {
                "type": "api",
                "key": "opencode-go-test-key"
            }
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        let auth = try JSONDecoder().decode(OpenCodeAuth.self, from: data)

        XCTAssertEqual(auth.openCodeGo?.key, "opencode-go-test-key")
    }
}
