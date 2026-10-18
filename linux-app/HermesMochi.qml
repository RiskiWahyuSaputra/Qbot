import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Quickshell
import Quickshell.Wayland
import Quickshell.Io

PanelWindow {
    id: root

    anchors {
        top: true
    }

    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.namespace: "hermes-mochi"
    WlrLayershell.exclusiveZone: 0
    // OnDemand saat panel terbuka: tanpa ini TextField catatan tidak pernah
    // menerima ketikan. Compositor memberi fokus hanya setelah diklik.
    WlrLayershell.keyboardFocus: ((islandExpanded && !isNotifying) || notifyType === "request") ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

    implicitWidth: 720
    // Kartu permintaan bisa tinggi; area transparan tetap click-through (mask = capsule).
    implicitHeight: ((islandExpanded && !isNotifying) || notifyType === "request") ? 420 : 64
    color: "transparent"

    // Input region mengikuti badan island saja (terbuka maupun tertutup): area
    // transparan di sekitarnya tidak menangkap klik (click-through) di Niri.
    mask: Region {
        item: islandCapsule
    }

    property bool islandExpanded: false
    property bool isNotifying: false
    property string notifyType: "" // "done" | "approval"
    property string activeTab: "notes" // Default tab Catatan; dipulihkan dari settings saat dimuat
    onActiveTabChanged: if (settingsReady) settings.tab = activeTab

    // Preferensi pengguna, tersimpan di ~/.config/hermes-coucou/settings.json
    // (bertahan setelah restart, tidak seperti PersistentProperties).
    property bool settingsReady: false
    readonly property var tabKeys: ["notes", "status", "usage", "tools", "projects", "dev", "interview"]

    FileView {
        id: settingsFile
        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/hermes-coucou/settings.json"
        onAdapterUpdated: if (root.settingsReady) settingsWriteTimer.restart()
        onLoaded: {
            if (root.tabKeys.indexOf(settings.tab) >= 0) root.activeTab = settings.tab;
            root.settingsReady = true;
        }
        onLoadFailed: error => {
            root.settingsReady = true;
            if (error == FileViewError.FileNotFound) {
                Quickshell.execDetached(["mkdir", "-p", path.substring(0, path.lastIndexOf("/"))]);
                settingsWriteTimer.restart();
            }
        }

        adapter: JsonAdapter {
            id: settings
            property string avatar: "white"
            property string tab: "notes"
        }
    }

    Timer {
        id: settingsWriteTimer
        interval: 400
        onTriggered: settingsFile.writeAdapter()
    }

    // Status
    property string currentStatus: "Standby"
    property string activeDetail: "Ready for tasks"
    property color statusColor: "#22c55e"
    readonly property string avatarModel: settings.avatar // "white" | "strobi" | "nova" | "citrus" | "kirby"
    property string avatarExpression: "proud" // "proud" | "happy" | "working" | "celebrate" | "idle" | "angry" | "dizzy" | "wave" | "task_start"

    // Eye Tracking Coordinates relative to pill
    property real cursorLookX: 0.0
    property real cursorLookY: 0.0
    property real cursorXInIsland: 0.0
    property real cursorYInIsland: 0.0
    property bool cursorOnRobot: false

    // Hover Anger & Dizzy Click State
    property bool isAngry: false
    property bool isDizzy: false
    property int robotClickCount: 0

    // Bridge & Approval State
    property bool bridgeReady: false          // proses bridge + HTTP lokal hidup
    property int bridgeFailCount: 0           // kegagalan bridge beruntun (cap restart)
    property bool hermesConnected: false      // WebSocket Hermes terhubung
    property bool hermesWorking: false        // ada task yang sedang berjalan
    property string hermesStatusMessage: ""   // pesan BridgeStatus terakhir
    property bool decisionPending: false      // keputusan sedang dikirim, tunggu ACK
    property bool approvalActionable: false   // approval valid & bisa diklik
    property string pendingSessionId: ""
    property string pendingRequestId: ""
    property string pendingDecisionId: ""
    property string pendingDecisionChoice: ""
    property int commandSeq: 0

    // Sesi agent coding (Claude Code via claude_hook.py, OpenCode via plugin),
    // terbaru di depan: {id, agent, project, state, detail, prompt, promptAt, updated}
    // state: idle | working | waiting | done | error
    property var agentSessions: []

    // Detail pill notifikasi yang sedang tampil.
    property string notifySource: ""          // hermes | claude | opencode
    property string notifyProject: ""
    property string notifyDuration: ""        // lama task, untuk pill "selesai"
    property bool notifyError: false
    property real notifyProgress: 1.0         // bar hitung mundur di bawah pill
    property double hermesTaskStartedAt: 0

    // Antrean izin/pertanyaan agent yang menunggu jawaban (yang pertama ditampilkan).
    // Item = event AgentRequest dari bridge: {request_id, agent, kind, project, title,
    // detail, can_always, questions:[{question, header, options:[{label, description}], multiSelect, custom}]}
    property var agentRequests: []
    readonly property var currentRequest: agentRequests.length > 0 ? agentRequests[0] : null
    property string reqShownId: ""
    property int reqIndex: 0                  // pertanyaan ke-berapa (multi-pertanyaan)
    property var reqSelections: []            // [[label]] per pertanyaan
    property bool reqSending: false
    property string reqError: ""
    property string reqAnswerCmdId: ""

    // Toast hasil aksi lokal (launch/media/clipboard)
    property string toastPrevStatus: ""
    property string toastPrevDetail: ""
    property color toastPrevColor: "#22c55e"

    // Folder aplikasi mengikuti lokasi file QML ini (tanpa path hardcoded).
    // Selalu diakhiri "/" supaya kontrak nama file benar.
    readonly property string appDir: {
        let u = Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "");
        return u.charAt(u.length - 1) === "/" ? u : u + "/";
    }

    // Notes Model
    ListModel {
        id: notesModel
    }

    // 9Router Usage State
    property int usageRequests: 0
    property real usageCost: 0.0
    property int usageTokens: 0
    property bool usageAvailable: false
    property bool usageLoaded: false

    property int usage60dRequests: 0
    property real usage60dCost: 0.0
    property int usage60dTokens: 0

    property var activeModelsList: []
    property var recentLogsList: []

    // System Monitor State (untuk Tab Status)
    property int sysCpu: 0
    property int sysRamPercent: 0
    property string sysRamUsed: "0 GB"
    property string sysRamTotal: "0 GB"
    property string sysUptime: "-"
    property string sysKernel: "-"
    property int sysProcesses: 0

    // Spotify & Media State
    property bool mediaActive: false
    property bool mediaPlaying: false
    property string mediaTitle: "Tidak Ada Media"
    property string mediaArtist: "Buka Spotify / Musik"
    property string mediaArtUrl: ""
    property string mediaSource: "Spotify"

    // Realtime Clock State
    property string currentTimeHoursMins: "00:00"
    property string currentTimeSecs: "00"
    property string currentDateStr: "Senin, 1 Jan"

    Timer {
        id: clockTimer
        interval: 1000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            var d = new Date();
            var h = String(d.getHours()).padStart(2, '0');
            var m = String(d.getMinutes()).padStart(2, '0');
            var s = String(d.getSeconds()).padStart(2, '0');
            root.currentTimeHoursMins = h + ":" + m;
            root.currentTimeSecs = s;

            var days = ["Minggu", "Senin", "Selasa", "Rabu", "Kamis", "Jumat", "Sabtu"];
            var months = ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"];
            root.currentDateStr = days[d.getDay()] + ", " + d.getDate() + " " + months[d.getMonth()];
        }
    }

    // Bridge persisten: stdout = event NDJSON, stdin = perintah (decision/launch/media/notes).
    // Tidak ada lagi polling file /tmp setiap 100ms.
    Process {
        id: bridgeProcess
        command: [(Quickshell.env("HERMES_COUCOU_PYTHON") || "python3"), "-u", root.appDir + "mochi_bridge.py", "--stdio"]
        running: false
        stdinEnabled: true
        stdout: SplitParser {
            onRead: data => root.handleBridgeLine(data)
        }
        stderr: SplitParser {
            onRead: data => console.log("BRIDGE_ERR: " + data)
        }
        onStarted: console.log("BRIDGE_STARTED pid=" + processId)
        onExited: (exitCode, exitStatus) => {
            console.log("BRIDGE_EXIT code=" + exitCode);
            root.bridgeReady = false;
            root.bridgeFailCount += 1;
            root.invalidateApproval("Bridge berhenti (kode " + exitCode + ")");
            if (root.bridgeFailCount <= 5) {
                bridgeRestartTimer.restart();
            } else {
                console.log("BRIDGE_GIVEUP: 5 kegagalan berturut-turut, tidak restart otomatis");
            }
        }
    }

    Timer {
        id: bridgeRestartTimer
        interval: 1200
        repeat: false
        onTriggered: {
            if (!bridgeProcess.running) {
                bridgeProcess.running = true;
            }
        }
    }

    Component.onCompleted: {
        console.log("COMPLETE appDir=" + appDir + " py=" + Quickshell.env("HERMES_COUCOU_PYTHON"));
        bridgeProcess.running = true;
    }

    function sendBridgeCommand(payload) {
        commandSeq += 1;
        let id = "qml-" + commandSeq;
        payload.id = id;
        if (bridgeProcess.running) {
            bridgeProcess.write(JSON.stringify(payload) + "\n");
        } else {
            showActionToast(false, "Bridge tidak berjalan");
        }
        return id;
    }

    // Kembali ke status dasar (koneksi/working/standby) setelah notifikasi,
    // toast sapaan, atau hasil approval selesai ditampilkan.
    function restoreBaseline() {
        avatarExpression = "proud";
        if (!hermesConnected) {
            let connecting = hermesStatusMessage.indexOf("connecting") >= 0;
            currentStatus = connecting ? "Menghubungi Hermes…" : "Hermes Offline";
            activeDetail = hermesStatusMessage || "Menunggu koneksi Hermes…";
            statusColor = connecting ? "#eab308" : "#ef4444";
        } else if (hermesWorking) {
            currentStatus = "Working";
            activeDetail = "Executing task...";
            statusColor = "#38bdf8";
        } else {
            currentStatus = "Standby";
            activeDetail = "Ready for tasks";
            statusColor = "#22c55e";
        }
    }

    function agentName(agent) {
        if (agent === "claude") return "Claude Code";
        if (agent === "opencode") return "OpenCode";
        if (agent === "hermes") return "Hermes";
        return "";
    }

    function sourceColor(agent) {
        if (agent === "claude") return "#d97757";
        if (agent === "opencode") return "#e4e4e7";
        return "#c4b5fd";
    }

    function stateColor(state) {
        if (state === "waiting") return "#f97316";
        if (state === "working") return "#38bdf8";
        if (state === "done") return "#22c55e";
        if (state === "error") return "#ef4444";
        return "#71717a";
    }

    function stateLabel(state) {
        if (state === "waiting") return "Butuh input";
        if (state === "working") return "Bekerja";
        if (state === "done") return "Selesai";
        if (state === "error") return "Error";
        return "Idle";
    }

    // Status terpenting dari semua sesi satu agent: waiting > working > error > done > idle.
    function agentAggregate(agent) {
        let rank = {none: 0, idle: 1, done: 2, error: 3, working: 4, waiting: 5};
        let best = "none";
        for (let i = 0; i < agentSessions.length; i++) {
            let sess = agentSessions[i];
            if (sess.agent === agent && (rank[sess.state] || 0) > rank[best]) best = sess.state;
        }
        return best;
    }

    function agentsPresent() {
        let out = [];
        for (let i = 0; i < agentSessions.length; i++) {
            if (out.indexOf(agentSessions[i].agent) < 0) out.push(agentSessions[i].agent);
        }
        return out.sort();
    }

    function agoText(ms) {
        let sec = Math.max(0, Math.floor((Date.now() - ms) / 1000));
        if (sec < 60) return sec + " dtk";
        if (sec < 3600) return Math.floor(sec / 60) + " mnt";
        return Math.floor(sec / 3600) + " jam";
    }

    function formatDuration(ms) {
        let sec = Math.max(0, Math.round(ms / 1000));
        if (sec < 60) return sec + " dtk";
        let min = Math.floor(sec / 60);
        if (min < 60) return min + "m " + (sec % 60) + "d";
        return Math.floor(min / 60) + "j " + (min % 60) + "m";
    }

    // Tampilkan pill notifikasi. opts: {source, title, detail, color, expression,
    // project, duration, error}. Approval yang terbuka tidak boleh tertimpa, dan
    // island yang sedang dibuka pengguna tidak direbut (status saja yang berubah).
    function showNotification(type, opts) {
        if ((notifyType === "approval" || notifyType === "request") && type !== "approval") return;
        currentStatus = opts.title;
        activeDetail = opts.detail || "";
        statusColor = opts.color;
        let timers = {task_start: taskStartNotifyTimer, done: completionCollapseTimer,
                      agent_wait: agentNotifyTimer, info: infoNotifyTimer,
                      interview: interviewNotifyTimer};
        for (let key in timers) timers[key].stop();
        if (type !== "approval" && (capsuleHover.hovered || windowHover.hovered)) {
            timers[type].restart();
            return;
        }
        islandExpanded = false;
        isNotifying = true;
        notifyType = type;
        notifySource = opts.source || "";
        notifyProject = opts.project || "";
        notifyDuration = opts.duration || "";
        notifyError = !!opts.error;
        if (opts.expression) avatarExpression = opts.expression;
        notifyPopAnim.restart();
        notifyProgressAnim.stop();
        notifyProgress = 1.0;
        if (type !== "approval") {
            notifyProgressAnim.duration = timers[type].interval;
            notifyProgressAnim.restart();
            timers[type].restart();
        }
    }

    // Tampilkan request terdepan di antrean, atau tutup kartu bila antrean kosong.
    // Approval Hermes selalu didahulukan; kartu muncul lagi setelah approval selesai.
    function refreshRequestView() {
        if (notifyType === "approval") return;
        let req = currentRequest;
        if (!req) {
            if (notifyType === "request") {
                isNotifying = false;
                notifyType = "";
                restoreBaseline();
            }
            return;
        }
        if (reqShownId !== req.request_id) {
            reqShownId = req.request_id;
            reqIndex = 0;
            let sel = [];
            for (let i = 0; i < (req.questions || []).length; i++) sel.push([]);
            reqSelections = sel;
            reqSending = false;
            reqError = "";
            requestCustomInput.text = "";
            notifyPopAnim.restart();
        }
        taskStartNotifyTimer.stop();
        completionCollapseTimer.stop();
        agentNotifyTimer.stop();
        infoNotifyTimer.stop();
        notifyProgressAnim.stop();
        islandExpanded = false;
        isNotifying = true;
        notifyType = "request";
        notifySource = req.agent;
        notifyProject = req.project || "";
        let isPerm = req.kind === "permission";
        currentStatus = isPerm ? "Butuh izin" : "Ada pertanyaan";
        activeDetail = req.title || "";
        statusColor = isPerm ? "#f97316" : "#38bdf8";
        avatarExpression = isPerm ? "angry" : "task_start";
    }

    function removeRequest(requestId) {
        let list = [];
        for (let i = 0; i < agentRequests.length; i++) {
            if (agentRequests[i].request_id !== requestId) list.push(agentRequests[i]);
        }
        agentRequests = list;
        if (reqShownId === requestId) reqShownId = "";
        refreshRequestView();
    }

    function submitRequestAnswer(answer) {
        if (!currentRequest || reqSending) return;
        reqSending = true;
        reqError = "";
        reqAnswerCmdId = sendBridgeCommand({action: "agent_answer", request_id: currentRequest.request_id, answer: answer});
    }

    function reqToggleOption(label) {
        let q = currentRequest.questions[reqIndex];
        let sel = reqSelections.slice();
        let cur = (sel[reqIndex] || []).slice();
        if (q.multiSelect) {
            let at = cur.indexOf(label);
            if (at >= 0) cur.splice(at, 1); else cur.push(label);
            sel[reqIndex] = cur;
            reqSelections = sel;
        } else {
            sel[reqIndex] = [label];
            reqSelections = sel;
            reqAdvance();
        }
    }

    // Lanjut ke pertanyaan berikutnya, atau kirim semua jawaban di pertanyaan terakhir.
    function reqAdvance() {
        let custom = requestCustomInput.text.trim();
        if (custom.length > 0) {
            let sel = reqSelections.slice();
            let q = currentRequest.questions[reqIndex];
            sel[reqIndex] = q.multiSelect ? (sel[reqIndex] || []).concat([custom]) : [custom];
            reqSelections = sel;
            requestCustomInput.text = "";
        }
        if (!reqSelections[reqIndex] || reqSelections[reqIndex].length === 0) return;
        if (reqIndex < currentRequest.questions.length - 1) {
            reqIndex += 1;
        } else {
            submitRequestAnswer({answers: reqSelections});
        }
    }

    function handleAgentEvent(msg) {
        let agent = msg.agent || "claude";
        let sid = agent + ":" + (msg.session_id || "default");
        let list = agentSessions.slice();
        let idx = -1;
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === sid) { idx = i; break; }
        }
        if (msg.event === "AgentSessionEnd") {
            if (idx >= 0) list.splice(idx, 1);
            agentSessions = list;
            return;
        }
        let sess = idx >= 0 ? Object.assign({}, list[idx])
                            : {id: sid, agent: agent, project: "", state: "idle", detail: "", prompt: "", promptAt: 0};
        if (msg.project) sess.project = msg.project;
        let text = msg.message || "";
        let failed = msg.kind === "error";
        switch (msg.event) {
        case "AgentSessionStart": sess.state = "idle"; sess.detail = "Sesi dimulai"; break;
        case "AgentPrompt": sess.state = "working"; sess.prompt = text; sess.promptAt = Date.now(); sess.detail = "Prompt: " + text; break;
        case "AgentToolStart": sess.state = "working"; sess.detail = text; break;
        case "AgentToolDone": sess.state = "working"; sess.detail = "✓ " + text; break;
        case "AgentWaiting": sess.state = "waiting"; sess.detail = text; break;
        case "AgentStop":
            sess.state = failed ? "error" : "done";
            sess.detail = failed ? "Error: " + text : (sess.prompt ? "Selesai: " + sess.prompt : "Giliran selesai");
            break;
        }
        sess.updated = Date.now();
        if (idx >= 0) list.splice(idx, 1);
        list.unshift(sess);
        agentSessions = list.slice(0, 8);

        // Pill: task diterima, task selesai/gagal, dan permintaan izin.
        // Notifikasi "menunggu input" (idle) cukup mengubah status sesi.
        if (msg.event === "AgentPrompt") {
            showNotification("task_start", {source: agent, title: "Task diterima", detail: text || "Prompt baru",
                                            color: "#a78bfa", expression: "task_start", project: sess.project});
        } else if (msg.event === "AgentStop") {
            showNotification("done", {source: agent, title: failed ? "Task gagal" : "Task selesai",
                                      detail: failed ? text : (sess.prompt || "Giliran selesai"),
                                      color: failed ? "#ef4444" : "#22c55e", expression: failed ? "dizzy" : "celebrate",
                                      project: sess.project, error: failed,
                                      duration: sess.promptAt ? formatDuration(Date.now() - sess.promptAt) : ""});
            sess.promptAt = 0;
        } else if (msg.event === "AgentWaiting" && msg.kind === "permission") {
            showNotification("agent_wait", {source: agent, title: "Butuh izin", detail: text + " · jawab di terminal",
                                            color: "#f97316", expression: "angry", project: sess.project});
        }
    }

    function invalidateApproval(reason) {
        let wasApproval = (notifyType === "approval");
        pendingSessionId = "";
        pendingRequestId = "";
        pendingDecisionId = "";
        approvalActionable = false;
        decisionPending = false;
        if (wasApproval) {
            isNotifying = false;
            notifyType = "";
            currentStatus = "Approval Dibatalkan";
            activeDetail = reason || "Permintaan approval tidak lagi valid";
            statusColor = "#ef4444";
            avatarExpression = "idle";
            completionCollapseTimer.restart();
        }
    }

    function submitDecision(choice) {
        if (decisionPending) return;
        if (!approvalActionable || !pendingRequestId) {
            currentStatus = "Tidak Valid";
            activeDetail = "Approval sudah tidak berlaku";
            statusColor = "#ef4444";
            completionCollapseTimer.restart();
            return;
        }
        if (!hermesConnected) {
            currentStatus = "Hermes Offline";
            activeDetail = "Tidak bisa mengirim keputusan";
            statusColor = "#ef4444";
            return;
        }
        decisionPending = true;
        pendingDecisionChoice = choice;
        pendingDecisionId = sendBridgeCommand({
            action: "decision",
            session_id: pendingSessionId,
            request_id: pendingRequestId,
            decision: choice
        });
        currentStatus = choice === "allow" ? "Mengirim persetujuan…" : "Mengirim penolakan…";
        activeDetail = "Menunggu konfirmasi Hermes";
        statusColor = "#38bdf8";
    }

    function showActionToast(ok, message) {
        if (notifyType === "approval" || notifyType === "request" || decisionPending) return;
        // Sukses dibungkam hanya untuk pesan yang sudah jelas tanpa toast
        // (notes/media refresh); sisanya — termasuk dev server — harus kasih
        // umpan balik supaya sekali klik langsung terasa.
        const silent = ["Notes saved", "Command completed", "Status dev server diperbarui",
                        "Status interview diperbarui", "Membuat jawaban…"];
        if (ok && (!message || silent.indexOf(message) !== -1)) return;
        toastPrevStatus = currentStatus;
        toastPrevDetail = activeDetail;
        toastPrevColor = statusColor;
        currentStatus = ok ? "Selesai ✓" : "Gagal ✗";
        activeDetail = message || (ok ? "Aksi selesai" : "Aksi lokal gagal");
        statusColor = ok ? "#22c55e" : "#ef4444";
        toolToastTimer.restart();
    }

    // Tipe catatan: tag tersimpan, atau deteksi dari teks untuk catatan lama.
    function noteType(text, tag) {
        if (tag === "cmd" || tag === "task" || tag === "note") return tag;
        let t = (text || "").trim();
        let prefixes = ["claude", "git", "npm", "php", "curl", "cargo", "ssh", "./"];
        for (let i = 0; i < prefixes.length; i++) {
            if (t.startsWith(prefixes[i])) return "cmd";
        }
        return "note";
    }

    function applyNotes(notes) {
        if (!Array.isArray(notes)) return;
        notesModel.clear();
        for (let n of notes) {
            if (!n || typeof n.text !== "string") continue;
            // Role ListModel harus bertipe konsisten: id selalu string.
            notesModel.append({id: String(n.id), text: n.text, time: n.time || "",
                               done: !!n.done, tag: root.noteType(n.text, n.tag)});
        }
    }

    function runCommandNote(idx) {
        if (idx < 0 || idx >= notesModel.count) return;
        let itm = notesModel.get(idx);
        if (itm.tag !== "cmd") return;
        // Catatan lama mungkin belum punya tag "cmd" di file; simpan dulu
        // (stdin bridge diproses berurutan) karena bridge memverifikasi tag.
        saveNotesToFile();
        sendBridgeCommand({action: "run_note", note_id: String(itm.id)});
    }

    function handleBridgeLine(line) {
        if (!line) return;
        let msg;
        try { msg = JSON.parse(line); } catch (e) { return; }
        if (!msg || typeof msg !== "object" || !msg.event) return;

        // Selama approval terbuka, event progres task tidak boleh mengganti
        // pill approval (tombol Reject/Run akan hilang padahal request masih aktif).
        let approvalOpen = root.notifyType === "approval";
        if (approvalOpen && ["PreToolUse", "PostToolUse", "TaskStarted", "StopSuccess"].indexOf(msg.event) >= 0) {
            root.hermesWorking = msg.event !== "StopSuccess";
            return;
        }

        switch (msg.event) {
        case "BridgeReady":
            // Bridge baru tidak tahu request lama (hook/plugin sudah diputus).
            root.agentRequests = [];
            root.refreshRequestView();
            root.bridgeReady = true;
            root.bridgeFailCount = 0;
            fetchNotesProcess.running = true;
            sendBridgeCommand({ action: "dev_status" });
            break;

        case "BridgeStatus":
            root.hermesConnected = !!msg.connected;
            root.hermesStatusMessage = msg.message || "";
            if (!msg.connected) {
                root.hermesWorking = false;
                root.invalidateApproval(msg.message || "Hermes terputus");
                if (!root.isNotifying) root.restoreBaseline();
            } else if (!root.isNotifying && (root.currentStatus === "Hermes Offline"
                       || root.currentStatus === "Menghubungi Hermes…")) {
                root.restoreBaseline();
            }
            break;

        case "PermissionRequest": {
            let actionable = msg.actionable !== false
                    && typeof msg.session_id === "string" && msg.session_id.length > 0
                    && typeof msg.request_id === "string" && msg.request_id.length > 0
                    && root.hermesConnected;
            if (actionable) {
                root.pendingSessionId = msg.session_id;
                root.pendingRequestId = msg.request_id;
                root.pendingDecisionId = "";
                root.approvalActionable = true;
                root.decisionPending = false;
                root.showNotification("approval", {source: "hermes", title: "Approval Required",
                    detail: msg.message || (msg.tool_name ? "Tool: " + msg.tool_name : "Action needs approval"),
                    color: "#eab308", expression: "angry"});
            } else {
                // Event sintetis/demo (tanpa request Hermes asli): tampil info saja,
                // tanpa tombol karena tidak ada request yang bisa dikonfirmasi.
                root.showNotification("info", {source: "hermes", title: "Approval (Demo)",
                    detail: msg.message || "Event approval demo", color: "#eab308", expression: "angry"});
            }
            break;
        }

        case "ApprovalResolved":
            if (msg.session_id === root.pendingSessionId && msg.request_id === root.pendingRequestId) {
                root.pendingSessionId = "";
                root.pendingRequestId = "";
                root.pendingDecisionId = "";
                root.approvalActionable = false;
                root.decisionPending = false;
                if (root.notifyType === "approval") {
                    root.isNotifying = false;
                    root.notifyType = "";
                    root.currentStatus = "Approval Selesai";
                    root.activeDetail = "Diselesaikan dari klien lain";
                    root.statusColor = "#38bdf8";
                    completionCollapseTimer.restart();
                }
            }
            break;

        case "DecisionResult": {
            if (!msg.id || msg.id !== root.pendingDecisionId) break;
            let allowed = root.pendingDecisionChoice === "allow";
            root.pendingDecisionId = "";
            root.decisionPending = false;
            if (msg.ok) {
                root.pendingSessionId = "";
                root.pendingRequestId = "";
                root.approvalActionable = false;
                root.isNotifying = false;
                root.notifyType = "";
                root.currentStatus = allowed ? "Approved ✓" : "Ditolak ✗";
                root.activeDetail = allowed ? "Command sedang berjalan…" : "Command dibatalkan";
                root.statusColor = allowed ? "#22c55e" : "#ef4444";
                if (allowed) root.avatarExpression = "working";
                completionCollapseTimer.restart();
            } else {
                // Keputusan TIDAK dikonfirmasi Hermes: UI approval tetap terbuka.
                root.currentStatus = "Gagal Dikirim ✗";
                root.activeDetail = msg.message || "Hermes tidak mengonfirmasi keputusan";
                root.statusColor = "#ef4444";
            }
            break;
        }

        case "AgentRequest":
            if (msg.request_id && (msg.kind === "permission" || msg.kind === "question")) {
                root.agentRequests = root.agentRequests.concat([msg]);
                root.refreshRequestView();
            }
            break;

        case "AgentRequestClosed":
            root.removeRequest(msg.request_id);
            break;

        case "ActionResult":
            if (msg.id && msg.id === root.reqAnswerCmdId) {
                root.reqAnswerCmdId = "";
                if (!msg.ok) {
                    // Gagal: kartu tetap terbuka supaya bisa dicoba lagi / dijawab di terminal.
                    root.reqSending = false;
                    root.reqError = msg.message || "Gagal mengirim jawaban";
                }
                break;
            }
            showActionToast(!!msg.ok, msg.message || "");
            break;

        case "DevServerStatus":
            root.devServers = Array.isArray(msg.projects) ? msg.projects : [];
            break;

        case "InterviewStatus":
            root.interviewState = msg.state || "idle";
            root.interviewSource = msg.source || root.interviewSource;
            root.interviewAuto = msg.auto !== false;
            root.interviewMessage = msg.message || "";
            root.interviewProfile = msg.profile || "";
            if (!root.interviewRunning) { root.interviewLevel = 0; root.interviewSpeaking = false; root.interviewThinking = false; }
            break;

        case "InterviewLevel":
            root.interviewLevel = Number(msg.level) || 0;
            root.interviewSpeaking = !!msg.speaking;
            break;

        case "InterviewTranscript": {
            let lines = root.interviewTranscript.concat([{ seq: msg.seq, text: msg.text || "", time: msg.time || "" }]);
            root.interviewTranscript = lines.slice(-60);
            break;
        }

        case "InterviewAnswer":
            root.handleInterviewAnswer(msg);
            break;

        case "AgentSessionStart":
        case "AgentPrompt":
        case "AgentToolStart":
        case "AgentToolDone":
        case "AgentWaiting":
        case "AgentStop":
        case "AgentSessionEnd":
            root.handleAgentEvent(msg);
            break;

        case "NotesUpdated":
            applyNotes(msg.notes);
            break;

        case "PreToolUse":
            root.hermesWorking = true;
            root.currentStatus = "Working";
            root.activeDetail = msg.tool_name ? "Running: " + msg.tool_name : "Executing task...";
            root.statusColor = "#38bdf8";
            break;

        case "TaskStarted":
            root.hermesWorking = true;
            root.hermesTaskStartedAt = Date.now();
            root.showNotification("task_start", {source: "hermes", title: "Task diterima",
                detail: msg.message || "Mulai mengerjakan task...", color: "#a78bfa", expression: "task_start"});
            break;

        case "PostToolUse":
            root.hermesWorking = true;
            root.currentStatus = "Working";
            root.activeDetail = msg.tool_name ? "Done: " + msg.tool_name : "Step finished";
            root.statusColor = "#38bdf8";
            break;

        case "StopSuccess": {
            root.hermesWorking = false;
            let took = root.hermesTaskStartedAt > 0 ? root.formatDuration(Date.now() - root.hermesTaskStartedAt) : "";
            root.hermesTaskStartedAt = 0;
            root.showNotification("done", {source: "hermes", title: "Task selesai",
                detail: msg.message || "Task selesai!", color: "#22c55e", expression: "celebrate", duration: took});
            break;
        }
        }
    }

    Timer {
        id: completionCollapseTimer
        interval: 4400
        repeat: false
        onTriggered: {
            // Approval tidak boleh ditutup timer: harus menunggu hasil keputusan.
            if (root.notifyType === "approval" && root.approvalActionable) return;
            if (root.notifyType === "request") return;
            root.isNotifying = false;
            root.notifyType = "";
            if (!capsuleHover.hovered && !windowHover.hovered) {
                root.islandExpanded = false;
            }
            root.restoreBaseline();
            root.refreshRequestView(); // request yang tertunda oleh approval tampil lagi
        }
    }

    // Pill "butuh izin" agent sedikit lebih lama dari info biasa.
    Timer {
        id: agentNotifyTimer
        interval: 6000
        repeat: false
        onTriggered: {
            if (root.notifyType === "request") return;
            if (root.notifyType === "agent_wait") {
                root.isNotifying = false;
                root.notifyType = "";
            }
            if (root.currentStatus === "Butuh izin") root.restoreBaseline();
        }
    }

    NumberAnimation {
        id: notifyProgressAnim
        target: root
        property: "notifyProgress"
        from: 1.0
        to: 0.0
        duration: 3000
    }

    // Sesi tanpa kabar (agent crash / terminal ditutup tanpa SessionEnd):
    // "bekerja" > 15 mnt jadi idle, sesi > 3 jam dibuang.
    Timer {
        interval: 60000
        running: root.agentSessions.length > 0
        repeat: true
        onTriggered: {
            let now = Date.now();
            let changed = false;
            let list = [];
            for (let i = 0; i < root.agentSessions.length; i++) {
                let sess = root.agentSessions[i];
                if (now - sess.updated > 3 * 3600000) { changed = true; continue; }
                if ((sess.state === "working" || sess.state === "waiting") && now - sess.updated > 15 * 60000) {
                    sess = Object.assign({}, sess, {state: "idle", detail: "Tidak ada kabar"});
                    changed = true;
                }
                list.push(sess);
            }
            if (changed) root.agentSessions = list;
        }
    }

    // Pill "Jawaban siap" (Interview Assist): cukup lama untuk membaca kalimat inti.
    Timer {
        id: interviewNotifyTimer
        interval: 8000
        repeat: false
        onTriggered: {
            if (root.notifyType === "request") return;
            if (root.notifyType === "interview") {
                root.isNotifying = false;
                root.notifyType = "";
                root.restoreBaseline();
            } else if (root.currentStatus === "💡 Jawaban siap") {
                root.restoreBaseline();
            }
        }
    }

    // Notifikasi info/demo (approval tanpa request Hermes asli) ditutup otomatis.
    Timer {
        id: infoNotifyTimer
        interval: 3600
        repeat: false
        onTriggered: {
            if (root.notifyType === "request") return;
            if (root.notifyType === "info") {
                root.isNotifying = false;
                root.notifyType = "";
                root.restoreBaseline();
            } else if (root.currentStatus === "Approval (Demo)") {
                root.restoreBaseline();
            }
        }
    }

    // Toast hasil aksi lokal: tampil sesaat lalu kembali ke status sebelumnya.
    Timer {
        id: toolToastTimer
        interval: 2800
        repeat: false
        onTriggered: {
            if (root.notifyType === "approval" || root.decisionPending) return;
            if (root.currentStatus === "Selesai ✓" || root.currentStatus === "Gagal ✗") {
                root.currentStatus = root.toastPrevStatus;
                root.activeDetail = root.toastPrevDetail;
                root.statusColor = root.toastPrevColor;
            }
        }
    }

    // Simpan catatan lewat bridge (atomic, tervalidasi) tanpa menulis file langsung.
    function saveNotesToFile() {
        let arr = [];
        for (let i = 0; i < notesModel.count; i++) {
            let itm = notesModel.get(i);
            arr.push({id: String(itm.id), text: itm.text, time: itm.time, done: !!itm.done, tag: root.noteType(itm.text, itm.tag)});
        }
        sendBridgeCommand({action: "notes_save", notes: arr});
    }

    function addNoteItem(txt, tag) {
        if (!txt || txt.trim().length === 0) return;
        let now = new Date();
        let timeStr = (now.getHours() < 10 ? "0" : "") + now.getHours() + ":" + (now.getMinutes() < 10 ? "0" : "") + now.getMinutes();
        let newId = String(Date.now());
        // Langsung insert di awal list UI
        notesModel.insert(0, {id: newId, text: txt.trim(), time: timeStr, done: false, tag: root.noteType(txt, tag)});
        saveNotesToFile();
    }

    function toggleNoteDone(idx) {
        if (idx >= 0 && idx < notesModel.count) {
            let itm = notesModel.get(idx);
            notesModel.setProperty(idx, "done", !itm.done);
            saveNotesToFile();
        }
    }

    function deleteNoteItem(idx) {
        if (idx >= 0 && idx < notesModel.count) {
            notesModel.remove(idx);
            saveNotesToFile();
        }
    }

    // Refresh Notes setelah bridge siap (HTTP bind selesai)
    Process {
        id: fetchNotesProcess
        command: ["python3", root.appDir + "bridge_client.py", "get", "/notes"]
        running: false
        stdout: SplitParser {
            onRead: data => {
                try {
                    applyNotes(JSON.parse(data));
                } catch(e) {}
            }
        }
    }

    // Process untuk Fetch System Info
    Process {
        id: fetchSysInfoProcess
        command: ["python3", root.appDir + "bridge_client.py", "get", "/sysinfo"]
        running: false
        stdout: SplitParser {
            onRead: data => {
                try {
                    let s = JSON.parse(data);
                    root.sysCpu = s.cpu || 0;
                    root.sysRamPercent = s.ram_percent || 0;
                    root.sysRamUsed = s.ram_used || "0 GB";
                    root.sysRamTotal = s.ram_total || "0 GB";
                    root.sysUptime = s.uptime || "-";
                    root.sysKernel = s.kernel || "-";
                    root.sysProcesses = s.active_processes || 0;
                } catch(e) {}
            }
        }
    }

    // Process untuk Fetch 9Router Usage
    Process {
        id: fetchUsageProcess
        command: ["python3", root.appDir + "bridge_client.py", "get", "/usage"]
        running: false
        stdout: SplitParser {
            onRead: data => {
                try {
                    let u = JSON.parse(data);
                    root.usageLoaded = true;
                    root.usageAvailable = !!u.available;
                    if (u.today) {
                        root.usageRequests = u.today.requests || 0;
                        root.usageCost = u.today.cost || 0.0;
                        root.usageTokens = u.today.tokens || 0;
                    }
                    if (u.all60d) {
                        root.usage60dRequests = u.all60d.requests || 0;
                        root.usage60dCost = u.all60d.cost || 0.0;
                        root.usage60dTokens = u.all60d.tokens || 0;
                    }
                    if (u.activeModels) {
                        root.activeModelsList = u.activeModels;
                    }
                    if (u.recentLogs) {
                        root.recentLogsList = u.recentLogs;
                    }
                } catch(e) {}
            }
        }
    }

    // Process untuk Fetch Media Info (Spotify)
    Timer {
        id: mediaPollTimer
        interval: 1200
        running: true
        repeat: true
        onTriggered: {
            if (root.islandExpanded) {
                fetchMediaProcess.running = true;
            }
        }
    }

    // Refresh sesudah player sempat memproses perintah; fetch langsung sering
    // mengembalikan status lama (play/pause berkedip balik, judul belum ganti).
    Timer {
        id: mediaRefreshDelay
        interval: 600
        repeat: false
        onTriggered: fetchMediaProcess.running = true
    }

    Process {
        id: fetchMediaProcess
        command: ["python3", root.appDir + "bridge_client.py", "get", "/media"]
        running: false
        stdout: SplitParser {
            onRead: data => {
                try {
                    let m = JSON.parse(data);
                    root.mediaActive = m.active || false;
                    root.mediaPlaying = m.is_playing || false;
                    root.mediaTitle = m.title || "Tidak Ada Media";
                    root.mediaArtist = m.artist || "Buka Spotify / Musik";
                    root.mediaArtUrl = m.artUrl || "";
                    root.mediaSource = m.player || "Spotify";
                } catch(e) {}
            }
        }
    }

    // Git & Web Projects Portal State
    property var gitProjectsList: []
    property string activeGitProjectId: ""

    // Dev Server State (php artisan serve / npm run dev, dikelola bridge)
    property var devServers: []

    // Interview Assist (interview.py: rekam lawan bicara -> Whisper -> saran jawaban)
    property string interviewState: "idle"    // idle | loading | listening | error
    property string interviewSource: "system" // system (Zoom/Meet) | mic (tatap muka)
    property bool interviewAuto: true
    property string interviewMessage: ""
    property string interviewProfile: ""
    property real interviewLevel: 0
    property bool interviewSpeaking: false
    property var interviewTranscript: []      // [{seq, text, time}] terbaru di akhir
    property var interviewAnswers: []         // [{qid, question, text, done, error}] terbaru di awal
    property int interviewAnswerIndex: 0      // 0 = jawaban terbaru
    property bool interviewThinking: false
    readonly property bool interviewRunning: interviewState === "loading" || interviewState === "listening"
    readonly property var interviewShownAnswer: interviewAnswers.length > interviewAnswerIndex ? interviewAnswers[interviewAnswerIndex] : null

    Process {
        id: fetchProjectsProcess
        command: ["python3", root.appDir + "bridge_client.py", "get", "/projects"]
        running: false
        stdout: SplitParser {
            onRead: data => {
                try {
                    let d = JSON.parse(data);
                    if (d.projects) root.gitProjectsList = d.projects;
                    if (d.active_id) root.activeGitProjectId = d.active_id;
                } catch(e) {}
            }
        }
    }

    Timer {
        id: projectsPollTimer
        interval: 8000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (root.islandExpanded && root.activeTab === "projects") {
                fetchProjectsProcess.running = true;
            }
        }
    }

    // 1234 → "1.2K", 1234567 → "1.2M", 1.5e9 → "1.50B"
    function formatTokens(n) {
        n = Number(n) || 0;
        if (n >= 1e9) return (n / 1e9).toFixed(2) + "B";
        if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
        if (n >= 1e3) return (n / 1e3).toFixed(1) + "K";
        return "" + n;
    }

    // Tab Status & 9Router ikut segar selama terbuka (sebelumnya hanya saat tab diklik).
    Timer {
        interval: 3000
        running: root.islandExpanded && !root.isNotifying
                 && (root.activeTab === "status" || root.activeTab === "usage")
        repeat: true
        onTriggered: {
            if (root.activeTab === "status") fetchSysInfoProcess.running = true;
            else fetchUsageProcess.running = true;
        }
    }

    function openWebUrl(url) {
        if (!url || url === "") return;
        sendBridgeCommand({action: "launch", name: "open_url", url: url});
    }

    function openProjectInCode(path) {
        if (!path || path === "") return;
        sendBridgeCommand({action: "launch", name: "open_project", path: path});
    }

    function launchTool(name) {
        sendBridgeCommand({action: "launch", name: name});
    }

    // ---- Dev Server helpers ----
    function devProject(projectId) {
        for (let i = 0; i < root.devServers.length; i++) {
            if (root.devServers[i].id === projectId) return root.devServers[i];
        }
        return null;
    }

    function devService(projectId, key) {
        let project = root.devProject(projectId);
        if (project && Array.isArray(project.services)) {
            for (let i = 0; i < project.services.length; i++) {
                if (project.services[i].key === key) return project.services[i];
            }
        }
        return { key: key, label: "", available: false, running: false, pid: null, port: null };
    }

    function devToggle(projectId, key) {
        let service = root.devService(projectId, key);
        if (!service.available) return;
        sendBridgeCommand({ action: service.running ? "dev_stop" : "dev_start",
                            project: projectId, services: [key] });
    }

    function devStartProject(projectId) {
        sendBridgeCommand({ action: "dev_start", project: projectId });
    }

    function devStopProject(projectId) {
        sendBridgeCommand({ action: "dev_stop", project: projectId });
    }

    function interviewToggle() {
        if (root.interviewRunning) {
            sendBridgeCommand({ action: "interview_stop" });
        } else {
            root.interviewTranscript = [];
            root.interviewAnswers = [];
            root.interviewAnswerIndex = 0;
            sendBridgeCommand({ action: "interview_start", source: root.interviewSource, auto: root.interviewAuto });
        }
    }

    function handleInterviewAnswer(msg) {
        let list = root.interviewAnswers.slice();
        let idx = list.findIndex(a => a.qid === msg.qid);
        if (msg.skipped) {
            if (idx >= 0) list.splice(idx, 1);
        } else {
            let item = { qid: msg.qid, question: msg.question || "", text: msg.text || "",
                         done: !!msg.done, error: msg.error || "" };
            if (idx >= 0) list[idx] = item;
            else { list.unshift(item); root.interviewAnswerIndex = 0; }
        }
        root.interviewAnswers = list.slice(0, 20);
        root.interviewThinking = !msg.done;
        // Jawaban siap: kabari lewat pill kecuali tab Interview sedang terbuka.
        if (msg.done && !msg.skipped && !msg.error && msg.text
                && !(root.islandExpanded && root.activeTab === "interview")) {
            let core = msg.text.split("\n").map(l => l.trim()).filter(l => l.length > 0)[0] || msg.text;
            root.showNotification("interview", {title: "💡 Jawaban siap", detail: core,
                                                color: "#3b82f6", expression: "happy"});
        }
    }

    // Area hover + mask SELURUH WINDOW saat terbuka: pointer bebas bergerak di
    // margin panel tanpa membuat island kolaps, dan klik tidak jatuh tembus.
    HoverHandler {
        id: windowHover
        onHoveredChanged: {
            if (hovered) {
                autoCloseTimer.stop();
            } else {
                if (!capsuleHover.hovered) {
                    autoCloseTimer.restart();
                }
            }
        }
    }

    // Dynamic Island Capsule
    Rectangle {
        id: islandCapsule
        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter

        width: {
            if (root.islandExpanded && !root.isNotifying) return 660;
            if (root.isNotifying) return (root.notifyType === "approval" || root.notifyType === "request") ? 600 : 500;
            return 240;
        }

        height: {
            if (root.islandExpanded && !root.isNotifying) return 380;
            if (root.notifyType === "request") return Math.min(404, requestCard.implicitHeight + 30);
            if (root.isNotifying) return (root.notifyType === "approval" || root.notifyType === "interview") ? 64 : 60;
            return 44;
        }

        topLeftRadius: 0
        topRightRadius: 0
        bottomLeftRadius: (root.islandExpanded && !root.isNotifying) ? 26 : 22
        bottomRightRadius: (root.islandExpanded && !root.isNotifying) ? 26 : 22

        color: "#0a0a0c"
        border.color: {
            if (root.notifyType === "approval") return "#f59e0b";
            if (root.notifyType === "request") return root.statusColor;
            if (root.notifyType === "agent_wait") return "#f97316";
            if (root.isNotifying && !root.islandExpanded) return Qt.darker(root.statusColor, 2.2);
            return "#27272a";
        }
        Behavior on border.color { ColorAnimation { duration: 250 } }
        border.width: (root.notifyType === "approval") ? 1.5 : 1.0

        Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.15 } }
        Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutBack; easing.overshoot: 1.05 } }

        // Mouse Tracker untuk Mata Mochi & Auto Open/Close
        HoverHandler {
            id: capsuleHover
            onPointChanged: {
                let p = point.position;
                root.cursorXInIsland = p.x;
                root.cursorYInIsland = p.y;

                let relX = (p.x - islandCapsule.width / 2) / (islandCapsule.width / 2);
                let relY = (p.y - islandCapsule.height / 2) / (islandCapsule.height / 2);
                root.cursorLookX = Math.max(-1.0, Math.min(1.0, relX));
                root.cursorLookY = Math.max(-1.0, Math.min(1.0, relY));
            }

            onHoveredChanged: {
                if (hovered) {
                    autoCloseTimer.stop();
                    if (root.isNotifying && root.notifyType === "interview") {
                        interviewNotifyTimer.stop();
                        root.isNotifying = false;
                        root.notifyType = "";
                        root.restoreBaseline();
                        root.activeTab = "interview";
                    }
                    if (!root.isNotifying) {
                        root.islandExpanded = true;
                        fetchMediaProcess.running = true;
                    }
                } else {
                    root.cursorLookX = 0.0;
                    root.cursorLookY = 0.0;
                    root.cursorOnRobot = false;
                    root.isAngry = false;
                    robotAngerCountdown.stop();
                    autoCloseTimer.restart();
                }
            }
        }

        Timer {
            id: autoCloseTimer
            interval: 350
            repeat: false
            onTriggered: {
                if (!capsuleHover.hovered && !windowHover.hovered && !root.isNotifying) {
                    root.islandExpanded = false;
                }
            }
        }

        Timer {
            id: robotAngerCountdown
            interval: 3000
            repeat: false
            onTriggered: {
                if (root.cursorOnRobot && !root.isDizzy) {
                    root.isAngry = true;
                }
            }
        }

        // Jeda antar klik > 1.2 dtk memutus hitungan klik beruntun.
        Timer {
            id: clickStreakTimer
            interval: 1200
            repeat: false
            onTriggered: root.robotClickCount = 0
        }

        Timer {
            id: angerFadeTimer
            interval: 1400
            repeat: false
            onTriggered: {
                root.isAngry = false;
                if (root.cursorOnRobot) robotAngerCountdown.restart();
            }
        }

        Timer {
            id: dizzyTimer
            interval: 3500 // Efek pusing bergetar selama 3.5 detik lalu reda
            repeat: false
            onTriggered: {
                root.isDizzy = false;
                root.robotClickCount = 0;
            }
        }

        Item {
            anchors.fill: parent
            anchors.margins: 8

            // 1. TAMPILAN STANDBY BIASA
            Row {
                visible: !root.isNotifying && !root.islandExpanded
                anchors.centerIn: parent
                spacing: 12

                // Karakter Interaktif Bible Strong Avatar Lab (Diperbesar)
                BibleStrongAvatar {
                    size: 32
                    anchors.verticalCenter: parent.verticalCenter
                    avatarType: root.avatarModel
                    expression: root.avatarExpression !== "proud" ? root.avatarExpression : (capsuleHover.hovered ? "wave" : (root.hermesWorking ? "working" : "idle"))
                    targetLookX: root.cursorLookX
                    targetLookY: root.cursorLookY
                }

                Text {
                    text: "QBot"
                    color: "#ffffff"
                    font.pixelSize: 14
                    font.bold: true
                    font.weight: Font.Black
                    font.family: "Inter, sans-serif"
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Logo Hermes dengan cincin warna status koneksi/task.
                Rectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 22; height: 22; radius: 11
                    color: "transparent"
                    border.color: root.statusColor
                    border.width: 1.5
                    SourceLogo { anchors.centerIn: parent; kind: "hermes"; size: 18 }
                }

                // Logo agent coding yang punya sesi; cincin = status, berdenyut saat aktif.
                Repeater {
                    model: root.agentsPresent()
                    Rectangle {
                        id: agentBadge
                        required property string modelData
                        readonly property string aggState: root.agentAggregate(modelData)
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22; height: 22; radius: 11
                        color: "transparent"
                        border.color: root.stateColor(agentBadge.aggState)
                        border.width: 1.5
                        SourceLogo { anchors.centerIn: parent; kind: agentBadge.modelData; size: 18 }
                        SequentialAnimation on opacity {
                            running: agentBadge.aggState === "working" || agentBadge.aggState === "waiting"
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) agentBadge.opacity = 1
                            NumberAnimation { to: 0.5; duration: 700; easing.type: Easing.InOutSine }
                            NumberAnimation { to: 1.0; duration: 700; easing.type: Easing.InOutSine }
                        }
                    }
                }
            }

            // 2. PILL NOTIFIKASI (TASK DITERIMA / SELESAI / BUTUH IZIN / APPROVAL)
            RowLayout {
                visible: root.isNotifying && !root.islandExpanded && root.notifyType !== "request"
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 4
                anchors.bottomMargin: 3
                spacing: 12

                // Mochi + badge logo sumber di pojok kanan bawah
                Item {
                    Layout.preferredWidth: 40
                    Layout.preferredHeight: 40
                    Layout.alignment: Qt.AlignVCenter

                    // Riak cincin selama task baru diterima / menunggu izin
                    Rectangle {
                        id: notifyRipple
                        anchors.centerIn: parent
                        width: 40; height: 40; radius: 20
                        color: "transparent"
                        border.color: root.statusColor
                        border.width: 1.5
                        opacity: 0
                        ParallelAnimation {
                            running: root.isNotifying && (root.notifyType === "task_start" || root.notifyType === "agent_wait")
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) notifyRipple.opacity = 0
                            NumberAnimation { target: notifyRipple; property: "scale"; from: 0.85; to: 1.35; duration: 1100; easing.type: Easing.OutCubic }
                            NumberAnimation { target: notifyRipple; property: "opacity"; from: 0.7; to: 0; duration: 1100; easing.type: Easing.OutCubic }
                        }
                    }

                    BibleStrongAvatar {
                        id: animMochi
                        anchors.centerIn: parent
                        size: 34
                        avatarType: root.avatarModel
                        expression: root.avatarExpression !== "proud" ? root.avatarExpression : (root.notifyType === "done" ? "celebrate" : "working")
                        targetLookX: root.cursorLookX
                        targetLookY: root.cursorLookY

                        // Pop + putar setiap notifikasi baru (dipicu showNotification)
                        ParallelAnimation {
                            id: notifyPopAnim
                            SequentialAnimation {
                                NumberAnimation { target: animMochi; property: "scale"; from: 0.5; to: 1.25; duration: 260; easing.type: Easing.OutBack }
                                NumberAnimation { target: animMochi; property: "scale"; to: 1.0; duration: 260; easing.type: Easing.InOutQuad }
                            }
                            NumberAnimation { target: animMochi; property: "rotation"; from: -200; to: 0; duration: 620; easing.type: Easing.OutCubic }
                        }
                    }

                    SourceLogo {
                        visible: root.notifySource !== ""
                        kind: root.notifySource
                        size: 20
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: -4
                        anchors.bottomMargin: -3
                    }
                }

                // Judul (chip agent + status + chip project) dan detail
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    spacing: 3

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            visible: root.notifySource !== ""
                            implicitWidth: srcChipTxt.implicitWidth + 10
                            implicitHeight: 15
                            radius: 4
                            color: "transparent"
                            border.color: Qt.darker(root.sourceColor(root.notifySource), 1.6)
                            border.width: 1
                            Text {
                                id: srcChipTxt
                                anchors.centerIn: parent
                                text: root.agentName(root.notifySource).toUpperCase()
                                color: root.sourceColor(root.notifySource)
                                font.pixelSize: 8
                                font.bold: true
                                font.letterSpacing: 0.6
                            }
                        }

                        Text {
                            text: root.currentStatus
                            color: root.statusColor
                            font.pixelSize: 13
                            font.weight: Font.ExtraBold
                            font.family: "Inter, sans-serif"
                        }

                        Rectangle {
                            visible: root.notifyProject !== ""
                            implicitWidth: projChipTxt.implicitWidth + 10
                            implicitHeight: 15
                            radius: 4
                            color: "#18181b"
                            border.color: "#27272a"
                            Text {
                                id: projChipTxt
                                anchors.centerIn: parent
                                text: "▸ " + root.notifyProject
                                color: "#a1a1aa"
                                font.pixelSize: 8
                                font.bold: true
                                font.family: "JetBrains Mono, monospace"
                            }
                        }

                        Item { Layout.fillWidth: true }
                    }

                    Text {
                        Layout.fillWidth: true
                        text: root.activeDetail
                        color: "#d4d4d8"
                        font.pixelSize: 10
                        // Command approval / kalimat inti jawaban interview: sampai 2 baris.
                        readonly property bool twoLines: root.notifyType === "approval" || root.notifyType === "interview"
                        elide: Text.ElideRight
                        wrapMode: twoLines ? Text.WrapAtWordBoundaryOrAnywhere : Text.NoWrap
                        maximumLineCount: twoLines ? 2 : 1
                    }
                }

                // Indikator kanan: titik memantul (diterima), centang + durasi (selesai),
                // atau penanda terminal (butuh izin).
                Item {
                    visible: root.notifyType === "task_start" || root.notifyType === "done" || root.notifyType === "agent_wait"
                    Layout.preferredWidth: 56
                    Layout.preferredHeight: 40
                    Layout.alignment: Qt.AlignVCenter

                    Row {
                        visible: root.notifyType === "task_start"
                        anchors.centerIn: parent
                        spacing: 5
                        Repeater {
                            model: 3
                            Rectangle {
                                id: bounceDot
                                required property int index
                                width: 7; height: 7; radius: 3.5
                                color: root.statusColor
                                SequentialAnimation on y {
                                    running: root.isNotifying && root.notifyType === "task_start"
                                    loops: Animation.Infinite
                                    PauseAnimation { duration: bounceDot.index * 130 }
                                    NumberAnimation { from: 0; to: -7; duration: 220; easing.type: Easing.OutQuad }
                                    NumberAnimation { from: -7; to: 0; duration: 220; easing.type: Easing.InQuad }
                                    PauseAnimation { duration: (2 - bounceDot.index) * 130 + 260 }
                                }
                            }
                        }
                    }

                    Column {
                        visible: root.notifyType === "done"
                        anchors.centerIn: parent
                        spacing: 3

                        Rectangle {
                            id: doneCheck
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 24; height: 24; radius: 12
                            color: root.notifyError ? "#450a0a" : "#052e16"
                            border.color: root.notifyError ? "#ef4444" : "#22c55e"
                            border.width: 1.5
                            Text {
                                anchors.centerIn: parent
                                text: root.notifyError ? "✕" : "✓"
                                color: root.notifyError ? "#fca5a5" : "#86efac"
                                font.pixelSize: 13
                                font.bold: true
                            }
                            SequentialAnimation on scale {
                                running: root.isNotifying && root.notifyType === "done"
                                NumberAnimation { from: 0; to: 0; duration: 180 }
                                NumberAnimation { from: 0; to: 1.2; duration: 220; easing.type: Easing.OutBack }
                                NumberAnimation { to: 1.0; duration: 160 }
                            }
                        }

                        Text {
                            visible: root.notifyDuration !== ""
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "⏱ " + root.notifyDuration
                            color: "#71717a"
                            font.pixelSize: 8
                            font.bold: true
                        }
                    }

                    Rectangle {
                        visible: root.notifyType === "agent_wait"
                        anchors.centerIn: parent
                        width: 44; height: 22; radius: 6
                        color: "#1c1917"
                        border.color: "#f97316"
                        Text {
                            anchors.centerIn: parent
                            text: ">_"
                            color: "#fdba74"
                            font.pixelSize: 11
                            font.bold: true
                            font.family: "JetBrains Mono, monospace"
                        }
                    }
                }

                // Tombol Run & Reject khusus jika Approval Required
                Row {
                    visible: root.notifyType === "approval"
                    spacing: 8
                    Layout.alignment: Qt.AlignVCenter

                    // Tombol Reject (Tolak)
                    Rectangle {
                        implicitWidth: rejectText.implicitWidth + 18
                        height: 28
                        radius: 6
                        opacity: root.decisionPending ? 0.5 : 1.0
                        color: rejectHover.containsMouse ? "#450a0a" : "#1f1315"
                        border.color: rejectHover.containsMouse ? "#ef4444" : "#991b1b"
                        border.width: 1

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 4
                            Text { text: "✕"; color: "#f87171"; font.pixelSize: 10; font.bold: true }
                            Text {
                                id: rejectText
                                text: root.decisionPending ? "Sending…" : "Reject"
                                color: "#fca5a5"
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }
                        MouseArea {
                            id: rejectHover
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            enabled: root.approvalActionable && !root.decisionPending && root.hermesConnected
                            onClicked: root.submitDecision("deny")
                        }
                    }

                    // Tombol Run (Izinkan)
                    Rectangle {
                        implicitWidth: runText.implicitWidth + 20
                        height: 28
                        radius: 6
                        opacity: root.decisionPending ? 0.5 : 1.0
                        color: runHover.containsMouse ? "#16a34a" : "#22c55e"
                        border.color: "#86efac"
                        border.width: 1

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 5
                            Text { text: "⚡"; font.pixelSize: 11 }
                            Text {
                                id: runText
                                text: root.decisionPending ? "Sending…" : "Run"
                                color: "#052e16"
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }
                        MouseArea {
                            id: runHover
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            enabled: root.approvalActionable && !root.decisionPending && root.hermesConnected
                            onClicked: root.submitDecision("allow")
                        }
                    }
                }
            }

            // 2b. KARTU PERMINTAAN AGENT: izin (Tolak / Izinkan) atau pertanyaan pilihan
            ColumnLayout {
                id: requestCard
                visible: root.notifyType === "request" && root.currentRequest !== null
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.leftMargin: 6
                anchors.rightMargin: 6
                anchors.topMargin: 4
                spacing: 8

                readonly property var req: root.currentRequest
                readonly property bool isPerm: req !== null && req.kind === "permission"
                readonly property var question: (req && !isPerm && req.questions.length > root.reqIndex) ? req.questions[root.reqIndex] : null
                readonly property var picked: root.reqSelections[root.reqIndex] || []

                // Header: Mochi + logo, chip agent/project, judul, posisi antrean
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 10

                    Item {
                        Layout.preferredWidth: 34
                        Layout.preferredHeight: 34
                        BibleStrongAvatar {
                            anchors.centerIn: parent
                            size: 30
                            avatarType: root.avatarModel
                            expression: root.avatarExpression
                            targetLookX: root.cursorLookX
                            targetLookY: root.cursorLookY
                        }
                        SourceLogo {
                            kind: root.notifySource
                            size: 18
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            anchors.rightMargin: -4
                            anchors.bottomMargin: -3
                        }
                    }

                    ColumnLayout {
                        spacing: 2
                        RowLayout {
                            spacing: 6
                            Rectangle {
                                implicitWidth: reqSrcTxt.implicitWidth + 10; implicitHeight: 15; radius: 4
                                color: "transparent"
                                border.color: Qt.darker(root.sourceColor(root.notifySource), 1.6)
                                Text {
                                    id: reqSrcTxt
                                    anchors.centerIn: parent
                                    text: root.agentName(root.notifySource).toUpperCase()
                                    color: root.sourceColor(root.notifySource)
                                    font.pixelSize: 8; font.bold: true; font.letterSpacing: 0.6
                                }
                            }
                            Rectangle {
                                visible: root.notifyProject !== ""
                                implicitWidth: reqProjTxt.implicitWidth + 10; implicitHeight: 15; radius: 4
                                color: "#18181b"; border.color: "#27272a"
                                Text {
                                    id: reqProjTxt
                                    anchors.centerIn: parent
                                    text: "▸ " + root.notifyProject
                                    color: "#a1a1aa"
                                    font.pixelSize: 8; font.bold: true; font.family: "JetBrains Mono, monospace"
                                }
                            }
                            Rectangle {
                                visible: requestCard.question !== null && requestCard.question.header !== ""
                                implicitWidth: reqHeaderTxt.implicitWidth + 10; implicitHeight: 15; radius: 4
                                color: "#0c4a6e"
                                Text {
                                    id: reqHeaderTxt
                                    anchors.centerIn: parent
                                    text: requestCard.question ? requestCard.question.header : ""
                                    color: "#bae6fd"
                                    font.pixelSize: 8; font.bold: true
                                }
                            }
                        }
                        Text {
                            text: requestCard.isPerm ? (requestCard.req ? (requestCard.req.title || "Butuh izin") : "")
                                  : "Pertanyaan" + (requestCard.req && requestCard.req.questions.length > 1
                                                    ? " " + (root.reqIndex + 1) + "/" + requestCard.req.questions.length : "")
                            color: root.statusColor
                            font.pixelSize: 13
                            font.weight: Font.ExtraBold
                        }
                    }

                    Item { Layout.fillWidth: true }

                    Rectangle {
                        visible: root.agentRequests.length > 1
                        Layout.alignment: Qt.AlignTop
                        implicitWidth: queueTxt.implicitWidth + 12; implicitHeight: 18; radius: 9
                        color: "#27272a"
                        Text {
                            id: queueTxt
                            anchors.centerIn: parent
                            text: "1/" + root.agentRequests.length + " antrean"
                            color: "#d4d4d8"; font.pixelSize: 9; font.bold: true
                        }
                    }
                }

                // ---- IZIN: perintah yang akan dijalankan ----
                Rectangle {
                    visible: requestCard.isPerm
                    Layout.fillWidth: true
                    implicitHeight: permDetail.implicitHeight + 16
                    radius: 8
                    color: "#111114"
                    border.color: "#27272a"
                    Text {
                        id: permDetail
                        anchors.fill: parent
                        anchors.margins: 8
                        text: requestCard.req ? (requestCard.req.detail || "-") : ""
                        color: "#e4e4e7"
                        font.pixelSize: 11
                        font.family: "JetBrains Mono, monospace"
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        maximumLineCount: 5
                        elide: Text.ElideRight
                    }
                }

                // ---- PERTANYAAN: teks + pilihan ----
                Text {
                    visible: requestCard.question !== null
                    Layout.fillWidth: true
                    text: requestCard.question ? requestCard.question.question : ""
                    color: "#f4f4f5"
                    font.pixelSize: 12
                    font.bold: true
                    wrapMode: Text.WordWrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                }

                Flickable {
                    visible: requestCard.question !== null && requestCard.question.options.length > 0
                    Layout.fillWidth: true
                    Layout.preferredHeight: Math.min(optionCol.implicitHeight, 172)
                    contentHeight: optionCol.implicitHeight
                    clip: true
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: optionCol
                        width: parent.width
                        spacing: 5

                        Repeater {
                            model: requestCard.question ? requestCard.question.options : []
                            Rectangle {
                                id: optionRow
                                required property var modelData
                                required property int index
                                readonly property bool chosen: requestCard.picked.indexOf(modelData.label) >= 0
                                width: optionCol.width
                                height: optionText.implicitHeight + 14
                                radius: 7
                                color: chosen ? "#0c4a6e" : (optionHover.containsMouse ? "#1f1f24" : "#16161a")
                                border.color: chosen ? "#38bdf8" : (optionHover.containsMouse ? "#3f3f46" : "#27272a")
                                Behavior on color { ColorAnimation { duration: 120 } }

                                Row {
                                    id: optionText
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    spacing: 8

                                    // Nomor (single) atau checkbox (multi)
                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 18; height: 18
                                        radius: requestCard.question && requestCard.question.multiSelect ? 4 : 9
                                        color: optionRow.chosen ? "#38bdf8" : "transparent"
                                        border.color: optionRow.chosen ? "#38bdf8" : "#52525b"
                                        Text {
                                            anchors.centerIn: parent
                                            text: optionRow.chosen ? "✓" : (optionRow.index + 1)
                                            color: optionRow.chosen ? "#082f49" : "#a1a1aa"
                                            font.pixelSize: 9; font.bold: true
                                        }
                                    }

                                    Column {
                                        width: parent.width - 26
                                        spacing: 1
                                        Text {
                                            width: parent.width
                                            text: optionRow.modelData.label
                                            color: "#f4f4f5"
                                            font.pixelSize: 11; font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            visible: text !== ""
                                            width: parent.width
                                            text: optionRow.modelData.description || ""
                                            color: "#a1a1aa"
                                            font.pixelSize: 9
                                            wrapMode: Text.WordWrap
                                            maximumLineCount: 2
                                            elide: Text.ElideRight
                                        }
                                    }
                                }

                                MouseArea {
                                    id: optionHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: !root.reqSending
                                    onClicked: root.reqToggleOption(optionRow.modelData.label)
                                }
                            }
                        }
                    }
                }

                // Jawaban bebas (bila agent mengizinkan / pertanyaan tanpa pilihan)
                Rectangle {
                    visible: requestCard.question !== null && (requestCard.question.custom || requestCard.question.options.length === 0)
                    Layout.fillWidth: true
                    implicitHeight: 30
                    radius: 7
                    color: "#16161a"
                    border.color: requestCustomInput.activeFocus ? "#38bdf8" : "#27272a"
                    TextField {
                        id: requestCustomInput
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        placeholderText: "Jawaban lain… (Enter untuk kirim)"
                        placeholderTextColor: "#71717a"
                        color: "#ffffff"
                        font.pixelSize: 11
                        background: null
                        enabled: !root.reqSending
                        onAccepted: root.reqAdvance()
                    }
                }

                Text {
                    visible: root.reqError !== ""
                    Layout.fillWidth: true
                    text: "⚠ " + root.reqError
                    color: "#f87171"
                    font.pixelSize: 10
                    wrapMode: Text.WordWrap
                }

                // Footer tombol
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    Text {
                        text: "Jawab di terminal"
                        color: termLink.containsMouse ? "#e4e4e7" : "#71717a"
                        font.pixelSize: 10
                        font.underline: termLink.containsMouse
                        MouseArea {
                            id: termLink
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            enabled: !root.reqSending
                            onClicked: root.submitRequestAnswer({decision: "terminal"})
                        }
                    }

                    Text {
                        visible: root.reqSending
                        text: "Mengirim…"
                        color: "#38bdf8"
                        font.pixelSize: 10
                    }

                    Item { Layout.fillWidth: true }

                    // Tombol izin
                    Repeater {
                        model: requestCard.isPerm ? [
                            {key: "deny", label: "Tolak", fg: "#fca5a5", bg: "#1f1315", border: "#991b1b"},
                            {key: "always", label: "Selalu izinkan", fg: "#bae6fd", bg: "#0b1f2e", border: "#0369a1"},
                            {key: "allow", label: "Izinkan", fg: "#052e16", bg: "#22c55e", border: "#86efac"}
                        ].filter(b => b.key !== "always" || (requestCard.req && requestCard.req.can_always)) : []
                        Rectangle {
                            id: permBtn
                            required property var modelData
                            implicitWidth: permBtnTxt.implicitWidth + 22
                            implicitHeight: 28
                            radius: 7
                            color: permBtnHover.containsMouse ? Qt.lighter(modelData.bg, 1.3) : modelData.bg
                            border.color: modelData.border
                            opacity: root.reqSending ? 0.5 : 1.0
                            Text {
                                id: permBtnTxt
                                anchors.centerIn: parent
                                text: permBtn.modelData.label
                                color: permBtn.modelData.fg
                                font.pixelSize: 11; font.bold: true
                            }
                            MouseArea {
                                id: permBtnHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: !root.reqSending
                                onClicked: root.submitRequestAnswer({decision: permBtn.modelData.key})
                            }
                        }
                    }

                    // Tombol pertanyaan
                    Rectangle {
                        visible: requestCard.question !== null && root.reqIndex > 0
                        implicitWidth: backTxt.implicitWidth + 20; implicitHeight: 28; radius: 7
                        color: backHover.containsMouse ? "#27272a" : "#18181b"
                        border.color: "#3f3f46"
                        Text { id: backTxt; anchors.centerIn: parent; text: "Kembali"; color: "#d4d4d8"; font.pixelSize: 11; font.bold: true }
                        MouseArea {
                            id: backHover
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            enabled: !root.reqSending
                            onClicked: root.reqIndex -= 1
                        }
                    }

                    Rectangle {
                        readonly property bool ready: requestCard.picked.length > 0 || requestCustomInput.text.trim().length > 0
                        readonly property bool last: requestCard.req !== null && root.reqIndex >= requestCard.req.questions.length - 1
                        id: nextBtn
                        visible: requestCard.question !== null && (requestCard.question.multiSelect || requestCustomInput.text.trim().length > 0
                                                                   || requestCard.question.options.length === 0 || (requestCard.picked.length > 0 && !nextBtn.last))
                        implicitWidth: nextTxt.implicitWidth + 22; implicitHeight: 28; radius: 7
                        color: ready ? (nextHover.containsMouse ? "#0ea5e9" : "#0284c7") : "#18181b"
                        border.color: ready ? "#7dd3fc" : "#27272a"
                        Text {
                            id: nextTxt
                            anchors.centerIn: parent
                            text: nextBtn.last ? "Kirim" : "Lanjut"
                            color: nextBtn.ready ? "#f0f9ff" : "#52525b"
                            font.pixelSize: 11; font.bold: true
                        }
                        MouseArea {
                            id: nextHover
                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            enabled: nextBtn.ready && !root.reqSending
                            onClicked: root.reqAdvance()
                        }
                    }
                }
            }

            // 3. TAMPILAN EXPANDED SAAT DI-HOVER
            RowLayout {
                visible: root.islandExpanded && !root.isNotifying
                anchors.fill: parent
                spacing: 14

                // PANEL KIRI: AVATAR BESAR & MEDIA PLAYER CONTROL (SPOTIFY INTEGRATED)
                Rectangle {
                    Layout.preferredWidth: 168
                    Layout.fillHeight: true
                    radius: 14
                    color: "#121215"
                    border.color: "#27272a"
                    clip: true

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        // Avatar Besar di Sebelah Kiri
                        Item {
                            Layout.alignment: Qt.AlignHCenter
                            width: 68
                            height: 68

                            BibleStrongAvatar {
                                id: largeAvatar
                                anchors.centerIn: parent
                                size: 66
                                avatarType: root.avatarModel
                                expression: root.isDizzy ? "dizzy" : (root.isAngry ? "angry" : (root.hermesWorking ? "working" : "proud"))
                                targetLookX: root.cursorLookX
                                targetLookY: root.cursorLookY
                            }

                            // Pointer diam di atas avatar (bukan seluruh panel kiri) → kesal.
                            HoverHandler {
                                onHoveredChanged: {
                                    root.cursorOnRobot = hovered;
                                    if (hovered) {
                                        robotAngerCountdown.restart();
                                    } else {
                                        root.isAngry = false;
                                        robotAngerCountdown.stop();
                                    }
                                }
                            }

                            // Klik = kesal; tiga klik beruntun = pusing & bergetar.
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (root.isDizzy) return;
                                    root.robotClickCount += 1;
                                    clickStreakTimer.restart();
                                    if (root.robotClickCount >= 3) {
                                        root.robotClickCount = 0;
                                        root.isAngry = false;
                                        root.isDizzy = true;
                                        dizzyTimer.restart();
                                    } else {
                                        root.isAngry = true;
                                        angerFadeTimer.restart();
                                    }
                                }
                            }
                        }

                        // Label Robot & Status
                        Column {
                            Layout.fillWidth: true
                            Layout.alignment: Qt.AlignHCenter
                            spacing: 2

                            Text {
                                text: "QBot"
                                color: "#ffffff"
                                font.pixelSize: 14
                                font.weight: Font.Black
                                font.family: "Inter, sans-serif"
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            Row {
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 5
                                Rectangle {
                                    width: 6; height: 6; radius: 3; color: root.statusColor
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                Text {
                                    text: root.currentStatus
                                    color: root.statusColor
                                    font.pixelSize: 10
                                    font.bold: true
                                    font.family: "Inter, sans-serif"
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        // KARTU SPOTIFY MEDIA PLAYER (REIMAGINED CLEAN & PROPORTIONAL)
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: spotifyCol.implicitHeight + 20
                            radius: 10
                            color: "#18181b"
                            border.color: root.mediaPlaying ? "#1db954" : "#27272a"
                            border.width: 1

                            Behavior on border.color { ColorAnimation { duration: 250 } }

                            ColumnLayout {
                                id: spotifyCol
                                anchors.fill: parent
                                anchors.margins: 10
                                spacing: 8

                                // Header Row: Spotify Logo + Player Name (Rapi)
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6

                                    Image {
                                        source: "file:///usr/share/icons/Papirus/24x24/apps/spotify.svg"
                                        Layout.preferredWidth: 14
                                        Layout.preferredHeight: 14
                                        fillMode: Image.PreserveAspectFit
                                    }

                                    Text {
                                        text: root.mediaSource
                                        color: root.mediaPlaying ? "#1db954" : "#a1a1aa"
                                        font.pixelSize: 9
                                        font.bold: true
                                        font.family: "Inter, sans-serif"
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                    }

                                    // Audio Visualizer Waveform Bar (Kecil di Kanan)
                                    Row {
                                        spacing: 2
                                        Layout.alignment: Qt.AlignVCenter

                                        Repeater {
                                            model: [
                                                { maxH: 12, minH: 3, dur: 380 },
                                                { maxH: 16, minH: 4, dur: 290 },
                                                { maxH: 11, minH: 3, dur: 450 },
                                                { maxH: 15, minH: 4, dur: 330 },
                                                { maxH: 9,  minH: 3, dur: 410 }
                                            ]
                                            Rectangle {
                                                width: 2.5
                                                height: root.mediaPlaying ? 8 : 3
                                                radius: 1
                                                color: root.mediaPlaying ? "#1db954" : "#52525b"
                                                anchors.bottom: parent.bottom

                                                SequentialAnimation on height {
                                                    running: root.mediaPlaying
                                                    loops: Animation.Infinite
                                                    NumberAnimation { to: modelData.maxH; duration: modelData.dur; easing.type: Easing.InOutQuad }
                                                    NumberAnimation { to: modelData.minH; duration: modelData.dur; easing.type: Easing.InOutQuad }
                                                }
                                            }
                                        }
                                    }
                                }

                                // Body Row: Album Art (40x40) + Track Info (Vertikal)
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 10

                                    // Album Art Thumbnail (Cover HD)
                                    Rectangle {
                                        Layout.preferredWidth: 42
                                        Layout.preferredHeight: 42
                                        radius: 7
                                        color: "#27272a"
                                        clip: true

                                        Image {
                                            anchors.fill: parent
                                            visible: !!root.mediaArtUrl
                                            source: root.mediaArtUrl
                                            fillMode: Image.PreserveAspectCrop
                                            asynchronous: true
                                            smooth: true
                                            cache: true
                                        }

                                        // Placeholder Icon ketika artwork kosong
                                        Image {
                                            anchors.centerIn: parent
                                            width: 22; height: 22
                                            source: "file:///usr/share/icons/Papirus/48x48/apps/spotify.svg"
                                            visible: !root.mediaArtUrl
                                            fillMode: Image.PreserveAspectFit
                                        }
                                    }

                                    // Track Title & Artist (Teks Rapi)
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 2

                                        Text {
                                            text: root.mediaTitle
                                            color: "#f4f4f5"
                                            font.pixelSize: 10
                                            font.bold: true
                                            font.family: "Inter, sans-serif"
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }

                                        Text {
                                            text: root.mediaArtist
                                            color: "#71717a"
                                            font.pixelSize: 9
                                            font.family: "Inter, sans-serif"
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                    }
                                }

                                // Media Controls: Previous | Play/Pause | Next (Lebih Lengkung & Lebar)
                                RowLayout {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.topMargin: 2
                                    spacing: 10

                                    // Tombol Prev
                                    Rectangle {
                                        width: 28; height: 28; radius: 14
                                        color: prevMediaHover.containsMouse ? "#27272a" : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "⏮"
                                            color: "#a1a1aa"
                                            font.pixelSize: 13
                                        }
                                        MouseArea {
                                            id: prevMediaHover
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.sendBridgeCommand({action: "media", name: "previous"});
                                                mediaRefreshDelay.restart();
                                            }
                                        }
                                    }

                                    // Tombol Play / Pause Circle (Hijau Spotify)
                                    Rectangle {
                                        width: 30; height: 30; radius: 15
                                        color: "#1db954"
                                        Text {
                                            anchors.centerIn: parent
                                            text: root.mediaPlaying ? "⏸" : "▶"
                                            color: "#000000"
                                            font.pixelSize: 13
                                        }
                                        MouseArea {
                                            anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.sendBridgeCommand({action: "media", name: "play-pause"});
                                                root.mediaPlaying = !root.mediaPlaying;
                                                mediaRefreshDelay.restart();
                                            }
                                        }
                                    }

                                    // Tombol Next
                                    Rectangle {
                                        width: 28; height: 28; radius: 14
                                        color: nextMediaHover.containsMouse ? "#27272a" : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "⏭"
                                            color: "#a1a1aa"
                                            font.pixelSize: 13
                                        }
                                        MouseArea {
                                            id: nextMediaHover
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                root.sendBridgeCommand({action: "media", name: "next"});
                                                mediaRefreshDelay.restart();
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // KARTU JAM DIGITAL & TANGGAL (AESTHETIC WIDGET)
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 52
                            radius: 8
                            color: "#18181b"
                            border.color: "#27272a"
                            border.width: 1

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 6
                                spacing: 1

                                // Jam & Detik
                                RowLayout {
                                    Layout.alignment: Qt.AlignHCenter
                                    spacing: 3

                                    Text {
                                        text: root.currentTimeHoursMins
                                        color: "#ffffff"
                                        font.pixelSize: 18
                                        font.bold: true
                                        font.family: "JetBrains Mono, Inter, monospace"
                                    }

                                    Text {
                                        text: ":" + root.currentTimeSecs
                                        color: "#38bdf8"
                                        font.pixelSize: 12
                                        font.bold: true
                                        font.family: "JetBrains Mono, Inter, monospace"
                                    }

                                    // Badge Mini WIB
                                    Rectangle {
                                        width: 24; height: 13; radius: 3
                                        color: "#27272a"
                                        Layout.alignment: Qt.AlignVCenter
                                        Text {
                                            anchors.centerIn: parent
                                            text: "WIB"
                                            color: "#94a3b8"
                                            font.pixelSize: 8
                                            font.bold: true
                                        }
                                    }
                                }

                                // Tanggal Lengkap
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: root.currentDateStr
                                    color: "#a1a1aa"
                                    font.pixelSize: 9
                                    font.family: "Inter, sans-serif"
                                }
                            }
                        }

                        Item { Layout.fillHeight: true }

                        // Quick Avatar Switcher (Klik untuk ganti model Avatar Lab)
                        Row {
                            Layout.alignment: Qt.AlignHCenter
                            spacing: 6

                            Repeater {
                                model: ["white", "strobi", "nova", "citrus", "kirby"]
                                Rectangle {
                                    width: 16; height: 16; radius: 8
                                    color: {
                                        if (modelData === "white") return "#ffffff";
                                        if (modelData === "strobi") return "#5b7fe5";
                                        if (modelData === "nova") return "#55b6c3";
                                        if (modelData === "citrus") return "#ffcf24";
                                        if (modelData === "kirby") return "#ffb6e0";
                                        return "#a1a1aa";
                                    }
                                    border.color: root.avatarModel === modelData ? "#38bdf8" : "#3f3f46"
                                    border.width: 1.5

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: settings.avatar = modelData
                                    }
                                }
                            }
                        }
                    }
                }

                // PANEL KANAN: TAB NAVIGASI & KONTEN (CATATAN / STATUS / 9ROUTER)
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 8

                    // Navigasi Tab
                    Row {
                        spacing: 6
                        Layout.fillWidth: true

                        Rectangle {
                            width: 66; height: 26; radius: 6
                            color: root.activeTab === "notes" ? "#27272a" : "transparent"
                            Text { anchors.centerIn: parent; text: "Catatan"; color: root.activeTab === "notes" ? "#fff" : "#71717a"; font.pixelSize: 11; font.bold: true }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.activeTab = "notes"; fetchNotesProcess.running = true } }
                        }
                        Rectangle {
                            width: 60; height: 26; radius: 6
                            color: root.activeTab === "status" ? "#27272a" : "transparent"
                            Text { anchors.centerIn: parent; text: "Status"; color: root.activeTab === "status" ? "#fff" : "#71717a"; font.pixelSize: 11; font.bold: true }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.activeTab = "status"; fetchSysInfoProcess.running = true } }
                        }
                        Rectangle {
                            width: 66; height: 26; radius: 6
                            color: root.activeTab === "usage" ? "#27272a" : "transparent"
                            Text { anchors.centerIn: parent; text: "9Router"; color: root.activeTab === "usage" ? "#fff" : "#71717a"; font.pixelSize: 11; font.bold: true }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.activeTab = "usage"; fetchUsageProcess.running = true } }
                        }
                        Rectangle {
                            width: 54; height: 26; radius: 6
                            color: root.activeTab === "tools" ? "#27272a" : "transparent"
                            Text { anchors.centerIn: parent; text: "Tools"; color: root.activeTab === "tools" ? "#fff" : "#71717a"; font.pixelSize: 11; font.bold: true }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.activeTab = "tools" }
                        }
                        Rectangle {
                            width: 68; height: 26; radius: 6
                            color: root.activeTab === "projects" ? "#27272a" : "transparent"
                            Text { anchors.centerIn: parent; text: "Projects"; color: root.activeTab === "projects" ? "#fff" : "#71717a"; font.pixelSize: 11; font.bold: true }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.activeTab = "projects";
                                    fetchProjectsProcess.running = true;
                                }
                            }
                        }
                        Rectangle {
                            id: devTabBtn
                            width: 44; height: 26; radius: 6
                            color: root.activeTab === "dev" ? "#27272a" : "transparent"
                            Text { anchors.centerIn: parent; text: "Dev"; color: root.activeTab === "dev" ? "#fff" : "#71717a"; font.pixelSize: 11; font.bold: true }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.activeTab = "dev";
                                    sendBridgeCommand({ action: "dev_status" });
                                }
                            }
                        }
                        Rectangle {
                            width: 72; height: 26; radius: 6
                            color: root.activeTab === "interview" ? "#27272a" : "transparent"
                            Row {
                                anchors.centerIn: parent
                                spacing: 4
                                Rectangle {
                                    visible: root.interviewRunning
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 6; height: 6; radius: 3
                                    color: "#ef4444"
                                }
                                Text { text: "Interview"; color: root.activeTab === "interview" ? "#fff" : "#71717a"; font.pixelSize: 11; font.bold: true }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.activeTab = "interview";
                                    sendBridgeCommand({ action: "interview_status" });
                                }
                            }
                        }
                    }

                // TAB 1: CATATAN (DENGAN TO-DO CHECKBOX, RUN COMMAND TERMINAL & TAGS)
                ColumnLayout {
                    id: notesTabCol
                    visible: root.activeTab === "notes"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 8

                    property string filterTag: "all" // "all" | "cmd" | "task" | "note"
                    property string selectedTag: "cmd" // "cmd" | "task" | "note"
                    property bool confirmClear: false
                    // Jumlah catatan yang lolos filter (untuk empty state per filter).
                    readonly property int visibleNoteCount: {
                        let n = notesModel.count;
                        if (filterTag === "all") return n;
                        let c = 0;
                        for (let i = 0; i < n; i++) {
                            if (notesModel.get(i).tag === filterTag) c++;
                        }
                        return c;
                    }

                    // Header Mini Bar: Sub-Tab Filter Kategori & Quick Clear
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        // Filter Tabs: Semua, Command, Task, Memo
                        Row {
                            spacing: 4
                            Repeater {
                                model: [
                                    { key: "all", label: "Semua" },
                                    { key: "cmd", label: "Command" },
                                    { key: "task", label: "Task" },
                                    { key: "note", label: "Memo" }
                                ]
                                Rectangle {
                                    id: filterChipRect
                                    width: filterChipTxt.implicitWidth + 16
                                    height: 24; radius: 6
                                    color: notesTabCol.filterTag === modelData.key ? "#27272a" : "#18181b"
                                    border.color: notesTabCol.filterTag === modelData.key ? "#3f3f46" : "#27272a"
                                    border.width: 1

                                    Text {
                                        id: filterChipTxt
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        color: notesTabCol.filterTag === modelData.key ? "#ffffff" : "#71717a"
                                        font.pixelSize: 10
                                        font.bold: notesTabCol.filterTag === modelData.key
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            notesTabCol.filterTag = modelData.key;
                                            if (modelData.key !== "all") {
                                                notesTabCol.selectedTag = modelData.key;
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        // Tombol Clear All jika ada catatan
                        // Klik pertama minta konfirmasi; klik kedua (≤3 dtk) baru menghapus.
                        Rectangle {
                            visible: notesModel.count > 0
                            width: 76; height: 24; radius: 6
                            color: notesTabCol.confirmClear ? "#450a0a" : (clearAllHover.containsMouse ? "#27272a" : "#18181b")
                            border.color: notesTabCol.confirmClear ? "#ef4444" : "#27272a"
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: notesTabCol.confirmClear ? "Yakin hapus?" : "Hapus Semua"
                                color: notesTabCol.confirmClear ? "#fca5a5" : (clearAllHover.containsMouse ? "#ffffff" : "#71717a")
                                font.pixelSize: 9
                                font.bold: true
                            }

                            MouseArea {
                                id: clearAllHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (!notesTabCol.confirmClear) {
                                        notesTabCol.confirmClear = true;
                                        clearConfirmTimer.restart();
                                        return;
                                    }
                                    notesTabCol.confirmClear = false;
                                    clearConfirmTimer.stop();
                                    notesModel.clear();
                                    root.saveNotesToFile();
                                }
                            }

                            Timer {
                                id: clearConfirmTimer
                                interval: 3000
                                repeat: false
                                onTriggered: notesTabCol.confirmClear = false
                            }
                        }
                    }

                    // Card Container List
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 8
                        color: "#121215"
                        border.color: "#27272a"
                        border.width: 1

                        ListView {
                            id: notesListView
                            anchors.fill: parent
                            anchors.margins: 6
                            model: notesModel
                            spacing: 0
                            clip: true

                            // Empty State (juga saat filter aktif tidak punya isi)
                            Text {
                                anchors.centerIn: parent
                                visible: notesTabCol.visibleNoteCount === 0
                                text: notesTabCol.filterTag === "cmd" ? "Belum ada perintah command" : (notesTabCol.filterTag === "task" ? "Belum ada task tersimpan" : (notesTabCol.filterTag === "note" ? "Belum ada memo tersimpan" : "Belum ada catatan tersimpan"))
                                color: "#52525b"
                                font.pixelSize: 11
                            }

                            // Wrapper Item: jarak antar kartu ada di dalam delegate, sehingga
                            // item yang tersaring benar-benar 0px (tanpa celah spacing).
                            delegate: Item {
                                id: noteItemDelegate
                                readonly property string txt: model.text || ""
                                readonly property string itemType: root.noteType(txt, model.tag)
                                readonly property bool isCmd: itemType === "cmd"
                                readonly property bool isTask: itemType === "task"
                                readonly property bool itemVisible: notesTabCol.filterTag === "all" || notesTabCol.filterTag === itemType

                                visible: itemVisible
                                width: notesListView.width
                                height: itemVisible ? (delegateLayout.implicitHeight + 12 + 6) : 0

                              Rectangle {
                                width: parent.width
                                height: parent.height - 6
                                radius: 6
                                color: "#18181b"
                                border.color: "#27272a"
                                border.width: 1

                                RowLayout {
                                    id: delegateLayout
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    spacing: 8
                                    visible: noteItemDelegate.itemVisible

                                    // 1. Checkbox To-Do (Centang Selesai) - Hanya tampil jika BUKAN command
                                    Rectangle {
                                        visible: !noteItemDelegate.isCmd
                                        width: 16; height: 16; radius: 4
                                        color: model.done ? "#27272a" : "transparent"
                                        border.color: model.done ? "#52525b" : "#3f3f46"
                                        border.width: 1
                                        Layout.alignment: Qt.AlignTop
                                        Layout.topMargin: 2

                                        Text {
                                            anchors.centerIn: parent
                                            text: "✓"
                                            color: "#ffffff"
                                            font.pixelSize: 10
                                            font.bold: true
                                            visible: !!model.done
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.toggleNoteDone(index)
                                        }
                                    }

                                    // 2. Konten Memo / Command
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 3

                                        RowLayout {
                                            spacing: 6

                                            // Tag Badge
                                            Rectangle {
                                                implicitWidth: tagLbl.implicitWidth + 8
                                                height: 14; radius: 3
                                                color: "#27272a"
                                                border.color: "#3f3f46"
                                                border.width: 1

                                                Text {
                                                    id: tagLbl
                                                    anchors.centerIn: parent
                                                    text: noteItemDelegate.isCmd ? "COMMAND" : (noteItemDelegate.isTask ? "TASK" : "MEMO")
                                                    color: "#ffffff"
                                                    font.pixelSize: 8
                                                    font.bold: true
                                                }
                                            }

                                            Text {
                                                text: model.time || ""
                                                color: "#71717a"
                                                font.pixelSize: 9
                                            }
                                        }

                                        Text {
                                            text: noteItemDelegate.txt
                                            color: "#ffffff"
                                            font.pixelSize: 11
                                            font.family: noteItemDelegate.isCmd ? "JetBrains Mono, monospace" : "Inter, sans-serif"
                                            font.strikeout: !!model.done
                                            wrapMode: Text.Wrap
                                            Layout.fillWidth: true
                                            Layout.maximumWidth: notesListView.width - 95
                                        }
                                    }

                                    // 3. Action Buttons: Run (jika command), Copy & Delete
                                    Row {
                                        spacing: 4
                                        Layout.alignment: Qt.AlignTop

                                        // Tombol RUN Terminal (Hanya jika terdeteksi command)
                                        Rectangle {
                                            visible: noteItemDelegate.isCmd
                                            width: 22; height: 22; radius: 4
                                            color: runBtnHover.containsMouse ? "#27272a" : "#1f1f23"
                                            border.color: "#3f3f46"
                                            border.width: 1

                                            Text {
                                                anchors.centerIn: parent
                                                text: "▶"
                                                color: "#ffffff"
                                                font.pixelSize: 9
                                                font.bold: true
                                            }

                                            MouseArea {
                                                id: runBtnHover
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.runCommandNote(index)
                                            }
                                        }

                                        // Tombol Copy
                                        Rectangle {
                                            id: copyBtn
                                            width: 22; height: 22; radius: 4
                                            color: copyBtnHover.containsMouse ? "#27272a" : "transparent"
                                            border.color: "transparent"
                                            property bool copiedRecently: false

                                            Text {
                                                anchors.centerIn: parent
                                                text: copyBtn.copiedRecently ? "✓" : "📋"
                                                color: "#ffffff"
                                                font.pixelSize: copyBtn.copiedRecently ? 12 : 11
                                            }

                                            MouseArea {
                                                id: copyBtnHover
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    let noteTxt = noteItemDelegate.txt;
                                                    copyNoteProcess.command = ["python3", root.appDir + "bridge_client.py", "post", "/clipboard/copy", JSON.stringify({text: noteTxt})];
                                                    copyNoteProcess.running = true;
                                                    copyBtn.copiedRecently = true;
                                                    resetCopyTimer.restart();
                                                }
                                            }

                                            Timer {
                                                id: resetCopyTimer
                                                interval: 1500
                                                repeat: false
                                                onTriggered: copyBtn.copiedRecently = false
                                            }
                                        }

                                        // Tombol Delete (✕)
                                        Rectangle {
                                            id: delBtn
                                            width: 22; height: 22; radius: 4
                                            color: delBtnHover.containsMouse ? "#27272a" : "transparent"
                                            border.color: "transparent"

                                            Text {
                                                anchors.centerIn: parent
                                                text: "✕"
                                                color: delBtnHover.containsMouse ? "#ef4444" : "#71717a"
                                                font.pixelSize: 10
                                                font.bold: true
                                            }

                                            MouseArea {
                                                id: delBtnHover
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.deleteNoteItem(index)
                                            }
                                        }
                                    }
                                }
                              }
                            }
                        }
                    }

                    // Input Memo Baru + Selector Tag
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            // Pilihan Tag Cepat (Command / Task / Memo)
                            Row {
                                spacing: 4
                                Repeater {
                                    model: [
                                        { key: "cmd", label: "Command" },
                                        { key: "task", label: "Task" },
                                        { key: "note", label: "Memo" }
                                    ]
                                    Rectangle {
                                        width: tagRowLbl.implicitWidth + 14
                                        height: 22; radius: 4
                                        color: notesTabCol.selectedTag === modelData.key ? "#27272a" : "#18181b"
                                        border.color: notesTabCol.selectedTag === modelData.key ? "#3f3f46" : "#27272a"
                                        border.width: 1

                                        Text {
                                            id: tagRowLbl
                                            anchors.centerIn: parent
                                            text: modelData.label
                                            color: "#ffffff"
                                            font.pixelSize: 9
                                            font.bold: true
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: notesTabCol.selectedTag = modelData.key
                                        }
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 6

                            Rectangle {
                                Layout.fillWidth: true
                                height: 32
                                radius: 6
                                color: "#18181b"
                                border.color: noteInput.activeFocus ? "#3f3f46" : "#27272a"
                                border.width: 1

                                TextField {
                                    id: noteInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    placeholderText: notesTabCol.selectedTag === "cmd" ? "Ketik perintah terminal..." : (notesTabCol.selectedTag === "task" ? "Tulis task kerjaan..." : "Tulis memo...")
                                    placeholderTextColor: "#71717a"
                                    color: "#ffffff"
                                    font.pixelSize: 11
                                    font.family: notesTabCol.selectedTag === "cmd" ? "JetBrains Mono, monospace" : "Inter, sans-serif"
                                    background: null
                                    Keys.onEscapePressed: event => {
                                        noteInput.focus = false;
                                        event.accepted = true;
                                    }
                                    onAccepted: {
                                        if (noteInput.text.trim().length > 0) {
                                            root.addNoteItem(noteInput.text.trim(), notesTabCol.selectedTag);
                                            noteInput.text = "";
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                id: saveNoteBtn
                                width: 68
                                height: 32
                                radius: 6
                                color: saveBtnHover.containsMouse ? "#27272a" : "#202024"
                                border.color: "#27272a"
                                border.width: 1

                                Text {
                                    anchors.centerIn: parent
                                    text: "Simpan"
                                    color: "#ffffff"
                                    font.pixelSize: 11
                                    font.bold: true
                                }

                                MouseArea {
                                    id: saveBtnHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        if (noteInput.text.trim().length > 0) {
                                            root.addNoteItem(noteInput.text.trim(), notesTabCol.selectedTag);
                                            noteInput.text = "";
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // TAB 2: STATUS (HERMES AGENT & SYSTEM MONITOR)
                ColumnLayout {
                    visible: root.activeTab === "status"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    // Kartu 1: Status Agent Hermes
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: statusAgentCol.implicitHeight + 20
                        radius: 8
                        color: "#18181b"
                        border.color: "#27272a"

                        ColumnLayout {
                            id: statusAgentCol
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 6

                            RowLayout {
                                spacing: 8
                                SourceLogo { kind: "hermes"; size: 16 }
                                Text {
                                    text: "Hermes Agent: " + root.currentStatus
                                    color: root.statusColor
                                    font.pixelSize: 13
                                    font.bold: true
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: "Niri Wayland"
                                    color: "#71717a"
                                    font.pixelSize: 10
                                }
                            }

                            Text {
                                text: root.activeDetail && root.activeDetail.length > 0 ? root.activeDetail : "Siap menerima prompt & task dari ganteng."
                                color: "#d4d4d8"
                                font.pixelSize: 11
                                wrapMode: Text.Wrap
                                Layout.fillWidth: true
                            }
                        }
                    }

                    // Kartu Agent Coding: tiap sesi Claude Code / OpenCode
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: agentCol.implicitHeight + 16
                        radius: 8
                        color: "#18181b"
                        border.color: (root.agentAggregate("claude") === "waiting" || root.agentAggregate("opencode") === "waiting") ? "#f97316" : "#27272a"

                        ColumnLayout {
                            id: agentCol
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4

                            RowLayout {
                                spacing: 6
                                SourceLogo { kind: "claude"; size: 15 }
                                SourceLogo { kind: "opencode"; size: 15 }
                                Text { text: "Agent Coding"; color: "#f4f4f5"; font.pixelSize: 12; font.bold: true }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: root.agentSessions.length > 0 ? root.agentSessions.length + " sesi" : ""
                                    color: "#71717a"; font.pixelSize: 9
                                }
                            }

                            Text {
                                visible: root.agentSessions.length === 0
                                text: "Belum ada sesi Claude Code / OpenCode yang aktif"
                                color: "#52525b"
                                font.pixelSize: 9
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Repeater {
                                model: root.agentSessions.slice(0, 3)
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    SourceLogo { kind: modelData.agent; size: 14 }
                                    Text {
                                        text: modelData.project || "?"
                                        color: "#e4e4e7"; font.pixelSize: 10; font.bold: true
                                        elide: Text.ElideRight
                                        Layout.preferredWidth: 80
                                    }
                                    Rectangle {
                                        implicitWidth: agentStateTxt.implicitWidth + 8; height: 14; radius: 3
                                        color: "transparent"
                                        border.color: root.stateColor(modelData.state); border.width: 1
                                        Text {
                                            id: agentStateTxt
                                            anchors.centerIn: parent
                                            text: root.stateLabel(modelData.state)
                                            color: root.stateColor(modelData.state)
                                            font.pixelSize: 8; font.bold: true
                                        }
                                    }
                                    Text {
                                        text: modelData.detail || ""
                                        color: "#a1a1aa"; font.pixelSize: 9
                                        font.family: "JetBrains Mono, monospace"
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Text {
                                        // currentTimeSecs: dependensi agar "x dtk" ikut berdetak
                                        text: root.currentTimeSecs !== "" ? root.agoText(modelData.updated) : ""
                                        color: "#52525b"; font.pixelSize: 8
                                    }
                                }
                            }
                        }
                    }

                    // Section Title: System Hardware & Resource
                    Text {
                        text: "RESOURCE SISTEM (ARCH LINUX)"
                        color: "#71717a"
                        font.pixelSize: 10
                        font.bold: true
                        topPadding: 2
                    }

                    // Kartu 2: Metrik RAM & Uptime
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        // RAM Usage Card
                        Rectangle {
                            Layout.fillWidth: true; height: 50; radius: 8; color: "#18181b"; border.color: "#27272a"
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 4
                                RowLayout {
                                    Text { text: "RAM Terpakai"; color: "#71717a"; font.pixelSize: 9 }
                                    Item { Layout.fillWidth: true }
                                    Text { text: "" + root.sysRamPercent + "%"; color: root.sysRamPercent > 85 ? "#ef4444" : "#38bdf8"; font.pixelSize: 10; font.bold: true }
                                }
                                // Progress bar mini RAM
                                Rectangle {
                                    Layout.fillWidth: true; height: 4; radius: 2; color: "#27272a"
                                    Rectangle {
                                        width: parent.width * (root.sysRamPercent / 100.0)
                                        height: parent.height; radius: 2
                                        color: root.sysRamPercent > 85 ? "#ef4444" : "#38bdf8"
                                    }
                                }
                                Text { text: root.sysRamUsed + " / " + root.sysRamTotal; color: "#a1a1aa"; font.pixelSize: 9 }
                            }
                        }

                        // Uptime Card
                        Rectangle {
                            Layout.fillWidth: true; height: 50; radius: 8; color: "#18181b"; border.color: "#27272a"
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 2
                                Text { text: "System Uptime"; color: "#71717a"; font.pixelSize: 9 }
                                Text { text: root.sysUptime; color: "#22c55e"; font.pixelSize: 12; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: root.sysProcesses + " proses · " + root.sysKernel; color: "#71717a"; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                        }
                    }

                    // Spacer bawah agar menempel ke atas
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
                }

                // TAB 3: 9ROUTER USAGE
                ColumnLayout {
                    visible: root.activeTab === "usage"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    // Header: Hari Ini (Today)
                    Text {
                        text: "HARI INI (TODAY)"
                        color: "#71717a"
                        font.pixelSize: 10
                        font.bold: true
                    }

                    // Metrik Hari Ini
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: "#18181b"; border.color: "#27272a"
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Requests"; color: "#71717a"; font.pixelSize: 9 }
                                Text { text: "" + root.usageRequests; color: "#fff"; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: "#18181b"; border.color: "#27272a"
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Biaya Hari Ini"; color: "#71717a"; font.pixelSize: 9 }
                                Text { text: "$" + root.usageCost.toFixed(2); color: "#22c55e"; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: "#18181b"; border.color: "#27272a"
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Tokens"; color: "#71717a"; font.pixelSize: 9 }
                                Text { text: root.formatTokens(root.usageTokens); color: "#38bdf8"; font.pixelSize: 13; font.bold: true }
                            }
                        }
                    }

                    // Header: Akumulasi 60 Hari Terakhir
                    Text {
                        text: "TOTAL 60 HARI TERAKHIR (ALL-TIME 60D)"
                        color: "#71717a"
                        font.pixelSize: 10
                        font.bold: true
                        topPadding: 2
                    }

                    // Metrik 60 Hari
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: "#18181b"; border.color: "#27272a"
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Total Requests"; color: "#71717a"; font.pixelSize: 9 }
                                Text { text: "" + root.usage60dRequests; color: "#facc15"; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: "#18181b"; border.color: "#27272a"
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Total Biaya (60d)"; color: "#71717a"; font.pixelSize: 9 }
                                Text { text: "$" + root.usage60dCost.toFixed(2); color: "#4ade80"; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: "#18181b"; border.color: "#27272a"
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Total Tokens (60d)"; color: "#71717a"; font.pixelSize: 9 }
                                Text { text: root.formatTokens(root.usage60dTokens); color: "#a855f7"; font.pixelSize: 13; font.bold: true }
                            }
                        }
                    }

                    // Section: Model AI Aktif & Recent Requests
                    Text {
                        text: "MODEL AI AKTIF HARI INI"
                        color: "#71717a"
                        font.pixelSize: 10
                        font.bold: true
                        topPadding: 2
                    }

                    Text {
                        visible: root.activeModelsList.length === 0
                        text: "Belum ada request hari ini"
                        color: "#52525b"
                        font.pixelSize: 10
                    }

                    Column {
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: root.activeModelsList
                            Rectangle {
                                width: parent.width
                                height: 26
                                radius: 6
                                color: "#18181b"
                                border.color: "#27272a"

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8

                                    Rectangle {
                                        width: 6; height: 6; radius: 3
                                        color: modelData.name.indexOf("claude") !== -1 ? "#f97316" : "#38bdf8"
                                    }

                                    Text {
                                        text: modelData.name
                                        color: "#f4f4f5"
                                        font.pixelSize: 11
                                        font.bold: true
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }

                                    Text {
                                        text: "" + modelData.requests + " reqs"
                                        color: "#a1a1aa"
                                        font.pixelSize: 10
                                    }

                                    Text {
                                        text: "$" + modelData.cost.toFixed(2)
                                        color: "#22c55e"
                                        font.pixelSize: 10
                                        font.bold: true
                                    }
                                }
                            }
                        }
                    }

                    // Status Bar Ringkas
                    Rectangle {
                        Layout.fillWidth: true; height: 30; radius: 6; color: "#18181b"; border.color: "#27272a"
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 8
                            Text { text: "Gateway 9Router"; color: "#71717a"; font.pixelSize: 10 }
                            Item { Layout.fillWidth: true }
                            // Status nyata dari bridge, bukan label "Active" statis.
                            Rectangle { width: 6; height: 6; radius: 3; color: !root.usageLoaded ? "#71717a" : (root.usageAvailable ? "#22c55e" : "#ef4444") }
                            Text {
                                text: !root.usageLoaded ? "Memuat…" : (root.usageAvailable ? "Database terbaca" : "Data tidak tersedia")
                                color: !root.usageLoaded ? "#71717a" : (root.usageAvailable ? "#22c55e" : "#ef4444")
                                font.pixelSize: 10; font.bold: true
                            }
                        }
                    }

                    // Spacer agar konten tetap nempel di atas
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
                }

                // TAB 4: QUICK TOOLS (ASSET ICONS ASLI & RELIABLE LAUNCH)
                ColumnLayout {
                    visible: root.activeTab === "tools"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 10

                    Text {
                        text: "QUICK LAUNCH & SHORTCUTS"
                        color: "#71717a"
                        font.pixelSize: 10
                        font.bold: true
                    }

                    // Grid Shortcut Aplikasi (Avatar Lab Bot Icons Berwarna Sesuai Aplikasi)
                    GridLayout {
                        columns: 2
                        Layout.fillWidth: true
                        rowSpacing: 10
                        columnSpacing: 10

                        // 1. VS Code (Robot Biru Strobi #5b7fe5)
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 52
                            radius: 8
                            color: vscodeHover.containsMouse ? "#27272a" : "#18181b"
                            border.color: vscodeHover.containsMouse ? "#5b7fe5" : "#27272a"
                            border.width: 1

                            Behavior on color { ColorAnimation { duration: 150 } }
                            Behavior on border.color { ColorAnimation { duration: 150 } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 12

                                BibleStrongAvatar {
                                    size: 30
                                    avatarType: "strobi" // Robot Biru
                                    expression: "proud"
                                    targetLookX: vscodeHover.containsMouse ? 0.35 : root.cursorLookX
                                    targetLookY: root.cursorLookY
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text { text: "Visual Studio Code"; color: "#f4f4f5"; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: "Code Editor"; color: "#71717a"; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                            }
                            MouseArea {
                                id: vscodeHover
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.launchTool("editor");
                                }
                            }
                        }

                        // 2. Kitty Terminal (Robot Putih White / Mochi)
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 52
                            radius: 8
                            color: kittyHover.containsMouse ? "#27272a" : "#18181b"
                            border.color: kittyHover.containsMouse ? "#ffffff" : "#27272a"
                            border.width: 1

                            Behavior on color { ColorAnimation { duration: 150 } }
                            Behavior on border.color { ColorAnimation { duration: 150 } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 12

                                BibleStrongAvatar {
                                    size: 30
                                    avatarType: "white" // Robot Putih
                                    expression: "proud"
                                    targetLookX: kittyHover.containsMouse ? 0.35 : root.cursorLookX
                                    targetLookY: root.cursorLookY
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text { text: "Kitty Terminal"; color: "#f4f4f5"; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: "Shell Emulator"; color: "#71717a"; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                            }
                            MouseArea {
                                id: kittyHover
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.launchTool("terminal");
                                }
                            }
                        }

                        // 3. File Manager (Robot Coklat / Amber #b45309)
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 52
                            radius: 8
                            color: filesHover.containsMouse ? "#27272a" : "#18181b"
                            border.color: filesHover.containsMouse ? "#d97706" : "#27272a"
                            border.width: 1

                            Behavior on color { ColorAnimation { duration: 150 } }
                            Behavior on border.color { ColorAnimation { duration: 150 } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 12

                                BibleStrongAvatar {
                                    size: 30
                                    avatarType: "amber" // Robot Coklat / Amber
                                    expression: "proud"
                                    targetLookX: filesHover.containsMouse ? 0.35 : root.cursorLookX
                                    targetLookY: root.cursorLookY
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text { text: "Files Manager"; color: "#f4f4f5"; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: "Explore Directory"; color: "#71717a"; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                            }
                            MouseArea {
                                id: filesHover
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.launchTool("files");
                                }
                            }
                        }

                        // 4. Area Screenshot (Robot Hijau Green #22c55e)
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 52
                            radius: 8
                            color: shotHover.containsMouse ? "#27272a" : "#18181b"
                            border.color: shotHover.containsMouse ? "#22c55e" : "#27272a"
                            border.width: 1

                            Behavior on color { ColorAnimation { duration: 150 } }
                            Behavior on border.color { ColorAnimation { duration: 150 } }

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 12

                                BibleStrongAvatar {
                                    size: 30
                                    avatarType: "green" // Robot Hijau
                                    expression: "proud"
                                    targetLookX: shotHover.containsMouse ? 0.35 : root.cursorLookX
                                    targetLookY: root.cursorLookY
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    Text { text: "Screenshot Area"; color: "#f4f4f5"; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: "Grim + Slurp crop"; color: "#71717a"; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
                                }
                            }
                            MouseArea {
                                id: shotHover
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.launchTool("screenshot");
                                }
                            }
                        }
                    }

                    Text {
                        text: "AUDIO & VOLUME CONTROL"
                        color: "#71717a"
                        font.pixelSize: 10
                        font.bold: true
                        topPadding: 4
                    }

                    // Audio Quick Control Bar (Konsisten & Rapi)
                    Rectangle {
                        Layout.fillWidth: true; height: 46; radius: 8; color: "#18181b"; border.color: "#27272a"
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10

                            Image {
                                source: "file:///usr/share/icons/Papirus/24x24/actions/audio-volume-high.svg"
                                width: 20; height: 20; fillMode: Image.PreserveAspectFit
                            }

                            Column {
                                spacing: 1
                                Text { text: "Volume Speaker"; color: "#f4f4f5"; font.pixelSize: 11; font.bold: true }
                                Text { text: "PipeWire Audio"; color: "#71717a"; font.pixelSize: 9 }
                            }

                            Item { Layout.fillWidth: true }

                            // Tombol -5%
                            Rectangle {
                                width: 44; height: 28; radius: 6; color: volDownHover.containsMouse ? "#27272a" : "#202024"
                                border.color: "#27272a"
                                Text { anchors.centerIn: parent; text: "-5%"; color: "#fff"; font.pixelSize: 10; font.bold: true }
                                MouseArea {
                                    id: volDownHover
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.launchTool("volume_down");
                                    }
                                }
                            }

                            // Tombol Mute / Unmute
                            Rectangle {
                                width: 52; height: 28; radius: 6; color: volMuteHover.containsMouse ? "#ef444433" : "#202024"
                                border.color: "#ef4444"
                                border.width: 1
                                Text { anchors.centerIn: parent; text: "Mute"; color: "#ef4444"; font.pixelSize: 10; font.bold: true }
                                MouseArea {
                                    id: volMuteHover
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.launchTool("volume_mute");
                                    }
                                }
                            }

                            // Tombol +5%
                            Rectangle {
                                width: 44; height: 28; radius: 6; color: volUpHover.containsMouse ? "#27272a" : "#202024"
                                border.color: "#27272a"
                                Text { anchors.centerIn: parent; text: "+5%"; color: "#fff"; font.pixelSize: 10; font.bold: true }
                                MouseArea {
                                    id: volUpHover
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.launchTool("volume_up");
                                    }
                                }
                            }
                        }
                    }

                    // Spacer bawah
                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                    }
                }

                // TAB 5: GIT & WEB PROJECTS PORTAL
                ColumnLayout {
                    visible: root.activeTab === "projects"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 6

                    // Header Bar
                    RowLayout {
                        Layout.fillWidth: true

                        RowLayout {
                            spacing: 6
                            Text {
                                text: "PROJECTS & DEPLOYMENT LINKS"
                                color: "#f4f4f5"
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }

                        Item { Layout.fillWidth: true }

                        Rectangle {
                            width: 60; height: 22; radius: 5
                            color: refreshHover.containsMouse ? "#27272a" : "#18181b"
                            border.color: "#3f3f46"; border.width: 1
                            Row {
                                anchors.centerIn: parent
                                spacing: 4
                                Text { text: "Refresh"; color: "#a1a1aa"; font.pixelSize: 9; font.bold: true }
                            }
                            MouseArea {
                                id: refreshHover
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: fetchProjectsProcess.running = true
                            }
                        }
                    }

                    // List Container
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 8
                        color: "#121215"
                        border.color: "#27272a"
                        border.width: 1

                        ListView {
                            id: projectsListView
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 6
                            clip: true
                            model: root.gitProjectsList

                            Text {
                                anchors.centerIn: parent
                                visible: root.gitProjectsList.length === 0
                                text: "Memuat project… (atau tidak ada di ~/Projects/project-web)"
                                color: "#52525b"
                                font.pixelSize: 11
                            }

                            delegate: Rectangle {
                                width: projectsListView.width
                                implicitHeight: projCol.implicitHeight + 14
                                radius: 8
                                color: modelData.is_active ? "#18181b" : "#141416"
                                border.color: modelData.is_active ? "#0284c7" : "#27272a"
                                border.width: modelData.is_active ? 1 : 1

                                ColumnLayout {
                                    id: projCol
                                    anchors.fill: parent
                                    anchors.margins: 7
                                    spacing: 5

                                    // Baris 1: Status & Nama Project
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6

                                        Text {
                                            text: modelData.name || modelData.id
                                            color: "#ffffff"
                                            font.pixelSize: 11
                                            font.bold: true
                                        }

                                        // Active Badge
                                        Rectangle {
                                            visible: Boolean(modelData.is_active)
                                            implicitWidth: actLbl.implicitWidth + 8
                                            height: 14
                                            radius: 3
                                            color: "#0369a1"
                                            Text {
                                                id: actLbl
                                                anchors.centerIn: parent
                                                text: "ACTIVE"
                                                color: "#e0f2fe"
                                                font.pixelSize: 8
                                                font.bold: true
                                            }
                                        }

                                        // Branch Pill
                                        Rectangle {
                                            implicitWidth: bLbl.implicitWidth + 8
                                            height: 14
                                            radius: 3
                                            color: "#2e1065"
                                            border.color: "#7e22ce"
                                            border.width: 1
                                            Text {
                                                id: bLbl
                                                anchors.centerIn: parent
                                                text: modelData.branch || "master"
                                                color: "#d8b4fe"
                                                font.pixelSize: 8
                                                font.bold: true
                                                font.family: "JetBrains Mono, monospace"
                                            }
                                        }

                                        Item { Layout.fillWidth: true }

                                        // Commits Today Badge
                                        Rectangle {
                                            implicitWidth: cTodayLbl.implicitWidth + 8
                                            height: 14
                                            radius: 3
                                            color: modelData.commits_today > 0 ? "#052e16" : "#27272a"
                                            border.color: modelData.commits_today > 0 ? "#22c55e" : "#3f3f46"
                                            border.width: 1
                                            Text {
                                                id: cTodayLbl
                                                anchors.centerIn: parent
                                                text: modelData.commits_today > 0 ? (modelData.commits_today + " commit hari ini") : "0 commit"
                                                color: modelData.commits_today > 0 ? "#86efac" : "#71717a"
                                                font.pixelSize: 8
                                                font.bold: true
                                            }
                                        }

                                        // Clean / Dirty Status
                                        Text {
                                            text: modelData.modified > 0 ? ("+" + modelData.modified + " modif") : "✓ clean"
                                            color: modelData.modified > 0 ? "#fbbf24" : "#10b981"
                                            font.pixelSize: 8
                                            font.bold: true
                                            font.family: "JetBrains Mono, monospace"
                                        }
                                    }

                                    // Baris 2: Last Commit Message
                                    Text {
                                        Layout.fillWidth: true
                                        text: modelData.last_commit || "-"
                                        color: "#71717a"
                                        font.pixelSize: 9
                                        font.family: "JetBrains Mono, monospace"
                                        elide: Text.ElideRight
                                    }

                                    // Baris 3: Action Buttons (Staging / Production / VS Code)
                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 6

                                        // Tombol Staging
                                        Rectangle {
                                            visible: Boolean(modelData.staging && modelData.staging.length > 0)
                                            implicitWidth: stgRow.implicitWidth + 12
                                            height: 20
                                            radius: 4
                                            color: stgHover.containsMouse ? "#0369a1" : "#082f49"
                                            border.color: "#0284c7"
                                            border.width: 1

                                            RowLayout {
                                                id: stgRow
                                                anchors.centerIn: parent
                                                spacing: 4
                                                Text {
                                                    text: "Staging"
                                                    color: "#7dd3fc"
                                                    font.pixelSize: 9
                                                    font.bold: true
                                                }
                                            }
                                            MouseArea {
                                                id: stgHover
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                preventStealing: true
                                                onClicked: root.openWebUrl(modelData.staging)
                                            }
                                        }

                                        // Tombol Production
                                        Rectangle {
                                            visible: Boolean(modelData.production && modelData.production.length > 0)
                                            implicitWidth: prodRow.implicitWidth + 12
                                            height: 20
                                            radius: 4
                                            color: prodHover.containsMouse ? "#047857" : "#022c22"
                                            border.color: "#059669"
                                            border.width: 1

                                            RowLayout {
                                                id: prodRow
                                                anchors.centerIn: parent
                                                spacing: 4
                                                Text {
                                                    text: "Production"
                                                    color: "#6ee7b7"
                                                    font.pixelSize: 9
                                                    font.bold: true
                                                }
                                            }
                                            MouseArea {
                                                id: prodHover
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                preventStealing: true
                                                onClicked: root.openWebUrl(modelData.production)
                                            }
                                        }

                                        Item { Layout.fillWidth: true }

                                        // Tombol Open Code
                                        Rectangle {
                                            implicitWidth: codeRow.implicitWidth + 10
                                            height: 20
                                            radius: 4
                                            color: codeHover.containsMouse ? "#27272a" : "#18181b"
                                            border.color: "#3f3f46"
                                            border.width: 1

                                            RowLayout {
                                                id: codeRow
                                                anchors.centerIn: parent
                                                spacing: 4
                                                Text {
                                                    text: "VS Code"
                                                    color: "#d4d4d8"
                                                    font.pixelSize: 9
                                                }
                                            }
                                            MouseArea {
                                                id: codeHover
                                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                preventStealing: true
                                                onClicked: root.openProjectInCode(modelData.path)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // TAB 6: DEV SERVER (php artisan serve + npm run dev per project)
                ColumnLayout {
                    visible: root.activeTab === "dev"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 6

                    Text {
                        text: "DEV SERVERS"
                        color: "#71717a"
                        font.pixelSize: 10
                        font.bold: true
                    }

                    // Card Container List dengan ListView (Scrollable & Anti-Overflow)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 8
                        color: "#121215"
                        border.color: "#27272a"
                        border.width: 1

                        ListView {
                            id: devListView
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 6
                            clip: true
                            model: root.devServers

                            Text {
                                anchors.centerIn: parent
                                visible: root.devServers.length === 0
                                text: root.bridgeReady ? "Tidak ada project dev server" : "Bridge belum siap…"
                                color: "#52525b"
                                font.pixelSize: 11
                            }

                            delegate: Rectangle {
                                id: devRow
                                width: devListView.width
                                implicitHeight: 46
                                radius: 6
                                color: devRow.anyRunning ? "#18181b" : "#141416"
                                border.color: devRow.anyRunning ? "#22c55e44" : "#27272a"
                                border.width: 1

                                property var php: root.devService(modelData.id, "php")
                                property var npm: root.devService(modelData.id, "npm")
                                property bool anyRunning: php.running || npm.running
                                property int availableCount: (php.available ? 1 : 0) + (npm.available ? 1 : 0)
                                property int runningCount: (php.running ? 1 : 0) + (npm.running ? 1 : 0)

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.margins: 6
                                    spacing: 6

                                    // Nama project + detail service
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2

                                        RowLayout {
                                            spacing: 5
                                            Rectangle {
                                                width: 6; height: 6; radius: 3
                                                color: devRow.anyRunning ? "#22c55e" : "#3f3f46"
                                            }
                                            Text {
                                                text: modelData.name
                                                color: "#ffffff"
                                                font.pixelSize: 11
                                                font.bold: true
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                        }

                                        Text {
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                            color: "#71717a"
                                            font.pixelSize: 9
                                            text: {
                                                let parts = [];
                                                if (devRow.php.available)
                                                    parts.push("artisan" + (devRow.php.port ? " :" + devRow.php.port : "") + (devRow.php.running ? " ✓" : ""));
                                                if (devRow.npm.available)
                                                    parts.push("npm dev" + (devRow.npm.running ? " ✓" : ""));
                                                return parts.join(" · ") || "tidak ada service";
                                            }
                                        }
                                    }

                                    // Toggle: artisan serve
                                    Rectangle {
                                        visible: devRow.php.available
                                        Layout.preferredWidth: 46
                                        height: 22
                                        radius: 4
                                        color: devRow.php.running ? "#052e16" : "#18181b"
                                        border.color: devRow.php.running ? "#22c55e" : "#3f3f46"
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "serve"
                                            color: devRow.php.running ? "#86efac" : "#a1a1aa"
                                            font.pixelSize: 9
                                            font.bold: true
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.devToggle(modelData.id, "php")
                                        }
                                    }

                                    // Toggle: npm run dev
                                    Rectangle {
                                        visible: devRow.npm.available
                                        Layout.preferredWidth: 52
                                        height: 22
                                        radius: 4
                                        color: devRow.npm.running ? "#052e16" : "#18181b"
                                        border.color: devRow.npm.running ? "#22c55e" : "#3f3f46"
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "npm dev"
                                            color: devRow.npm.running ? "#86efac" : "#a1a1aa"
                                            font.pixelSize: 9
                                            font.bold: true
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.devToggle(modelData.id, "npm")
                                        }
                                    }

                                    // Start semua service project ini
                                    Rectangle {
                                        Layout.preferredWidth: 44
                                        height: 22
                                        radius: 4
                                        color: {
                                            if (devRow.availableCount > devRow.runningCount)
                                                return devStartHover.containsMouse ? "#14532d" : "#052e16";
                                            return "#18181b";
                                        }
                                        border.color: devRow.availableCount > devRow.runningCount ? "#22c55e" : "#27272a"
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "Start"
                                            color: devRow.availableCount > devRow.runningCount ? "#86efac" : "#52525b"
                                            font.pixelSize: 9
                                            font.bold: true
                                        }
                                        MouseArea {
                                            id: devStartHover
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            enabled: devRow.availableCount > devRow.runningCount
                                            onClicked: {
                                                root.devStartProject(modelData.id);
                                            }
                                        }
                                    }

                                    // Stop semua service project ini
                                    Rectangle {
                                        Layout.preferredWidth: 42
                                        height: 22
                                        radius: 4
                                        color: {
                                            if (devRow.runningCount > 0)
                                                return devStopHover.containsMouse ? "#450a0a" : "#1c1917";
                                            return "#18181b";
                                        }
                                        border.color: devRow.runningCount > 0 ? "#ef4444" : "#27272a"
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "Stop"
                                            color: devRow.runningCount > 0 ? "#fca5a5" : "#52525b"
                                            font.pixelSize: 9
                                            font.bold: true
                                        }
                                        MouseArea {
                                            id: devStopHover
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            enabled: devRow.runningCount > 0
                                            onClicked: {
                                                root.devStopProject(modelData.id);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // TAB 7: INTERVIEW ASSIST (transkrip lawan bicara + saran jawaban)
                ColumnLayout {
                    visible: root.activeTab === "interview"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 6

                    // Kontrol: sumber audio, auto, jawab manual, start/stop
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            width: 8; height: 8; radius: 4
                            color: root.interviewState === "listening" ? (root.interviewSpeaking ? "#ef4444" : "#22c55e")
                                 : root.interviewState === "loading" ? "#f59e0b"
                                 : root.interviewState === "error" ? "#ef4444" : "#3f3f46"
                        }
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: root.interviewState === "error" ? "#fca5a5" : "#a1a1aa"
                            font.pixelSize: 10
                            text: root.interviewState === "listening"
                                  ? (root.interviewThinking ? "Menyusun jawaban…" : root.interviewSpeaking ? "Lawan bicara berbicara…" : "Mendengarkan")
                                  : (root.interviewMessage || "Siap. Pakai headset agar suaramu tidak ikut terekam.")
                        }

                        // Meter level audio: bukti suara benar-benar tertangkap
                        Rectangle {
                            visible: root.interviewRunning
                            width: 40; height: 4; radius: 2
                            color: "#27272a"
                            Rectangle {
                                width: parent.width * Math.min(1, root.interviewLevel)
                                height: parent.height; radius: 2
                                color: root.interviewSpeaking ? "#ef4444" : "#22c55e"
                                Behavior on width { NumberAnimation { duration: 120 } }
                            }
                        }

                        Repeater {
                            model: [{ key: "system", label: "Sistem" }, { key: "mic", label: "Mic" }]
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool chosen: root.interviewSource === modelData.key
                                width: 44; height: 22; radius: 4
                                opacity: root.interviewRunning && !chosen ? 0.4 : 1
                                color: chosen ? "#1e1b4b" : "#18181b"
                                border.color: chosen ? "#818cf8" : "#3f3f46"
                                border.width: 1
                                Text { anchors.centerIn: parent; text: modelData.label; color: parent.chosen ? "#c7d2fe" : "#a1a1aa"; font.pixelSize: 9; font.bold: true }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    enabled: !root.interviewRunning
                                    onClicked: root.interviewSource = modelData.key
                                }
                            }
                        }

                        Rectangle {
                            width: 40; height: 22; radius: 4
                            color: root.interviewAuto ? "#052e16" : "#18181b"
                            border.color: root.interviewAuto ? "#22c55e" : "#3f3f46"
                            border.width: 1
                            Text { anchors.centerIn: parent; text: "Auto"; color: root.interviewAuto ? "#86efac" : "#a1a1aa"; font.pixelSize: 9; font.bold: true }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    root.interviewAuto = !root.interviewAuto;
                                    if (root.interviewRunning)
                                        sendBridgeCommand({ action: "interview_auto", enabled: root.interviewAuto });
                                }
                            }
                        }

                        Rectangle {
                            readonly property bool usable: root.interviewTranscript.length > 0
                            width: 44; height: 22; radius: 4
                            color: usable ? (jawabHover.containsMouse ? "#1e3a8a" : "#172554") : "#18181b"
                            border.color: usable ? "#3b82f6" : "#27272a"
                            border.width: 1
                            Text { anchors.centerIn: parent; text: "Jawab"; color: parent.usable ? "#93c5fd" : "#52525b"; font.pixelSize: 9; font.bold: true }
                            MouseArea {
                                id: jawabHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                enabled: parent.usable
                                onClicked: { root.interviewThinking = true; sendBridgeCommand({ action: "interview_answer" }); }
                            }
                        }

                        Rectangle {
                            width: 50; height: 22; radius: 4
                            color: root.interviewRunning ? (ivStartHover.containsMouse ? "#450a0a" : "#1c1917")
                                                         : (ivStartHover.containsMouse ? "#14532d" : "#052e16")
                            border.color: root.interviewRunning ? "#ef4444" : "#22c55e"
                            border.width: 1
                            Text {
                                anchors.centerIn: parent
                                text: root.interviewRunning ? "Stop" : "Mulai"
                                color: root.interviewRunning ? "#fca5a5" : "#86efac"
                                font.pixelSize: 9
                                font.bold: true
                            }
                            MouseArea {
                                id: ivStartHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.interviewToggle()
                            }
                        }
                    }

                    // Transkrip lawan bicara (scroll otomatis ke bawah)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.preferredHeight: 1
                        Layout.maximumHeight: 84
                        radius: 8
                        color: "#0e0e10"
                        border.color: "#27272a"
                        border.width: 1

                        ListView {
                            id: ivTranscriptView
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 3
                            clip: true
                            model: root.interviewTranscript
                            onCountChanged: positionViewAtEnd()

                            Text {
                                anchors.centerIn: parent
                                visible: root.interviewTranscript.length === 0
                                text: root.interviewRunning ? "Transkrip akan muncul di sini…" : "TRANSKRIP"
                                color: "#52525b"
                                font.pixelSize: 10
                            }

                            delegate: Text {
                                required property var modelData
                                width: ivTranscriptView.width
                                wrapMode: Text.Wrap
                                color: "#a1a1aa"
                                font.pixelSize: 10
                                textFormat: Text.PlainText
                                text: modelData.time.slice(0, 5) + "  " + modelData.text
                            }
                        }
                    }

                    // Kartu saran jawaban (terbaru; ‹ › untuk riwayat)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.preferredHeight: 4
                        radius: 8
                        color: "#121215"
                        border.color: root.interviewThinking ? "#3b82f6" : "#27272a"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                Text {
                                    Layout.fillWidth: true
                                    elide: Text.ElideRight
                                    color: "#71717a"
                                    font.pixelSize: 9
                                    font.italic: true
                                    text: root.interviewShownAnswer ? "❝ " + root.interviewShownAnswer.question : "SARAN JAWABAN"
                                }
                                Text {
                                    visible: root.interviewAnswers.length > 1
                                    text: "‹"
                                    color: root.interviewAnswerIndex < root.interviewAnswers.length - 1 ? "#e4e4e7" : "#3f3f46"
                                    font.pixelSize: 13; font.bold: true
                                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.interviewAnswerIndex < root.interviewAnswers.length - 1) root.interviewAnswerIndex += 1 }
                                }
                                Text {
                                    visible: root.interviewAnswers.length > 1
                                    text: (root.interviewAnswerIndex + 1) + "/" + root.interviewAnswers.length
                                    color: "#71717a"; font.pixelSize: 9
                                }
                                Text {
                                    visible: root.interviewAnswers.length > 1
                                    text: "›"
                                    color: root.interviewAnswerIndex > 0 ? "#e4e4e7" : "#3f3f46"
                                    font.pixelSize: 13; font.bold: true
                                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.interviewAnswerIndex > 0) root.interviewAnswerIndex -= 1 }
                                }
                            }

                            Flickable {
                                id: ivAnswerFlick
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                contentHeight: ivAnswerText.paintedHeight
                                boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                                TextEdit {
                                    id: ivAnswerText
                                    width: ivAnswerFlick.width - 8
                                    readOnly: true
                                    selectByMouse: true
                                    wrapMode: TextEdit.Wrap
                                    color: root.interviewShownAnswer && root.interviewShownAnswer.error ? "#fca5a5" : "#f4f4f5"
                                    selectionColor: "#3b82f6"
                                    font.pixelSize: 14
                                    text: {
                                        let a = root.interviewShownAnswer;
                                        if (a) return a.error || a.text || "…";
                                        if (root.interviewThinking) return "Menyusun jawaban…";
                                        if (root.interviewRunning) return "Menunggu pertanyaan dari lawan bicara…";
                                        return "Tekan Mulai saat interview dimulai.\n"
                                             + "• Sistem: suara dari Zoom/Meet/Discord (online)\n"
                                             + "• Mic: interview tatap muka\n"
                                             + "Isi profil/CV di " + (root.interviewProfile || "~/.config/hermes-coucou/interview_profile.md")
                                             + " supaya jawaban sesuai pengalamanmu.";
                                    }
                                }
                            }
                        }
                    }
                }

            } // Tutup Panel Kanan (ColumnLayout)
        } // Tutup RowLayout (Panel Kiri + Panel Kanan)
    }

        // Bar hitung mundur sisa waktu tampil pill notifikasi
        Rectangle {
            visible: root.isNotifying && !root.islandExpanded && root.notifyType !== "approval" && root.notifyType !== "request"
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 3
            anchors.left: parent.left
            anchors.leftMargin: 22
            width: (parent.width - 44) * root.notifyProgress
            height: 2
            radius: 1
            color: root.statusColor
            opacity: 0.7
        }
}

        // Sapaan pembuka saat QBot pertama kali aktif (Welcome Wave)
        Timer {
            id: welcomeWaveTimer
            interval: 600
            repeat: false
            running: true
            onTriggered: {
                root.avatarExpression = "wave";
                root.currentStatus = "Halo ganteng! 👋";
                root.activeDetail = "QBot siap menerima task hari ini.";
                root.statusColor = "#22c55e";
                waveResetTimer.restart();
            }
        }

    // Timer reset ekspresi Task Start (tampilkan pill 2.8s lalu kembali ke standby/working)
    Timer {
        id: taskStartNotifyTimer
        interval: 2800
        repeat: false
        onTriggered: {
            if (root.notifyType === "request") return;
            if (root.notifyType === "task_start") {
                root.isNotifying = false;
                root.notifyType = "";
                root.restoreBaseline();
            } else if (root.currentStatus === "Task diterima") {
                root.restoreBaseline();
            }
        }
    }

    // Selesai melambai: ekspresi & teks sapaan kembali ke status sebenarnya.
    Timer {
        id: waveResetTimer
        interval: 2600
        repeat: false
        onTriggered: {
            if (root.avatarExpression === "wave") root.avatarExpression = "proud";
            if (root.currentStatus === "Halo ganteng! 👋" && !root.isNotifying) root.restoreBaseline();
        }
    }

    // Proses sekali-pakai untuk aksi berbasis klien (clipboard).
    Process { id: copyNoteProcess; running: false }

    // Real-Time SQLite Watcher untuk Hermes Desktop
    Process {
        id: hermesWatcherProcess
        command: ["python3", "-u", root.appDir + "hermes_watcher.py"]
        running: true
        stderr: SplitParser {
            onRead: data => console.log("WATCHER_ERR: " + data)
        }
        onStarted: console.log("WATCHER_STARTED pid=" + processId)
        onExited: (exitCode, exitStatus) => console.log("WATCHER_EXIT code=" + exitCode)
    }
}
