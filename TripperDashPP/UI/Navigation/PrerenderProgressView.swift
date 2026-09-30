//
//  PrerenderProgressView.swift
//  TripperDashPP
//
//  Full-screen progress sheet shown while the route tile cache bakes
//  right after navigation starts (the stream is already live; see
//  MapPickerView.prerenderRouteTiles). The bake takes ~10-20 s for a typical
//  35 km route — long enough to need explicit progress feedback. On a weak
//  signal it can take much longer, so "Continue" dismisses the cover (the
//  bake keeps running and the dash keeps its map) to uncover the HUD.
//

import SwiftUI

struct PrerenderProgressView: View {
    let progress: Double  // 0.0…1.0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 24) {
                Image(systemName: "map.fill")
                    .font(.system(size: 48, weight: .regular))
                    .foregroundStyle(.white)

                Text("Downloading map tiles")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)

                Text("Caching tiles ahead so the map still works with no signal.")
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: 280)

                Text(String(format: "%.0f %%", min(max(progress, 0), 1) * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))

                Button("Continue") { dismiss() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        }
    }
}
