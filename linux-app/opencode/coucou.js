// Plugin OpenCode → bridge Coucou (status sesi di island).
//
// Dipasang (symlink) oleh agent_hooks_install.py ke ~/.config/opencode/plugins/.
// Pengiriman tidak pernah di-await dan semua error ditelan: OpenCode tidak boleh
// tertahan atau gagal karena Coucou mati/lambat. Token hanya dikirim ke 127.0.0.1.
import { readFileSync } from "node:fs";
import { basename, join } from "node:path";
import { tmpdir } from "node:os";

const PORT = process.env.HERMES_COUCOU_PORT || "4848";

function tokenPath() {
  const runtime = process.env.XDG_RUNTIME_DIR;
  return runtime
    ? join(runtime, "hermes-coucou", "bridge.token")
    : join(tmpdir(), `hermes-coucou-${process.getuid()}`, "bridge.token");
}

function short(text, limit = 80) {
  const clean = String(text ?? "").split(/\s+/).filter(Boolean).join(" ");
  return clean.length <= limit ? clean : clean.slice(0, limit - 1) + "…";
}

// "bash: git status" / "edit: main.ts" — cukup untuk dibaca sekilas.
function summary(tool, args) {
  if (!args || typeof args !== "object") return tool;
  let detail = args.command || args.description;
  if (!detail) {
    const path = args.filePath || args.path;
    detail = path ? basename(String(path)) : args.pattern || args.url;
  }
  return detail ? `${tool}: ${short(detail, 60)}` : tool;
}

async function bridge(path, payload, timeoutMs) {
  const token = readFileSync(tokenPath(), "ascii").trim();
  if (!/^[0-9a-f]{64}$/.test(token)) throw new Error("bad token");
  const res = await fetch(`http://127.0.0.1:${PORT}${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ agent: "opencode", ...payload }),
    signal: AbortSignal.timeout(timeoutMs),
  });
  return res.json();
}

async function send(payload) {
  try {
    await bridge("/event", payload, 400);
  } catch {
    // Coucou tidak jalan / token belum ada: diam saja.
  }
}

// Panggil API server OpenCode lewat client plugin (ikut fetch & header direktori
// milik OpenCode); fallback ke serverUrl bila client internal tidak tersedia.
async function opencodePost(ctx, url, path, body) {
  const raw = ctx.client?._client;
  if (raw?.post) {
    const res = await raw.post({ url, path, body, headers: { "Content-Type": "application/json" } });
    if (res?.error) throw new Error(JSON.stringify(res.error));
    return;
  }
  let resolved = url;
  for (const [key, value] of Object.entries(path)) resolved = resolved.replace(`{${key}}`, encodeURIComponent(value));
  const res = await fetch(new URL(resolved.replace(/^\//, ""), ctx.serverUrl), {
    method: "POST",
    headers: { "Content-Type": "application/json", "x-opencode-directory": encodeURIComponent(ctx.directory || "") },
    body: JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`HTTP ${res.status}`);
}

const ASK_WAIT = 600; // detik; TUI tetap menampilkan prompt yang sama secara paralel

export const CoucouPlugin = async (ctx) => {
  const { directory } = ctx;
  const project = basename(directory || "") || "opencode";
  const children = new Set(); // sesi subagent: jangan dianggap "task selesai"

  // Tampilkan izin/pertanyaan di island; jawaban dikirim balik ke OpenCode.
  // Tidak di-await oleh handler event: OpenCode tidak pernah tertahan.
  const askIsland = (request, reply) => {
    void (async () => {
      try {
        const result = await bridge("/agent/request", { project, timeout: ASK_WAIT, ...request }, (ASK_WAIT + 10) * 1000);
        const answer = result?.status === "answered" ? result.answer : null;
        if (answer && answer.decision !== "terminal") await reply(answer);
      } catch {
        // Coucou mati / sudah dijawab di TUI: prompt OpenCode tetap jalan seperti biasa.
      }
    })();
  };
  const cancelIsland = (id) => {
    if (id) void bridge("/agent/request/cancel", { request_id: id }, 400).catch(() => {});
  };

  const emit = (event, sessionID, extra = {}) => {
    if (!sessionID || children.has(sessionID)) return;
    void send({ event, session_id: sessionID, project, ...extra });
  };

  return {
    event: async ({ event }) => {
      const p = event.properties || {};
      switch (event.type) {
        case "session.created":
          if (p.info?.parentID) children.add(p.info.id);
          else emit("AgentSessionStart", p.info?.id, { message: "Sesi dimulai" });
          break;
        case "session.idle":
          emit("AgentStop", p.sessionID, { message: "Giliran selesai" });
          break;
        case "session.error":
          emit("AgentStop", p.sessionID, {
            kind: "error",
            message: short(p.error?.data?.message || p.error?.name || "Error", 120),
          });
          break;
        case "session.deleted":
          emit("AgentSessionEnd", p.info?.id, { message: "Sesi dihapus" });
          children.delete(p.info?.id);
          break;
        // Izin/pertanyaan subagent tetap ditampilkan: itu juga butuh jawaban.
        case "permission.asked": {
          const detail = p.metadata?.command || (p.patterns || []).join(", ") || p.permission;
          askIsland(
            { kind: "permission", request_id: p.id, session_id: p.sessionID, title: `Izinkan ${p.permission}?`,
              detail: `${p.permission}: ${short(detail, 600)}`, can_always: (p.always || []).length > 0,
              command: p.permission === "bash" && typeof p.metadata?.command === "string" ? p.metadata.command : "" },
            (answer) => opencodePost(ctx, "/permission/{requestID}/reply", { requestID: p.id }, {
              reply: { allow: "once", always: "always", deny: "reject" }[answer.decision] || "reject",
            }),
          );
          break;
        }
        case "permission.updated": // API lama (v1)
          askIsland(
            { kind: "permission", request_id: p.id, session_id: p.sessionID, title: "Izinkan?",
              detail: short(p.title || p.type || "Butuh izin", 600), can_always: true },
            (answer) => opencodePost(ctx, "/session/{id}/permissions/{permissionID}", { id: p.sessionID, permissionID: p.id }, {
              response: { allow: "once", always: "always", deny: "reject" }[answer.decision] || "reject",
            }),
          );
          break;
        case "permission.replied":
          cancelIsland(p.requestID || p.permissionID);
          emit("AgentToolStart", p.sessionID, { message: "Izin dijawab" });
          break;
        case "question.asked":
          askIsland(
            { kind: "question", request_id: p.id, session_id: p.sessionID, title: "OpenCode bertanya",
              questions: (p.questions || []).map((q) => ({
                question: q.question, header: q.header, options: q.options || [],
                multiSelect: !!q.multiple, custom: q.custom !== false,
              })) },
            (answer) => opencodePost(ctx, "/question/{requestID}/reply", { requestID: p.id }, { answers: answer.answers }),
          );
          break;
        case "question.replied":
        case "question.rejected":
          cancelIsland(p.requestID);
          break;
      }
    },
    "chat.message": async (input, output) => {
      const text = (output.parts || [])
        .filter((part) => part.type === "text" && !part.synthetic)
        .map((part) => part.text)
        .join(" ");
      emit("AgentPrompt", input.sessionID, { message: short(text) || "Prompt baru" });
    },
    "tool.execute.before": async (input, output) => {
      emit("AgentToolStart", input.sessionID, { tool_name: input.tool, message: summary(input.tool, output.args) });
    },
    "tool.execute.after": async (input) => {
      emit("AgentToolDone", input.sessionID, { tool_name: input.tool, message: summary(input.tool, input.args) });
    },
  };
};
