import Foundation
import os.log

private let logger = Logger(subsystem: "com.opencodeproviders", category: "OpenCodeGoProvider")

struct OpenCodeGoUsageWindow: Equatable {
    let usagePercent: Double
    let resetDate: Date?
}

struct OpenCodeGoUsage: Equatable {
    let rolling: OpenCodeGoUsageWindow?
    let weekly: OpenCodeGoUsageWindow?
    let monthly: OpenCodeGoUsageWindow?

    var usagePercents: [Double] {
        [rolling?.usagePercent, weekly?.usagePercent, monthly?.usagePercent].compactMap { $0 }
    }

    var missingWindowNames: [String] {
        var names: [String] = []
        if rolling == nil { names.append("rolling") }
        if weekly == nil { names.append("weekly") }
        if monthly == nil { names.append("monthly") }
        return names
    }
}

private struct OpenCodeGoUsageAPIResponse: Decodable {
    struct Window: Decodable {
        let status: String?
        let percent: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case status
            case percent
            case resetsAt
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decodeIfPresent(String.self, forKey: .status)
            if let value = try? container.decode(Double.self, forKey: .percent) {
                percent = value
            } else if let text = try? container.decode(String.self, forKey: .percent) {
                percent = Double(text)
            } else {
                percent = nil
            }
            resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        }
    }

    let usage: [String: Window]
}

enum OpenCodeGoAPI {
    static let modelsURL = URL(string: "https://opencode.ai/zen/go/v1/models")!
    static let usageURL = URL(string: "https://opencode.ai/zen/go/v1/usage")!
    static let usageSourceLabel = "OpenCode Go API (zen/go/v1/usage)"
}

final class OpenCodeGoProvider: ProviderProtocol {
    let identifier: ProviderIdentifier = .openCodeGo
    let type: ProviderType = .quotaBased
    let fetchTimeout: TimeInterval = 15
    let minimumFetchInterval: TimeInterval = 60

    private let tokenManager: TokenManager
    private let session: URLSession
    private let apiKeyOverride: String?

    init(
        tokenManager: TokenManager = .shared,
        session: URLSession = .shared,
        apiKeyOverride: String? = nil
    ) {
        self.tokenManager = tokenManager
        self.session = session
        self.apiKeyOverride = apiKeyOverride
    }

    func fetch() async throws -> ProviderResult {
        logger.info("OpenCode Go fetch started")

        guard let apiKey = apiKeyOverride ?? tokenManager.getOpenCodeGoAPIKey() else {
            logger.error("OpenCode Go API key not found")
            throw ProviderError.authenticationFailed("OpenCode Go API key not available")
        }

        let modelCount = try await fetchModelCount(apiKey: apiKey)
        // The API error propagates with its classification intact so the
        // CLI keeps reporting authentication/network exit codes correctly.
        let usage = try await fetchUsageAPI(apiKey: apiKey)
        let credentialSource = OpenCodeGoAPI.usageSourceLabel
        logger.info("OpenCode Go usage fetched from API")

        let missingWindowNames = usage.missingWindowNames
        if !missingWindowNames.isEmpty {
            logger.warning("OpenCode Go usage from \(credentialSource, privacy: .public) missing window(s): \(missingWindowNames.joined(separator: ", "), privacy: .public)")
        }

        let overallUsed = usage.usagePercents.max() ?? 0
        let aggregateUsedPercent = UsagePercentDisplayFormatter.wholePercent(from: overallUsed)
        let remainingPercent = max(0, 100 - aggregateUsedPercent)

        let quotaUsage = ProviderUsage.quotaBased(
            remaining: remainingPercent,
            entitlement: 100,
            overagePermitted: false
        )

        let authPath = tokenManager.lastFoundAuthPath?.path ?? "~/.local/share/opencode/auth.json"
        let details = DetailedUsage(
            fiveHourUsage: usage.rolling?.usagePercent,
            fiveHourReset: usage.rolling?.resetDate,
            sevenDayUsage: usage.weekly?.usagePercent,
            sevenDayReset: usage.weekly?.resetDate,
            planType: "Go",
            openCodeGoMonthlyUsage: usage.monthly?.usagePercent,
            openCodeGoMonthlyReset: usage.monthly?.resetDate,
            openCodeGoModelCount: modelCount,
            authSource: authPath,
            authUsageSummary: credentialSource
        )

        logger.info(
            "OpenCode Go usage fetched: 5h=\(usage.rolling?.usagePercent.description ?? "n/a", privacy: .public)%, weekly=\(usage.weekly?.usagePercent.description ?? "n/a", privacy: .public)%, monthly=\(usage.monthly?.usagePercent.description ?? "n/a", privacy: .public)%"
        )

        return ProviderResult(usage: quotaUsage, details: details)
    }

    static func parseUsageAPIJSON(_ data: Data) throws -> OpenCodeGoUsage {
        let response: OpenCodeGoUsageAPIResponse
        do {
            response = try JSONDecoder().decode(OpenCodeGoUsageAPIResponse.self, from: data)
        } catch {
            throw ProviderError.decodingError("Unexpected OpenCode Go usage response (\(error.localizedDescription))")
        }

        let usage = OpenCodeGoUsage(
            rolling: apiWindow(response.usage["rolling"]),
            weekly: apiWindow(response.usage["weekly"]),
            monthly: apiWindow(response.usage["monthly"])
        )

        guard !usage.usagePercents.isEmpty else {
            throw ProviderError.decodingError(
                "OpenCode Go usage response contained no usage windows. Please report this issue."
            )
        }

        return usage
    }

    private func fetchUsageAPI(apiKey: String) async throws -> OpenCodeGoUsage {
        var request = URLRequest(url: OpenCodeGoAPI.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await fetchData(request: request)
        return try Self.parseUsageAPIJSON(data)
    }

    private static func apiWindow(_ window: OpenCodeGoUsageAPIResponse.Window?) -> OpenCodeGoUsageWindow? {
        guard let window, let percent = window.percent else { return nil }
        if let status = window.status, status.lowercased() != "ok" {
            logger.warning("OpenCode Go usage window has non-ok status: \(status, privacy: .public)")
            return nil
        }
        return OpenCodeGoUsageWindow(
            usagePercent: percent,
            resetDate: window.resetsAt.flatMap(APIValueParser.parseDate(from:))
        )
    }

    private func fetchModelCount(apiKey: String) async throws -> Int {
        var request = URLRequest(url: OpenCodeGoAPI.modelsURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data = try await fetchData(request: request)
        let object = try JSONSerialization.jsonObject(with: data)

        if let dictionary = object as? [String: Any] {
            if let dataArray = dictionary["data"] as? [Any] {
                return dataArray.count
            }
            if let modelsArray = dictionary["models"] as? [Any] {
                return modelsArray.count
            }
        }

        if let array = object as? [Any] {
            return array.count
        }

        throw ProviderError.decodingError("Unexpected OpenCode Go models response")
    }

    private func fetchData(request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderError.networkError("Invalid response from OpenCode Go")
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let message = errorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
                if httpResponse.statusCode == 401 || httpResponse.statusCode == 403 {
                    throw ProviderError.authenticationFailed(message)
                }
                throw ProviderError.networkError(message)
            }

            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.networkError(error.localizedDescription)
        }
    }

    private func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let message = object["message"] as? String, !message.isEmpty {
                return message
            }
            if let error = object["error"] as? String, !error.isEmpty {
                return error
            }
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String,
               !message.isEmpty {
                return message
            }
        }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
