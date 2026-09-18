import SwiftUI
import UniformTypeIdentifiers

struct SandboxView: View {
    @ObservedObject var model: SandboxViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var isChoosingModel = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .center, spacing: 16) {
                        Image("InferPeerLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 104, height: 104)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("InferPeer Sandbox")
                                .font(.headline)
                            Label(model.platformLabel, systemImage: model.platformSystemImage)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text("Platform identity")
                }

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
                    Button("Choose pinned model folder") {
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

                Section("Physical-device cluster") {
                    Text(model.clusterStatus)
                        .font(.caption)
                }
            }
            .navigationTitle("InferPeer Sandbox")
        }
        .task {
            model.runChecks()
            model.runBundledModel()
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
