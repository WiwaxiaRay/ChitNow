//
//  thenowApp.swift
//  thenow Watch App
//
//  Created by 大慈大悲無寿耶和華 on 2026/06/08.
//

import SwiftUI

@main
struct thenow_Watch_AppApp: App {
    init() {
        WatchSessionManager.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
