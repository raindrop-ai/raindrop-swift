import SwiftUI

@main
struct RaindropTestApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(model.status)
                    .font(.footnote.monospaced())
                    .accessibilityIdentifier("status")
                button("trackAi") { model.trackAi() }
                button("flush") { Task { await model.flush() } }
                button("runInteraction") { Task { await model.runInteraction() } }
                button("trackPII") { Task { await model.trackPII() } }
                button("hotPath") { model.hotPath() }
                button("beginOpen") { model.beginOpen() }
                button("resumeFinish") { Task { await model.resumeFinish() } }
                button("diagnostics") { model.diagnostics() }
            }
            .padding()
        }
    }

    private func button(_ id: String, _ action: @escaping () -> Void) -> some View {
        Button(id, action: action)
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(id)
    }
}
