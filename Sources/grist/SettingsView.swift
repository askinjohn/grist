import SwiftUI
import AppKit

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    var state: NSVisualEffectView.State = .active
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

struct SettingsView: View {
    /// Sheet chrome — fixed so content always scrolls inside, never grows off-screen.
    static let sheetWidth: CGFloat = 720
    static let sheetHeight: CGFloat = 560

    @State private var selectedTab = 0

    private let tabs: [(title: String, icon: String)] = [
        ("General", "gearshape.fill"),
        ("AI Models", "cpu"),
        ("AI Templates", "sparkles.rectangle.stack.fill"),
        ("Integrations", "link"),
    ]

    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // ── Fixed header ───────────────────────────────────────
                HStack(alignment: .center, spacing: 12) {
                    GristIconBadge(systemName: "gearshape.2.fill", tint: .accent, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settings")
                            .font(.title3.weight(.semibold))
                        Text("Workflow, models, search index, integrations")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 32)
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 10)

                // ── Fixed tab bar (all four always visible) ───────────
                HStack(spacing: 6) {
                    ForEach(Array(tabs.enumerated()), id: \.offset) { index, tab in
                        TabButton(
                            title: tab.title,
                            icon: tab.icon,
                            isSelected: selectedTab == index
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = index
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)

                // ── Scrollable content (fills remaining height) ───────
                Group {
                    switch selectedTab {
                    case 0:
                        GeneralSettingsView()
                    case 1:
                        AIModelsSettingsView()
                    case 2:
                        TemplatesSettingsView()
                    default:
                        IntegrationsSettingsView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
            }
        }
        .frame(width: Self.sheetWidth, height: Self.sheetHeight)
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.primary.opacity(0.12) : Color.clear)
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .stroke(isSelected ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

struct GeneralSettingsView: View {
    @AppStorage("autoEnhance") private var autoEnhance = true
    @AppStorage("autoExtractTasks") private var autoExtractTasks = true
    @AppStorage("aiProviderType") private var aiProviderType: String = "Ollama"
    @AppStorage("OllamaURL") private var ollamaURL: String = "http://127.0.0.1:11434"
    
    @AppStorage("openAIBaseURL") private var openAIBaseURL: String = "https://api.openai.com/v1"
    @AppStorage("openAIAPIKey") private var openAIAPIKey: String = ""
    @AppStorage("openAIModel") private var openAIModel: String = "gpt-4o"

    @State private var chunkCount = 0
    @State private var isReindexing = false
    @State private var reindexStatus = ""
    @State private var reindexProgress: (done: Int, total: Int) = (0, 0)
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                
                // Section 1: Workflow
                VStack(alignment: .leading, spacing: 12) {
                    Text("Workflow")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    
                    settingsToggleRow(
                        title: "Auto-Enhance Meetings",
                        subtitle: "Generate AI summaries automatically when recording stops",
                        isOn: $autoEnhance
                    )

                    settingsToggleRow(
                        title: "Auto-extract tasks",
                        subtitle: "After Enhance, pull action items into the Tasks list",
                        isOn: $autoExtractTasks
                    )
                }

                // Library search / RAG
                VStack(alignment: .leading, spacing: 12) {
                    Text("Library search (RAG)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Search index")
                                    .font(.system(size: 16, weight: .medium, design: .rounded))
                                Text(chunkCount == 0
                                     ? "Empty — Ask everything will use keywords only until you rebuild."
                                     : "\(chunkCount) chunks indexed for semantic search.")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                if !reindexStatus.isEmpty {
                                    Text(reindexStatus)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                rebuildIndex()
                            } label: {
                                if isReindexing {
                                    HStack(spacing: 8) {
                                        ProgressView().controlSize(.small)
                                        if reindexProgress.total > 0 {
                                            Text("\(reindexProgress.done)/\(reindexProgress.total)")
                                                .font(.caption.monospacedDigit())
                                        }
                                    }
                                } else {
                                    Text("Rebuild search index")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isReindexing)
                        }

                        Text("Requires local embeddings: `ollama pull nomic-embed-text`. New imports and saves re-index automatically.")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
                .onAppear { chunkCount = Database.shared.chunkCount() }
                
                // Section 2: AI Engine
                VStack(alignment: .leading, spacing: 12) {
                    Text("AI Engine Configuration")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    
                    VStack(spacing: 0) {
                        settingsFieldRow(label: "Provider") {
                            Picker("", selection: $aiProviderType) {
                                Text("Ollama (Local)").tag("Ollama")
                                Text("OpenAI Compatible").tag("OpenAI Compatible")
                            }
                            .labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }

                        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                        if aiProviderType == "Ollama" {
                            settingsFieldRow(label: "Local URL") {
                                TextField("http://127.0.0.1:11434", text: $ollamaURL)
                                    .textFieldStyle(.roundedBorder)
                            }
                        } else {
                            settingsFieldRow(label: "API URL") {
                                TextField("https://api.openai.com/v1", text: $openAIBaseURL)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                            settingsFieldRow(label: "API Key") {
                                SecureField("sk-...", text: $openAIAPIKey)
                                    .textFieldStyle(.roundedBorder)
                            }

                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)

                            settingsFieldRow(label: "Model") {
                                TextField("gpt-4o", text: $openAIModel)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Label + control that wraps on narrow sheets (no fixed control widths).
    @ViewBuilder
    private func settingsFieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                Text(label)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .layoutPriority(1)
                content()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(16)

            VStack(alignment: .leading, spacing: 8) {
                Text(label)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func settingsToggleRow(title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                Text(subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
    }

    private func rebuildIndex() {
        isReindexing = true
        reindexStatus = "Indexing…"
        let meetings = Database.shared.fetchActiveMeetings()
        Task {
            // Poll progress while reindex runs
            let progressTask = Task { @MainActor in
                while !Task.isCancelled {
                    reindexProgress = RAGEngine.shared.reindexProgress
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
            let result = await RAGEngine.shared.reindexAll(meetings: meetings)
            progressTask.cancel()
            await MainActor.run {
                isReindexing = false
                chunkCount = result.chunks
                reindexProgress = (result.items, result.items)
                if let err = result.error {
                    reindexStatus = "Finished with errors: \(err) (\(result.chunks) chunks)"
                } else {
                    reindexStatus = "Indexed \(result.items) items → \(result.chunks) chunks"
                }
            }
        }
    }
}

// MARK: - AI Models (role config + JSON)

struct AIModelsSettingsView: View {
    @ObservedObject private var ai = AIConfigManager.shared
    @State private var showJSON = true
    @State private var draftRoles: [String: AIRoleConfig] = [:]
    @State private var draftBackends: [String: AIBackendConfig] = [:]
    @State private var statusNote = ""

    private var backendNames: [String] {
        Array(ai.config.backends.keys).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("AI models by job")
                        .font(.title3.weight(.semibold))
                    Text("Each feature can use a different model and backend (local Ollama or OpenAI-compatible). Edit the table or the raw JSON below. File: Application Support/Grist/ai-config.json")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Roles table
                VStack(alignment: .leading, spacing: 10) {
                    Text("Roles")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    VStack(spacing: 0) {
                        ForEach(AIRole.allCases) { role in
                            roleRow(role)
                            if role != AIRole.allCases.last {
                                Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
                            }
                        }
                    }
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))

                    HStack {
                        Button("Apply role table") {
                            applyRoleTable()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("Reload from disk") {
                            ai.reloadFromDisk()
                            loadDrafts()
                            statusNote = "Reloaded"
                        }
                        .buttonStyle(.bordered)
                        Spacer()
                    }
                }

                // Backends (compact)
                VStack(alignment: .leading, spacing: 10) {
                    Text("Backends")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(backendNames, id: \.self) { name in
                        backendEditor(name: name)
                    }
                }

                // JSON editor
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Config JSON")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                        Spacer()
                        Toggle("Show", isOn: $showJSON)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    if showJSON {
                        Text("Edit freely — Save writes ai-config.json. Invalid JSON is not applied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $ai.jsonText)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(Color.black.opacity(0.25))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                            )

                        HStack(spacing: 10) {
                            Button("Save JSON") {
                                if ai.saveJSONText() {
                                    loadDrafts()
                                    statusNote = "JSON saved"
                                } else {
                                    statusNote = "JSON error: \(ai.lastError ?? "?")"
                                }
                            }
                            .buttonStyle(.borderedProminent)

                            Button("Pretty format") {
                                if let pretty = AIConfigManager.prettyJSON(ai.config) {
                                    ai.jsonText = pretty
                                }
                            }
                            .buttonStyle(.bordered)

                            Button("Reset defaults") {
                                ai.resetToDefaults()
                                loadDrafts()
                                statusNote = "Defaults restored"
                            }
                            .buttonStyle(.bordered)

                            Button("Reveal in Finder") {
                                // Ensure file exists
                                _ = ai.saveConfig(ai.config)
                                ai.revealInFinder()
                            }
                            .buttonStyle(.bordered)

                            Spacer()
                        }

                        if let err = ai.lastError, !err.isEmpty {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if !statusNote.isEmpty {
                            Text(statusNote)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(AIConfigManager.configFileURL.path)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { loadDrafts() }
    }

    private func loadDrafts() {
        draftRoles = ai.config.roles
        draftBackends = ai.config.backends
        if ai.jsonText.isEmpty {
            ai.jsonText = AIConfigManager.prettyJSON(ai.config) ?? ""
        }
    }

    private func applyRoleTable() {
        var c = ai.config
        for (k, v) in draftRoles {
            c.roles[k] = v
        }
        for (k, v) in draftBackends {
            c.backends[k] = v
        }
        if ai.saveConfig(c) {
            statusNote = "Roles & backends saved"
            loadDrafts()
        } else {
            statusNote = ai.lastError ?? "Save failed"
        }
    }

    @ViewBuilder
    private func roleRow(_ role: AIRole) -> some View {
        let binding = Binding(
            get: {
                draftRoles[role.rawValue]
                    ?? ai.config.roles[role.rawValue]
                    ?? AIRoleConfig(backend: "local", model: "gemma2:2b")
            },
            set: { draftRoles[role.rawValue] = $0 }
        )
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.label)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(role.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                Picker("", selection: Binding(
                    get: { binding.wrappedValue.backend },
                    set: { binding.wrappedValue = AIRoleConfig(backend: $0, model: binding.wrappedValue.model) }
                )) {
                    ForEach(backendNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(minWidth: 90)

                TextField("model name", text: Binding(
                    get: { binding.wrappedValue.model },
                    set: { binding.wrappedValue = AIRoleConfig(backend: binding.wrappedValue.backend, model: $0) }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 100, maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.label)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(role.help)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Picker("Backend", selection: Binding(
                    get: { binding.wrappedValue.backend },
                    set: { binding.wrappedValue = AIRoleConfig(backend: $0, model: binding.wrappedValue.model) }
                )) {
                    ForEach(backendNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                TextField("model name", text: Binding(
                    get: { binding.wrappedValue.model },
                    set: { binding.wrappedValue = AIRoleConfig(backend: binding.wrappedValue.backend, model: $0) }
                ))
                .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func backendEditor(name: String) -> some View {
        let b = draftBackends[name] ?? ai.config.backends[name] ?? AIBackendConfig(type: .ollama, baseURL: "", apiKey: nil, apiKeyEnv: nil)
        VStack(alignment: .leading, spacing: 8) {
            Text(name)
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                Text("Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("", selection: Binding(
                    get: { draftBackends[name]?.type ?? b.type },
                    set: { newType in
                        var x = draftBackends[name] ?? b
                        x.type = newType
                        draftBackends[name] = x
                    }
                )) {
                    ForEach(AIBackendConfig.AIBackendType.allCases, id: \.self) { t in
                        Text(t.label).tag(t)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("Base URL")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("URL", text: Binding(
                    get: { draftBackends[name]?.baseURL ?? b.baseURL },
                    set: { v in
                        var x = draftBackends[name] ?? b
                        x.baseURL = v
                        draftBackends[name] = x
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: .infinity)

                if (draftBackends[name]?.type ?? b.type) == .openaiCompatible {
                    Text("API key")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("optional if using env", text: Binding(
                        get: { draftBackends[name]?.apiKey ?? b.apiKey ?? "" },
                        set: { v in
                            var x = draftBackends[name] ?? b
                            x.apiKey = v.isEmpty ? nil : v
                            draftBackends[name] = x
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)

                    Text("API key env var")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("OPENAI_API_KEY", text: Binding(
                        get: { draftBackends[name]?.apiKeyEnv ?? b.apiKeyEnv ?? "" },
                        set: { v in
                            var x = draftBackends[name] ?? b
                            x.apiKeyEnv = v.isEmpty ? nil : v
                            draftBackends[name] = x
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(14)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct TemplatesSettingsView: View {
    @State private var templates: [AITemplate] = []
    @State private var selectedTemplateId: String?
    @State private var editingName = ""
    @State private var editingPrompt = ""

    private let listWidth: CGFloat = 200

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar list
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Templates")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button(action: createNewTemplate) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.body)
                    }
                    .buttonStyle(.plain)
                    .help("New template")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                ScrollView {
                    LazyVStack(spacing: 4) {
                        if templates.isEmpty {
                            Text("No templates yet")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 14)
                                .padding(.top, 8)
                        }
                        ForEach(templates) { template in
                            Button {
                                selectedTemplateId = template.id
                            } label: {
                                Text(template.name)
                                    .font(.system(size: 13, weight: selectedTemplateId == template.id ? .semibold : .regular, design: .rounded))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(selectedTemplateId == template.id ? Color.accentColor.opacity(0.15) : Color.clear)
                                    .foregroundStyle(selectedTemplateId == template.id ? Color.accentColor : Color.primary)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
            }
            .frame(width: listWidth)
            .frame(maxHeight: .infinity)
            .background(Color.primary.opacity(0.04))

            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(width: 1)

            // Detail / editor
            VStack(alignment: .leading, spacing: 14) {
                if selectedTemplateId != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Template Name")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextField("Template Name", text: $editingName)
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .textFieldStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Prompt")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        TextEditor(text: $editingPrompt)
                            .font(.system(size: 13, weight: .regular, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.primary.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                    }
                    .frame(maxHeight: .infinity)

                    HStack {
                        Button(role: .destructive, action: deleteSelected) {
                            Text("Delete")
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button("Save Changes") {
                            saveChanges()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Spacer()
                    VStack(spacing: 10) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text("Select a template or create a new one.")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Button("New template", action: createNewTemplate)
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity)
                    Spacer()
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            loadTemplates()
        }
        .onChange(of: selectedTemplateId) { _, newId in
            if let id = newId, let template = templates.first(where: { $0.id == id }) {
                editingName = template.name
                editingPrompt = template.prompt
            }
        }
    }
    
    private func loadTemplates() {
        templates = Database.shared.fetchTemplates()
    }
    
    private func createNewTemplate() {
        let newId = UUID().uuidString
        let newTemplate = AITemplate(id: newId, name: "New Template", prompt: "Summarize this meeting...")
        Database.shared.saveTemplate(newTemplate)
        loadTemplates()
        selectedTemplateId = newId
    }
    
    private func deleteSelected() {
        guard let id = selectedTemplateId else { return }
        Database.shared.deleteTemplate(id: id)
        selectedTemplateId = nil
        loadTemplates()
    }
    
    private func saveChanges() {
        guard let id = selectedTemplateId else { return }
        let updated = AITemplate(id: id, name: editingName, prompt: editingPrompt)
        Database.shared.saveTemplate(updated)
        loadTemplates()
    }
}

// MARK: - Integrations (Obsidian)

struct IntegrationsSettingsView: View {
    @ObservedObject private var integrations = IntegrationsConfigManager.shared
    @State private var draft: ObsidianIntegrationConfig = .default
    @State private var status = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Integrations")
                        .font(.title3.weight(.semibold))
                    Text("Optional bridges to apps on your machine. Nothing leaves this Mac unless you connect a cloud service later.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Obsidian card
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        GristIconBadge(systemName: "book.closed.fill", tint: .purple, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Obsidian")
                                .font(.headline)
                            Text("Write Grist notes as Markdown into your vault")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $draft.enabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Vault folder")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Text(draft.vaultPath.isEmpty ? "No vault selected" : draft.vaultPath)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(draft.vaultPath.isEmpty ? .tertiary : .secondary)
                                .lineLimit(2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Button("Choose…") {
                                if let url = ObsidianExporter.pickVaultFolder() {
                                    draft.vaultPath = url.path
                                }
                            }
                            .buttonStyle(.bordered)
                            if !draft.vaultPath.isEmpty {
                                Button("Reveal") {
                                    NSWorkspace.shared.activateFileViewerSelecting(
                                        [URL(fileURLWithPath: draft.vaultPath)]
                                    )
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Subfolder")
                            .font(.callout)
                        TextField("Grist", text: $draft.subfolder)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Filename pattern")
                            .font(.callout)
                        TextField("{date}-{title}", text: $draft.filenamePattern)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: .infinity)
                    }
                    Text("{date} = yyyy-MM-dd · {title} = note title · {id} = short id")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    Divider()

                    Text("Default sections")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Toggle("Metadata", isOn: $draft.includeMetadata)
                    Toggle("Sources / links", isOn: $draft.includeSources)
                    Toggle("AI Summary", isOn: $draft.includeSummary)
                    Toggle("Notes body", isOn: $draft.includeNotes)
                    Toggle("Transcript / captions", isOn: $draft.includeTranscript)

                    Divider()

                    Toggle(isOn: $draft.autoExportAfterEnhance) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("After Enhance, send to Obsidian")
                            Text("Writes a new Markdown file when Enhance finishes")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Toggle(isOn: $draft.openAfterExport) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open in Obsidian after send")
                            Text("Uses the obsidian:// URL scheme if Obsidian is installed")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        if !status.isEmpty {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save") {
                            integrations.updateObsidian { $0 = draft }
                            status = integrations.lastMessage
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                    }
                }
                .padding(18)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )

                Text("Config file: \(integrations.configPath)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)

                // Voice / TTS (local)
                VoiceSettingsCard()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            draft = integrations.config.obsidian
        }
    }
}

// MARK: - Voice / TTS settings (macOS system speech only)

struct VoiceSettingsCard: View {
    @ObservedObject private var speech = SpeechService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                GristIconBadge(systemName: "speaker.wave.2.fill", tint: .purple, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Read aloud")
                        .font(.headline)
                    Text("macOS system voice — on-device only. No cloud, no extra app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text("For a more natural voice, install Enhanced or Premium voices in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices…, then pick them below. Rate and pitch help a little; true emotion/cloning needs neural TTS later.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Voice", selection: $speech.selectedVoiceId) {
                Text("Best available English").tag("")
                ForEach(speech.availableVoices, id: \.identifier) { v in
                    Text(SpeechService.voiceLabel(v)).tag(v.identifier)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Rate")
                    Spacer()
                    Text(String(format: "%.0f%%", speech.rate * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speech.rate, in: 0.5...1.15, step: 0.05)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Pitch")
                    Spacer()
                    Text(String(format: "%.2f", speech.pitch))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $speech.pitch, in: 0.7...1.4, step: 0.05)
            }

            HStack {
                Button("System voice settings…") {
                    speech.openSpokenContentSettings()
                }
                .buttonStyle(.bordered)
                Spacer()
                Button("Test voice") {
                    speech.speak("Hello from Grist. This is your read aloud voice.")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
            }
        }
        .padding(18)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.purple.opacity(0.2), lineWidth: 1)
        )
    }
}
