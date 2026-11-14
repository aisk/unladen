// A first start without a configuration file: one is written at the default
// path with a panel token, a client key and Kilo's free model, so that the
// control panel opens, the API is not left to anyone, and a request is
// answered before any account is added.

#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

enum FirstStart {
    /// What a start without a configuration file made up.
    struct Outcome: Sendable, Equatable {
        /// The file written; `nil` when none could be, and `panelToken`
        /// holds for this run alone.
        var path: String?
        /// Why no file was written.
        var problem: String?
        var panelToken: String
        /// The key of client `default`; `nil` when no file was written.
        var clientKey: String?
    }

    /// The name the written client goes by.
    static let clientName = "default"

    /// What serves every model name until the menu says otherwise: Kilo
    /// picks a free model for it, and needs no key.
    static let model = "kilo/kilo-auto/free"

    /// A token of 32 characters, from 24 random bytes.
    static func token() -> String { Base64URL.random(24) }

    /// Writes a configuration file at `path` (`nil`: there is no default
    /// path), its directory created as needed. When the file cannot be
    /// written, the outcome carries a panel token for this run alone and no
    /// client: a key that changes with each start would serve no caller.
    static func create(at path: String?) -> Outcome {
        let panelToken = token()
        guard let path else {
            return Outcome(path: nil, problem: "no default path (set HOME or XDG_CONFIG_HOME)", panelToken: panelToken)
        }
        let clientKey = token()
        do throws(ConfigError) {
            try makeDirectories(URL(fileURLWithPath: path).deletingLastPathComponent().path)
            try ConfigManager.write(text(panelToken: panelToken, clientKey: clientKey), to: path)
        } catch {
            return Outcome(path: nil, problem: error.message, panelToken: panelToken)
        }
        return Outcome(path: path, panelToken: panelToken, clientKey: clientKey)
    }

    /// `mkdir -p`, new directories 0700: the file holds keys.
    private static func makeDirectories(_ path: String) throws(ConfigError) {
        var current = path.hasPrefix("/") ? "" : "."
        for component in path.split(separator: "/") {
            current += "/" + component
            if mkdir(current, 0o700) != 0, errno != EEXIST {
                throw ConfigError(message: "cannot create \(current): \(String(cString: strerror(errno)))")
            }
        }
    }

    /// The file written.
    static func text(panelToken: String, clientKey: String) -> String {
        """
        // Written by unladen on its first start. Edit it here or in the control
        // panel at /admin, which signs in with panel.token. A provider without
        // an account here takes its keys from the environment (ANTHROPIC_API_KEY,
        // OPENAI_API_KEY, ...).
        {
          "panel": { "token": "\(panelToken)" },
          // Kilo's free models need no key, a limited number of requests an hour.
          "accounts": { "kilo": {} },
          // Every model name goes to a free model Kilo picks, until other
          // entries are added.
          "models": { "*": "\(model)" },
          // Callers present a client's key as a Bearer token or x-api-key.
          "clients": {
            "\(clientName)": { "key": "\(clientKey)", "models": "*" }
          }
        }

        """
    }

    /// The notice printed at start, the secrets included: they are shown
    /// this once, and later only the file holds them.
    static func notice(_ outcome: Outcome, host: String, port: Int) -> String {
        let shown = host == "0.0.0.0" || host == "::" || host == "[::]" ? "localhost" : host
        let address = "http://\(shown.contains(":") && !shown.hasPrefix("[") ? "[\(shown)]" : shown):\(port)"
        var lines: [String] = []
        if let path = outcome.path {
            lines.append("No configuration file was found, so unladen wrote one: \(path)")
        } else {
            lines.append("No configuration file was found, and none could be written:")
            lines.append("\(outcome.problem ?? "unknown reason").")
            lines.append("The panel token below holds until the gateway stops.")
        }
        lines.append("")
        lines.append("Control panel: \(address)/admin")
        lines.append("Panel token:   \(outcome.panelToken)" + (outcome.path == nil ? "" : "   (panel.token in the file)"))
        if let key = outcome.clientKey {
            lines.append("API key:       \(key)   (clients.\(clientName) in the file)")
            lines.append("")
            lines.append("Callers present the API key as a Bearer token or x-api-key. Every model")
            lines.append("name is answered by a free model from Kilo (\(model)) until")
            lines.append("accounts and models are added in the panel.")
        }
        let rule = String(repeating: "*", count: 72)
        return "\n" + rule + "\n" + lines.joined(separator: "\n") + "\n" + rule + "\n\n"
    }
}
