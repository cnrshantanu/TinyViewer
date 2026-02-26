import SwiftUI

@main
struct Tiny_ViewerApp: App {
    var body: some Scene {
        WindowGroup("Tiny Viewer") {
            ContentView()
        }
        .windowResizability(.contentSize)
    }
}
