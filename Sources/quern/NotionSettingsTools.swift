import SwiftUI

struct NotionExportRecord: Codable, Identifiable {
    var id = UUID().uuidString
    var timestamp = Date()
    var title: String
    var status: String
    var destination: String
}

@MainActor final class NotionExportHistory: ObservableObject {
    static let shared = NotionExportHistory()
    @Published var records: [NotionExportRecord] = []
    private init() {
        if let data = UserDefaults.standard.data(forKey: "notionExportHistory") {
            records = (try? JSONDecoder().decode([NotionExportRecord].self, from: data)) ?? []
        }
    }
    func record(title: String, status: String, destination: String) {
        records.insert(.init(title: title, status: status, destination: destination), at: 0)
        records = Array(records.prefix(30))
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: "notionExportHistory")
    }
}

struct NotionDestination: Identifiable {
    var id: String
    var title: String
    var kind: String
}

struct NotionConnectionTools: View {
    @Binding var config: NotionIntegrationConfig
    @Binding var token: String
    @ObservedObject private var history = NotionExportHistory.shared
    @State private var destinations: [NotionDestination] = []
    @State private var query = ""
    @State private var status = ""
    @State private var busy = false
    @State private var cursor: String?
    @State private var route = "default"
    @State private var expandedRoute: String?

    private func effectiveToken() throws -> String {
        let entered = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !entered.isEmpty { return entered }
        return try NotionSecretStore.requiredToken()
    }

    private var selectedID: String {
        switch route {
        case "meeting": return config.meetingPageID
        case "note": return config.notePageID
        case "task": return config.taskPageID
        default: return config.parentPageID
        }
    }

    private var selectedKind: String {
        switch route {
        case "meeting": return config.meetingDestinationKind
        case "note": return config.noteDestinationKind
        case "task": return config.taskDestinationKind
        default: return config.destinationKind ?? "page"
        }
    }

    private var selectedName: String {
        switch route {
        case "meeting": return config.meetingDestinationName
        case "note": return config.noteDestinationName
        case "task": return config.taskDestinationName
        default: return config.destinationName ?? ""
        }
    }

    private var routeID: Binding<String> {
        Binding(get: { selectedID }, set: { value in
            switch route {
            case "meeting": config.meetingPageID = value; config.meetingDestinationName = ""
            case "note": config.notePageID = value; config.noteDestinationName = ""
            case "task":
                if config.taskPageID != value { config.taskListPageID = ""; config.taskBlockIDs = [] }
                config.taskPageID = value; config.taskDestinationName = ""
            default: config.parentPageID = value; config.destinationName = nil
            }
        })
    }

    private var routeKind: Binding<String> {
        Binding(get: { selectedKind }, set: { value in
            switch route {
            case "meeting": config.meetingDestinationKind = value
            case "note": config.noteDestinationKind = value
            case "task":
                if config.taskDestinationKind != value { config.taskListPageID = ""; config.taskBlockIDs = [] }
                config.taskDestinationKind = value
            default: config.destinationKind = value
            }
        })
    }

    private func id(for value: String) -> String {
        switch value {
        case "meeting": return config.meetingPageID
        case "note": return config.notePageID
        case "task": return config.taskPageID
        default: return config.parentPageID
        }
    }

    private func name(for value: String) -> String {
        switch value {
        case "meeting": return config.meetingDestinationName
        case "note": return config.noteDestinationName
        case "task": return config.taskDestinationName
        default: return config.destinationName ?? ""
        }
    }

    private func displayName(for value: String) -> String {
        let title = name(for: value)
        if !title.isEmpty { return title }
        let identifier = id(for: value)
        return identifier.isEmpty ? "" : "ID \(identifier.suffix(8))"
    }

    private func summary(for value: String) -> String {
        if !id(for: value).isEmpty { return displayName(for: value) }
        if value == "meeting" || value == "note" {
            return config.parentPageID.isEmpty ? "No destination" : "Inherits \(displayName(for: "default"))"
        }
        return value == "default" ? "No fallback destination" : "No task destination"
    }

    private func toggleRoute(_ value: String, expanded: Bool) {
        guard expanded else {
            if expandedRoute == value { expandedRoute = nil }
            return
        }
        expandedRoute = value
        route = value
        destinations = []
        cursor = nil
        query = ""
        status = ""
    }

