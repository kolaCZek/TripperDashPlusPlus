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

        let resolution = await SharedDestinationResolver.resolve(text: text, url: url)

        if let deepLink = SharedDeepLink.encode(resolution) {
            await openMainApp(deepLink)
        } else {
            log.warning("share resolved to nothing actionable")
        }
        // Always finish — even on empty, the sheet must dismiss.
        finish()
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

    /// Open the main app via its custom scheme. Extensions can't call
    /// UIApplication.shared.open, so walk the responder chain to find an
    /// `open(_:options:completionHandler:)` and invoke it.
    @MainActor
    private func openMainApp(_ url: URL) async {
        var responder: UIResponder? = self
        let selector = sel_registerName("openURL:")
        while let r = responder {
            if r.responds(to: selector) {
                _ = r.perform(selector, with: url)
                log.info("opened main app: \(url.absoluteString, privacy: .public)")
                return
            }
            responder = r.next
        }
        log.error("could not find a responder to open \(url.absoluteString, privacy: .public)")
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
