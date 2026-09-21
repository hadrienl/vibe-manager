import SwiftUI
import VibeUI

@main
struct VibeManagerApp: App {
  @State private var environment = AppEnvironment()

  var body: some Scene {
    WindowGroup {
      RootView(model: environment.appModel)
    }
    .defaultSize(width: 1_180, height: 760)

    Settings {
      Form {
        Text("Settings will be available in a future version.")
          .foregroundStyle(.secondary)
      }
      .padding()
      .frame(width: 420)
    }
  }
}
