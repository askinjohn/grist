import SwiftUI

/// Main-area browser used by All, Unfiled, Meetings, Notes, and focused folders.
extension MainView {
    var libraryBrowserTitle: String {
        if isSearching { return "Search results" }
        if let focusedFolder { return focusedFolder }
        switch libraryFilter {
        case .all: return "All items"
        case .unfiled: return "Unfiled"
        case .meetings: return "Meetings"
        case .notes: return "Notes"
        default: return "Library"
        }
    }

    var libraryBrowserView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(libraryBrowserTitle).font(.title2.weight(.semibold))
                    Text(isSearching ? "\(filteredMeetings.count) match\(filteredMeetings.count == 1 ? "" : "es") for “\(searchText)”" : "\(filteredMeetings.count) item\(filteredMeetings.count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("Sort", selection: $librarySort) {
                    Text("Newest").tag("newest")
                    Text("Oldest").tag("oldest")
                    Text("Title").tag("title")
                }.frame(maxWidth: 140)
                Button { openCreateSheet(kind: .meeting) } label: { Label("Meeting", systemImage: "video") }
                    .buttonStyle(.bordered)
                Button { openCreateSheet(kind: .note) } label: { Label("Note", systemImage: "square.and.pencil") }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Divider()
            if filteredMeetings.isEmpty {
                ContentUnavailableView(isSearching ? "No search results" : "No items here", systemImage: "tray", description: Text(isSearching ? "Try a different word or phrase." : "Create a note or meeting to get started."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if isSearching {
                            Text("Notes").font(.headline)
                            libraryRows(browserItems.filter(\.isNoteType))
                            Text("Meetings").font(.headline).padding(.top, 12)
                            libraryRows(browserItems.filter { !$0.isNoteType })
                        } else { libraryRows(browserItems) }

                    }.padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    var browserItems: [Meeting] {
        filteredMeetings.sorted {
            switch librarySort {
            case "title": return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case "oldest": return $0.timestamp < $1.timestamp
            default: return $0.timestamp > $1.timestamp
            }
        }
    }

    @ViewBuilder func libraryRows(_ items: [Meeting]) -> some View {
        if items.isEmpty { Text("No matches").font(.caption).foregroundStyle(.secondary) }
                        ForEach(items) { item in
                            Button {
                                if isSearching { openSearchResult(item) } else { selectedMeeting = item }
                                selectedTask = nil
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: item.isNoteType ? "note.text" : "waveform")
                                        .foregroundStyle(item.isNoteType ? .blue : .secondary)
                                        .frame(width: 22)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(SearchEvidence.highlight(item.title.isEmpty ? "Untitled" : item.title, query: searchText))
                                        if isSearching, let hit = SearchEvidence.match(item, query: searchText) {
                                            Text(SearchEvidence.highlight(hit.quote, query: searchText)).font(.callout).lineLimit(3)
                                        }
                                        Text("\(item.kindLabel) · \(item.formattedCreated)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(14)
                                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .draggable(item.id)
                            .contextMenu {
                                Menu("Move to folder") {
                                    Button("Unfiled") { _ = acceptDrop([item.id], toFolder: nil) }
                                    ForEach(folders, id: \.self) { folder in Button(folder) { _ = acceptDrop([item.id], toFolder: folder) } }
                                }
                                Button("Export…") { openExportSheet(meeting: item) }
                                Button("Delete", role: .destructive) { db.softDeleteMeeting(id: item.id); loadMeetings() }
                            }
                        }
    }

}
