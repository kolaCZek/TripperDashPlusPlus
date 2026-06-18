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
//  call source view. When PiP starts (auto on background), Apple
//  reparents our MKMapView into the PiP overlay; render loop in
//  MapViewSource keeps ticking via CADisplayLink (which IS allowed
//  in BG when PiP is active). Frames flow normally to the encoder.
//
//  When PiP stops, Apple hands the MKMapView back; we return it to
//  the HUD overlay container so foreground operation is unchanged.
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
    /// AVKit reparents the mapView between this container and the
    /// PiP overlay's view controller.
    private weak var hudContainer: UIView?

    /// AVKit content view controller; its view becomes the PiP
    /// overlay's content. We move mapView in here on willStart.
    private var pipContentVC: AVPictureInPictureVideoCallViewController?

    private var pipController: AVPictureInPictureController?

    /// Required by AVKit: the "source view" pointing at where the
    /// content is in the regular app hierarchy. AVKit uses this
    /// frame to animate the PiP transition. It must be in the view
    /// hierarchy and visible when PiP arms.
    private weak var sourceView: UIView?

    var isPiPActive: Bool {
        pipController?.isPictureInPictureActive ?? false
    }

    /// Wire the controller. Call AFTER both the mapView is fully
    /// initialised AND sourceView is in the view hierarchy with a
    /// non-zero frame. AVKit's PiP arming checks isPictureInPicture-
    /// Possible against the source view's geometry.
    func attach(mapView: MKMapView, sourceView: UIView, hudContainer: UIView) {
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

    // MARK: - Setup

    private func setupPiP() {
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            log.warning("PiP not supported on this device")
            return
        }
        guard let sourceView else {
            log.error("setupPiP called without sourceView")
            return
        }

        // The content VC owns the view that becomes the PiP overlay.
        // We set its preferredContentSize to match the dash native
        // resolution so the PiP bubble has the right aspect ratio.
        let contentVC = AVPictureInPictureVideoCallViewController()
        contentVC.preferredContentSize = CGSize(width: 526, height: 300)
        contentVC.view.backgroundColor = .black
        self.pipContentVC = contentVC

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: contentVC
        )

        let controller = AVPictureInPictureController(contentSource: source)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        // The controlsStyle=1 trick suppresses the playback UI overlay
        // (the play/pause/dismiss controls) since we have no playback.
        // Private KVC but used by every video-call PiP app on GitHub.
        controller.setValue(1, forKey: "controlsStyle")
        self.pipController = controller

        log.info("PiP controller ready (autoFromInline=true, sourceView=\(sourceView.bounds.size.width, privacy: .public)x\(sourceView.bounds.size.height, privacy: .public))")
    }

    /// Manual trigger - for cases where auto-from-inline does not
    /// fire (e.g. when sourceView is too small at background time).
    func startPiP() {
        guard let pipController else { return }
        guard pipController.isPictureInPicturePossible else {
            log.warning("startPiP called but not possible (sourceView in hierarchy? size? layer ready?)")
            return
        }
        if !pipController.isPictureInPictureActive {
            pipController.startPictureInPicture()
        }
    }

    func stopPiP() {
        pipController?.stopPictureInPicture()
    }
}

// MARK: - AVPictureInPictureControllerDelegate

@available(iOS 15.0, *)
extension MapPiPController: AVPictureInPictureControllerDelegate {

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        Task { @MainActor in
            self.log.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.log.info("PiP will start - reparenting MKMapView into PiP overlay")
            self.reparentMapToPiP()
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.log.info("PiP started - MapKit pipeline should now survive screen lock")
        }
    }

    nonisolated func pictureInPictureControllerWillStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.log.info("PiP will stop - reparenting MKMapView back to HUD")
            self.reparentMapToHUD()
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            self.log.info("PiP stopped")
        }
    }

    // MARK: - Reparenting

    private func reparentMapToPiP() {
        guard let mapView, let pipContentVC else { return }
        mapView.removeFromSuperview()
        pipContentVC.view.addSubview(mapView)
        mapView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: pipContentVC.view.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: pipContentVC.view.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: pipContentVC.view.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: pipContentVC.view.bottomAnchor),
        ])
        pipContentVC.view.layoutIfNeeded()
    }

    private func reparentMapToHUD() {
        guard let mapView, let hudContainer else { return }
        mapView.removeFromSuperview()
        hudContainer.addSubview(mapView)
        mapView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            mapView.leadingAnchor.constraint(equalTo: hudContainer.leadingAnchor),
            mapView.trailingAnchor.constraint(equalTo: hudContainer.trailingAnchor),
            mapView.topAnchor.constraint(equalTo: hudContainer.topAnchor),
            mapView.bottomAnchor.constraint(equalTo: hudContainer.bottomAnchor),
        ])
        hudContainer.layoutIfNeeded()
    }
}
