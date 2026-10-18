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
    // Dibuka lewat hotkey (IPC): ambil keyboard penuh supaya navigasi tombol
    // langsung jalan tanpa klik; dilepas lagi saat island menutup.
    WlrLayershell.keyboardFocus: kbdMode ? WlrKeyboardFocus.Exclusive
        : ((islandExpanded && !isNotifying) || notifyType === "request") ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.None

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
    property bool kbdMode: false             // island dibuka lewat hotkey, fokus keyboard eksklusif
    // Fokus eksklusif dilepas begitu tidak ada lagi panel atau kartu yang terbuka;
    // tanpa ini QBot terus menahan keyboard setelah kartu izin dijawab.
    onIslandExpandedChanged: if (!islandExpanded && notifyType !== "request" && notifyType !== "approval") kbdMode = false
    onNotifyTypeChanged: if (notifyType !== "request" && notifyType !== "approval" && !islandExpanded) kbdMode = false
    property bool isNotifying: false
    property string notifyType: "" // "done" | "approval"
    property string activeTab: "notes" // Default tab Catatan; dipulihkan dari settings saat dimuat
    onActiveTabChanged: if (settingsReady) settings.tab = activeTab

    // Preferensi pengguna, tersimpan di ~/.config/hermes-coucou/settings.json
    // (bertahan setelah restart, tidak seperti PersistentProperties).
    property bool settingsReady: false
    // Tab dikelompokkan supaya navigasi muat di island; Interview berdiri sendiri.
    readonly property var tabGroups: [
        {key: "agent", label: "Agent", tabs: [{key: "agent", label: "Agent"}]},
        {key: "work", label: "Kerja", tabs: [{key: "projects", label: "Projects"}, {key: "dev", label: "Dev Server"}]},
        {key: "system", label: "Sistem", tabs: [{key: "status", label: "Status"}, {key: "usage", label: "9Router"}, {key: "tools", label: "Tools"}]},
        {key: "notes", label: "Catatan", tabs: [{key: "notes", label: "Catatan"}]}
    ]
    readonly property var tabKeys: ["agent", "projects", "dev", "status", "usage", "tools", "notes", "interview"]
    property var lastTabInGroup: ({})        // sub-tab terakhir per grup
    readonly property var subTabs: {
        let g = groupOf(activeTab);
        for (let i = 0; i < tabGroups.length; i++) {
            if (tabGroups[i].key === g) return tabGroups[i].tabs;
        }
        return [];
    }

    function groupOf(tab) {
        for (let i = 0; i < tabGroups.length; i++) {
            for (let j = 0; j < tabGroups[i].tabs.length; j++) {
                if (tabGroups[i].tabs[j].key === tab) return tabGroups[i].key;
            }
        }
        return "";
    }

    function selectGroup(index) {
        let g = tabGroups[index];
        selectTab(lastTabInGroup[g.key] || g.tabs[0].key);
    }

    FileView {
        id: settingsFile
        path: (Quickshell.env("XDG_CONFIG_HOME") || Quickshell.env("HOME") + "/.config") + "/hermes-coucou/settings.json"
        printErrors: false // file belum ada saat pertama jalan: ditangani onLoadFailed
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
            property string theme: "zinc"
            property bool sound: true
            property bool autoSafe: false     // auto-izinkan perintah baca-saja (opt-in)
        }
    }

    // Perintah baca-saja yang boleh diizinkan otomatis bila autoSafe aktif.
    // Sengaja ketat: tanpa operator shell, tanpa kutip (bisa menyamarkan opsi),
    // dan opsi yang menulis file / menjalankan program ditolak.
    function isSafeCommand(cmd) {
        cmd = (cmd || "").trim();
        if (!cmd || /[;&|`$<>(){}\\'"\n\r]/.test(cmd)) return false;
        let t = cmd.split(/\s+/);
        if (t[0] === "git")
            return t.length >= 2 && ["status", "diff", "log", "show"].indexOf(t[1]) >= 0
                && !t.some(a => /^--(output|ext-diff)/.test(a));
        if (t[0] === "find")
            return !t.some(a => /^-(exec|execdir|ok|okdir|delete|fprint|fprint0|fprintf|fls)$/.test(a));
        if (t[0] === "rg")
            return !t.some(a => /^--pre/.test(a));
        return ["ls", "pwd", "cat", "head", "tail", "wc", "grep", "du", "df", "which", "stat"].indexOf(t[0]) >= 0;
    }

    property var autoAllowPending: ({})      // id perintah bridge -> request yang diizinkan otomatis

    function autoAllow(req) {
        let id = sendBridgeCommand({action: "agent_answer", request_id: req.request_id, answer: {decision: "allow"}});
        autoAllowPending[id] = req;
        logActivity(req.agent, req.project, "auto", req.command);
        showNotification("info", {source: req.agent, title: "Diizinkan otomatis", detail: req.command,
                                  color: "#22c55e", expression: "happy", project: req.project || ""});
    }

    // Riwayat aktivitas agent + statistik harian, di ~/.local/share/hermes-coucou/activity.json.
    // history: [{t, agent, project, kind, text, dur}] terbaru di depan (maks 60);
    // kind: start | done | error | allow | deny | always | auto | answer.
    // daily: {"YYYY-MM-DD": {tasks, done, errors, perms}} 14 hari terakhir.
    FileView {
        id: activityFile
        path: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/hermes-coucou/activity.json"
        printErrors: false // file belum ada saat pertama jalan: ditangani onLoadFailed
        onAdapterUpdated: activityWriteTimer.restart()
        onLoadFailed: error => {
            if (error == FileViewError.FileNotFound)
                Quickshell.execDetached(["mkdir", "-p", path.substring(0, path.lastIndexOf("/"))]);
        }
        adapter: JsonAdapter {
            id: activity
            property var history: []
            property var daily: ({})
        }
    }

    Timer {
        id: activityWriteTimer
        interval: 1500
        onTriggered: activityFile.writeAdapter()
    }

    function dayKey(d) {
        return d.getFullYear() + "-" + String(d.getMonth() + 1).padStart(2, "0") + "-" + String(d.getDate()).padStart(2, "0");
    }

    function logActivity(agent, project, kind, text, dur) {
        let entry = {t: Date.now(), agent: agent || "", project: project || "", kind: kind, text: text || "", dur: dur || ""};
        activity.history = [entry].concat(activity.history || []).slice(0, 60);

        let field = {start: "tasks", done: "done", error: "errors", allow: "perms", deny: "perms", always: "perms", auto: "perms"}[kind];
        if (!field) return;
        let daily = Object.assign({}, activity.daily || {});
        let key = dayKey(new Date());
        let today = Object.assign({tasks: 0, done: 0, errors: 0, perms: 0}, daily[key] || {});
        today[field] += 1;
        daily[key] = today;
        let keys = Object.keys(daily).sort();
        for (let i = 0; i < keys.length - 14; i++) delete daily[keys[i]];
        activity.daily = daily;
    }

    function activityLabel(kind) {
        return {start: "Task diterima", done: "Selesai", error: "Gagal", allow: "Diizinkan", auto: "Auto-izin",
                deny: "Ditolak", always: "Selalu diizinkan", answer: "Dijawab"}[kind] || kind;
    }

    function activityColor(kind) {
        if (kind === "done" || kind === "allow" || kind === "always" || kind === "auto") return "#22c55e";
        if (kind === "error" || kind === "deny") return "#ef4444";
        if (kind === "start") return "#a78bfa";
        return theme.accent;
    }

    function clockText(ms) {
        let d = new Date(ms);
        let time = String(d.getHours()).padStart(2, "0") + ":" + String(d.getMinutes()).padStart(2, "0");
        return dayKey(d) === dayKey(new Date()) ? time : d.getDate() + "/" + (d.getMonth() + 1) + " " + time;
    }

    // Efek suara (assets/sounds, dibuat oleh scripts/gen-sounds.py) lewat PipeWire.
    function playSound(name) {
        if (!settings.sound) return;
        Quickshell.execDetached(["pw-play", appDir + "assets/sounds/" + name + ".wav"]);
    }

    // Palet netral + aksen. Warna status (hijau selesai, merah gagal, oranye
    // butuh izin) sengaja sama di semua tema supaya maknanya tetap terbaca.
    readonly property var themePresets: ({
        zinc:       {label: "Zinc", base: "#0a0a0c", mantle: "#121215", surface0: "#18181b", surface1: "#27272a", surface2: "#3f3f46",
                     overlay: "#52525b", subtext0: "#71717a", subtext1: "#a1a1aa", textDim: "#d4d4d8", text: "#f4f4f5", accent: "#38bdf8"},
        catppuccin: {label: "Catppuccin", base: "#11111b", mantle: "#181825", surface0: "#1e1e2e", surface1: "#313244", surface2: "#45475a",
                     overlay: "#585b70", subtext0: "#7f849c", subtext1: "#a6adc8", textDim: "#bac2de", text: "#cdd6f4", accent: "#cba6f7"},
        tokyonight: {label: "Tokyo Night", base: "#16161e", mantle: "#1a1b26", surface0: "#1f2335", surface1: "#292e42", surface2: "#3b4261",
                     overlay: "#545c7e", subtext0: "#737aa2", subtext1: "#9aa5ce", textDim: "#a9b1d6", text: "#c0caf5", accent: "#7aa2f7"},
        gruvbox:    {label: "Gruvbox", base: "#1d2021", mantle: "#282828", surface0: "#32302f", surface1: "#3c3836", surface2: "#504945",
                     overlay: "#665c54", subtext0: "#928374", subtext1: "#a89984", textDim: "#d5c4a1", text: "#ebdbb2", accent: "#fabd2f"},
        nord:       {label: "Nord", base: "#242933", mantle: "#2e3440", surface0: "#3b4252", surface1: "#434c5e", surface2: "#4c566a",
                     overlay: "#616e88", subtext0: "#7b88a1", subtext1: "#a3b1c9", textDim: "#d8dee9", text: "#eceff4", accent: "#88c0d0"}
    })
    readonly property var themeNames: ["zinc", "catppuccin", "tokyonight", "gruvbox", "nord"]
    readonly property var theme: themePresets[settings.theme] || themePresets.zinc

    function cycleTheme() {
        let i = themeNames.indexOf(settings.theme);
        settings.theme = themeNames[(i + 1) % themeNames.length];
    }

    Timer {
        id: settingsWriteTimer
        interval: 400
        onTriggered: settingsFile.writeAdapter()
    }

    // Kendali dari luar, mis. keybind Niri:
    //   Mod+Space { spawn "qs" "-p" "<repo>/linux-app/HermesMochi.qml" "ipc" "call" "qbot" "toggle"; }
    IpcHandler {
        target: "qbot"

        function toggle(): void {
            if (root.islandExpanded || root.kbdMode) close();
            else open();
        }
        // Kartu izin/pertanyaan yang sedang tampil ikut mendapat fokus keyboard.
        function open(): void {
            root.kbdMode = true;
            if (root.notifyType !== "request" && root.notifyType !== "approval") {
                root.isNotifying = false;
                root.notifyType = "";
                root.islandExpanded = true;
            }
        }
        function close(): void {
            root.kbdMode = false;
            root.islandExpanded = false;
        }
        // Ringkasan state sebagai JSON, untuk skrip / status bar.
        function status(): string {
            return JSON.stringify({expanded: root.islandExpanded, keyboard: root.kbdMode, tab: root.activeTab,
                                   notify: root.notifyType, pending: root.agentRequests.length,
                                   hermes: root.hermesConnected, sessions: root.agentSessions.length});
        }
        function tab(name: string): string {
            if (root.tabKeys.indexOf(name) < 0) return "tab tidak dikenal: " + name + " (" + root.tabKeys.join(", ") + ")";
            open();
            root.selectTab(name);
            return "ok";
        }
        function sound(on: bool): void {
            settings.sound = on;
        }
        function autosafe(on: bool): void {
            settings.autoSafe = on;
        }
        function theme(name: string): string {
            if (!root.themePresets[name]) return "tema tidak dikenal: " + name + " (" + root.themeNames.join(", ") + ")";
            settings.theme = name;
            return "ok";
        }
    }

    // Pindah tab + muat data tab itu (dipakai klik, keyboard, dan IPC).
    function selectTab(key) {
        activeTab = key;
        let g = groupOf(key);
        if (g) lastTabInGroup[g] = key;
        if (key === "notes") fetchNotesProcess.running = true;
        else if (key === "status") fetchSysInfoProcess.running = true;
        else if (key === "usage") fetchUsageProcess.running = true;
        else if (key === "projects") fetchProjectsProcess.running = true;
        else if (key === "dev") sendBridgeCommand({ action: "dev_status" });
        else if (key === "interview") sendBridgeCommand({ action: "interview_status" });
    }

    function cycleTab(step) {
        let n = tabKeys.length;
        selectTab(tabKeys[(tabKeys.indexOf(activeTab) + step + n) % n]);
    }

    function isEnter(key) {
        return key === Qt.Key_Return || key === Qt.Key_Enter;
    }

    // Keyboard: kartu izin (Y izinkan, N tolak, A selalu, T terminal; sengaja bukan
    // Enter, supaya Enter yang diketik untuk jendela lain tidak memberi izin),
    // pertanyaan (1-9 pilih, Enter lanjut, Backspace kembali), approval Hermes
    // (Y/N), dan panel (1-4 grup, 5 Interview, ←→ / Tab pindah tab, Esc tutup).
    function handleKey(event) {
        let k = event.key;
        if (notifyType === "approval") {
            if (k === Qt.Key_Y) submitDecision("allow");
            else if (k === Qt.Key_N) submitDecision("deny");
            else if (k === Qt.Key_Escape) kbdMode = false;
            else return;
        } else if (notifyType === "request" && currentRequest) {
            if (reqSending) { event.accepted = true; return; }
            if (k === Qt.Key_Escape) kbdMode = false;
            else if (k === Qt.Key_T) submitRequestAnswer({decision: "terminal"});
            else if (currentRequest.kind === "permission") {
                if (k === Qt.Key_Y) submitRequestAnswer({decision: "allow"});
                else if (k === Qt.Key_N) submitRequestAnswer({decision: "deny"});
                else if (k === Qt.Key_A && currentRequest.can_always) submitRequestAnswer({decision: "always"});
                else return;
            } else {
                let q = currentRequest.questions[reqIndex];
                if (k >= Qt.Key_1 && k <= Qt.Key_9 && q && k - Qt.Key_1 < q.options.length) reqToggleOption(q.options[k - Qt.Key_1].label);
                else if (isEnter(k)) reqAdvance();
                else if (k === Qt.Key_Backspace && reqIndex > 0) reqIndex -= 1;
                else return;
            }
        } else if (islandExpanded && !isNotifying) {
            if (k === Qt.Key_Escape) { kbdMode = false; islandExpanded = false; }
            else if (k >= Qt.Key_1 && k < Qt.Key_1 + tabGroups.length) selectGroup(k - Qt.Key_1);
            else if (k === Qt.Key_1 + tabGroups.length) selectTab("interview");
            else if (k === Qt.Key_Right || k === Qt.Key_Tab) cycleTab(1);
            else if (k === Qt.Key_Left || k === Qt.Key_Backtab) cycleTab(-1);
            else return;
        } else {
            return;
        }
        event.accepted = true;
    }

    onKbdModeChanged: if (kbdMode) islandCapsule.forceActiveFocus()

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
    property string approvalDetail: ""        // perintah approval Hermes, untuk riwayat
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
    property var reqAnswerLog: null           // entri riwayat, dicatat setelah jawaban terkirim

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
        if (agent === "opencode") return root.theme.textDim;
        return "#c4b5fd";
    }

    function stateColor(state) {
        if (state === "waiting") return "#f97316";
        if (state === "working") return "#38bdf8";
        if (state === "done") return "#22c55e";
        if (state === "error") return "#ef4444";
        return root.theme.subtext0;
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
        if (type === "done") playSound(opts.error ? "error" : "done");
        else if (type === "approval" || type === "agent_wait") playSound("request");
        else if (type === "task_start" || type === "interview") playSound("pop");
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
            playSound("request");
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
        let kind = answer.decision === "terminal" ? "" : (currentRequest.kind === "permission" ? answer.decision : "answer");
        reqAnswerLog = kind ? {agent: currentRequest.agent, project: currentRequest.project || "", kind: kind,
                               text: currentRequest.detail || currentRequest.title || ""} : null;
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
            logActivity(agent, sess.project, "start", text || "Prompt baru");
            showNotification("task_start", {source: agent, title: "Task diterima", detail: text || "Prompt baru",
                                            color: "#a78bfa", expression: "task_start", project: sess.project});
        } else if (msg.event === "AgentStop") {
            logActivity(agent, sess.project, failed ? "error" : "done", failed ? text : (sess.prompt || "Giliran selesai"),
                        sess.promptAt ? formatDuration(Date.now() - sess.promptAt) : "");
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
                root.approvalDetail = msg.message || (msg.tool_name ? "Tool: " + msg.tool_name : "Action needs approval");
                root.showNotification("approval", {source: "hermes", title: "Approval Required",
                    detail: root.approvalDetail,
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
                root.logActivity("hermes", "", allowed ? "allow" : "deny", root.approvalDetail);
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
                if (msg.kind === "permission" && settings.autoSafe && root.isSafeCommand(msg.command)) {
                    root.autoAllow(msg);
                    break;
                }
                root.agentRequests = root.agentRequests.concat([msg]);
                root.refreshRequestView();
            }
            break;

        case "AgentRequestClosed":
            root.removeRequest(msg.request_id);
            break;

        case "ActionResult":
            if (msg.id && root.autoAllowPending[msg.id]) {
                // Auto-izin gagal terkirim: tampilkan kartunya supaya dijawab manual.
                let req = root.autoAllowPending[msg.id];
                delete root.autoAllowPending[msg.id];
                if (!msg.ok) {
                    root.agentRequests = root.agentRequests.concat([req]);
                    root.refreshRequestView();
                }
                break;
            }
            if (msg.id && msg.id === root.reqAnswerCmdId) {
                root.reqAnswerCmdId = "";
                if (msg.ok && root.reqAnswerLog) {
                    let e = root.reqAnswerLog;
                    root.logActivity(e.agent, e.project, e.kind, e.text);
                }
                root.reqAnswerLog = null;
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
            root.logActivity("hermes", "", "start", msg.message || "Task baru");
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
            root.logActivity("hermes", "", "done", msg.message || "Task selesai", took);
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

        // Penerima tombol: event yang tidak dipakai TextField anak naik ke sini.
        focus: true
        Keys.onPressed: event => root.handleKey(event)

        topLeftRadius: 0
        topRightRadius: 0
        bottomLeftRadius: (root.islandExpanded && !root.isNotifying) ? 26 : 22
        bottomRightRadius: (root.islandExpanded && !root.isNotifying) ? 26 : 22

        color: root.theme.base
        border.color: {
            if (root.notifyType === "approval") return "#f59e0b";
            if (root.notifyType === "request") return root.statusColor;
            if (root.notifyType === "agent_wait") return "#f97316";
            if (root.isNotifying && !root.islandExpanded) return Qt.darker(root.statusColor, 2.2);
            return root.theme.surface1;
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
                            color: root.theme.surface0
                            border.color: root.theme.surface1
                            Text {
                                id: projChipTxt
                                anchors.centerIn: parent
                                text: "▸ " + root.notifyProject
                                color: root.theme.subtext1
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
                        color: root.theme.textDim
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
                            color: root.theme.subtext0
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
                                color: root.theme.surface0; border.color: root.theme.surface1
                                Text {
                                    id: reqProjTxt
                                    anchors.centerIn: parent
                                    text: "▸ " + root.notifyProject
                                    color: root.theme.subtext1
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
                        color: root.theme.surface1
                        Text {
                            id: queueTxt
                            anchors.centerIn: parent
                            text: "1/" + root.agentRequests.length + " antrean"
                            color: root.theme.textDim; font.pixelSize: 9; font.bold: true
                        }
                    }
                }

                // ---- IZIN: perintah yang akan dijalankan ----
                Rectangle {
                    visible: requestCard.isPerm
                    Layout.fillWidth: true
                    implicitHeight: permDetail.implicitHeight + 16
                    radius: 8
                    color: root.theme.mantle
                    border.color: root.theme.surface1
                    Text {
                        id: permDetail
                        anchors.fill: parent
                        anchors.margins: 8
                        text: requestCard.req ? (requestCard.req.detail || "-") : ""
                        color: root.theme.textDim
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
                    color: root.theme.text
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
                                color: chosen ? "#0c4a6e" : (optionHover.containsMouse ? root.theme.surface0 : root.theme.surface0)
                                border.color: chosen ? root.theme.accent : (optionHover.containsMouse ? root.theme.surface2 : root.theme.surface1)
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
                                        color: optionRow.chosen ? root.theme.accent : "transparent"
                                        border.color: optionRow.chosen ? root.theme.accent : root.theme.overlay
                                        Text {
                                            anchors.centerIn: parent
                                            text: optionRow.chosen ? "✓" : (optionRow.index + 1)
                                            color: optionRow.chosen ? "#082f49" : root.theme.subtext1
                                            font.pixelSize: 9; font.bold: true
                                        }
                                    }

                                    Column {
                                        width: parent.width - 26
                                        spacing: 1
                                        Text {
                                            width: parent.width
                                            text: optionRow.modelData.label
                                            color: root.theme.text
                                            font.pixelSize: 11; font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        Text {
                                            visible: text !== ""
                                            width: parent.width
                                            text: optionRow.modelData.description || ""
                                            color: root.theme.subtext1
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
                    color: root.theme.surface0
                    border.color: requestCustomInput.activeFocus ? root.theme.accent : root.theme.surface1
                    TextField {
                        id: requestCustomInput
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        placeholderText: "Jawaban lain… (Enter untuk kirim)"
                        placeholderTextColor: root.theme.subtext0
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
                        color: termLink.containsMouse ? root.theme.textDim : root.theme.subtext0
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
                        visible: islandCapsule.activeFocus && !root.reqSending
                        text: requestCard.isPerm
                              ? "⌨ Y izinkan · N tolak" + (requestCard.req && requestCard.req.can_always ? " · A selalu" : "") + " · T terminal"
                              : "⌨ 1-9 pilih · Enter lanjut · T terminal"
                        color: root.theme.overlay
                        font.pixelSize: 9
                    }

                    Text {
                        visible: root.reqSending
                        text: "Mengirim…"
                        color: root.theme.accent
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
                        color: backHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                        border.color: root.theme.surface2
                        Text { id: backTxt; anchors.centerIn: parent; text: "Kembali"; color: root.theme.textDim; font.pixelSize: 11; font.bold: true }
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
                        color: ready ? (nextHover.containsMouse ? "#0ea5e9" : "#0284c7") : root.theme.surface0
                        border.color: ready ? "#7dd3fc" : root.theme.surface1
                        Text {
                            id: nextTxt
                            anchors.centerIn: parent
                            text: nextBtn.last ? "Kirim" : "Lanjut"
                            color: nextBtn.ready ? "#f0f9ff" : root.theme.overlay
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
                    color: root.theme.mantle
                    border.color: root.theme.surface1
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
                            color: root.theme.surface0
                            border.color: root.mediaPlaying ? "#1db954" : root.theme.surface1
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
                                        color: root.mediaPlaying ? "#1db954" : root.theme.subtext1
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
                                                color: root.mediaPlaying ? "#1db954" : root.theme.overlay
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
                                        color: root.theme.surface1
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
                                            color: root.theme.text
                                            font.pixelSize: 10
                                            font.bold: true
                                            font.family: "Inter, sans-serif"
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }

                                        Text {
                                            text: root.mediaArtist
                                            color: root.theme.subtext0
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
                                        color: prevMediaHover.containsMouse ? root.theme.surface1 : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "⏮"
                                            color: root.theme.subtext1
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
                                        color: nextMediaHover.containsMouse ? root.theme.surface1 : "transparent"
                                        Text {
                                            anchors.centerIn: parent
                                            text: "⏭"
                                            color: root.theme.subtext1
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
                            color: root.theme.surface0
                            border.color: root.theme.surface1
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
                                        color: root.theme.accent
                                        font.pixelSize: 12
                                        font.bold: true
                                        font.family: "JetBrains Mono, Inter, monospace"
                                    }

                                    // Badge Mini WIB
                                    Rectangle {
                                        width: 24; height: 13; radius: 3
                                        color: root.theme.surface1
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
                                    color: root.theme.subtext1
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
                                        return root.theme.subtext1;
                                    }
                                    border.color: root.avatarModel === modelData ? root.theme.accent : root.theme.surface2
                                    border.width: 1.5

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: settings.avatar = modelData
                                    }
                                }
                            }

                            Rectangle { width: 1; height: 12; color: root.theme.surface2; anchors.verticalCenter: parent.verticalCenter }

                            // Ganti tema: lingkaran berwarna aksen tema aktif, klik = tema berikutnya.
                            Rectangle {
                                width: 16; height: 16; radius: 8
                                color: root.theme.surface1
                                border.color: root.theme.accent
                                border.width: 1.5
                                Text {
                                    anchors.centerIn: parent
                                    text: "◐"
                                    color: root.theme.accent
                                    font.pixelSize: 10
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        root.cycleTheme();
                                        root.showActionToast(true, "Tema: " + root.theme.label);
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

                    // Navigasi: 4 grup + sub-tab grup aktif sebaris, Interview di kanan.
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: root.tabGroups
                            Rectangle {
                                id: groupBtn
                                required property var modelData
                                required property int index
                                readonly property bool active: root.groupOf(root.activeTab) === modelData.key
                                implicitWidth: groupTxt.implicitWidth + 14
                                implicitHeight: 26
                                radius: 6
                                color: active ? root.theme.surface1 : (groupHover.containsMouse ? root.theme.surface0 : "transparent")
                                Text {
                                    id: groupTxt
                                    anchors.centerIn: parent
                                    text: groupBtn.modelData.label
                                    color: groupBtn.active ? "#fff" : root.theme.subtext0
                                    font.pixelSize: 11; font.bold: true
                                }
                                MouseArea {
                                    id: groupHover
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.selectGroup(groupBtn.index)
                                }
                            }
                        }

                        Rectangle {
                            visible: root.subTabs.length > 1
                            implicitWidth: 1; implicitHeight: 14
                            color: root.theme.surface2
                            Layout.leftMargin: 2; Layout.rightMargin: 2
                        }

                        Repeater {
                            model: root.subTabs.length > 1 ? root.subTabs : []
                            Rectangle {
                                id: subBtn
                                required property var modelData
                                readonly property bool active: root.activeTab === modelData.key
                                implicitWidth: subTxt.implicitWidth + 14
                                implicitHeight: 20
                                radius: 10
                                color: active ? Qt.darker(root.theme.accent, 2.8) : "transparent"
                                border.color: active ? Qt.darker(root.theme.accent, 1.6) : root.theme.surface1
                                Text {
                                    id: subTxt
                                    anchors.centerIn: parent
                                    text: subBtn.modelData.label
                                    color: subBtn.active ? root.theme.text : root.theme.subtext0
                                    font.pixelSize: 9; font.bold: true
                                }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.selectTab(subBtn.modelData.key)
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        // Interview: mode khusus; bingkai + titik merah saat merekam.
                        Rectangle {
                            id: ivNavBtn
                            readonly property bool active: root.activeTab === "interview"
                            implicitWidth: ivNavRow.implicitWidth + 14
                            implicitHeight: 26
                            radius: 6
                            color: active ? root.theme.surface1 : (ivNavHover.containsMouse ? root.theme.surface0 : "transparent")
                            border.color: root.interviewRunning ? "#ef4444" : "transparent"
                            Row {
                                id: ivNavRow
                                anchors.centerIn: parent
                                spacing: 4
                                Rectangle {
                                    visible: root.interviewRunning
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 6; height: 6; radius: 3
                                    color: "#ef4444"
                                }
                                Text { text: "Interview"; color: ivNavBtn.active ? "#fff" : root.theme.subtext0; font.pixelSize: 10; font.bold: true }
                            }
                            MouseArea {
                                id: ivNavHover
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectTab("interview")
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
                                    color: notesTabCol.filterTag === modelData.key ? root.theme.surface1 : root.theme.surface0
                                    border.color: notesTabCol.filterTag === modelData.key ? root.theme.surface2 : root.theme.surface1
                                    border.width: 1

                                    Text {
                                        id: filterChipTxt
                                        anchors.centerIn: parent
                                        text: modelData.label
                                        color: notesTabCol.filterTag === modelData.key ? "#ffffff" : root.theme.subtext0
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
                            color: notesTabCol.confirmClear ? "#450a0a" : (clearAllHover.containsMouse ? root.theme.surface1 : root.theme.surface0)
                            border.color: notesTabCol.confirmClear ? "#ef4444" : root.theme.surface1
                            border.width: 1

                            Text {
                                anchors.centerIn: parent
                                text: notesTabCol.confirmClear ? "Yakin hapus?" : "Hapus Semua"
                                color: notesTabCol.confirmClear ? "#fca5a5" : (clearAllHover.containsMouse ? "#ffffff" : root.theme.subtext0)
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
                        color: root.theme.mantle
                        border.color: root.theme.surface1
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
                                color: root.theme.overlay
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
                                color: root.theme.surface0
                                border.color: root.theme.surface1
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
                                        color: model.done ? root.theme.surface1 : "transparent"
                                        border.color: model.done ? root.theme.overlay : root.theme.surface2
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
                                                color: root.theme.surface1
                                                border.color: root.theme.surface2
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
                                                color: root.theme.subtext0
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
                                            color: runBtnHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                                            border.color: root.theme.surface2
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
                                            color: copyBtnHover.containsMouse ? root.theme.surface1 : "transparent"
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
                                            color: delBtnHover.containsMouse ? root.theme.surface1 : "transparent"
                                            border.color: "transparent"

                                            Text {
                                                anchors.centerIn: parent
                                                text: "✕"
                                                color: delBtnHover.containsMouse ? "#ef4444" : root.theme.subtext0
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
                                        color: notesTabCol.selectedTag === modelData.key ? root.theme.surface1 : root.theme.surface0
                                        border.color: notesTabCol.selectedTag === modelData.key ? root.theme.surface2 : root.theme.surface1
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
                                color: root.theme.surface0
                                border.color: noteInput.activeFocus ? root.theme.surface2 : root.theme.surface1
                                border.width: 1

                                TextField {
                                    id: noteInput
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8
                                    verticalAlignment: TextInput.AlignVCenter
                                    placeholderText: notesTabCol.selectedTag === "cmd" ? "Ketik perintah terminal..." : (notesTabCol.selectedTag === "task" ? "Tulis task kerjaan..." : "Tulis memo...")
                                    placeholderTextColor: root.theme.subtext0
                                    color: "#ffffff"
                                    font.pixelSize: 11
                                    font.family: notesTabCol.selectedTag === "cmd" ? "JetBrains Mono, monospace" : "Inter, sans-serif"
                                    background: null
                                    Keys.onEscapePressed: event => {
                                        islandCapsule.forceActiveFocus(); // Esc berikutnya menutup island
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
                                color: saveBtnHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                                border.color: root.theme.surface1
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

                // TAB AGENT: status Hermes + semua sesi Claude Code / OpenCode
                ColumnLayout {
                    visible: root.activeTab === "agent"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    // Kartu: Status Agent Hermes
                    Rectangle {
                        Layout.fillWidth: true
                        implicitHeight: statusAgentCol.implicitHeight + 20
                        radius: 8
                        color: root.theme.surface0
                        border.color: root.theme.surface1

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
                                    color: root.theme.subtext0
                                    font.pixelSize: 10
                                }
                            }

                            Text {
                                text: root.activeDetail && root.activeDetail.length > 0 ? root.activeDetail : "Siap menerima prompt & task dari ganteng."
                                color: root.theme.textDim
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
                        color: root.theme.surface0
                        border.color: (root.agentAggregate("claude") === "waiting" || root.agentAggregate("opencode") === "waiting") ? "#f97316" : root.theme.surface1

                        ColumnLayout {
                            id: agentCol
                            anchors.fill: parent
                            anchors.margins: 8
                            spacing: 4

                            RowLayout {
                                spacing: 6
                                SourceLogo { kind: "claude"; size: 15 }
                                SourceLogo { kind: "opencode"; size: 15 }
                                Text { text: "Agent Coding"; color: root.theme.text; font.pixelSize: 12; font.bold: true }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: root.agentSessions.length > 0 ? root.agentSessions.length + " sesi" : ""
                                    color: root.theme.subtext0; font.pixelSize: 9
                                }
                                // Auto-izinkan perintah baca-saja (git status, ls, cat, …)
                                Rectangle {
                                    implicitWidth: autoSafeTxt.implicitWidth + 12; implicitHeight: 18; radius: 9
                                    color: settings.autoSafe ? "#052e16" : "transparent"
                                    border.color: settings.autoSafe ? "#22c55e" : root.theme.surface2
                                    Text {
                                        id: autoSafeTxt
                                        anchors.centerIn: parent
                                        text: "Auto-izin aman: " + (settings.autoSafe ? "On" : "Off")
                                        color: settings.autoSafe ? "#86efac" : root.theme.subtext0
                                        font.pixelSize: 8; font.bold: true
                                    }
                                    MouseArea {
                                        anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: settings.autoSafe = !settings.autoSafe
                                    }
                                }
                            }

                            Text {
                                visible: root.agentSessions.length === 0
                                text: "Belum ada sesi Claude Code / OpenCode yang aktif"
                                color: root.theme.overlay
                                font.pixelSize: 9
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Repeater {
                                model: root.agentSessions
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    SourceLogo { kind: modelData.agent; size: 14 }
                                    Text {
                                        text: modelData.project || "?"
                                        color: root.theme.textDim; font.pixelSize: 10; font.bold: true
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
                                        color: root.theme.subtext1; font.pixelSize: 9
                                        font.family: "JetBrains Mono, monospace"
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Text {
                                        // currentTimeSecs: dependensi agar "x dtk" ikut berdetak
                                        text: root.currentTimeSecs !== "" ? root.agoText(modelData.updated) : ""
                                        color: root.theme.overlay; font.pixelSize: 8
                                    }
                                }
                            }
                        }
                    }

                    // Riwayat: task diterima/selesai dan keputusan izin, terbaru di atas.
                    RowLayout {
                        Layout.fillWidth: true
                        Text { text: "RIWAYAT"; color: root.theme.subtext0; font.pixelSize: 10; font.bold: true }
                        Item { Layout.fillWidth: true }
                        Text {
                            readonly property var today: (activity.daily || {})[root.dayKey(new Date())]
                            visible: !!today
                            text: today ? "Hari ini: " + today.done + " selesai · " + today.perms + " izin" + (today.errors ? " · " + today.errors + " gagal" : "") : ""
                            color: root.theme.subtext0; font.pixelSize: 9
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 8
                        color: root.theme.mantle
                        border.color: root.theme.surface1

                        ListView {
                            id: historyView
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 2
                            clip: true
                            model: activity.history || []
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                            Text {
                                anchors.centerIn: parent
                                visible: historyView.count === 0
                                text: "Belum ada aktivitas tercatat"
                                color: root.theme.overlay
                                font.pixelSize: 10
                            }

                            delegate: RowLayout {
                                required property var modelData
                                width: historyView.width - 8
                                spacing: 6
                                Text {
                                    text: root.clockText(modelData.t)
                                    color: root.theme.overlay
                                    font.pixelSize: 9
                                    font.family: "JetBrains Mono, monospace"
                                    Layout.preferredWidth: 30
                                }
                                SourceLogo { kind: modelData.agent || "hermes"; size: 12 }
                                Text {
                                    visible: !!modelData.project
                                    text: modelData.project
                                    color: root.theme.textDim; font.pixelSize: 9; font.bold: true
                                    elide: Text.ElideRight
                                    Layout.maximumWidth: 80
                                }
                                Text {
                                    text: root.activityLabel(modelData.kind)
                                    color: root.activityColor(modelData.kind)
                                    font.pixelSize: 9; font.bold: true
                                }
                                Text {
                                    text: modelData.text
                                    color: root.theme.subtext1
                                    font.pixelSize: 9
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Text {
                                    visible: !!modelData.dur
                                    text: "⏱ " + modelData.dur
                                    color: root.theme.subtext0; font.pixelSize: 8
                                }
                            }
                        }
                    }
                }

                // TAB 2: STATUS (SYSTEM MONITOR)
                ColumnLayout {
                    visible: root.activeTab === "status"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    // Section Title: System Hardware & Resource
                    Text {
                        text: "RESOURCE SISTEM (ARCH LINUX)"
                        color: root.theme.subtext0
                        font.pixelSize: 10
                        font.bold: true
                        topPadding: 2
                    }

                    // Kartu 2: Metrik RAM & Uptime
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        // CPU Usage Card
                        Rectangle {
                            Layout.fillWidth: true; height: 50; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 4
                                RowLayout {
                                    Text { text: "CPU"; color: root.theme.subtext0; font.pixelSize: 9 }
                                    Item { Layout.fillWidth: true }
                                    Text { text: root.sysCpu + "%"; color: root.sysCpu > 85 ? "#ef4444" : "#a78bfa"; font.pixelSize: 10; font.bold: true }
                                }
                                Rectangle {
                                    Layout.fillWidth: true; height: 4; radius: 2; color: root.theme.surface1
                                    Rectangle {
                                        width: parent.width * Math.min(1, root.sysCpu / 100.0)
                                        height: parent.height; radius: 2
                                        color: root.sysCpu > 85 ? "#ef4444" : "#a78bfa"
                                    }
                                }
                                Text { text: root.sysProcesses + " proses"; color: root.theme.subtext1; font.pixelSize: 9 }
                            }
                        }

                        // RAM Usage Card
                        Rectangle {
                            Layout.fillWidth: true; height: 50; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 4
                                RowLayout {
                                    Text { text: "RAM Terpakai"; color: root.theme.subtext0; font.pixelSize: 9 }
                                    Item { Layout.fillWidth: true }
                                    Text { text: "" + root.sysRamPercent + "%"; color: root.sysRamPercent > 85 ? "#ef4444" : root.theme.accent; font.pixelSize: 10; font.bold: true }
                                }
                                // Progress bar mini RAM
                                Rectangle {
                                    Layout.fillWidth: true; height: 4; radius: 2; color: root.theme.surface1
                                    Rectangle {
                                        width: parent.width * (root.sysRamPercent / 100.0)
                                        height: parent.height; radius: 2
                                        color: root.sysRamPercent > 85 ? "#ef4444" : root.theme.accent
                                    }
                                }
                                Text { text: root.sysRamUsed + " / " + root.sysRamTotal; color: root.theme.subtext1; font.pixelSize: 9 }
                            }
                        }

                        // Uptime Card
                        Rectangle {
                            Layout.fillWidth: true; height: 50; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 2
                                Text { text: "System Uptime"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: root.sysUptime; color: "#22c55e"; font.pixelSize: 12; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                Text { text: root.sysKernel; color: root.theme.subtext0; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
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
                        color: root.theme.subtext0
                        font.pixelSize: 10
                        font.bold: true
                    }

                    // Metrik Hari Ini
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Requests"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: "" + root.usageRequests; color: "#fff"; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Biaya Hari Ini"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: "$" + root.usageCost.toFixed(2); color: "#22c55e"; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Tokens"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: root.formatTokens(root.usageTokens); color: root.theme.accent; font.pixelSize: 13; font.bold: true }
                            }
                        }
                    }

                    // Header: Akumulasi 60 Hari Terakhir
                    Text {
                        text: "TOTAL 60 HARI TERAKHIR (ALL-TIME 60D)"
                        color: root.theme.subtext0
                        font.pixelSize: 10
                        font.bold: true
                        topPadding: 2
                    }

                    // Metrik 60 Hari
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Total Requests"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: "" + root.usage60dRequests; color: "#facc15"; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Total Biaya (60d)"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: "$" + root.usage60dCost.toFixed(2); color: "#4ade80"; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Total Tokens (60d)"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: root.formatTokens(root.usage60dTokens); color: "#a855f7"; font.pixelSize: 13; font.bold: true }
                            }
                        }
                    }

                    // Section: Model AI Aktif & Recent Requests
                    Text {
                        text: "MODEL AI AKTIF HARI INI"
                        color: root.theme.subtext0
                        font.pixelSize: 10
                        font.bold: true
                        topPadding: 2
                    }

                    Text {
                        visible: root.activeModelsList.length === 0
                        text: "Belum ada request hari ini"
                        color: root.theme.overlay
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
                                color: root.theme.surface0
                                border.color: root.theme.surface1

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
                                        color: root.theme.text
                                        font.pixelSize: 11
                                        font.bold: true
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }

                                    Text {
                                        text: "" + modelData.requests + " reqs"
                                        color: root.theme.subtext1
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
                        Layout.fillWidth: true; height: 30; radius: 6; color: root.theme.surface0; border.color: root.theme.surface1
                        RowLayout {
                            anchors.fill: parent; anchors.margins: 8
                            Text { text: "Gateway 9Router"; color: root.theme.subtext0; font.pixelSize: 10 }
                            Item { Layout.fillWidth: true }
                            // Status nyata dari bridge, bukan label "Active" statis.
                            Rectangle { width: 6; height: 6; radius: 3; color: !root.usageLoaded ? root.theme.subtext0 : (root.usageAvailable ? "#22c55e" : "#ef4444") }
                            Text {
                                text: !root.usageLoaded ? "Memuat…" : (root.usageAvailable ? "Database terbaca" : "Data tidak tersedia")
                                color: !root.usageLoaded ? root.theme.subtext0 : (root.usageAvailable ? "#22c55e" : "#ef4444")
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
                        color: root.theme.subtext0
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
                            color: vscodeHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                            border.color: vscodeHover.containsMouse ? "#5b7fe5" : root.theme.surface1
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
                                    Text { text: "Visual Studio Code"; color: root.theme.text; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: "Code Editor"; color: root.theme.subtext0; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
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
                            color: kittyHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                            border.color: kittyHover.containsMouse ? "#ffffff" : root.theme.surface1
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
                                    Text { text: "Kitty Terminal"; color: root.theme.text; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: "Shell Emulator"; color: root.theme.subtext0; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
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
                            color: filesHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                            border.color: filesHover.containsMouse ? "#d97706" : root.theme.surface1
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
                                    Text { text: "Files Manager"; color: root.theme.text; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: "Explore Directory"; color: root.theme.subtext0; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
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
                            color: shotHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                            border.color: shotHover.containsMouse ? "#22c55e" : root.theme.surface1
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
                                    Text { text: "Screenshot Area"; color: root.theme.text; font.pixelSize: 11; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                    Text { text: "Grim + Slurp crop"; color: root.theme.subtext0; font.pixelSize: 9; elide: Text.ElideRight; Layout.fillWidth: true }
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
                        color: root.theme.subtext0
                        font.pixelSize: 10
                        font.bold: true
                        topPadding: 4
                    }

                    // Audio Quick Control Bar (Konsisten & Rapi)
                    Rectangle {
                        Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10

                            Image {
                                source: "file:///usr/share/icons/Papirus/24x24/actions/audio-volume-high.svg"
                                width: 20; height: 20; fillMode: Image.PreserveAspectFit
                            }

                            Column {
                                spacing: 1
                                Text { text: "Volume Speaker"; color: root.theme.text; font.pixelSize: 11; font.bold: true }
                                Text { text: "PipeWire Audio"; color: root.theme.subtext0; font.pixelSize: 9 }
                            }

                            Item { Layout.fillWidth: true }

                            // Tombol -5%
                            Rectangle {
                                width: 44; height: 28; radius: 6; color: volDownHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                                border.color: root.theme.surface1
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
                                width: 52; height: 28; radius: 6; color: volMuteHover.containsMouse ? "#ef444433" : root.theme.surface0
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
                                width: 44; height: 28; radius: 6; color: volUpHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                                border.color: root.theme.surface1
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

                    // Suara notifikasi QBot (izin masuk, task selesai/gagal)
                    Rectangle {
                        Layout.fillWidth: true; height: 34; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 8; spacing: 8
                            Text { text: settings.sound ? "🔔" : "🔕"; font.pixelSize: 12 }
                            Text { text: "Suara notifikasi QBot"; color: root.theme.text; font.pixelSize: 11; font.bold: true }
                            Item { Layout.fillWidth: true }
                            Rectangle {
                                width: 44; height: 22; radius: 6
                                color: settings.sound ? "#052e16" : root.theme.surface0
                                border.color: settings.sound ? "#22c55e" : root.theme.surface2
                                Text {
                                    anchors.centerIn: parent
                                    text: settings.sound ? "On" : "Off"
                                    color: settings.sound ? "#86efac" : root.theme.subtext0
                                    font.pixelSize: 10; font.bold: true
                                }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        settings.sound = !settings.sound;
                                        root.playSound("pop");
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
                                color: root.theme.text
                                font.pixelSize: 11
                                font.bold: true
                            }
                        }

                        Item { Layout.fillWidth: true }

                        Rectangle {
                            width: 60; height: 22; radius: 5
                            color: refreshHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                            border.color: root.theme.surface2; border.width: 1
                            Row {
                                anchors.centerIn: parent
                                spacing: 4
                                Text { text: "Refresh"; color: root.theme.subtext1; font.pixelSize: 9; font.bold: true }
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
                        color: root.theme.mantle
                        border.color: root.theme.surface1
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
                                color: root.theme.overlay
                                font.pixelSize: 11
                            }

                            delegate: Rectangle {
                                width: projectsListView.width
                                implicitHeight: projCol.implicitHeight + 14
                                radius: 8
                                color: modelData.is_active ? root.theme.surface0 : root.theme.mantle
                                border.color: modelData.is_active ? "#0284c7" : root.theme.surface1
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
                                            color: modelData.commits_today > 0 ? "#052e16" : root.theme.surface1
                                            border.color: modelData.commits_today > 0 ? "#22c55e" : root.theme.surface2
                                            border.width: 1
                                            Text {
                                                id: cTodayLbl
                                                anchors.centerIn: parent
                                                text: modelData.commits_today > 0 ? (modelData.commits_today + " commit hari ini") : "0 commit"
                                                color: modelData.commits_today > 0 ? "#86efac" : root.theme.subtext0
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
                                        color: root.theme.subtext0
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
                                            color: codeHover.containsMouse ? root.theme.surface1 : root.theme.surface0
                                            border.color: root.theme.surface2
                                            border.width: 1

                                            RowLayout {
                                                id: codeRow
                                                anchors.centerIn: parent
                                                spacing: 4
                                                Text {
                                                    text: "VS Code"
                                                    color: root.theme.textDim
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
                        color: root.theme.subtext0
                        font.pixelSize: 10
                        font.bold: true
                    }

                    // Card Container List dengan ListView (Scrollable & Anti-Overflow)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 8
                        color: root.theme.mantle
                        border.color: root.theme.surface1
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
                                color: root.theme.overlay
                                font.pixelSize: 11
                            }

                            delegate: Rectangle {
                                id: devRow
                                width: devListView.width
                                implicitHeight: 46
                                radius: 6
                                color: devRow.anyRunning ? root.theme.surface0 : root.theme.mantle
                                border.color: devRow.anyRunning ? "#22c55e44" : root.theme.surface1
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
                                                color: devRow.anyRunning ? "#22c55e" : root.theme.surface2
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
                                            color: root.theme.subtext0
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
                                        color: devRow.php.running ? "#052e16" : root.theme.surface0
                                        border.color: devRow.php.running ? "#22c55e" : root.theme.surface2
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "serve"
                                            color: devRow.php.running ? "#86efac" : root.theme.subtext1
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
                                        color: devRow.npm.running ? "#052e16" : root.theme.surface0
                                        border.color: devRow.npm.running ? "#22c55e" : root.theme.surface2
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "npm dev"
                                            color: devRow.npm.running ? "#86efac" : root.theme.subtext1
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
                                            return root.theme.surface0;
                                        }
                                        border.color: devRow.availableCount > devRow.runningCount ? "#22c55e" : root.theme.surface1
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "Start"
                                            color: devRow.availableCount > devRow.runningCount ? "#86efac" : root.theme.overlay
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
                                            return root.theme.surface0;
                                        }
                                        border.color: devRow.runningCount > 0 ? "#ef4444" : root.theme.surface1
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "Stop"
                                            color: devRow.runningCount > 0 ? "#fca5a5" : root.theme.overlay
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
                                 : root.interviewState === "error" ? "#ef4444" : root.theme.surface2
                        }
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: root.interviewState === "error" ? "#fca5a5" : root.theme.subtext1
                            font.pixelSize: 10
                            text: root.interviewState === "listening"
                                  ? (root.interviewThinking ? "Menyusun jawaban…" : root.interviewSpeaking ? "Lawan bicara berbicara…" : "Mendengarkan")
                                  : (root.interviewMessage || "Siap. Pakai headset agar suaramu tidak ikut terekam.")
                        }

                        // Meter level audio: bukti suara benar-benar tertangkap
                        Rectangle {
                            visible: root.interviewRunning
                            width: 40; height: 4; radius: 2
                            color: root.theme.surface1
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
                                color: chosen ? "#1e1b4b" : root.theme.surface0
                                border.color: chosen ? "#818cf8" : root.theme.surface2
                                border.width: 1
                                Text { anchors.centerIn: parent; text: modelData.label; color: parent.chosen ? "#c7d2fe" : root.theme.subtext1; font.pixelSize: 9; font.bold: true }
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
                            color: root.interviewAuto ? "#052e16" : root.theme.surface0
                            border.color: root.interviewAuto ? "#22c55e" : root.theme.surface2
                            border.width: 1
                            Text { anchors.centerIn: parent; text: "Auto"; color: root.interviewAuto ? "#86efac" : root.theme.subtext1; font.pixelSize: 9; font.bold: true }
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
                            color: usable ? (jawabHover.containsMouse ? "#1e3a8a" : "#172554") : root.theme.surface0
                            border.color: usable ? "#3b82f6" : root.theme.surface1
                            border.width: 1
                            Text { anchors.centerIn: parent; text: "Jawab"; color: parent.usable ? "#93c5fd" : root.theme.overlay; font.pixelSize: 9; font.bold: true }
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
                        color: root.theme.mantle
                        border.color: root.theme.surface1
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
                                color: root.theme.overlay
                                font.pixelSize: 10
                            }

                            delegate: Text {
                                required property var modelData
                                width: ivTranscriptView.width
                                wrapMode: Text.Wrap
                                color: root.theme.subtext1
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
                        color: root.theme.mantle
                        border.color: root.interviewThinking ? "#3b82f6" : root.theme.surface1
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
                                    color: root.theme.subtext0
                                    font.pixelSize: 9
                                    font.italic: true
                                    text: root.interviewShownAnswer ? "❝ " + root.interviewShownAnswer.question : "SARAN JAWABAN"
                                }
                                Text {
                                    visible: root.interviewAnswers.length > 1
                                    text: "‹"
                                    color: root.interviewAnswerIndex < root.interviewAnswers.length - 1 ? root.theme.textDim : root.theme.surface2
                                    font.pixelSize: 13; font.bold: true
                                    MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                                        onClicked: if (root.interviewAnswerIndex < root.interviewAnswers.length - 1) root.interviewAnswerIndex += 1 }
                                }
                                Text {
                                    visible: root.interviewAnswers.length > 1
                                    text: (root.interviewAnswerIndex + 1) + "/" + root.interviewAnswers.length
                                    color: root.theme.subtext0; font.pixelSize: 9
                                }
                                Text {
                                    visible: root.interviewAnswers.length > 1
                                    text: "›"
                                    color: root.interviewAnswerIndex > 0 ? root.theme.textDim : root.theme.surface2
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
                                    color: root.interviewShownAnswer && root.interviewShownAnswer.error ? "#fca5a5" : root.theme.text
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
