import { Database } from "bun:sqlite";
import { Hono } from "hono";
import { cors } from "hono/cors";
import { timingSafeEqual } from "node:crypto";
import { mkdirSync } from "fs";
import { dirname, resolve } from "path";

const VERSION = "0.1.0";
const PORT = Number(process.env.PORT || 8787);
const HOST = process.env.HOST || "0.0.0.0";
const DB_PATH = resolve(process.env.DB_PATH || "./data/quern-sync.db");

function ensureToken(): string {
  let token = process.env.QUERN_SYNC_TOKEN;
  if (!token) {
    token = crypto.randomUUID().replace(/-/g, "") + crypto.randomUUID().replace(/-/g, "");
    process.env.QUERN_SYNC_TOKEN = token;
    console.warn(
      "[quern-sync] QUERN_SYNC_TOKEN not set — generated a dev token (do not use in production):\n" +
        `  ${token}`,
    );
  }
  return token;
}

const SYNC_TOKEN = ensureToken();

mkdirSync(dirname(DB_PATH), { recursive: true });

const db = new Database(DB_PATH, { create: true });
db.exec("PRAGMA journal_mode=WAL;");
db.exec("PRAGMA busy_timeout=5000;");
db.exec("PRAGMA synchronous=NORMAL;");
db.exec(`
  CREATE TABLE IF NOT EXISTS meetings (
    id TEXT PRIMARY KEY,
    title TEXT,
    timestamp REAL,
    manual_notes TEXT,
    transcript TEXT,
    summary TEXT,
    template TEXT,
    group_name TEXT,
    duration_seconds INTEGER DEFAULT 0,
    is_deleted INTEGER DEFAULT 0,
    updated_at REAL NOT NULL
  );
  CREATE TABLE IF NOT EXISTS folders (
    name TEXT PRIMARY KEY,
    created_at REAL,
    updated_at REAL
  );
  CREATE TABLE IF NOT EXISTS tasks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    notes TEXT DEFAULT '',
    source_meeting_id TEXT,
    source_title TEXT,
    status TEXT DEFAULT 'open',
    created_at REAL,
    completed_at REAL,
    is_deleted INTEGER DEFAULT 0,
    updated_at REAL NOT NULL
  );
`);

