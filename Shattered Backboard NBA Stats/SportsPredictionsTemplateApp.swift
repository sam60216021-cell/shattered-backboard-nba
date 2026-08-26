//
//  ShatteredBackboardApp.swift — NBA app entry point.
//

import SwiftData
import SwiftUI

@main
struct ShatteredBackboardApp: App {
    @AppStorage("hasOnboarded") private var hasOnboarded = false
    @ObservedObject private var store = StoreKitManager.shared

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if !hasOnboarded {
                    OnboardingView()
                } else {
                    ContentView()
                }
                #else
                if !hasOnboarded {
                    OnboardingView()
                } else if !store.isSubscribed {
                    PaywallView()
                } else {
                    ContentView()
                }
                #endif
            }
            .preferredColorScheme(.dark)
            .modelContainer(AppDatabase.shared.container)
        }
    }
}
