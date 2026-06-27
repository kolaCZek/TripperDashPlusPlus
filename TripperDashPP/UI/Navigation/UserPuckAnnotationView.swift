//
//  UserPuckAnnotationView.swift
//  TripperDashPP
//
//  Custom MKUserLocation view that draws Apple's blue dot PLUS a
//  heading "cone" (the translucent wedge that shows which way the
//  rider is facing) on a north-up map.
//
//  Why custom: MapKit only renders its built-in heading cone when the
//  map is in `.followWithHeading` user-tracking mode — but that mode
//  also rotates the whole map, which the picker deliberately does NOT
//  do (it's locked north-up). So we replace the system puck with our
//  own look-alike: a blue dot with a white ring + soft shadow, and a
//  separately-rotating cone underneath it.
//
//  Because the map never rotates, the cone's on-screen rotation equals
//  the device's true heading measured clockwise from north (0° = up).
//  We rotate only the cone layer; the dot stays put.
//

import MapKit
import UIKit

final class UserPuckAnnotationView: MKAnnotationView {

    static let reuseID = "UserPuckAnnotationView"

    /// View is a fixed square big enough to hold the cone at full reach.
    private let side: CGFloat = 120

    /// Rotating container holding the gradient cone (masked to a wedge).
    private let coneContainer = CALayer()
    private let coneGradient = CAGradientLayer()
    private let coneMask = CAShapeLayer()

    /// The blue dot (sits on top, never rotates).
    private let dotLayer = CAShapeLayer()
    private let dotRing = CAShapeLayer()

    /// Cone geometry.
    private let coneHalfAngle: CGFloat = 32 * .pi / 180   // half of the wedge
    private let coneRadius: CGFloat = 52
    private let dotRadius: CGFloat = 9

    /// Latest heading in degrees clockwise from north, or nil to hide
    /// the cone (unknown / uncalibrated). Setting it rotates the cone.
    var headingDegrees: CLLocationDirection? {
        didSet { applyHeading() }
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        setup()
    }

    private func setup() {
        frame = CGRect(x: 0, y: 0, width: side, height: side)
        // Let touches fall through to the map (tap-to-drop-pin must keep
        // working even right on the puck). hit-testing is gated by
        // `isUserInteractionEnabled`, NOT `isEnabled` (which only blocks
        // annotation *selection*) — so disable interaction outright and
        // the map's tap recognizer fires even directly over the puck.
        isUserInteractionEnabled = false
        isEnabled = false
        canShowCallout = false
        backgroundColor = .clear
        centerOffset = .zero

        let center = CGPoint(x: side / 2, y: side / 2)

        // --- Cone (rotating) -------------------------------------------
        coneContainer.frame = bounds
        // The wedge fades from solid-ish blue at the dot to transparent at
        // the tip; a vertical (upward) gradient masked by the wedge path
        // gives that falloff. Rotating the whole container rotates both
        // the gradient and its mask together.
        coneGradient.frame = bounds
        coneGradient.colors = [
            UIColor.systemBlue.withAlphaComponent(0.55).cgColor,
            UIColor.systemBlue.withAlphaComponent(0.0).cgColor
        ]
        coneGradient.startPoint = CGPoint(x: 0.5, y: 0.5)   // at the dot
        coneGradient.endPoint   = CGPoint(x: 0.5, y: 0.0)   // straight up

        coneMask.path = wedgePath(center: center).cgPath
        coneMask.fillColor = UIColor.black.cgColor
        coneGradient.mask = coneMask

        coneContainer.addSublayer(coneGradient)
        // Rotate around the dot (= container center).
        coneContainer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        coneContainer.frame = bounds
        layer.addSublayer(coneContainer)

        // --- Dot (static) ----------------------------------------------
        let dotPath = UIBezierPath(arcCenter: center, radius: dotRadius,
                                   startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        // White ring slightly larger, behind the blue fill, with a soft
        // drop shadow — mirrors the system puck.
        dotRing.path = UIBezierPath(arcCenter: center, radius: dotRadius + 3,
                                    startAngle: 0, endAngle: 2 * .pi, clockwise: true).cgPath
        dotRing.fillColor = UIColor.white.cgColor
        dotRing.shadowColor = UIColor.black.cgColor
        dotRing.shadowOpacity = 0.35
        dotRing.shadowRadius = 3
        dotRing.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(dotRing)

        dotLayer.path = dotPath
        dotLayer.fillColor = UIColor.systemBlue.cgColor
        layer.addSublayer(dotLayer)

        applyHeading()
    }

    /// Wedge path: tip at the dot center, opening straight up, spanning
    /// ±`coneHalfAngle`. UIKit angles are clockwise with 0 at +x, so
    /// "up" is -90°.
    private func wedgePath(center: CGPoint) -> UIBezierPath {
        let up = -CGFloat.pi / 2
        let path = UIBezierPath()
        path.move(to: center)
        path.addArc(withCenter: center,
                    radius: coneRadius,
                    startAngle: up - coneHalfAngle,
                    endAngle: up + coneHalfAngle,
                    clockwise: true)
        path.close()
        return path
    }

    private func applyHeading() {
        guard let deg = headingDegrees, deg >= 0 else {
            coneContainer.isHidden = true
            return
        }
        coneContainer.isHidden = false
        // North-up map → on-screen rotation == compass heading. UIKit
        // positive rotation is clockwise (y grows down), which matches
        // compass convention, so no sign flip. No implicit animation so
        // the cone tracks heading crisply rather than lagging.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        coneContainer.setAffineTransform(CGAffineTransform(rotationAngle: deg * .pi / 180))
        CATransaction.commit()
    }
}
