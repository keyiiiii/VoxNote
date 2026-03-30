import SwiftUI

@main
struct VoxNoteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowResizability(.contentSize)
        .commands {
            // 「新規」メニューを非表示
            CommandGroup(replacing: .newItem) {}
        }
    }
}
