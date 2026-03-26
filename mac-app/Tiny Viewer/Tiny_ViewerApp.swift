import SwiftUI

@main
struct Tiny_ViewerApp: App {
    var body: some Scene {
        MenuBarExtra {
            ContentView()
        } label: {
            Image(systemName: "display")
        }
        .menuBarExtraStyle(.window)
    }
}
