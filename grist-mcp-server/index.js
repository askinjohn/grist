#!/usr/bin/env bun
/**
 * Grist MCP server — compile with Bun for Claude Desktop:
 *   bun install && bun build ./index.js --compile --outfile grist-mcp-server
 *
 * Tools: list_folders, create_note
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

// Connect to Grist's SQLite DB (create empty file if app hasn't run yet)
const dbPath = path.join(os.homedir(), "Library/Application Support/Grist/meetings.db");
fs.mkdirSync(path.dirname(dbPath), { recursive: true });
const db = new Database(dbPath);

// Ensure tables exist so MCP works even before the first app launch
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

const server = new Server(
  {
    name: "grist-mcp-server",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// Define tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [
      {
        name: "list_folders",
        description: "List all existing folders in Grist.",
        inputSchema: {
          type: "object",
          properties: {},
        },
      },
      {
        name: "create_note",
        description: "Create a new note/meeting in Grist. This allows you to push summaries, daily updates, or logs directly into the user's Grist app.",
        inputSchema: {
          type: "object",
          properties: {
            title: {
              type: "string",
              description: "The title of the note",
            },
            content: {
              type: "string",
              description: "The main content or summary of the note (Markdown supported)",
            },
            folder: {
              type: "string",
              description: "Optional folder name to group the note in (must be an existing folder or a new one)",
            },
          },
          required: ["title", "content"],
        },
      },
    ],
  };
});

// Handle tool execution
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  switch (request.params.name) {
    case "list_folders": {
      const stmt = db.prepare("SELECT name FROM folders");
      const folders = stmt.all();
      const folderNames = folders.map(f => f.name);
      return {
        content: [
          {
            type: "text",
            text: JSON.stringify(folderNames, null, 2),
          },
        ],
      };
    }

    case "create_note": {
      const { title, content, folder } = request.params.arguments;

      // If a folder is provided, ensure it exists in the folders table
      if (folder) {
        const checkFolder = db.prepare("SELECT name FROM folders WHERE name = ?").get(folder);
        if (!checkFolder) {
          const now = Date.now() / 1000;
          db.prepare("INSERT INTO folders (name, created_at) VALUES (?, ?)").run(folder, now);
        }
      }

      // Generate a UUID for the new meeting/note
      const crypto = await import('crypto');
      const uuid = crypto.randomUUID();
      const timestamp = Date.now() / 1000;

      // Insert into meetings table
      const insertStmt = db.prepare(`
        INSERT INTO meetings (id, title, timestamp, manual_notes, transcript, summary, template, group_name, is_deleted)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
      `);

      insertStmt.run(
        uuid,
        title,
        timestamp,
        "", // manualNotes
        "", // transcript
        content, // summary (this is where the AI generated note goes)
        "Default", // template
        folder || null, // groupName
        0 // isDeleted
      );

      return {
        content: [
          {
            type: "text",
            text: `Successfully created note '${title}' in folder '${folder || "None"}' with ID ${uuid}.`,
          },
        ],
      };
    }

    default:
      throw new Error(`Unknown tool: ${request.params.name}`);
  }
});

// Run server
async function run() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  console.error("Grist MCP Server running on stdio");
}

run().catch(console.error);
