//
//  PrerenderProgressView.swift
//  TripperDashPP
//
//  Full-screen progress sheet shown while the route tile cache bakes
//  before navigation can start. The bake takes ~10-20 s for a typical
//  35 km route — long enough to need explicit progress feedback,
//  short enough to not need a cancel button.
//

import SwiftUI

struct PrerenderProgressView: View {
    let progress: Double  // 0.0…1.0

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

                Text("Cache for navigating with the phone locked.")
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
            }
        }
    }
}
