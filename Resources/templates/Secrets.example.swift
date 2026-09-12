//
//  Secrets.example.swift
//  Norra
//
//  Copy to Secrets.swift and fill in. Secrets.swift is gitignored; this
//  template is not, so it must never hold a real value.
//
//  Get these from https://developer.volvocars.com/account/ — create an
//  application to receive a VCC API key immediately. The client id and
//  secret arrive after Volvo's app review (14–21 days); until then the key
//  alone is enough to exercise everything against test credentials.
//
//  Leave any field empty to fall back to the environment or Settings; see
//  VolvoCredentials for the order.
//

enum Secrets {
    static let vccApiKey = ""
    static let clientId = ""
    static let clientSecret = ""
    /// Must match the callback registered with the application exactly.
    /// Norra listens on this port during sign-in and nowhere else.
    static let redirectURI = "http://localhost:9631/callback"
}