function bearerMatches(header: string | undefined, expected: string): boolean {
  if (!header || !header.startsWith("Bearer ")) return false;
  const got = header.slice("Bearer ".length).trim();
  const a = Buffer.from(got);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  try {
    return timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

type MeetingIn = {
  id: string;
  title?: string | null;
  timestamp?: number | null;
  manual_notes?: string | null;
  transcript?: string | null;
  summary?: string | null;
  template?: string | null;
  group_name?: string | null;
  duration_seconds?: number | null;
  is_deleted?: boolean | number | null;
  updated_at: number;
};

type FolderIn = {
  name: string;
  created_at?: number | null;
  updated_at: number;
};

type TaskIn = {
  id: string;
  title: string;
  notes?: string | null;
  source_meeting_id?: string | null;
  source_title?: string | null;
  status?: string | null;
  created_at?: number | null;
  completed_at?: number | null;
  is_deleted?: boolean | number | null;
  updated_at: number;
};

function asBoolInt(v: boolean | number | null | undefined): number {
  if (v === true || v === 1) return 1;
  return 0;
}

const getMeetingUpdated = db.prepare(
  "SELECT updated_at FROM meetings WHERE id = ?",
);
const upsertMeeting = db.prepare(`
  INSERT INTO meetings (
    id, title, timestamp, manual_notes, transcript, summary,
    template, group_name, duration_seconds, is_deleted, updated_at
  ) VALUES (
    $id, $title, $timestamp, $manual_notes, $transcript, $summary,
    $template, $group_name, $duration_seconds, $is_deleted, $updated_at
  )
  ON CONFLICT(id) DO UPDATE SET
    title = excluded.title,
    timestamp = excluded.timestamp,
    manual_notes = excluded.manual_notes,
    transcript = excluded.transcript,
    summary = excluded.summary,
    template = excluded.template,
    group_name = excluded.group_name,
    duration_seconds = excluded.duration_seconds,
    is_deleted = excluded.is_deleted,
    updated_at = excluded.updated_at
`);

const getFolderUpdated = db.prepare(
  "SELECT updated_at FROM folders WHERE name = ?",
);
const upsertFolder = db.prepare(`
  INSERT INTO folders (name, created_at, updated_at)
  VALUES ($name, $created_at, $updated_at)
  ON CONFLICT(name) DO UPDATE SET
    created_at = COALESCE(excluded.created_at, folders.created_at),
    updated_at = excluded.updated_at
`);

const getTaskUpdated = db.prepare("SELECT updated_at FROM tasks WHERE id = ?");
const upsertTask = db.prepare(`
  INSERT INTO tasks (
    id, title, notes, source_meeting_id, source_title,
    status, created_at, completed_at, is_deleted, updated_at
  ) VALUES (
    $id, $title, $notes, $source_meeting_id, $source_title,
    $status, $created_at, $completed_at, $is_deleted, $updated_at
  )
  ON CONFLICT(id) DO UPDATE SET
    title = excluded.title,
    notes = excluded.notes,
    source_meeting_id = excluded.source_meeting_id,
    source_title = excluded.source_title,
    status = excluded.status,
    created_at = excluded.created_at,
    completed_at = excluded.completed_at,
    is_deleted = excluded.is_deleted,
    updated_at = excluded.updated_at
`);

const app = new Hono();

app.use(
  "/v1/*",
  cors({
    origin: (origin) => origin || "*",
    allowMethods: ["GET", "POST", "OPTIONS"],
    allowHeaders: ["Authorization", "Content-Type"],
  }),
);

app.use("/v1/*", async (c, next) => {
  if (c.req.path === "/v1/health") return next();
  const auth = c.req.header("Authorization");
  if (!bearerMatches(auth, SYNC_TOKEN)) {
    return c.json({ error: "unauthorized" }, 401);
  }
  return next();
});

app.get("/v1/health", (c) => c.json({ ok: true, version: VERSION }));

app.post("/v1/sync/push", async (c) => {
  let body: {
    meetings?: MeetingIn[];
    folders?: FolderIn[];
    tasks?: TaskIn[];
  };
  try {
    body = await c.req.json();
  } catch {
    return c.json({ error: "invalid json" }, 400);
  }

  const counts = { meetings: 0, folders: 0, tasks: 0 };

  const push = db.transaction(() => {
    for (const m of body.meetings ?? []) {
      if (!m?.id || typeof m.updated_at !== "number") continue;
      const existing = getMeetingUpdated.get(m.id) as
        | { updated_at: number }
        | null
        | undefined;
      if (existing && existing.updated_at > m.updated_at) continue;
      upsertMeeting.run({
        $id: m.id,
        $title: m.title ?? null,
        $timestamp: m.timestamp ?? null,
        $manual_notes: m.manual_notes ?? null,
        $transcript: m.transcript ?? null,
        $summary: m.summary ?? null,
        $template: m.template ?? null,
        $group_name: m.group_name ?? null,
        $duration_seconds: m.duration_seconds ?? 0,
        $is_deleted: asBoolInt(m.is_deleted),
        $updated_at: m.updated_at,
      });
      counts.meetings += 1;
    }

    for (const f of body.folders ?? []) {
      if (!f?.name || typeof f.updated_at !== "number") continue;
      const existing = getFolderUpdated.get(f.name) as
        | { updated_at: number }
        | null
        | undefined;
      if (existing && existing.updated_at > f.updated_at) continue;
      upsertFolder.run({
        $name: f.name,
        $created_at: f.created_at ?? null,
        $updated_at: f.updated_at,
      });
      counts.folders += 1;
    }

    for (const t of body.tasks ?? []) {
      if (!t?.id || typeof t.updated_at !== "number" || !t.title) continue;
      const existing = getTaskUpdated.get(t.id) as
        | { updated_at: number }
        | null
        | undefined;
      if (existing && existing.updated_at > t.updated_at) continue;
      upsertTask.run({
        $id: t.id,
        $title: t.title,
        $notes: t.notes ?? "",
        $source_meeting_id: t.source_meeting_id ?? null,
        $source_title: t.source_title ?? null,
        $status: t.status ?? "open",
        $created_at: t.created_at ?? null,
        $completed_at: t.completed_at ?? null,
        $is_deleted: asBoolInt(t.is_deleted),
        $updated_at: t.updated_at,
      });
      counts.tasks += 1;
    }
  });

  push();
  return c.json({ ok: true, upserted: counts });
});

app.get("/v1/library", (c) => {
  const limitRaw = c.req.query("limit");
  const limit = Math.min(
    Math.max(Number(limitRaw || 100) || 100, 1),
    1000,
  );
  const folder = c.req.query("folder");
  const q = c.req.query("q");

  const clauses = ["is_deleted = 0"];
  const params: (string | number)[] = [];

  if (folder) {
    clauses.push("group_name = ?");
    params.push(folder);
  }
  if (q) {
    clauses.push("title LIKE ?");
    params.push(`%${q}%`);
  }

  const sql = `
    SELECT id, title, timestamp, template, group_name, updated_at
    FROM meetings
    WHERE ${clauses.join(" AND ")}
    ORDER BY timestamp DESC
    LIMIT ?
  `;
  params.push(limit);

  const rows = db.prepare(sql).all(...params) as Array<{
    id: string;
    title: string | null;
    timestamp: number | null;
    template: string | null;
    group_name: string | null;
    updated_at: number;
  }>;

  const items = rows.map((r) => ({
    id: r.id,
    title: r.title,
    timestamp: r.timestamp,
    template: r.template,
    group_name: r.group_name,
    updated_at: r.updated_at,
    kind: r.template === "Note" ? "note" : "meeting",
  }));

  return c.json({ items });
});

app.get("/v1/notes/:id", (c) => {
  const id = c.req.param("id");
  const row = db
    .prepare("SELECT * FROM meetings WHERE id = ? AND is_deleted = 0")
    .get(id) as Record<string, unknown> | null | undefined;
  if (!row) return c.json({ error: "not found" }, 404);
  return c.json({
    ...row,
    is_deleted: Boolean(row.is_deleted),
  });
});

app.get("/v1/tasks", (c) => {
  const status = (c.req.query("status") || "open").toLowerCase();
  const clauses = ["is_deleted = 0"];
  const params: string[] = [];

  if (status === "open" || status === "done") {
    clauses.push("status = ?");
    params.push(status);
  } else if (status !== "all") {
    return c.json({ error: "status must be open|done|all" }, 400);
  }

  const rows = db
    .prepare(
      `SELECT * FROM tasks WHERE ${clauses.join(" AND ")} ORDER BY created_at DESC`,
    )
    .all(...params) as Array<Record<string, unknown>>;

  const items = rows.map((r) => ({
    ...r,
    is_deleted: Boolean(r.is_deleted),
  }));
  return c.json({ items });
});

app.get("/v1/folders", (c) => {
  const items = db
    .prepare("SELECT name, created_at, updated_at FROM folders ORDER BY name ASC")
    .all();
  return c.json({ items });
});

app.get("/v1/changes", (c) => {
  const sinceRaw = c.req.query("since");
  const since = Number(sinceRaw);
  if (!Number.isFinite(since)) {
    return c.json({ error: "since query param required (unix timestamp)" }, 400);
  }

  const meetings = db
    .prepare("SELECT * FROM meetings WHERE updated_at > ? ORDER BY updated_at ASC")
    .all(since) as Array<Record<string, unknown>>;
  const tasks = db
    .prepare("SELECT * FROM tasks WHERE updated_at > ? ORDER BY updated_at ASC")
    .all(since) as Array<Record<string, unknown>>;
  const folders = db
    .prepare(
      "SELECT name, created_at, updated_at FROM folders WHERE updated_at > ? ORDER BY updated_at ASC",
    )
    .all(since);

  return c.json({
    meetings: meetings.map((m) => ({ ...m, is_deleted: Boolean(m.is_deleted) })),
    tasks: tasks.map((t) => ({ ...t, is_deleted: Boolean(t.is_deleted) })),
    folders,
  });
});

console.log(`[quern-sync] listening on http://${HOST}:${PORT}`);
console.log(`[quern-sync] db=${DB_PATH}`);

export default {
  port: PORT,
  hostname: HOST,
  fetch: app.fetch,
};