    private func select(_ destination: NotionDestination) {
        switch route {
        case "meeting":
            config.meetingPageID = destination.id; config.meetingDestinationKind = destination.kind
            config.meetingDestinationName = destination.title
        case "note":
            config.notePageID = destination.id; config.noteDestinationKind = destination.kind
            config.noteDestinationName = destination.title
        case "task":
            if config.taskPageID != destination.id { config.taskListPageID = ""; config.taskBlockIDs = [] }
            config.taskPageID = destination.id; config.taskDestinationKind = destination.kind
            config.taskDestinationName = destination.title
        default:
            config.parentPageID = destination.id; config.destinationKind = destination.kind
            config.destinationName = destination.title
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach([("default", "Fallback", "square.stack"),
                     ("meeting", "Meetings", "video"),
                     ("note", "Notes", "note.text"),
                     ("task", "Tasks", "checklist")], id: \.0) { value, title, icon in
                DisclosureGroup(isExpanded: Binding(
                    get: { expandedRoute == value },
                    set: { toggleRoute(value, expanded: $0) }
                )) {
                    routeEditor
                        .padding(.top, 12)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .frame(width: 20)
                            .foregroundStyle(expandedRoute == value ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.callout.weight(.medium))
                            Text(summary(for: value))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if !id(for: value).isEmpty {
                            Text(value == "default" ? "Fallback" : "Custom")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        } else if (value == "meeting" || value == "note") && !config.parentPageID.isEmpty {
                            Text("Inherited")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(12)
                .background(expandedRoute == value ? Color.accentColor.opacity(0.06) : Color.primary.opacity(0.025),
                            in: RoundedRectangle(cornerRadius: 9))
                .disabled(busy && expandedRoute != value)
            }
            DisclosureGroup("Recent exports (\(history.records.count))") {
                ForEach(history.records) { record in
                    VStack(alignment: .leading) {
                        Text(record.title).font(.callout)
                        Text(record.timestamp.formatted() + " · " + record.status).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
                }
            }
        }
    }

    private var routeEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            if route == "default" {
                Text("Fallback for meetings and notes without a custom destination. A page collects blocks; a database creates one item per export.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if route == "task" {
                Text("Quern creates one task-list page here. Tasks never use the fallback destination.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(route == "meeting"
                     ? "Meeting notes and summaries go here. A page collects blocks; a database creates one item per meeting."
                     : "Notes and saved answers go here. A page collects blocks; a database creates one item per note.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if (route == "meeting" || route == "note") && selectedID.isEmpty {
                Text(config.parentPageID.isEmpty
                     ? "No fallback destination is configured yet."
                     : "Currently inherits \(displayName(for: "default")). Choose a destination below to override it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Find a shared page or database", text: $query).textFieldStyle(.roundedBorder)
                Button("Find") { search(more: false) }.disabled(busy)
            }
            HStack {
                TextField("Or paste page URL / data source ID", text: routeID)
                    .textFieldStyle(.roundedBorder)
                Picker("Type", selection: routeKind) {
                    Text("Page").tag("page")
                    Text("Database").tag("data_source")
                }.labelsHidden().frame(width: 110)
            }
            HStack {
                Button("Test connection") {
                    busy = true
                    Task {
                        do {
                            let secret = try effectiveToken()
                            _ = try await NotionExporter.request("users/me", token: secret)
                            let targetID = selectedID.isEmpty && (route == "meeting" || route == "note")
                                ? config.parentPageID : selectedID
                            let targetKind = selectedID.isEmpty && (route == "meeting" || route == "note")
                                ? (config.destinationKind ?? "page") : selectedKind
                            if !targetID.isEmpty {
                                let id = try NotionExporter.normalizedID(targetID)
                                _ = try await NotionExporter.request((targetKind == "data_source" ? "data_sources/" : "pages/") + id, token: secret)
                                status = "Connected. Destination is readable; export permissions are checked when you send."
                            } else { status = "Connected. Choose a destination, then Save Notion." }
                        } catch { status = error.localizedDescription }
                        busy = false
                    }
                }.disabled(busy)
                if (route == "meeting" || route == "note") && !selectedID.isEmpty {
                    Button("Inherit fallback") { routeID.wrappedValue = "" }
                }
                Spacer()
                if !selectedID.isEmpty {
                    Text(selectedName.isEmpty ? "Destination selected" : selectedName)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if busy { ProgressView().controlSize(.small) }
            if !status.isEmpty { Text(status).font(.caption).textSelection(.enabled) }
            if !destinations.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(destinations) { destination in
                            Button {
                                select(destination)
                                status = "Selected \(destination.title). Save Notion to apply."
                            } label: {
                                Label(destination.title, systemImage: destination.kind == "data_source" ? "tablecells" : "doc.text")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(7)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 170)
            }
            if cursor != nil { Button("More destinations") { search(more: true) }.disabled(busy) }
        }
    }

    private func search(more: Bool) {
        busy = true
        Task {
            do {
                let secret = try effectiveToken()
                var body: [String: Any] = ["query": query, "page_size": 20]
                if more, let cursor { body["start_cursor"] = cursor }
                let response = try await NotionExporter.request("search", method: "POST", token: secret, body: body)
                let results = response["results"] as? [[String: Any]] ?? []
                let found: [NotionDestination] = results.compactMap { object in
                    guard let id = object["id"] as? String, let kind = object["object"] as? String,
                          kind == "page" || kind == "data_source" else { return nil }
                    let properties = object["properties"] as? [String: [String: Any]] ?? [:]
                    let title = object["title"] as? [[String: Any]] ?? properties.values.first(where: { $0["type"] as? String == "title" })?["title"] as? [[String: Any]] ?? []
                    let name = title.compactMap { $0["plain_text"] as? String ?? ($0["text"] as? [String: Any])?["content"] as? String }.joined()
                    return .init(id: id, title: name.isEmpty ? "Untitled" : name, kind: kind)
                }
                destinations = more ? destinations + found : found
                cursor = response["next_cursor"] as? String
                status = destinations.isEmpty ? "No destinations found. Share a page or database with your integration in Notion." : "Choose a destination below."
            } catch { status = error.localizedDescription }
            busy = false
        }
    }
}
