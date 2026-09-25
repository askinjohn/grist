import Foundation
import SQLite3

// MARK: - Tasks

extension Database {
    func saveTask(_ task: QuernTask) {
        let query = """
        INSERT OR REPLACE INTO tasks
        (id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (task.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (task.title as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (task.notes as NSString).utf8String, -1, nil)
            if let sid = task.sourceMeetingId {
                sqlite3_bind_text(stmt, 4, (sid as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 4)
            }
            if let st = task.sourceTitle {
                sqlite3_bind_text(stmt, 5, (st as NSString).utf8String, -1, nil)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            sqlite3_bind_text(stmt, 6, (task.status as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 7, task.createdAt)
            if let c = task.completedAt {
                sqlite3_bind_double(stmt, 8, c)
            } else {
                sqlite3_bind_null(stmt, 8)
            }
            sqlite3_bind_int(stmt, 9, task.isDeleted ? 1 : 0)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func fetchTasks(includeDone: Bool = true) -> [QuernTask] {
        let query: String
        if includeDone {
            query = "SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted FROM tasks WHERE is_deleted = 0 ORDER BY status ASC, created_at DESC;"
        } else {
            query = "SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted FROM tasks WHERE is_deleted = 0 AND status = 'open' ORDER BY created_at DESC;"
        }
        var stmt: OpaquePointer?
        var results: [QuernTask] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readTaskRow(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func fetchTasks(forMeetingId meetingId: String) -> [QuernTask] {
        let query = "SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted FROM tasks WHERE is_deleted = 0 AND source_meeting_id = ? ORDER BY created_at DESC;"
        var stmt: OpaquePointer?
        var results: [QuernTask] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(readTaskRow(stmt))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func openTaskCount() -> Int {
        let query = "SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND status = 'open';"
        var stmt: OpaquePointer?
        var count = 0
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return count
    }

    /// Soft-delete.
    func deleteTask(id: String) {
        let query = "UPDATE tasks SET is_deleted = 1 WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Avoid exact duplicate open tasks from the same source with the same title.
    func hasOpenTask(title: String, sourceMeetingId: String?) -> Bool {
        let query: String
        if let sid = sourceMeetingId {
            query = "SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND status = 'open' AND title = ? AND source_meeting_id = ?;"
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (sid as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return count > 0
        } else {
            let q = "SELECT COUNT(*) FROM tasks WHERE is_deleted = 0 AND status = 'open' AND title = ? AND source_meeting_id IS NULL;"
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, q, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (title as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return count > 0
        }
    }

    private func readTaskRow(_ stmt: OpaquePointer?) -> QuernTask {
        func textCol(_ i: Int32) -> String? {
            guard let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }
        let completed: Double? = sqlite3_column_type(stmt, 7) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 7)
        return QuernTask(
            id: textCol(0) ?? UUID().uuidString,
            title: textCol(1) ?? "",
            notes: textCol(2) ?? "",
            sourceMeetingId: textCol(3),
            sourceTitle: textCol(4),
            status: textCol(5) ?? "open",
            createdAt: sqlite3_column_double(stmt, 6),
            completedAt: completed,
            isDeleted: sqlite3_column_int(stmt, 8) != 0
        )
    }
}
