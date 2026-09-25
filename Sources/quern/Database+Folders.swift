import Foundation
import SQLite3

extension Database {
    // MARK: - Folders
    
    func fetchFolders() -> [String] {
        var folders: [String] = []
        let query = "SELECT name FROM folders ORDER BY name ASC;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let nCStr = sqlite3_column_text(statement, 0) {
                    folders.append(String(cString: nCStr))
                }
            }
        }
        sqlite3_finalize(statement)
        return folders
    }
    
    func saveFolder(_ name: String) {
        let query = "INSERT OR REPLACE INTO folders (name, created_at) VALUES (?, ?);"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_double(statement, 2, Date().timeIntervalSince1970)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    enum FolderRenameError: LocalizedError {
        case emptyName
        case sameName
        case targetExists(String)
        case sourceMissing(String)

        var errorDescription: String? {
            switch self {
            case .emptyName: return "Folder name can’t be empty."
            case .sameName: return "New name is the same as the old name."
            case .targetExists(let n): return "A folder named “\(n)” already exists."
            case .sourceMissing(let n): return "Folder “\(n)” was not found."
            }
        }
    }

    /// Rename a folder and re-point all meetings that use it.
    /// Returns number of meetings updated.
    @discardableResult
    func renameFolder(from oldName: String, to newName: String) throws -> Int {
        let old = oldName.trimmingCharacters(in: .whitespacesAndNewlines)
        let new = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !new.isEmpty else { throw FolderRenameError.emptyName }
        guard old != new else { throw FolderRenameError.sameName }

        let existing = fetchFolders()
        guard existing.contains(old) else { throw FolderRenameError.sourceMissing(old) }
        if existing.contains(new) {
            throw FolderRenameError.targetExists(new)
        }

        // Preserve created_at when possible
        var createdAt = Date().timeIntervalSince1970
        let sel = "SELECT created_at FROM folders WHERE name = ?;"
        var selStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sel, -1, &selStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(selStmt, 1, (old as NSString).utf8String, -1, nil)
            if sqlite3_step(selStmt) == SQLITE_ROW {
                createdAt = sqlite3_column_double(selStmt, 0)
            }
        }
        sqlite3_finalize(selStmt)

        execute("BEGIN IMMEDIATE;")
        var committed = false
        defer {
            if !committed {
                execute("ROLLBACK;")
            }
        }

        let del = "DELETE FROM folders WHERE name = ?;"
        var delStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, del, -1, &delStmt, nil) == SQLITE_OK else {
            throw FolderRenameError.sourceMissing(old)
        }
        sqlite3_bind_text(delStmt, 1, (old as NSString).utf8String, -1, nil)
        if sqlite3_step(delStmt) != SQLITE_DONE {
            sqlite3_finalize(delStmt)
            throw FolderRenameError.sourceMissing(old)
        }
        sqlite3_finalize(delStmt)

        let ins = "INSERT INTO folders (name, created_at) VALUES (?, ?);"
        var insStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, ins, -1, &insStmt, nil) == SQLITE_OK else {
            throw FolderRenameError.targetExists(new)
        }
        sqlite3_bind_text(insStmt, 1, (new as NSString).utf8String, -1, nil)
        sqlite3_bind_double(insStmt, 2, createdAt)
        if sqlite3_step(insStmt) != SQLITE_DONE {
            sqlite3_finalize(insStmt)
            throw FolderRenameError.targetExists(new)
        }
        sqlite3_finalize(insStmt)

        let upd = "UPDATE meetings SET group_name = ? WHERE group_name = ?;"
        var updStmt: OpaquePointer?
        var changed = 0
        guard sqlite3_prepare_v2(db, upd, -1, &updStmt, nil) == SQLITE_OK else {
            throw FolderRenameError.sourceMissing(old)
        }
        sqlite3_bind_text(updStmt, 1, (new as NSString).utf8String, -1, nil)
        sqlite3_bind_text(updStmt, 2, (old as NSString).utf8String, -1, nil)
        if sqlite3_step(updStmt) == SQLITE_DONE {
            changed = Int(sqlite3_changes(db))
        } else {
            sqlite3_finalize(updStmt)
            throw FolderRenameError.sourceMissing(old)
        }
        sqlite3_finalize(updStmt)
        execute("COMMIT;")
        committed = true
        return changed
    }
    
    enum FolderDeleteContentsMode {
        /// Keep notes/meetings; clear their folder → Unfiled
        case moveToUnfiled
        /// Soft-delete notes/meetings in the folder (`is_deleted = 1`)
        case softDeleteContents
    }

    /// Remove the folder. Contents are either unfiled or soft-deleted.
    func deleteFolder(_ name: String, contents: FolderDeleteContentsMode) {
        switch contents {
        case .moveToUnfiled:
            let unfile = "UPDATE meetings SET group_name = '' WHERE group_name = ? AND is_deleted = 0;"
            var unfileStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, unfile, -1, &unfileStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(unfileStmt, 1, (name as NSString).utf8String, -1, nil)
                sqlite3_step(unfileStmt)
            }
            sqlite3_finalize(unfileStmt)
        case .softDeleteContents:
            // Collect ids first so we can drop RAG chunks after soft-delete.
            var ids: [String] = []
            let sel = "SELECT id FROM meetings WHERE group_name = ? AND is_deleted = 0;"
            var selStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sel, -1, &selStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(selStmt, 1, (name as NSString).utf8String, -1, nil)
                while sqlite3_step(selStmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(selStmt, 0) {
                        ids.append(String(cString: cStr))
                    }
                }
            }
            sqlite3_finalize(selStmt)

            let soft = "UPDATE meetings SET is_deleted = 1 WHERE group_name = ? AND is_deleted = 0;"
            var softStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, soft, -1, &softStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(softStmt, 1, (name as NSString).utf8String, -1, nil)
                sqlite3_step(softStmt)
            }
            sqlite3_finalize(softStmt)

            for id in ids {
                deleteChunks(forMeetingId: id)
            }
        }

        let query = "DELETE FROM folders WHERE name = ?"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }
}
