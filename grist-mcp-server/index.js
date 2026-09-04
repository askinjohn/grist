#!/usr/bin/env bun
/**
 * Grist MCP server — compile with Bun for Claude Desktop:
 *   bun install && bun build ./index.js --compile --outfile grist-mcp-server
 *
 * Tools: list_folders, list_notes, get_note, create_note, update_note
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
    version: "1.1.0",
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
