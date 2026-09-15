import SwiftUI
import UniformTypeIdentifiers

struct SandboxView: View {
    @ObservedObject var model: SandboxViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isChoosingModel = false

    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    LabeledContent("Platform", value: model.platformDescription)
                    LabeledContent("Lifecycle", value: model.lifecycleDescription)
                }

                Section("Automated smoke checks") {
                    ForEach(model.checks) { check in
                        HStack(alignment: .top) {
                            Image(
                                systemName: check.passed
                                    ? "checkmark.circle.fill" : "xmark.circle.fill"
                            )
                            .foregroundStyle(check.passed ? .green : .red)
                            VStack(alignment: .leading) {
                                Text(check.name)
                                Text(check.detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if model.isRunningChecks {
                        ProgressView("Running package checks…")
                    }
                    Button("Run checks again") {
                        model.runChecks()
                    }
                    .disabled(model.isRunningChecks)
                }

                Section("Real local MLX model") {
                    Text(model.modelStatus)
                        .font(.caption)
                    Button("Choose local MLX model") {
                        isChoosingModel = true
                    }
                    .disabled(model.isRunningModel)
                    if model.isRunningModel {
                        ProgressView("Loading and generating offline…")
                    }
                    if !model.generatedText.isEmpty {
                        Text(model.generatedText)
                            .textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("InferPeer Sandbox")
        }
        .task {
            model.runChecks()
        }
        .onChange(of: scenePhase) { _, phase in
            model.handle(phase)
        }
        .fileImporter(
            isPresented: $isChoosingModel,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            model.receiveModelSelection(result)
        }
    }
}
