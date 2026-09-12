//
//  VolvoCredentials.swift
//  Norra
//
//  Where the Volvo application credentials come from.
//
//  Unlike Polestar — whose client_id is a constant lifted from their own web
//  app — Volvo issues credentials per application, after a manual review, and
//  they are not ours to ship. So they are read at runtime, in this order:
//
//    1. Secrets.swift, if present. Gitignored. The personal-build path:
//       fill it in once and the app just works.
//    2. The environment, for `make run` and CI.
//    3. UserDefaults, which is what Settings writes.
//
//  The order matters. A developer with a Secrets.swift wants it to win over a
//  stale value typed into Settings months ago, and a CI run wants the
//  environment to win over whatever is in the container it inherited.
//

import Foundation

struct VolvoCredentials {
    let vccApiKey: String
    let clientId: String
    let clientSecret: String
    let redirectURI: String

    /// Nothing to talk to Volvo with. Checked before a poll is attempted so
    /// the user gets "open Settings" rather than a stream of 401s.
    var isConfigured: Bool {
        !vccApiKey.isEmpty && !clientId.isEmpty
    }

    static var current: VolvoCredentials {
        let key = value("VOLVO_VCC_API_KEY", "volvo_vcc_api_key", Secrets.vccApiKey)
        let id = value("VOLVO_CLIENT_ID", "volvo_client_id", Secrets.clientId)
        let secret = value("VOLVO_CLIENT_SECRET", "volvo_client_secret", Secrets.clientSecret)
        let redirect = value("VOLVO_REDIRECT_URI", "volvo_redirect_uri", Secrets.redirectURI)
        return VolvoCredentials(vccApiKey: key, clientId: id,
                                clientSecret: secret, redirectURI: redirect)
    }

    private static func value(_ env: String, _ defaultsKey: String, _ compiled: String) -> String {
        if !compiled.isEmpty { return compiled }
        if let fromEnv = ProcessInfo.processInfo.environment[env], !fromEnv.isEmpty { return fromEnv }
        return UserDefaults.standard.string(forKey: defaultsKey) ?? ""
    }

    /// Written by Settings. The secret is deliberately *not* stored here —
    /// it goes to the Keychain alongside the session token, because
    /// UserDefaults is a plist any process running as the user can read.
    static func store(vccApiKey: String, clientId: String, redirectURI: String) {
        let defaults = UserDefaults.standard
        defaults.set(vccApiKey, forKey: "volvo_vcc_api_key")
        defaults.set(clientId, forKey: "volvo_client_id")
        defaults.set(redirectURI, forKey: "volvo_redirect_uri")
    }
}
