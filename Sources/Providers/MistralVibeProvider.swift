import Foundation
import os

/// Reads the monthly Vibe Code allowance of a Le Chat plan (Pro, Team,
/// Student) from the billing endpoints Mistral Vibe's own footer gauge asks,
/// with the API key Vibe stored on sign-in — see `MistralVibeCredentials`.
///
/// The percentage is Mistral's, so this is `.official`. A Vibe key on a plan
/// without a Vibe Code allowance, an API or Codestral key, and an organization
/// member without the `see_org_inference_usage` permission are all readable
/// accounts that meter nothing visible here; Vibe hides its gauge for each of
/// them, and they read as `nothingMetered`, not as errors.
actor MistralVibeProvider: UsageProvider {
    nonisolated let id = "mistral-vibe"
    nonisolated let displayName = "Mistral Vibe"
    nonisolated let glyph = ProviderGlyph.mistral

    private let session: URLSession
    private let loadCredentials: () throws -> MistralVibeCredentials
    private let cache = CredentialCache<MistralVibeCredentials> { _ in false }

    init(session: URLSession = .shared,
         loadCredentials: (() throws -> MistralVibeCredentials)? = nil) {
        self.session = session
        self.loadCredentials = loadCredentials ?? { try MistralVibeCredentials.load() }
    }

    nonisolated var signInRoute: SignInRoute {
        .command("vibe --setup", name: "Mistral Vibe",
                 install: URL(string: "https://github.com/mistralai/mistral-vibe"))
    }

    nonisolated func account() -> ProviderAccount? {
        guard MistralVibeCredentials.isPresent() else { return nil }
        return ProviderAccount(
            label: nil,   // an API key names no one
            plan: nil,
            source: "Mistral Vibe",
            manageURL: URL(string: "https://console.mistral.ai/usage")
        )
    }

    nonisolated func forgetCachedCredential() { cache.forget() }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        let credentials = try cache.value(
            itemModifiedAt: { MistralVibeCredentials.modifiedAt() },
            reload: loadCredentials
        )

        // The plan name is a nicety; the budget is the reading. Both are
        // asked at once, and only the budget's failure fails the fetch.
        async let subscriptionData = try? get(MistralVibeUsage.subscriptionEndpoint,
                                              key: credentials.apiKey)
        let budgetData = try await get(MistralVibeUsage.budgetEndpoint, key: credentials.apiKey)
        Log.usage.debug("mistral vibe budget -> \(String(decoding: budgetData.prefix(400), as: UTF8.self), privacy: .public)")
        let budget = try MistralVibeUsage.budget(fromJSON: budgetData)
        let subscription = await subscriptionData.flatMap(MistralVibeUsage.subscription(fromJSON:))

        var window = budget.window
        // Past 100% with pay-as-you-go on, Vibe Code keeps working and bills
        // the rest — worth saying, since the ring alone reads as "stopped".
        if budget.paygEnabled ?? subscription?.paygEnabled ?? false {
            window = LimitWindow(id: window.id, label: window.label,
                                 usedFraction: window.usedFraction,
                                 detail: L10n.t("Pay-as-you-go beyond the allowance"),
                                 resetsAt: window.resetsAt, duration: window.duration)
        }

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            status: .ok,
            windows: [window],
            headlineID: window.id,
            weeklyID: nil,
            plan: subscription?.plan
        )
    }

    private func get(_ url: URL, key: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        Log.usage.debug("GET api.mistral.ai\(url.path, privacy: .public)")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.usage.debug("mistral \(url.lastPathComponent, privacy: .public) answered \(status)")

        switch status {
        case 200..<300:
            return data
        case 401:
            throw UsageProviderError.needsAuth
        // Vibe's own reading of these two: 403 is a member without the
        // permission to see the organization's usage, 404 a key or platform
        // that does not serve Vibe Code billing.
        case 403:
            throw UsageProviderError.nothingMetered(
                L10n.t("Your Mistral role can't see the organization's Vibe usage"))
        case 404:
            throw UsageProviderError.nothingMetered(L10n.t("No Vibe Code allowance on this account"))
        case 429:
            let retry = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init) ?? 60
            throw UsageProviderError.rateLimited(retryAfter: retry)
        default:
            throw UsageProviderError.badResponse(status: status)
        }
    }
}
