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
    @State private var selectedTab = 0
    
    var body: some View {
        ZStack {
            VisualEffectView(material: .popover, blendingMode: .behindWindow)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Custom Top Navigation
                HStack(spacing: 12) {
                    TabButton(title: "General", icon: "gearshape.fill", isSelected: selectedTab == 0) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedTab = 0
                        }
                    }
                    TabButton(title: "AI Models", icon: "cpu", isSelected: selectedTab == 1) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedTab = 1
                        }
                    }
                    TabButton(title: "AI Templates", icon: "sparkles.rectangle.stack.fill", isSelected: selectedTab == 2) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selectedTab = 2
                        }
                    }
                }
                .padding(.top, 30)
                .padding(.bottom, 20)
                
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                
                // Content Area
                ZStack {
                    switch selectedTab {
                    case 0:
                        GeneralSettingsView()
                            .transition(.opacity)
                    case 1:
                        AIModelsSettingsView()
                            .transition(.opacity)
                    default:
                        TemplatesSettingsView()
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
    }
}

struct TabButton: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(isSelected ? Color.white.opacity(0.15) : Color.clear)
            .foregroundColor(isSelected ? .primary : .secondary)
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.white.opacity(0.2) : Color.clear, lineWidth: 1)
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
            VStack(alignment: .leading, spacing: 32) {
                
                // Section 1: Workflow
                VStack(alignment: .leading, spacing: 12) {
                    Text("Workflow")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-Enhance Meetings")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                            Text("Generate AI summaries automatically when recording stops")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $autoEnhance)
                            .toggleStyle(.switch)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )

                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-extract tasks")
                                .font(.system(size: 16, weight: .medium, design: .rounded))
                            Text("After Enhance, pull action items into the Tasks list")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: $autoExtractTasks)
                            .toggleStyle(.switch)
                    }
                    .padding(16)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)
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
                        HStack {
                            Text("Provider")
                                .font(.system(size: 15, weight: .medium, design: .rounded))
                            Spacer()
                            Picker("", selection: $aiProviderType) {
                                Text("Ollama (Local)").tag("Ollama")
                                Text("OpenAI Compatible").tag("OpenAI Compatible")
                            }
                            .frame(width: 160)
                        }
                        .padding(16)
                        
                        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                        
                        if aiProviderType == "Ollama" {
                            HStack {
                                Text("Local URL")
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                Spacer()
                                TextField("http://127.0.0.1:11434", text: $ollamaURL)
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 250)
                            }
                            .padding(16)
                        } else {
                            HStack {
                                Text("API URL")
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                Spacer()
                                TextField("https://api.openai.com/v1", text: $openAIBaseURL)
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 250)
                            }
                            .padding(16)
                            
                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                            
                            HStack {
                                Text("API Key")
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                Spacer()
                                SecureField("sk-...", text: $openAIAPIKey)
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 250)
                            }
                            .padding(16)
                            
                            Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1)
                            
                            HStack {
                                Text("Model")
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                Spacer()
                                TextField("gpt-4o", text: $openAIModel)
                                    .textFieldStyle(.plain)
                                    .multilineTextAlignment(.trailing)
                                    .frame(width: 250)
                            }
                            .padding(16)
                        }
                    }
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)
                    )
                }
            }
            .padding(32)
        }
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
                            .frame(minHeight: 220, maxHeight: 320)
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
            .padding(28)
        }
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(role.label)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(role.help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 150, alignment: .leading)

            Picker("", selection: Binding(
                get: { binding.wrappedValue.backend },
                set: { binding.wrappedValue = AIRoleConfig(backend: $0, model: binding.wrappedValue.model) }
            )) {
                ForEach(backendNames, id: \.self) { name in
                    Text(name).tag(name)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            TextField("model name", text: Binding(
                get: { binding.wrappedValue.model },
                set: { binding.wrappedValue = AIRoleConfig(backend: binding.wrappedValue.backend, model: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 200)
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
            HStack {
                Text("Type")
                Spacer()
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
                .frame(width: 180)
            }
            HStack {
                Text("Base URL")
                Spacer()
                TextField("URL", text: Binding(
                    get: { draftBackends[name]?.baseURL ?? b.baseURL },
                    set: { v in
                        var x = draftBackends[name] ?? b
                        x.baseURL = v
                        draftBackends[name] = x
                    }
                ))
                .textFieldStyle(.roundedBorder)
                .frame(width: 280)
            }
            if (draftBackends[name]?.type ?? b.type) == .openaiCompatible {
                HStack {
                    Text("API key")
                    Spacer()
                    SecureField("optional if using env", text: Binding(
                        get: { draftBackends[name]?.apiKey ?? b.apiKey ?? "" },
                        set: { v in
                            var x = draftBackends[name] ?? b
                            x.apiKey = v.isEmpty ? nil : v
                            draftBackends[name] = x
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                }
                HStack {
                    Text("API key env var")
                    Spacer()
                    TextField("OPENAI_API_KEY", text: Binding(
                        get: { draftBackends[name]?.apiKeyEnv ?? b.apiKeyEnv ?? "" },
                        set: { v in
                            var x = draftBackends[name] ?? b
                            x.apiKeyEnv = v.isEmpty ? nil : v
                            draftBackends[name] = x
                        }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
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
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Your Templates")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Button(action: createNewTemplate) {
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(Color.accentColor)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
                
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(templates) { template in
                            Button {
                                selectedTemplateId = template.id
                            } label: {
                                HStack {
                                    Text(template.name)
                                        .font(.system(size: 14, weight: selectedTemplateId == template.id ? .semibold : .regular, design: .rounded))
                                    Spacer()
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(selectedTemplateId == template.id ? Color.accentColor.opacity(0.15) : Color.clear)
                                .foregroundColor(selectedTemplateId == template.id ? .accentColor : .primary)
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            .frame(width: 220)
            .background(Color.black.opacity(0.1))
            
            Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1)
            
            // Detail
            VStack(alignment: .leading, spacing: 20) {
                if let _ = selectedTemplateId {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Template Name")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        TextField("Template Name", text: $editingName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .textFieldStyle(.plain)
                    }
                    
                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Prompt")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                        
                        TextEditor(text: $editingPrompt)
                            .font(.system(size: 14, weight: .regular, design: .monospaced))
                            .padding(12)
                            .background(Color.black.opacity(0.2))
                            .cornerRadius(12)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1)
                            )
                    }
                    
                    HStack {
                        Button(action: deleteSelected) {
                            Text("Delete")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        
                        Spacer()
                        
                        Button {
                            saveChanges()
                        } label: {
                            Text("Save Changes")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .cornerRadius(8)
                        }
                        .buttonStyle(.plain)
                        .disabled(editingName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } else {
                    Spacer()
                    HStack {
                        Spacer()
                        Text("Select a template or create a new one.")
                            .font(.system(size: 15, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    Spacer()
                }
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
