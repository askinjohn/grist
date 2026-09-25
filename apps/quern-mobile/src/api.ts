export type LibraryItem = {
  id: string;
  title: string;
  timestamp: number;
  template: string;
  group_name: string;
  updated_at: number;
  kind: string;
};

export type NoteDetail = {
  id: string;
  title: string;
  timestamp: number;
  manual_notes: string;
  transcript: string;
  summary: string;
  template: string;
  group_name: string;
  duration_seconds: number;
  updated_at: number;
};

export type TaskItem = {
  id: string;
  title: string;
  notes: string;
  source_meeting_id: string | null;
  source_title: string | null;
  status: string;
  created_at: number;
  completed_at: number | null;
};

function normalizeBase(url: string): string {
  return url.trim().replace(/\/+$/, "");
}

async function request<T>(
  baseURL: string,
  token: string,
  path: string
): Promise<T> {
  const res = await fetch(`${normalizeBase(baseURL)}${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/json",
    },
  });
  if (!res.ok) {
    const body = await res.text();
    throw new Error(`${res.status}: ${body.slice(0, 160)}`);
  }
  return (await res.json()) as T;
}

export async function fetchHealth(baseURL: string): Promise<{ ok?: boolean; version?: string }> {
  const res = await fetch(`${normalizeBase(baseURL)}/v1/health`);
  if (!res.ok) throw new Error(`Health ${res.status}`);
  return res.json();
}

export async function fetchLibrary(
  baseURL: string,
  token: string
): Promise<LibraryItem[]> {
  const data = await request<{ items: LibraryItem[] }>(baseURL, token, "/v1/library?limit=200");
  return data.items ?? [];
}

export async function fetchNote(
  baseURL: string,
  token: string,
  id: string
): Promise<NoteDetail> {
  return request<NoteDetail>(baseURL, token, `/v1/notes/${encodeURIComponent(id)}`);
}

export async function fetchTasks(
  baseURL: string,
  token: string
): Promise<TaskItem[]> {
  const data = await request<{ items?: TaskItem[]; tasks?: TaskItem[] }>(
    baseURL,
    token,
    "/v1/tasks?status=open"
  );
  return data.items ?? data.tasks ?? [];
}
