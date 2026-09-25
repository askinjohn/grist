import SwiftUI
import AppKit
import UniformTypeIdentifiers
import AVFoundation

extension MainView {
    // MARK: - Computed Data

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredMeetings: [Meeting] {
        var list = meetings

        // While searching, look across the whole library (ignore folder / filter scope)
        // so results always “jump” to the real item.
        if isSearching {
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return list.filter { Self.meeting($0, matchesSearch: q) }
                .sorted { a, b in
                    // Prefer title hits, then recency
                    let at = a.title.localizedCaseInsensitiveContains(q)
                    let bt = b.title.localizedCaseInsensitiveContains(q)
                    if at != bt { return at && !bt }
                    return a.timestamp > b.timestamp
                }
        }

        // Folder focus wins over library filter
        if let folder = focusedFolder {
            list = list.filter { ($0.groupName ?? "") == folder }
        } else {
            switch libraryFilter {
            case .all, .askEverything, .tasks:
                break
            case .unfiled:
                list = list.filter { ($0.groupName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
            case .meetings:
                list = list.filter { !$0.isNoteType }
            case .notes:
                list = list.filter { $0.isNoteType }
            }
        }
        return list
    }

    static func meeting(_ m: Meeting, matchesSearch q: String) -> Bool {
        guard !q.isEmpty else { return true }
        return m.title.localizedCaseInsensitiveContains(q)
            || m.transcript.localizedCaseInsensitiveContains(q)
            || m.manualNotes.localizedCaseInsensitiveContains(q)
            || m.summary.localizedCaseInsensitiveContains(q)
            || (m.groupName?.localizedCaseInsensitiveContains(q) ?? false)
    }

    /// Open a search hit in the detail pane and jump to the matching tab.
    func openSearchResult(_ meeting: Meeting) {
        pendingSearchReveal = true
        // Clear folder focus so the row stays visible under “Search results”
        focusedFolder = nil
        libraryFilter = .all
        selectedMeeting = meetings.first(where: { $0.id == meeting.id }) ?? meeting
    }

    func handleSearchQueryChange(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let hits = filteredMeetings
        guard !hits.isEmpty else { return }
        // If nothing selected or selection not in results, jump to the best hit
        if selectedMeeting == nil || !hits.contains(where: { $0.id == selectedMeeting?.id }) {
            openSearchResult(hits[0])
        }
    }

    /// Pick the tab where the search query appears (summary > notes > transcript).
    func revealSearchMatch(in m: Meeting) {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        if m.isNoteType {
            if m.summary.localizedCaseInsensitiveContains(q) {
                selectedTab = "summary"
            } else {
                selectedTab = "notes"
                // Preview when the hit is in a long body
                noteShowPreview = m.manualNotes.count > 400 || m.transcript.localizedCaseInsensitiveContains(q)
            }
            return
        }
        // Meeting
        if m.summary.localizedCaseInsensitiveContains(q) {
            selectedTab = "summary"
        } else if m.manualNotes.localizedCaseInsensitiveContains(q) {
            selectedTab = "notes"
        } else if m.transcript.localizedCaseInsensitiveContains(q) {
            selectedTab = "transcript"
        } else {
            selectedTab = m.summary.isEmpty ? "transcript" : "summary"
        }
    }

    // MARK: - Export

    func exportFolder(_ name: String, options: ExportOptions = .default) {
        let items = meetings.filter { ($0.groupName ?? "") == name }
        guard !items.isEmpty else {
            statusMessage = "Folder is empty"
            return
        }
        if let dir = NoteExporter.saveFolderPanel(meetings: items, suggestedName: name, options: options) {
            statusMessage = "Exported \(items.count) files → \(dir.lastPathComponent)"
            NSWorkspace.shared.open(dir)
        }
    }

    /// Unfiled (or filter-scoped) items for the sidebar timeline. Folder contents live in the accordion.
    var groupedMeetings: [MeetingGroup] {
        if focusedFolder != nil {
            return timeGrouped(filteredMeetings, headerPrefix: nil)
        }
        // Prefer unfiled-only timeline; accordion owns folder files.
        switch libraryFilter {
        case .all, .unfiled:
            return timeGrouped(unfiledMeetingsForSidebar, headerPrefix: nil)
        case .meetings, .notes:
            // Meetings/Notes filter: unfiled of that kind only (filed items under accordion)
            return timeGrouped(unfiledMeetingsForSidebar, headerPrefix: nil)
        case .askEverything, .tasks:
            return []
        }
    }

    func timeGrouped(_ items: [Meeting], headerPrefix: String?) -> [MeetingGroup] {
        let cal = Calendar.current
        let now = Date()
        var today: [Meeting] = [], yesterday: [Meeting] = [], week: [Meeting] = [], older: [Meeting] = []

        for m in items {
            let d = Date(timeIntervalSince1970: m.timestamp)
            if cal.isDateInToday(d) { today.append(m) }
            else if cal.isDateInYesterday(d) { yesterday.append(m) }
            else if let diff = cal.dateComponents([.day], from: d, to: now).day, diff <= 7 { week.append(m) }
            else { older.append(m) }
        }

        func grp(_ name: String, _ list: [Meeting]) -> MeetingGroup? {
            guard !list.isEmpty else { return nil }
            let title = headerPrefix.map { "\($0) · \(name)" } ?? name
            return MeetingGroup(name: title, meetings: list.sorted { $0.timestamp > $1.timestamp })
        }

        return [grp("Today", today), grp("Yesterday", yesterday), grp("Last 7 Days", week), grp("Older", older)]
            .compactMap { $0 }
    }
}
