import Foundation

/// The Mistral API key Mistral Vibe signs its requests with.
///
/// Vibe resolves `MISTRAL_API_KEY` in this order, and so does this: the
/// process environment (which Vibe fills from `$VIBE_HOME/.env` at start-up,
/// so the file counts as environment), then the OS keyring. On macOS the
/// keyring write is `security add-generic-password -s ai.mistral.vibe -a
/// MISTRAL_API_KEY -A` — `-A` puts every application on the item's access
/// list, so reading it raises no dialogue. `vibe` is the service name used
/// before the rename; Vibe still reads it, and migrates it on the way.
///
/// The browser sign-in has a second mode, CLI OIDC, where the stored "key" is
/// the marker `vibe-cli-oidc` and the real ID token lives elsewhere. That
/// marker is not a credential this app can send, so it reads as signed out
/// rather than as a key that will be refused.
struct MistralVibeCredentials: Equatable {
    static let envKey = "MISTRAL_API_KEY"
    static let keychainServices = ["ai.mistral.vibe", "vibe"]
    static let oidcMarker = "vibe-cli-oidc"

    enum Source: Equatable {
        case environment
        case envFile
        case keychain
    }

    let apiKey: String
    let source: Source

    /// `VIBE_HOME` moves the whole data root, so the path honours it.
    static func vibeHome(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["VIBE_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".vibe")
    }

    static func envFileURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        vibeHome(environment: environment).appendingPathComponent(".env")
    }

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment,
                     envFile: URL? = nil,
                     keychain: () -> String? = readKeychain) throws -> MistralVibeCredentials {
        if let key = usable(environment[envKey]) {
            return MistralVibeCredentials(apiKey: key, source: .environment)
        }
        let file = envFile ?? envFileURL(environment: environment)
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let key = usable(dotenvValue(envKey, in: text)) {
            return MistralVibeCredentials(apiKey: key, source: .envFile)
        }
        if let key = usable(keychain()) {
            return MistralVibeCredentials(apiKey: key, source: .keychain)
        }
        throw UsageProviderError.needsAuth
    }

    static func readKeychain() -> String? {
        for service in keychainServices {
            if let value = KeychainItem.read(service: service, account: envKey) { return value }
        }
        return nil
    }

    /// When the keychain item or the `.env` file last changed — read without
    /// touching the secret, so `CredentialCache` can ask freely.
    static func modifiedAt(environment: [String: String] = ProcessInfo.processInfo.environment) -> Date? {
        let fileMod = (try? FileManager.default.attributesOfItem(
            atPath: envFileURL(environment: environment).path))?[.modificationDate] as? Date
        let keychainMod = KeychainItem.modifiedAt(services: keychainServices, account: envKey)
        return [fileMod, keychainMod].compactMap { $0 }.max()
    }

    /// Whether Vibe looks signed in, without reading any secret.
    static func isPresent(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if usable(environment[envKey]) != nil { return true }
        if let text = try? String(contentsOf: envFileURL(environment: environment), encoding: .utf8),
           usable(dotenvValue(envKey, in: text)) != nil {
            return true
        }
        return KeychainItem.newest(services: keychainServices, account: envKey) != nil
    }

    private static func usable(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value != oidcMarker
        else { return nil }
        return value
    }

    /// The subset of dotenv that `python-dotenv`'s `set_key` writes: `KEY=value`,
    /// optionally `export`-prefixed and single- or double-quoted. The last
    /// assignment wins, as it does when dotenv loads the file.
    static func dotenvValue(_ key: String, in text: String) -> String? {
        var found: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst("export ".count)) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == key else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "'" || quote == "\"" {
                value.removeFirst()
                if let end = value.firstIndex(of: quote) { value = String(value[..<end]) }
            } else if let comment = value.range(of: " #") {
                value = String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            found = value
        }
        return found
    }
}
