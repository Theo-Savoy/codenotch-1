import Foundation

/// Parses the two billing reads Mistral Vibe's own footer gauge is built from
/// (`vibe/app_server/_billing.py` in `mistral-vibe` 3.1):
///
/// `GET https://api.mistral.ai/v1/billing/budget`
/// ```json
/// {"vibe_budget":{"usage_percentage":40.2,"initial_budget":15.0,
///                 "reset_at":"2026-12-01T00:00:00Z","payg_enabled":false}}
/// ```
///
/// `GET https://api.mistral.ai/v1/billing/subscription`
/// ```json
/// {"plan_name":"INDIVIDUAL","vibe_payg_enabled":false}
/// ```
///
/// `usage_percentage` is a percentage, not a ratio: Vibe colours its gauge at
/// 75 and 90 and stops Vibe Code at 100. It can pass 100 when pay-as-you-go
/// carries usage past the allowance. A missing `vibe_budget`, or one with no
/// allowance (`initial_budget <= 0`), is how the API says the key meters no
/// Vibe Code plan — Vibe hides its gauge in that case, and so does this.
enum MistralVibeUsage {
    static let base = URL(string: "https://api.mistral.ai/v1/")!
    static let budgetEndpoint = base.appendingPathComponent("billing/budget")
    static let subscriptionEndpoint = base.appendingPathComponent("billing/subscription")

    struct Budget: Equatable {
        let window: LimitWindow
        let paygEnabled: Bool?
    }

    struct Subscription: Equatable {
        let plan: String?
        let paygEnabled: Bool?
    }

    static func budget(fromJSON data: Data) throws -> Budget {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw UsageProviderError.badResponse(status: 0) }
        guard let detail = root["vibe_budget"] as? [String: Any],
              let allowance = number(detail["initial_budget"]), allowance > 0
        else {
            throw UsageProviderError.nothingMetered(L10n.t("No Vibe Code allowance on this account"))
        }
        guard let percent = number(detail["usage_percentage"]), percent.isFinite
        else { throw UsageProviderError.badResponse(status: 0) }

        let paygEnabled = detail["payg_enabled"] as? Bool
        let resetsAt = (detail["reset_at"] as? String).flatMap(date(from:))
        let window = LimitWindow(
            id: "monthly",
            label: L10n.t("Monthly Vibe Code"),
            usedFraction: max(0, percent) / 100,
            resetsAt: resetsAt,
            // A calendar month is not a fixed length, and the reset date
            // already says where the window ends.
            duration: nil
        )
        return Budget(window: window, paygEnabled: paygEnabled)
    }

    static func subscription(fromJSON data: Data) -> Subscription? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return Subscription(plan: planTitle(root["plan_name"] as? String),
                            paygEnabled: root["vibe_payg_enabled"] as? Bool)
    }

    /// The names Vibe itself shows for each billed plan; anything else is
    /// shown as the account names it rather than guessed at.
    static func planTitle(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        switch name.uppercased() {
        case "FREE": return "Free"
        case "INDIVIDUAL": return "Pro"
        case "EDU": return "Student"
        case "TEAM": return "Team"
        default: return name.capitalized
        }
    }

    private static func number(_ any: Any?) -> Double? {
        if let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.doubleValue
        }
        if let text = any as? String { return Double(text) }
        return nil
    }

    private static func date(from stamp: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: stamp) { return date }
        if let date = ISO8601DateFormatter().date(from: stamp) { return date }
        // Python's `isoformat()` without a zone, read as UTC.
        let naive = DateFormatter()
        naive.locale = Locale(identifier: "en_US_POSIX")
        naive.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss"] {
            naive.dateFormat = format
            if let date = naive.date(from: stamp) { return date }
        }
        return nil
    }
}
