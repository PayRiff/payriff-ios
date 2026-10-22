import SwiftUI

@main
struct PayriffExampleApp: App {
    @StateObject private var model = ExampleModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
    }
}
