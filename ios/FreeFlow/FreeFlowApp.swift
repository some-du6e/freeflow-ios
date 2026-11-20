import SwiftUI

@main
struct FreeFlowApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FreeFlow")
                .font(.largeTitle.bold())
            Text("Dictate into any app with the FreeFlow keyboard. Try it in the field below.")
                .foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .accessibilityIdentifier("freeflow.app.testField")
                .accessibilityLabel("Test field")
                .frame(minHeight: 200)
                .padding(8)
                .overlay {
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.4))
                }
            Spacer(minLength: 0)
        }
        .padding()
    }
}
