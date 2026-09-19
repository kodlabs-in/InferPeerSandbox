import InferPeerCore
import InferPeerInference
import InferPeerModelStore
import SwiftUI
import UniformTypeIdentifiers

// Each section is a small independent view; keeping them together makes navigation auditable.
// swiftlint:disable file_length

private enum SandboxSection: String, CaseIterable, Identifiable {
    case resources = "Resources"
    case models = "Models"
    case chat = "Chat"
    case transcription = "Transcription"
    case benchmarks = "Benchmarks"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .resources: "cpu"
        case .models: "square.stack.3d.up"
        case .chat: "bubble.left.and.bubble.right"
        case .transcription: "waveform.and.mic"
        case .benchmarks: "gauge.with.dots.needle.67percent"
        }
    }
}

struct SandboxView: View {
    @ObservedObject var validation: SandboxViewModel
    @ObservedObject var resources: SandboxResourceController
    @ObservedObject var models: SandboxModelLibraryController
    @ObservedObject var chat: SandboxChatController
    @ObservedObject var transcription: SandboxTranscriptionController
    @ObservedObject var benchmarks: SandboxBenchmarkController

    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: SandboxSection? = .resources

    var body: some View {
        NavigationSplitView {
            List(SandboxSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationTitle("InferPeer")
            .safeAreaInset(edge: .bottom) {
                logo
            }
        } detail: {
            detail
        }
        .task {
            validation.runChecks()
            await resources.refresh()
            await models.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            validation.handle(phase)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .resources {
        case .resources:
            SandboxResourcesView(
                controller: resources,
                validation: validation
            )
        case .models:
            SandboxModelsView(controller: models)
        case .chat:
            SandboxChatView(controller: chat, installed: models.installed)
        case .transcription:
            SandboxTranscriptionView(
                controller: transcription,
                installed: models.installed
            )
        case .benchmarks:
            SandboxBenchmarksView(
                controller: benchmarks,
                installed: models.installed
            )
        }
    }

    private var logo: some View {
        HStack(spacing: 10) {
            Image("InferPeerLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 32, height: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("InferPeer Sandbox")
                    .font(.caption.weight(.semibold))
                Text(validation.platformLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}

private struct SandboxResourcesView: View {
    @ObservedObject var controller: SandboxResourceController
    @ObservedObject var validation: SandboxViewModel

    var body: some View {
        List {
            Section("Available resources") {
                ForEach(controller.resources) { resource in
                    resourceCard(resource)
                }
            }
            Section("Package validation") {
                ForEach(validation.checks) { check in
                    Label {
                        VStack(alignment: .leading) {
                            Text(check.name)
                            Text(check.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(
                            systemName: check.passed
                                ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                            .foregroundStyle(check.passed ? .green : .red)
                    }
                }
                if validation.isRunningChecks {
                    ProgressView("Running package checks…")
                }
            }
            Section("Status") {
                Text(controller.status)
                LabeledContent("Lifecycle", value: validation.lifecycleDescription)
            }
        }
        .navigationTitle("Resources")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await controller.refresh() }
            }
        }
    }

    private func resourceCard(_ resource: SandboxResourceCard) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(resource.name, systemImage: "checkmark.shield.fill")
                    .font(.headline)
                Spacer()
                Text(resource.execution.rawValue)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(resource.platform + " · " + resource.hardware)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            metric("Physical memory", resource.physicalMemoryBytes)
            metric("Available memory", resource.availableMemoryBytes)
            metric("Model storage", resource.freeStorageBytes)
            Text(resource.chipFeatures.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private func metric(_ title: String, _ bytes: UInt64?) -> some View {
        LabeledContent(title, value: bytes.map(byteCount) ?? "Unavailable")
            .font(.caption)
    }
}

private struct SandboxModelsView: View {
    @ObservedObject var controller: SandboxModelLibraryController

    var body: some View {
        List {
            Section("Signed starter catalog") {
                ForEach(controller.catalog) { model in
                    catalogRow(model)
                }
            }
            Section("Installed and verified") {
                if controller.installed.isEmpty {
                    Text("No model is installed yet.")
                        .foregroundStyle(.secondary)
                }
                ForEach(controller.installed) { model in
                    installedRow(model)
                }
            }
            Section("Activity") {
                Text(controller.status)
                    .font(.caption)
                if let progress = controller.progress {
                    ProgressView(
                        value: Double(progress.totalCompletedBytes),
                        total: Double(progress.totalBytes)
                    )
                    Text(
                        "\(byteCount(progress.totalCompletedBytes)) of "
                            + byteCount(progress.totalBytes)
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Models")
        .toolbar {
            if controller.activeJobID != nil {
                Button("Pause", systemImage: "pause.fill") {
                    controller.pause()
                }
            }
            Button("Refresh", systemImage: "arrow.clockwise") {
                Task { await controller.refresh() }
            }
        }
    }

    private func catalogRow(_ model: SandboxCatalogModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.displayName)
                    .font(.headline)
                Spacer()
                Text(model.status.rawValue.capitalized)
                    .font(.caption.weight(.semibold))
            }
            Text(
                "\(model.task.rawValue) · \(model.runtime) · "
                    + "\(model.format) · \(model.quantization)"
            )
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Text("\(byteCount(model.downloadBytes)) · \(model.support.sandboxTitle)")
                    .font(.caption)
                Spacer()
                Button("Install") {
                    controller.install(model)
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    controller.activeJobID != nil || !model.support.sandboxIsInstallable
                )
            }
        }
        .padding(.vertical, 4)
    }

    private func installedRow(_ model: SandboxInstalledModel) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(model.displayName)
                Text("\(model.runtime) · \(model.format) · \(byteCount(model.installedBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isLoaded {
                Text("Loaded")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            Button("Remove", role: .destructive) {
                controller.remove(model)
            }
        }
    }
}

private struct SandboxChatView: View {
    @ObservedObject var controller: SandboxChatController
    let installed: [SandboxInstalledModel]

    var body: some View {
        Form {
            Section("Exact model and resource") {
                Picker("Model", selection: $controller.selectedModel) {
                    Text("Choose a model").tag(ModelKey?.none)
                    ForEach(installed.filter { $0.tasks.contains(.textGeneration) }) { model in
                        Text(model.displayName).tag(Optional(model.key))
                    }
                }
                LabeledContent("Resource", value: "This device")
            }
            Section("Prompt") {
                TextEditor(text: $controller.prompt)
                    .frame(minHeight: 100)
                HStack {
                    Button("Run") {
                        controller.run(installed: installed)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(installed.isEmpty || controller.isRunning)
                    if controller.isRunning {
                        Button("Cancel", role: .destructive) {
                            controller.cancel()
                        }
                    }
                }
            }
            Section("Streamed output") {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if controller.isRunning {
                    ProgressView()
                }
                Text(controller.output.isEmpty ? "No output yet." : controller.output)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Chat")
    }
}

private struct SandboxTranscriptionView: View {
    @ObservedObject var controller: SandboxTranscriptionController
    let installed: [SandboxInstalledModel]

    @State private var showsImporter = false

    var body: some View {
        Form {
            Section("Exact model and resource") {
                Picker("Model", selection: $controller.selectedModel) {
                    Text("Choose a model").tag(ModelKey?.none)
                    ForEach(installed.filter { $0.tasks.contains(.transcribe) }) { model in
                        Text(model.displayName).tag(Optional(model.key))
                    }
                }
                LabeledContent("Resource", value: "This device")
            }
            Section("Existing audio file") {
                LabeledContent(
                    "Selected",
                    value: controller.audioURL?.lastPathComponent ?? "None"
                )
                Button("Choose Audio", systemImage: "waveform") {
                    showsImporter = true
                }
                HStack {
                    Button("Transcribe") {
                        controller.run(installed: installed)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.audioURL == nil || controller.isRunning)
                    if controller.isRunning {
                        Button("Cancel", role: .destructive) {
                            controller.cancel()
                        }
                    }
                }
            }
            Section("Transcript") {
                Text(controller.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if controller.isRunning {
                    ProgressView()
                }
                Text(controller.transcript.isEmpty ? "No transcript yet." : controller.transcript)
                    .textSelection(.enabled)
            }
        }
        .navigationTitle("Transcription")
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false,
            onCompletion: controller.receive
        )
    }
}

private struct SandboxBenchmarksView: View {
    @ObservedObject var controller: SandboxBenchmarkController
    let installed: [SandboxInstalledModel]

    var body: some View {
        List {
            Section("Deterministic suite") {
                Text(controller.status)
                    .font(.caption)
                Button("Run 3 warm samples") {
                    controller.run(installed: installed)
                }
                .disabled(
                    !installed.contains(where: { $0.tasks.contains(.textGeneration) })
                        || controller.isRunning
                )
                if controller.isRunning {
                    ProgressView("Measuring local runtime…")
                }
            }
            Section("Samples") {
                ForEach(Array(controller.samples.enumerated()), id: \.element.id) { index, sample in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sample \(index + 1)")
                            .font(.headline)
                        LabeledContent("First text", value: seconds(sample.firstTextSeconds))
                        LabeledContent("Total", value: seconds(sample.totalSeconds))
                        LabeledContent(
                            "Throughput",
                            value: String(format: "%.1f tokens/s", sample.tokensPerSecond)
                        )
                        LabeledContent(
                            "Quality floor",
                            value: sample.qualityPassed ? "Passed" : "Failed"
                        )
                    }
                    .font(.caption)
                }
            }
            Section("Physical energy trace") {
                Text(
                    "Use the Release build with Xcode Power Profiler. Rank models only "
                        + "after they pass the same output-quality floor."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Benchmarks")
    }

    private func seconds(_ value: Double?) -> String {
        guard let value else { return "No text" }
        return String(format: "%.3f s", value)
    }
}

private func byteCount(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}
// swiftlint:enable file_length
