//
//  SupportView.swift
//  TripperDashPP
//
//  Settings → Support: one-off tips as consumable in-app purchases. A tip
//  unlocks nothing; the app keeps no record of it.
//

import StoreKit
import SwiftUI

enum Tips {
    /// Consumable products in App Store Connect (and `Tips.storekit` for
    /// local runs), smallest first. Names and prices live there, not here.
    static let productIDs = [
        "eu.kolaczek.TripperDashPP.tip.small",
        "eu.kolaczek.TripperDashPP.tip.medium",
        "eu.kolaczek.TripperDashPP.tip.large",
    ]

    /// Finishes tips that complete outside the Support screen (Ask to Buy,
    /// a purchase interrupted by a crash or a payment-method fix), so the
    /// App Store stops re-delivering them. Runs for the app's lifetime.
    static func finishUpdates() async {
        for await update in Transaction.updates {
            if case .verified(let transaction) = update { await transaction.finish() }
        }
    }
}

struct SupportView: View {
    @State private var thanked = false

    var body: some View {
        List {
            Section {
                Text("I'm really glad you like TripperDash++. I build it in my spare time, and every feature is free, with no ads and no tracking. If it makes your rides better, a tip helps me keep it going.")
            }
            Section {
                ForEach(Tips.productIDs, id: \.self) { id in
                    ProductView(id: id) {
                        Image(systemName: Self.icon(for: id))
                            .foregroundStyle(.tint)
                    }
                    .productViewStyle(.compact)
                }
            } footer: {
                Text("A one-off tip. It unlocks nothing, it's simply a thank you.")
            }
        }
        .navigationTitle("Support")
        .onInAppPurchaseCompletion { _, result in
            if case .success(.success(.verified(let transaction))) = result {
                await transaction.finish()
                thanked = true
            }
        }
        .alert("Thank you! ❤️", isPresented: $thanked) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your support means a lot. Ride safe!")
        }
    }

    private static func icon(for id: String) -> String {
        switch id {
        case Tips.productIDs[0]: "cup.and.saucer.fill"
        case Tips.productIDs[1]: "fuelpump"
        default: "fuelpump.fill"
        }
    }
}

#Preview {
    NavigationStack { SupportView() }
}
