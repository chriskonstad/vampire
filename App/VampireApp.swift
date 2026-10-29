import SwiftUI
import Photos

@main
struct VampireApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark) // culling happens in the dark
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.authorizationStatus {
        case .authorized, .limited:
            SessionListView()
                #if DEBUG
                .task { await DevFixtureImporter.importPending() }
                #endif
        case .notDetermined:
            AuthPromptView()
        default:
            ContentUnavailableView(
                "Photo access required",
                systemImage: "photo.on.rectangle.angled",
                description: Text("Vampire culls photos in your library. Grant access in Settings → Privacy → Photos.")
            )
        }
    }
}

private struct AuthPromptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 56))
            Text("Vampire")
                .font(.largeTitle.bold())
            Text("Rip through a shoot. Keep only the immortals.")
                .foregroundStyle(.secondary)
            Button("Open Photo Library") {
                Task { await model.requestAuthorization() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
