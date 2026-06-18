//
//  MapPiPController.swift
//  TripperDashPP
//
//  Phase 8c - VideoCall-style PiP for arbitrary content.
//
//  Why this exists:
//  ----------------
//  Phase 8b proved that mounting MKMapView in our own view hierarchy
//  is not enough - Apple still throttles MapKit rendering when the
//  screen locks, regardless of view-in-hierarchy or PiP-as-process-
//  keepalive. The technical answer (researched against 120 real-world
//  apps using this API on GitHub, including CueCard teleprompter,
//  LiveContainer, and AgoraIO) is to use AVPictureInPictureVideoCall-
//  ViewController instead of playback-style PiP. When PiP starts,
//  Apple PHYSICALLY MOVES our source UIView into the PiP overlay
//  window (which stays VISIBLE even with screen locked). MapKit
//  cannot be throttled because, from its perspective, the map view
//  remains visible to the user the entire time.
//
//  How this fits with MapViewSource:
//  ---------------------------------
//  MapViewSource owns an MKMapView. MapPiPController takes that
//  same MKMapView (via reference) and wires it as the active video
//  call source view. When PiP starts (manually on background), Apple
//  reparents our MKMapView into the PiP overlay; render loop in
//  MapViewSource keeps ticking, frames flow normally to the encoder.
//
//  When PiP stops, Apple hands the MKMapView back; we return it to
//  the HUD overlay container so foreground operation is unchanged.
//
//  Why we trigger PiP manually (not canStartAutomaticallyFromInline):
//  -----------------------------------------------------------------
//  canStartPictureInPictureAutomaticallyFromInline is a playback-PiP
//  affordance; for VideoCall PiP it sets a flag but iOS does not
//  actually auto-start on background. Every real-world VideoCall PiP
//  app (LiveContainer, CueCard, AgoraIO) calls startPictureInPicture
//  explicitly on UIApplication.willResignActiveNotification - the
//  notification fires before the screen locks (and before iOS would
//  freeze the GPU pipeline), giving us a window to trigger PiP.
//
//  No entitlement needed - this is public API since iOS 15.
//

import AVKit
import MapKit
import OSLog
import UIKit

@available(iOS 15.0, *)
@MainActor
final class MapPiPController: NSObject {

    private let log = Logger(subsystem: "eu.kolaczek.tripperdashpp.pip",
                             category: "MapPiP")

    /// The MKMapView that gets reparented between HUD and PiP overlay.
    /// We do not own it; MapViewSource does. We just hold a reference
    /// so the delegate can move it on PiP start/stop.
    private weak var mapView: MKMapView?

    /// The container that hosts the MKMapView when PiP is *not*
    /// active (i.e. when the map should be visible in the HUD).
    private weak var hudContainer: UIView?

    /// AVKit content view controller; its view becomes the PiP
    /// overlay's content. We move mapView in here on willStart.
    private var pipContentVC: AVPictureInPictureVideoCallViewController?

    private var pipController: AVPictureInPictureController?

    /// Required by AVKit: the "source view" pointing at where the
    /// content is in the regular app hierarchy. AVKit uses this
    /// frame to animate the PiP transition.
    private weak var sourceView: UIView?

    /// Observer token for UIApplication.willResignActiveNotification.
    private var willResignObserver: NSObjectProtocol?

    var isPiPActive: Bool {
        pipController?.isPictureInPictureActive ?? false
    }

    override init() {
        super.init()
        registerForBackgroundTrigger()
    }

    deinit {
        if let token = willResignObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func registerForBackgroundTrigger() {
        let nc = NotificationCenter.default
        willResignObserver = nc.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // We're on main queue (via NotificationCenter queue: .main)
            // but the compiler does not know that.
            MainActor.assumeIsolated {
                self?.handleWillResignActive()
            }
        }
    }

    private func handleWillResignActive() {
        guard let controller = pipController else {
            log.warning("willResignActive but pipController is nil - PiP not wired yet")
            return
        }
        let possible = controller.isPictureInPicturePossible
        let active = controller.isPictureInPictureActive
        let svInWindow = (sourceView?.window != nil)
        log.info("willResignActive: possible=\(possible, privacy: .public), active=\(active, privacy: .public), sourceViewInWindow=\(svInWindow, privacy: .public)")
        guard possible, !active else { return }
        log.info("manually starting PiP on willResignActive")
        controller.startPictureInPicture()
    }

