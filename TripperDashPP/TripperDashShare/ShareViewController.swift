//
//  ShareViewController.swift
//  TripperDashShare  (Share Extension target)
//
//  The "Share to TripperDash++" entry point. Appears in the iOS share
//  sheet for Google Maps / Apple Maps (and anything sharing a URL or a
//  map location). It pulls the shared URL/text out of the extension
//  context, resolves it into waypoints via the SAME SharedDestination
//  Resolver the app uses (this file is a member of BOTH targets), then
//  hands the result to the main app by opening a `tripperdash://` deep
//  link and closing itself. No custom UI — resolve, open, done.
//
//  IMPORTANT target-membership note: SharedDestinationResolver.swift and
//  SharedDeepLink.swift must be added to THIS extension target too (check
//  their File Inspector → Target Membership). They have no UIKit/AppStatus
//  dependency, so they compile cleanly in the extension.
//

import UIKit
import UniformTypeIdentifiers
import os

private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp.share",
                        category: "ShareExtension")

final class ShareViewController: UIViewController {

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await handleShare() }
    }

    private func handleShare() async {
        let (text, url) = await extractPayload()
        log.info("share payload text=\(text ?? "nil", privacy: .public) url=\(url?.absoluteString ?? "nil", privacy: .public)")

        // Reject shares from unsupported apps up front. If the payload carries
        // a URL (directly or embedded in the text) and it isn't a Google/Apple
        // Maps or geo: link, we can't do anything useful with it — tell the
        // rider instead of silently opening the app with junk. A text-only
        // share with no URL (a bare "lat,lon" pair or a place name) still
        // flows through to the resolver as before.
        if let shared = url ?? SharedDestinationResolver.firstURL(in: text),
           !SharedDestinationResolver.isSupportedMapsURL(shared) {
            log.warning("unsupported share source: \(shared.absoluteString, privacy: .public)")
            showUnsupported()
            return
        }

        let resolution = await SharedDestinationResolver.resolve(text: text, url: url)

        // Prefer the fully-resolved deep link. But if the extension couldn't
        // resolve anything (e.g. a short-link redirect that fails under the
        // extension's tighter network sandbox — Apple's maps.apple/p/… is a
        // repeat offender), DON'T give up: hand the raw shared URL to the app
        // via tripperdash://open?url=… . The app runs with a normal network
        // stack and more time, and its handleIncomingURL re-resolves the raw
        // maps URL there. Never a silent dead end.
        let deepLink: URL
        if let encoded = SharedDeepLink.encode(resolution) {
            deepLink = encoded
        } else if let raw = url ?? SharedDestinationResolver.firstURL(in: text),
                  let passthrough = Self.rawURLDeepLink(raw) {
            log.info("extension could not resolve; passing raw URL to app: \(raw.absoluteString, privacy: .public)")
            deepLink = passthrough
        } else {
            log.warning("share resolved to nothing actionable")
            finish()
            return
        }
        // Open the app, THEN finish after a short grace period. Finishing
        // immediately tears the extension down and cancels the launch.
        openMainApp(deepLink)
        try? await Task.sleep(nanoseconds: 400_000_000)
        finish()
    }

    /// Wrap a raw shared maps URL in `tripperdash://open?url=<encoded>` so
    /// the main app can resolve it itself when the extension couldn't.
    private static func rawURLDeepLink(_ raw: URL) -> URL? {
        var comps = URLComponents()
        comps.scheme = SharedDeepLink.scheme
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "url", value: raw.absoluteString)]
        return comps.url
    }

    /// Pull the first URL and/or text string out of every attachment across
    /// every input item. Google Maps typically attaches a URL; some shares
    /// come through as plain text carrying the link.
    private func extractPayload() async -> (text: String?, url: URL?) {
        var foundText: String?
        var foundURL: URL?

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if foundURL == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    foundURL = await loadURL(provider)
                }
                if foundText == nil,
                   provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    foundText = await loadText(provider)
                }
            }
            // A subject/attributedContentText can also hold the label.
            if foundText == nil, let s = item.attributedContentText?.string,
               !s.isEmpty { foundText = s }
        }
        return (foundText, foundURL)
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                if let u = item as? URL { cont.resume(returning: u) }
                else if let d = item as? Data,
                        let s = String(data: d, encoding: .utf8),
                        let u = URL(string: s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    cont.resume(returning: u)
                } else { cont.resume(returning: nil) }
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { cont in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                cont.resume(returning: item as? String)
            }
        }
    }

    /// Open the main app via its custom `tripperdash://` scheme.
    ///
    /// `NSExtensionContext.open` is documented to work only from *Today*
    /// widgets, not Share extensions — from here it silently reports
    /// `false` and does nothing (that was the "dark rectangle flashes,
    /// nothing happens" symptom). The reliable path from a Share extension
    /// is to walk the responder chain, find the live `UIApplication`, and
    /// call its TYPE-SAFE `open(_:options:completionHandler:)`. Casting to
    /// `UIApplication` and calling the real Swift method (rather than an
    /// `objc_msgSend`/IMP hack with a hand-built options dictionary) is
    /// what avoids the earlier `-[__NSDictionary0 universalLinksOnly]`
    /// crash: UIKit builds the correct options object internally.
    private func openMainApp(_ url: URL) {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(url, options: [:]) { ok in
                    log.info("UIApplication.open ok=\(ok) for \(url.absoluteString, privacy: .public)")
                }
                return
            }
            responder = r.next
        }
        log.error("no UIApplication in responder chain for \(url.absoluteString, privacy: .public)")
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// Friendly dead-end for shares from apps we can't parse. Shows a simple
    /// alert explaining only Google Maps / Apple Maps links are supported,
    /// then closes the extension when the rider taps OK. Runs on the main
    /// actor because it touches UIKit.
    @MainActor
    private func showUnsupported() {
        let alert = UIAlertController(
            title: "Unsupported share",
            message: "TripperDash++ can only import places and routes shared "
                + "from Google Maps or Apple Maps. Please share from one of "
                + "those apps.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak self] _ in
            self?.finish()
        })
        present(alert, animated: true)
    }
}
