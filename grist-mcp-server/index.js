#!/usr/bin/env bun
/**
 * Grist MCP server — compile with Bun for Claude Desktop:
 *   bun install && bun build ./index.js --compile --outfile grist-mcp-server
 *
 * Tools: list_folders, list_notes, get_note, create_note, update_note,
 *         list_tasks, get_task, create_task, complete_task, reopen_task, update_task, delete_task
 * DB: ~/Library/Application Support/Grist/meetings.db
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import { Database } from "bun:sqlite";
import path from "path";
import os from "os";
import fs from "fs";
import crypto from "crypto";

const dbPath = path.join(os.homedir(), "Library/Application Support/Grist/meetings.db");
fs.mkdirSync(path.dirname(dbPath), { recursive: true });
const db = new Database(dbPath);

db.run(`
  CREATE TABLE IF NOT EXISTS folders (
    name TEXT PRIMARY KEY,
    created_at REAL
  );
`);
db.run(`
  CREATE TABLE IF NOT EXISTS meetings (
    id TEXT PRIMARY KEY,
    title TEXT,
    timestamp REAL,
    manual_notes TEXT,
    transcript TEXT,
    summary TEXT,
    template TEXT,
    group_name TEXT DEFAULT '',
    is_deleted INTEGER DEFAULT 0
  );
`);
db.run(`
  CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    notes TEXT DEFAULT '',
    source_meeting_id TEXT,
    source_title TEXT,
    status TEXT DEFAULT 'open',
    created_at REAL,
    completed_at REAL,
    is_deleted INTEGER DEFAULT 0
  );
`);

function ensureFolder(folder) {
  if (!folder) return;
  const row = db.prepare("SELECT name FROM folders WHERE name = ?").get(folder);
  if (!row) {
    db.prepare("INSERT INTO folders (name, created_at) VALUES (?, ?)").run(
      folder,
      Date.now() / 1000
    );
  }
}

function rowToNote(row) {
  if (!row) return null;
  return {
    id: row.id,
    title: row.title ?? "",
    folder: row.group_name || null,
    template: row.template ?? "",
    summary: row.summary ?? "",
    notes: row.manual_notes ?? "",
    transcript: row.transcript ?? "",
    timestamp: row.timestamp,
    is_note: (row.template ?? "") === "Note",
  };
}

function rowToTask(row) {
  if (!row) return null;
  return {
    id: row.id,
    title: row.title ?? "",
    notes: row.notes ?? "",
    status: row.status ?? "open",
    source_meeting_id: row.source_meeting_id || null,
    source_title: row.source_title || null,
    created_at: row.created_at,
    completed_at: row.completed_at ?? null,
  };
}

function findTask({ id, title }) {
  if (id) {
    return db
      .prepare(
        `SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted
         FROM tasks WHERE id = ? AND is_deleted = 0`
      )
      .get(id);
  }
  if (title) {
    const exact = db
      .prepare(
        `SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted
         FROM tasks WHERE title = ? AND is_deleted = 0
         ORDER BY created_at DESC LIMIT 1`
      )
      .get(title);
    if (exact) return exact;
    return db
      .prepare(
        `SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted
         FROM tasks WHERE title LIKE ? AND is_deleted = 0
         ORDER BY created_at DESC LIMIT 1`
      )
      .get(`%${title}%`);
  }
  return null;
}

function resolveSourceMeeting(source_meeting_id, source_title) {
  let sid = source_meeting_id || null;
  let stitle = source_title || null;
  if (sid) {
    const m = db
      .prepare(`SELECT id, title FROM meetings WHERE id = ? AND is_deleted = 0`)
      .get(sid);
    if (m) {
      sid = m.id;
      if (!stitle) stitle = m.title;
    }
  } else if (stitle) {
    const m = findNote({ title: stitle });
    if (m) {
      sid = m.id;
      stitle = m.title;
    }
  }
  return { sid, stitle };
}

function findNote({ id, title }) {
  if (id) {
    return db
      .prepare(
        `SELECT id, title, timestamp, manual_notes, transcript, summary, template, group_name
         FROM meetings WHERE id = ? AND is_deleted = 0`
      )
      .get(id);
  }
  if (title) {
    const exact = db
      .prepare(
        `SELECT id, title, timestamp, manual_notes, transcript, summary, template, group_name
         FROM meetings WHERE title = ? AND is_deleted = 0
         ORDER BY timestamp DESC LIMIT 1`
      )
      .get(title);
    if (exact) return exact;
    return db
      .prepare(
        `SELECT id, title, timestamp, manual_notes, transcript, summary, template, group_name
         FROM meetings WHERE title LIKE ? AND is_deleted = 0
         ORDER BY timestamp DESC LIMIT 1`
      )
      .get(`%${title}%`);
  }
  return null;
}

const server = new Server(
  {
    name: "grist-mcp-server",
    version: "1.2.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "list_folders",
        description: "List all folders in Grist.",
        inputSchema: { type: "object", properties: {} },
      },
      {
        name: "list_notes",
        description:
          "List notes/meetings in Grist (id, title, folder, timestamps). Use before update_note to find an id.",
        inputSchema: {
          type: "object",
          properties: {
            query: {
              type: "string",
              description: "Optional search in title, notes, or summary",
            },
            folder: {
              type: "string",
              description: "Optional folder name filter",
            },
            kind: {
              type: "string",
              enum: ["all", "notes", "meetings"],
              description: "Filter by kind (default all). notes = template Note",
            },
            limit: {
              type: "number",
              description: "Max results (default 30, max 100)",
            },
          },
        },
      },
      {
        name: "get_note",
        description: "Get one note/meeting by id or exact/partial title.",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string", description: "Note/meeting id" },
            title: {
              type: "string",
              description: "Title to match if id is unknown",
            },
          },
        },
      },
      {
        name: "create_note",
        description:
          "Create a new note in Grist (Markdown content). Use update_note to change an existing item.",
        inputSchema: {
          type: "object",
          properties: {
            title: { type: "string", description: "Title of the note" },
            content: {
              type: "string",
              description: "Body content (stored as the note’s written notes)",
            },
            summary: {
              type: "string",
              description: "Optional AI summary field (separate from notes body)",
            },
            folder: {
              type: "string",
              description: "Optional folder (created if missing)",
            },
          },
          required: ["title", "content"],
        },
      },
      {
        name: "update_note",
        description:
          "Update an existing Grist note/meeting. Identify by id (preferred) or title. Can change title, notes body, summary, and/or folder. Set append=true to append to notes/summary instead of replacing.",
        inputSchema: {
          type: "object",
          properties: {
            id: {
              type: "string",
              description: "Existing note/meeting id (from list_notes / get_note / create_note)",
            },
            title: {
              type: "string",
              description: "Find by title if id is omitted; also used as the new title when rename is set",
            },
            rename: {
              type: "string",
              description: "Optional new title (keeps identity; use with id)",
            },
            content: {
              type: "string",
              description: "New or appended notes body (manual_notes)",
            },
            summary: {
              type: "string",
              description: "New or appended AI summary field",
            },
            folder: {
              type: "string",
              description: "Move to this folder (empty string clears folder / unfiled)",
            },
            append: {
              type: "boolean",
              description: "If true, append content/summary with a blank line separator (default false = replace)",
            },
          },
        },
      },
      {
        name: "list_tasks",
        description:
          "List Grist tasks. Filter by status (open/done/all), source meeting, or text query.",
        inputSchema: {
          type: "object",
          properties: {
            status: {
              type: "string",
              enum: ["open", "done", "all"],
              description: "Default open",
            },
            source_meeting_id: {
              type: "string",
              description: "Only tasks linked to this meeting/note id",
            },
            query: {
              type: "string",
              description: "Search in title or notes",
            },
            limit: {
              type: "number",
              description: "Max results (default 50, max 200)",
            },
          },
        },
      },
      {
        name: "get_task",
        description: "Get one task by id or title.",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string" },
            title: { type: "string", description: "Match title if id unknown" },
          },
        },
      },
      {
        name: "create_task",
        description:
          "Create an open task. Optionally link it to a meeting/note via source_meeting_id or source_title.",
        inputSchema: {
          type: "object",
          properties: {
            title: { type: "string", description: "Task title" },
            notes: { type: "string", description: "Optional details" },
            source_meeting_id: {
              type: "string",
              description: "Link to meeting/note id (from list_notes)",
            },
            source_title: {
              type: "string",
              description: "Or resolve source by meeting/note title",
            },
          },
          required: ["title"],
        },
      },
      {
        name: "complete_task",
        description: "Mark a task as done (finish). Identify by id or title.",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string" },
            title: { type: "string" },
          },
        },
      },
      {
        name: "reopen_task",
        description: "Mark a done task as open again.",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string" },
            title: { type: "string" },
          },
        },
      },
      {
        name: "update_task",
        description: "Update task title, notes, and/or source link.",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string", description: "Preferred" },
            title: { type: "string", description: "Find by title if id omitted" },
            rename: { type: "string", description: "New title" },
            notes: { type: "string", description: "Replace notes" },
            source_meeting_id: {
              type: "string",
              description: "Set/change linked meeting id (empty string clears)",
            },
            source_title: {
              type: "string",
              description: "Set source label / resolve meeting by title",
            },
          },
        },
      },
      {
        name: "delete_task",
        description: "Soft-delete a task (hidden in Grist, not hard-removed).",
        inputSchema: {
          type: "object",
          properties: {
            id: { type: "string" },
            title: { type: "string" },
          },
        },
      },
    ],
  };
});

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const args = request.params.arguments ?? {};

  switch (request.params.name) {
    case "list_folders": {
      const folders = db.prepare("SELECT name FROM folders ORDER BY name ASC").all();
      return {
        content: [{ type: "text", text: JSON.stringify(folders.map((f) => f.name), null, 2) }],
      };
    }

    case "list_notes": {
      const limit = Math.min(Math.max(Number(args.limit) || 30, 1), 100);
      const kind = args.kind || "all";
      const clauses = ["is_deleted = 0"];
      const params = [];

      if (args.folder) {
        clauses.push("group_name = ?");
        params.push(args.folder);
      }
      if (kind === "notes") {
        clauses.push("template = 'Note'");
      } else if (kind === "meetings") {
        clauses.push("(template IS NULL OR template != 'Note')");
      }
      if (args.query) {
        clauses.push("(title LIKE ? OR manual_notes LIKE ? OR summary LIKE ?)");
        const q = `%${args.query}%`;
        params.push(q, q, q);
      }

      const sql = `
        SELECT id, title, timestamp, group_name, template,
               length(manual_notes) AS notes_len,
               length(summary) AS summary_len
        FROM meetings
        WHERE ${clauses.join(" AND ")}
        ORDER BY timestamp DESC
        LIMIT ?
      `;
      params.push(limit);
      const rows = db.prepare(sql).all(...params);
      const out = rows.map((r) => ({
        id: r.id,
        title: r.title,
        folder: r.group_name || null,
        kind: r.template === "Note" ? "note" : "meeting",
        timestamp: r.timestamp,
        notes_chars: r.notes_len ?? 0,
        summary_chars: r.summary_len ?? 0,
      }));
      return {
        content: [{ type: "text", text: JSON.stringify(out, null, 2) }],
      };
    }

    case "get_note": {
      if (!args.id && !args.title) {
        throw new Error("Provide id or title");
      }
      const row = findNote({ id: args.id, title: args.title });
      if (!row) {
        return {
          content: [{ type: "text", text: "No matching note/meeting found." }],
          isError: true,
        };
      }
      return {
        content: [{ type: "text", text: JSON.stringify(rowToNote(row), null, 2) }],
      };
    }

    case "create_note": {
      const { title, content, summary, folder } = args;
      if (!title || content === undefined) {
        throw new Error("title and content are required");
      }
      ensureFolder(folder);

      const id = crypto.randomUUID();
      const timestamp = Date.now() / 1000;
      db.prepare(`
        INSERT INTO meetings (id, title, timestamp, manual_notes, transcript, summary, template, group_name, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `).run(
        id,
        title,
        timestamp,
        content ?? "",
        "",
        summary ?? "",
        "Note",
        folder || "",
        0
      );

      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                ok: true,
                id,
                title,
                folder: folder || null,
                message: `Created note '${title}'${folder ? ` in '${folder}'` : ""}.`,
              },
              null,
              2
            ),
          },
        ],
      };
    }

    case "update_note": {
      if (!args.id && !args.title) {
        throw new Error("Provide id or title to identify the note");
      }
      if (
        args.content === undefined &&
        args.summary === undefined &&
        args.folder === undefined &&
        args.rename === undefined
      ) {
        throw new Error("Provide at least one of: content, summary, folder, rename");
      }

      const row = findNote({ id: args.id, title: args.title });
      if (!row) {
        return {
          content: [{ type: "text", text: "No matching note/meeting found to update." }],
          isError: true,
        };
      }

      const append = Boolean(args.append);
      let newTitle = row.title;
      let newNotes = row.manual_notes ?? "";
      let newSummary = row.summary ?? "";
      let newFolder = row.group_name ?? "";

      if (typeof args.rename === "string" && args.rename.trim()) {
        newTitle = args.rename.trim();
      }
      if (typeof args.content === "string") {
        newNotes = append && newNotes
          ? `${newNotes.replace(/\s+$/, "")}\n\n${args.content}`
          : args.content;
      }
      if (typeof args.summary === "string") {
        newSummary = append && newSummary
          ? `${newSummary.replace(/\s+$/, "")}\n\n${args.summary}`
          : args.summary;
      }
      if (typeof args.folder === "string") {
        newFolder = args.folder;
        if (newFolder) ensureFolder(newFolder);
      }

      db.prepare(`
        UPDATE meetings
        SET title = ?, manual_notes = ?, summary = ?, group_name = ?
        WHERE id = ?
      `).run(newTitle, newNotes, newSummary, newFolder, row.id);

      const updated = findNote({ id: row.id });
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              {
                ok: true,
                message: `Updated '${newTitle}' (${row.id}).`,
                note: rowToNote(updated),
              },
              null,
              2
            ),
          },
        ],
      };
    }

    case "list_tasks": {
      const status = args.status || "open";
      const limit = Math.min(Math.max(Number(args.limit) || 50, 1), 200);
      const clauses = ["is_deleted = 0"];
      const params = [];
      if (status === "open" || status === "done") {
        clauses.push("status = ?");
        params.push(status);
      }
      if (args.source_meeting_id) {
        clauses.push("source_meeting_id = ?");
        params.push(args.source_meeting_id);
      }
      if (args.query) {
        clauses.push("(title LIKE ? OR notes LIKE ?)");
        const q = `%${args.query}%`;
        params.push(q, q);
      }
      const sql = `
        SELECT id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted
        FROM tasks
        WHERE ${clauses.join(" AND ")}
        ORDER BY CASE status WHEN 'open' THEN 0 ELSE 1 END, created_at DESC
        LIMIT ?
      `;
      params.push(limit);
      const rows = db.prepare(sql).all(...params);
      return {
        content: [{ type: "text", text: JSON.stringify(rows.map(rowToTask), null, 2) }],
      };
    }

    case "get_task": {
      if (!args.id && !args.title) throw new Error("Provide id or title");
      const row = findTask({ id: args.id, title: args.title });
      if (!row) {
        return {
          content: [{ type: "text", text: "No matching task found." }],
          isError: true,
        };
      }
      return {
        content: [{ type: "text", text: JSON.stringify(rowToTask(row), null, 2) }],
      };
    }

    case "create_task": {
      const title = (args.title || "").trim();
      if (!title) throw new Error("title is required");
      const { sid, stitle } = resolveSourceMeeting(args.source_meeting_id, args.source_title);
      const id = crypto.randomUUID();
      const now = Date.now() / 1000;
      db.prepare(`
        INSERT INTO tasks
        (id, title, notes, source_meeting_id, source_title, status, created_at, completed_at, is_deleted)
        VALUES (?, ?, ?, ?, ?, 'open', ?, NULL, 0)
      `).run(id, title, args.notes ?? "", sid, stitle, now);
      const created = findTask({ id });
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              { ok: true, message: `Created task '${title}'.`, task: rowToTask(created) },
              null,
              2
            ),
          },
        ],
      };
    }

    case "complete_task": {
      if (!args.id && !args.title) throw new Error("Provide id or title");
      const row = findTask({ id: args.id, title: args.title });
      if (!row) {
        return {
          content: [{ type: "text", text: "No matching task found." }],
          isError: true,
        };
      }
      const now = Date.now() / 1000;
      db.prepare(`UPDATE tasks SET status = 'done', completed_at = ? WHERE id = ?`).run(now, row.id);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              { ok: true, message: `Completed '${row.title}'.`, task: rowToTask(findTask({ id: row.id })) },
              null,
              2
            ),
          },
        ],
      };
    }

    case "reopen_task": {
      if (!args.id && !args.title) throw new Error("Provide id or title");
      const row = findTask({ id: args.id, title: args.title });
      if (!row) {
        return {
          content: [{ type: "text", text: "No matching task found." }],
          isError: true,
        };
      }
      db.prepare(`UPDATE tasks SET status = 'open', completed_at = NULL WHERE id = ?`).run(row.id);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              { ok: true, message: `Reopened '${row.title}'.`, task: rowToTask(findTask({ id: row.id })) },
              null,
              2
            ),
          },
        ],
      };
    }

    case "update_task": {
      if (!args.id && !args.title) throw new Error("Provide id or title");
      if (
        args.rename === undefined &&
        args.notes === undefined &&
        args.source_meeting_id === undefined &&
        args.source_title === undefined
      ) {
        throw new Error("Provide at least one of: rename, notes, source_meeting_id, source_title");
      }
      const row = findTask({ id: args.id, title: args.title });
      if (!row) {
        return {
          content: [{ type: "text", text: "No matching task found." }],
          isError: true,
        };
      }
      let newTitle = row.title;
      let newNotes = row.notes ?? "";
      let sid = row.source_meeting_id;
      let stitle = row.source_title;
      if (typeof args.rename === "string" && args.rename.trim()) {
        newTitle = args.rename.trim();
      }
      if (typeof args.notes === "string") {
        newNotes = args.notes;
      }
      if (args.source_meeting_id !== undefined || args.source_title !== undefined) {
        const resolved = resolveSourceMeeting(
          args.source_meeting_id !== undefined ? args.source_meeting_id : sid,
          args.source_title !== undefined ? args.source_title : stitle
        );
        if (args.source_meeting_id === "") {
          sid = null;
          stitle = typeof args.source_title === "string" ? args.source_title || null : null;
        } else {
          sid = resolved.sid;
          stitle = resolved.stitle;
        }
      }
      db.prepare(`
        UPDATE tasks
        SET title = ?, notes = ?, source_meeting_id = ?, source_title = ?
        WHERE id = ?
      `).run(newTitle, newNotes, sid, stitle, row.id);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(
              { ok: true, message: `Updated task '${newTitle}'.`, task: rowToTask(findTask({ id: row.id })) },
              null,
              2
            ),
          },
        ],
      };
    }

    case "delete_task": {
      if (!args.id && !args.title) throw new Error("Provide id or title");
      const row = findTask({ id: args.id, title: args.title });
      if (!row) {
        return {
          content: [{ type: "text", text: "No matching task found." }],
          isError: true,
        };
      }
      db.prepare(`UPDATE tasks SET is_deleted = 1 WHERE id = ?`).run(row.id);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify({ ok: true, message: `Deleted task '${row.title}' (${row.id}).` }, null, 2),
          },
        ],
      };
    }

    default:
      throw new Error(`Unknown tool: ${request.params.name}`);
  }
});

async function run() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Grist MCP Server running on stdio");
}

run().catch(console.error);
