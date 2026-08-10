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

    /// Open the main app via its custom scheme. Share extensions can't
    /// touch UIApplication.shared, and the old `openURL:` responder-chain
    /// trick is HARD-BLOCKED on iOS 18 ("BUG IN CLIENT OF UIKIT … Force
    /// returning false"). Two routes that still work, tried in order:
    ///   1. NSExtensionContext.open — the sanctioned API; returns success.
    ///   2. Responder-chain `openURL:options:completionHandler:` (the
    ///      non-deprecated 3-arg selector) invoked via its IMP.
    /// Returns whether the app was opened.
    @MainActor
    @discardableResult
    private func openMainApp(_ url: URL) async -> Bool {
        // Route 1 — NSExtensionContext.open.
        if let ctx = extensionContext {
            let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                ctx.open(url) { success in cont.resume(returning: success) }
            }
            if ok {
                log.info("opened via extensionContext: \(url.absoluteString, privacy: .public)")
                return true
            }
        }

        // Route 2 — responder chain, non-deprecated selector via IMP.
        let selector = sel_registerName("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: selector), let method = r.method(for: selector) {
                typealias OpenFn = @convention(c)
                    (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let fn = unsafeBitCast(method, to: OpenFn.self)
                fn(r, selector, url as NSURL, NSDictionary(), nil)
                log.info("opened via responder chain: \(url.absoluteString, privacy: .public)")
                return true
            }
            responder = r.next
        }

        log.error("could not open \(url.absoluteString, privacy: .public)")
        return false
    }

    private func finish() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }
}
