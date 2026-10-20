import SwiftUI
import WebKit

/// An OpenID Connect provider's sign-in page (Authentik, Keycloak, Entra ID…). When the provider sends the browser
/// back to the server with a code, that page never loads: the code goes to Proxmox, which signs the user in.
struct OpenIDSignInSheet: View {
    let page: SignInFlow.OpenIDPage
    let realm: String
    /// The server's pinned certificate, for a provider that runs on the Proxmox host itself.
    let fingerprint: String?
    let complete: (_ code: String, _ state: String) -> Void
    let fail: (String) -> Void
    let cancel: () -> Void
    @State private var web: WebPage?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").foregroundStyle(.secondary)
                // Where the password goes, so it can be checked before typing it in.
                Text((web?.url ?? page.url).host() ?? "")
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if web?.isLoading == true { ProgressView().controlSize(.small) }
                Button("Cancel", action: cancel)
            }
            .padding(12)
            Divider()
            if let error {
                ContentUnavailableView("Couldn't open \(realm)", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if let web {
                WebView(web)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 560, height: 700)
        .task { await open() }
    }

    private func open() async {
        var configuration = WebPage.Configuration()
        // Nothing from the provider is kept: the next sign-in starts fresh.
        configuration.websiteDataStore = .nonPersistent()
        let navigation = OpenIDNavigation(trust: CertificateTrust(pinnedFingerprint: fingerprint), redirect: page.redirect) { items in
            if let code = items.first(where: { $0.name == "code" })?.value, let state = items.first(where: { $0.name == "state" })?.value {
                complete(code, state)
            } else {
                fail(items.first { $0.name == "error_description" }?.value ?? items.first { $0.name == "error" }?.value ?? "\(realm) didn't sign you in.")
            }
        }
        let web = WebPage(configuration: configuration, navigationDecider: navigation)
        self.web = web
        do {
            for try await _ in web.load(URLRequest(url: page.url)) {}
        } catch {
            // Turning away the return to the server ends the load with an error; that's the expected way out.
            if !navigation.returned.value, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}

/// Lets the provider's pages load, and catches the browser coming back to the server with the result.
private struct OpenIDNavigation: WebPage.NavigationDeciding {
    let trust: CertificateTrust
    let redirect: String
    let finish: ([URLQueryItem]) -> Void
    let returned = Flag()

    final class Flag {
        var value = false
    }

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        // The provider's own pages may live on the same host; the return is the server's root with a state.
        guard let url = action.request.url, url.absoluteString.hasPrefix(redirect),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false), ["", "/"].contains(components.path),
              let items = components.queryItems, items.contains(where: { $0.name == "state" }) else { return .allow }
        returned.value = true
        finish(items)
        return .cancel
    }

    func decideAuthenticationChallengeDisposition(for challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        trust.decide(challenge)
    }
}
