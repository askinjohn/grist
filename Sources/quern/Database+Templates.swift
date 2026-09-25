import Foundation
import SQLite3

// MARK: - Template Model & DB Extensions
struct AITemplate: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var prompt: String
}

extension Database {
    func saveTemplate(_ template: AITemplate) {
        let query = "INSERT OR REPLACE INTO templates (id, name, prompt) VALUES (?, ?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (template.id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (template.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 3, (template.prompt as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func deleteTemplate(id: String) {
        let query = "DELETE FROM templates WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }
    
    func fetchTemplates() -> [AITemplate] {
        let query = "SELECT id, name, prompt FROM templates ORDER BY name ASC;"
        var stmt: OpaquePointer?
        var results: [AITemplate] = []
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(AITemplate(
                    id: String(cString: sqlite3_column_text(stmt, 0)),
                    name: String(cString: sqlite3_column_text(stmt, 1)),
                    prompt: String(cString: sqlite3_column_text(stmt, 2))
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }
}