    /// Wire the controller. Call as soon as a UIView is in the
    /// hierarchy with a non-zero frame.
    func attach(mapView: MKMapView, sourceView: UIView, hudContainer: UIView) {
        if self.pipController != nil {
            log.debug("attach() called but controller already exists - ignoring")
            return
        }
        self.mapView = mapView
        self.sourceView = sourceView
        self.hudContainer = hudContainer
        setupPiP()
    }

    func detach() {
        pipController?.stopPictureInPicture()
        pipController = nil
        pipContentVC = nil
        mapView = nil
        sourceView = nil
        hudContainer = nil
    }

    /// Proactively start PiP. Call when streaming starts so PiP is
    /// already active before the user locks the screen. Without this,
    /// we rely on willResignActive — which fires too late on some
    /// phones (the app is already moving to background by then and
    /// PiP refuses to start).
    func startPiPNow() {
        guard let controller = pipController else {
            log.warning("startPiPNow: no controller yet, will retry on willResignActive")
            return
        }
        guard controller.isPictureInPicturePossible else {
            log.warning("startPiPNow: PiP not possible (sourceView likely not in window) - will retry on willResignActive")
            return
        }
        guard !controller.isPictureInPictureActive else {
            log.debug("startPiPNow: already active")
            return
        }
        log.info("startPiPNow: starting PiP proactively")
        controller.startPictureInPicture()
    }

    // MARK: - Setup

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log.warning("PiP not supported on this device")
            return
        }
        guard let sourceView = sourceView else {
            log.error("setupPiP() called without sourceView")
            return
        }

        // Configure audio session: PiP requires .playback category.
        // Combined with the SilentAudioKeeper's session this gives us
        // the BG audio mode entitlement-free path AVKit expects.
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback,
                                    options: [.mixWithOthers])
            try session.setActive(true)
            log.debug("AVAudioSession configured for PiP")
        } catch {
            log.error("AVAudioSession setup failed: \(error.localizedDescription, privacy: .public)")
        }

        // The PiP content view controller. Its `view` becomes the
        // PiP overlay's content; AVKit will reparent our mapView
        // into it on willStart.
        let contentVC = AVPictureInPictureVideoCallViewController()
        // 16:9-ish aspect to match our 526x300 source.
        contentVC.preferredContentSize = CGSize(width: 526, height: 300)
        self.pipContentVC = contentVC

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentVC
        )

        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.delegate = self
        // Setting both for safety; auto-from-inline is a no-op on
        // VideoCall PiP but cheap to set; we trigger manually anyway.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pipController = controller

        log.info("PiP controller ready (sourceView=\(sourceView.bounds.width, privacy: .public)x\(sourceView.bounds.height, privacy: .public), possible=\(controller.isPictureInPicturePossible, privacy: .public))")
    }
}

// MARK: - AVPictureInPictureControllerDelegate

@available(iOS 15.0, *)
extension MapPiPController: AVPictureInPictureControllerDelegate {

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                 failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            log.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            log.info("PiP will start - reparenting MKMapView into PiP overlay")
            guard let mapView = self.mapView,
                  let contentVC = self.pipContentVC else {
                log.error("willStart: mapView or contentVC missing")
                return
            }
            // Reset transform (HUD scaled it); fill the PiP overlay.
            mapView.transform = .identity
            mapView.removeFromSuperview()
            contentVC.view.addSubview(mapView)
            mapView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                mapView.topAnchor.constraint(equalTo: contentVC.view.topAnchor),
                mapView.bottomAnchor.constraint(equalTo: contentVC.view.bottomAnchor),
                mapView.leadingAnchor.constraint(equalTo: contentVC.view.leadingAnchor),
                mapView.trailingAnchor.constraint(equalTo: contentVC.view.trailingAnchor),
            ])
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            log.info("PiP started - MapKit pipeline should now survive screen lock")
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            log.info("PiP will stop - returning MKMapView to HUD")
            guard let mapView = self.mapView,
                  let hud = self.hudContainer else { return }
            mapView.removeFromSuperview()
            mapView.translatesAutoresizingMaskIntoConstraints = true
            hud.addSubview(mapView)
            // updateUIView() in MapViewHost will re-apply the scale
            // transform on the next SwiftUI layout pass.
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            log.info("PiP stopped")
        }
    }
}
