import { StatusBar } from "expo-status-bar";
import { useCallback, useEffect, useMemo, useState } from "react";
import {
  ActivityIndicator,
  Pressable,
  RefreshControl,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import AsyncStorage from "@react-native-async-storage/async-storage";
import {
  fetchHealth,
  fetchLibrary,
  fetchNote,
  fetchTasks,
  LibraryItem,
  NoteDetail,
  TaskItem,
} from "./src/api";

const STORAGE_URL = "quern.sync.baseURL";
const STORAGE_TOKEN = "quern.sync.token";

type Tab = "library" | "tasks" | "settings";

export default function App() {
  const [baseURL, setBaseURL] = useState("");
  const [token, setToken] = useState("");
  const [ready, setReady] = useState(false);
  const [tab, setTab] = useState<Tab>("library");
  const [items, setItems] = useState<LibraryItem[]>([]);
  const [tasks, setTasks] = useState<TaskItem[]>([]);
  const [selected, setSelected] = useState<NoteDetail | null>(null);
  const [detailTab, setDetailTab] = useState<"summary" | "notes" | "transcript">("summary");
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [status, setStatus] = useState("");

  useEffect(() => {
    (async () => {
      const [u, t] = await Promise.all([
        AsyncStorage.getItem(STORAGE_URL),
        AsyncStorage.getItem(STORAGE_TOKEN),
      ]);
      if (u) setBaseURL(u);
      if (t) setToken(t);
      setReady(true);
    })();
  }, []);

  const configured = useMemo(
    () => baseURL.trim().length > 0 && token.trim().length > 0,
    [baseURL, token]
  );

  const saveSettings = async () => {
    await AsyncStorage.setItem(STORAGE_URL, baseURL.trim());
    await AsyncStorage.setItem(STORAGE_TOKEN, token.trim());
    setStatus("Saved");
    setTab("library");
  };

  const refreshLibrary = useCallback(async () => {
    if (!configured) return;
    setLoading(true);
    setError("");
    try {
      const list = await fetchLibrary(baseURL, token);
      setItems(list);
      setStatus(`${list.length} notes`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [baseURL, token, configured]);

  const refreshTasks = useCallback(async () => {
    if (!configured) return;
    setLoading(true);
    setError("");
    try {
      const list = await fetchTasks(baseURL, token);
      setTasks(list);
      setStatus(`${list.length} open tasks`);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  }, [baseURL, token, configured]);

  useEffect(() => {
    if (!ready || !configured) return;
    if (tab === "library" && !selected) refreshLibrary();
    if (tab === "tasks") refreshTasks();
  }, [ready, configured, tab, selected, refreshLibrary, refreshTasks]);

  const openNote = async (id: string) => {
    setLoading(true);
    setError("");
    try {
      const note = await fetchNote(baseURL, token, id);
      setSelected(note);
      setDetailTab(
        note.summary.trim()
          ? "summary"
          : note.manual_notes.trim()
            ? "notes"
            : "transcript"
      );
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setLoading(false);
    }
  };

  const testConnection = async () => {
    setError("");
    try {
      const h = await fetchHealth(baseURL);
      setStatus(h.ok ? `Server OK${h.version ? ` v${h.version}` : ""}` : "Unexpected health");
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  };

  if (!ready) {
    return (
      <View style={styles.center}>
        <ActivityIndicator />
      </View>
    );
  }

  return (
    <SafeAreaView style={styles.root}>
      <StatusBar style="dark" />
      <View style={styles.header}>
        <Text style={styles.brand}>Quern</Text>
        <Text style={styles.sub}>Companion</Text>
      </View>

      {selected ? (
        <View style={styles.flex}>
          <Pressable onPress={() => setSelected(null)} style={styles.back}>
            <Text style={styles.backText}>← Library</Text>
          </Pressable>
          <Text style={styles.title}>{selected.title || "Untitled"}</Text>
          <Text style={styles.meta}>
            {selected.template === "Note" ? "Note" : "Meeting"}
            {selected.group_name ? ` · ${selected.group_name}` : ""}
          </Text>
          <View style={styles.seg}>
            {(["summary", "notes", "transcript"] as const).map((t) => (
              <Pressable
                key={t}
                onPress={() => setDetailTab(t)}
                style={[styles.segBtn, detailTab === t && styles.segOn]}
              >
                <Text style={[styles.segText, detailTab === t && styles.segTextOn]}>
                  {t[0].toUpperCase() + t.slice(1)}
                </Text>
              </Pressable>
            ))}
          </View>
          <ScrollView style={styles.flex} contentContainerStyle={styles.pad}>
            <Text style={styles.body}>
              {detailTab === "summary"
                ? selected.summary || "No summary"
                : detailTab === "notes"
                  ? selected.manual_notes || "No notes"
                  : selected.transcript || "No transcript"}
            </Text>
          </ScrollView>
        </View>
      ) : (
        <View style={styles.flex}>
          {tab === "settings" || !configured ? (
            <ScrollView contentContainerStyle={styles.pad}>
              <Text style={styles.section}>Connect to your sync server</Text>
              <Text style={styles.hint}>
                Same base URL and token as Mac Quern → Settings → Companion sync
              </Text>
              <Text style={styles.label}>Base URL</Text>
              <TextInput
                style={styles.input}
                autoCapitalize="none"
                autoCorrect={false}
                placeholder="http://192.168.1.10:8787"
                value={baseURL}
                onChangeText={setBaseURL}
              />
              <Text style={styles.label}>API token</Text>
              <TextInput
                style={styles.input}
                autoCapitalize="none"
                autoCorrect={false}
                secureTextEntry
                placeholder="QUERN_SYNC_TOKEN"
                value={token}
                onChangeText={setToken}
              />
              <View style={styles.row}>
                <Pressable style={styles.btnSecondary} onPress={testConnection}>
                  <Text style={styles.btnSecondaryText}>Test</Text>
                </Pressable>
                <Pressable style={styles.btn} onPress={saveSettings}>
                  <Text style={styles.btnText}>Save</Text>
                </Pressable>
              </View>
            </ScrollView>
          ) : tab === "tasks" ? (
            <ScrollView
              refreshControl={
                <RefreshControl refreshing={loading} onRefresh={refreshTasks} />
              }
              contentContainerStyle={styles.pad}
            >
              {tasks.length === 0 && !loading ? (
                <Text style={styles.hint}>No open tasks</Text>
              ) : (
                tasks.map((t) => (
                  <View key={t.id} style={styles.card}>
                    <Text style={styles.cardTitle}>{t.title}</Text>
                    {!!t.source_title && (
                      <Text style={styles.meta}>From {t.source_title}</Text>
                    )}
                    {!!t.notes && <Text style={styles.cardBody}>{t.notes}</Text>}
                  </View>
                ))
              )}
            </ScrollView>
          ) : (
            <ScrollView
              refreshControl={
                <RefreshControl refreshing={loading} onRefresh={refreshLibrary} />
              }
              contentContainerStyle={styles.pad}
            >
              {items.length === 0 && !loading ? (
                <Text style={styles.hint}>Library empty — sync from Mac Quern</Text>
              ) : (
                items.map((item) => (
                  <Pressable
                    key={item.id}
                    style={styles.card}
                    onPress={() => openNote(item.id)}
                  >
                    <Text style={styles.cardTitle}>{item.title || "Untitled"}</Text>
                    <Text style={styles.meta}>
                      {item.kind === "note" || item.template === "Note"
                        ? "Note"
                        : "Meeting"}
                      {item.group_name ? ` · ${item.group_name}` : ""}
                    </Text>
                  </Pressable>
                ))
              )}
            </ScrollView>
          )}
        </View>
      )}

      {(error || status) && (
        <Text style={[styles.footer, error ? styles.err : undefined]}>
          {error || status}
        </Text>
      )}

      {!selected && (
        <View style={styles.tabs}>
          <TabBtn label="Library" active={tab === "library"} onPress={() => setTab("library")} />
          <TabBtn label="Tasks" active={tab === "tasks"} onPress={() => setTab("tasks")} />
          <TabBtn label="Settings" active={tab === "settings"} onPress={() => setTab("settings")} />
        </View>
      )}
    </SafeAreaView>
  );
}

function TabBtn({
  label,
  active,
  onPress,
}: {
  label: string;
  active: boolean;
  onPress: () => void;
}) {
  return (
    <Pressable onPress={onPress} style={[styles.tab, active && styles.tabOn]}>
      <Text style={[styles.tabText, active && styles.tabTextOn]}>{label}</Text>
    </Pressable>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: "#f7f5f2" },
  flex: { flex: 1 },
  center: { flex: 1, alignItems: "center", justifyContent: "center" },
  header: {
    paddingHorizontal: 16,
    paddingTop: 8,
    paddingBottom: 4,
    flexDirection: "row",
    alignItems: "baseline",
    gap: 8,
  },
  brand: { fontSize: 22, fontWeight: "700", color: "#1c1917" },
  sub: { fontSize: 14, color: "#78716c" },
  pad: { padding: 16, paddingBottom: 32 },
  section: { fontSize: 18, fontWeight: "600", marginBottom: 6 },
  hint: { color: "#78716c", marginBottom: 16, lineHeight: 20 },
  label: { fontSize: 13, fontWeight: "600", color: "#57534e", marginBottom: 6 },
  input: {
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#e7e5e4",
    borderRadius: 10,
    paddingHorizontal: 12,
    paddingVertical: 10,
    marginBottom: 14,
    fontSize: 15,
  },
  row: { flexDirection: "row", gap: 10, marginTop: 4 },
  btn: {
    backgroundColor: "#2563eb",
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 10,
  },
  btnText: { color: "#fff", fontWeight: "600" },
  btnSecondary: {
    backgroundColor: "#fff",
    borderWidth: 1,
    borderColor: "#d6d3d1",
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderRadius: 10,
  },
  btnSecondaryText: { color: "#1c1917", fontWeight: "600" },
  card: {
    backgroundColor: "#fff",
    borderRadius: 12,
    padding: 14,
    marginBottom: 10,
    borderWidth: 1,
    borderColor: "#e7e5e4",
  },
  cardTitle: { fontSize: 16, fontWeight: "600", color: "#1c1917" },
  cardBody: { marginTop: 6, color: "#44403c", lineHeight: 20 },
  meta: { marginTop: 4, fontSize: 12, color: "#78716c" },
  title: {
    fontSize: 20,
    fontWeight: "700",
    paddingHorizontal: 16,
    color: "#1c1917",
  },
  back: { paddingHorizontal: 16, paddingVertical: 8 },
  backText: { color: "#2563eb", fontWeight: "600" },
  seg: {
    flexDirection: "row",
    gap: 6,
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  segBtn: {
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 999,
    backgroundColor: "#e7e5e4",
  },
  segOn: { backgroundColor: "#1c1917" },
  segText: { fontSize: 13, color: "#44403c", fontWeight: "600" },
  segTextOn: { color: "#fff" },
  body: { fontSize: 15, lineHeight: 22, color: "#292524" },
  footer: {
    paddingHorizontal: 16,
    paddingVertical: 6,
    fontSize: 12,
    color: "#57534e",
  },
  err: { color: "#b91c1c" },
  tabs: {
    flexDirection: "row",
    borderTopWidth: 1,
    borderTopColor: "#e7e5e4",
    backgroundColor: "#fff",
  },
  tab: { flex: 1, paddingVertical: 12, alignItems: "center" },
  tabOn: { borderTopWidth: 2, borderTopColor: "#2563eb", marginTop: -1 },
  tabText: { color: "#78716c", fontWeight: "600" },
  tabTextOn: { color: "#2563eb" },
});
