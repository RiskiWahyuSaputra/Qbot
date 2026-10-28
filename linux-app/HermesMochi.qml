import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Mpris

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
    readonly property var tabKeys: ["agent", "projects", "dev", "status", "usage", "tools", "notes", "music", "interview"]
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
            property bool avatarAuto: true    // robot di panel terbuka berganti warna per menu
            property string tab: "notes"
            property string theme: "noir"
            property bool sound: true
            property bool autoSafe: false     // auto-izinkan perintah baca-saja (opt-in)
            property string ntfyUrl: ""       // mis. https://ntfy.sh/topik-rahasia; kosong = mati
            property int ntfyDelay: 60        // detik menunggu sebelum dikirim ke HP
            property string greetedDay: ""    // hari terakhir ringkasan harian ditampilkan
            property bool voice: true         // dengarkan "halo qbot" dari mikrofon
        }
    }

    // Izin yang menunggu > ntfyDelay dtk dikirim ke HP lewat ntfy. Hanya agent + project,
    // tanpa isi perintah (bisa memuat token), karena topik ntfy.sh bersifat publik.
    property string remoteNotifyKey: ""

    function armRemoteNotify(key) {
        remoteNotifyKey = key;
        if (settings.ntfyUrl) remoteNotifyTimer.restart();
    }

    Timer {
        id: remoteNotifyTimer
        interval: Math.max(5, settings.ntfyDelay) * 1000
        onTriggered: {
            let key = "";
            if (root.notifyType === "approval" && root.approvalActionable) key = "hermes:" + root.pendingRequestId;
            else if (root.notifyType === "request" && root.currentRequest) key = root.currentRequest.request_id;
            if (!key || key !== root.remoteNotifyKey || !/^https?:\/\//.test(settings.ntfyUrl)) return;
            let agent = root.notifySource ? root.agentName(root.notifySource) : "Agent";
            let what = root.notifyType === "request" && root.currentRequest && root.currentRequest.kind === "question" ? "bertanya" : "butuh izin";
            Quickshell.execDetached(["curl", "-fsS", "-m", "10", "-H", "Title: QBot: " + agent + " " + what,
                                     "-H", "Tags: robot,hourglass", "-H", "Priority: high",
                                     "-d", (root.notifyProject ? "Project " + root.notifyProject + " · " : "")
                                           + "menunggu jawaban " + Math.round(interval / 1000) + " dtk. Jawab di island atau terminal.",
                                     settings.ntfyUrl]);
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
        onLoaded: root.activityReady = true
        onLoadFailed: error => {
            root.activityReady = true;
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

    property bool activityReady: false
    property string greetText: ""

    function greetingTitle() {
        let h = new Date().getHours();
        let part = h >= 4 && h < 11 ? "pagi" : h < 15 ? "siang" : h < 18 ? "sore" : "malam";
        return "Selamat " + part + ", ganteng! 👋";
    }

    // Ringkasan hari aktif terakhir sebelum hari ini, mis. "Kemarin: 5 task selesai · 3 izin".
    function lastDaySummary() {
        let today = dayKey(new Date());
        let keys = Object.keys(activity.daily || {}).filter(k => k < today).sort();
        if (keys.length === 0) return "";
        let key = keys[keys.length - 1];
        let d = activity.daily[key];
        let y = new Date(); y.setDate(y.getDate() - 1);
        let parts = key.split("-");
        let months = ["Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"];
        let label = key === dayKey(y) ? "Kemarin" : Number(parts[2]) + " " + months[Number(parts[1]) - 1];
        let out = [d.done + " task selesai", d.perms + " izin"];
        if (d.errors) out.push(d.errors + " gagal");
        return label + ": " + out.join(" · ");
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
        if (kind === "error" || kind === "deny") return "#ef4444";
        if (kind === "start") return theme.text;
        return theme.subtext1;
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
        noir:       {label: "Noir", base: "#000000", mantle: "#080808", surface0: "#101010", surface1: "#1a1a1a", surface2: "#262626",
                     overlay: "#404040", subtext0: "#6e6e6e", subtext1: "#a3a3a3", textDim: "#d4d4d4", text: "#fafafa", accent: "#ffffff"},
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
    readonly property var themeNames: ["noir", "zinc", "catppuccin", "tokyonight", "gruvbox", "nord"]
    readonly property var theme: themePresets[settings.theme] || themePresets.noir

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
        // Coba ekspresi Mochi; "" kembali otomatis (CPU / musik / jam).
        function mood(name: string): string {
            let names = ["", "sleepy", "sweat", "dance", "happy", "celebrate", "dizzy", "angry", "working", "wave"];
            if (names.indexOf(name) < 0) return "ekspresi tidak dikenal (" + names.slice(1).join(", ") + ")";
            root.moodOverride = name;
            return "ok";
        }
        function autosafe(on: bool): void {
            settings.autoSafe = on;
        }
        // URL topik ntfy (https://ntfy.sh/<topik> atau server sendiri); "" = mati.
        function ntfy(url: string): string {
            if (url !== "" && !/^https?:\/\/\S+$/.test(url)) return "URL harus diawali http:// atau https://";
            settings.ntfyUrl = url;
            return url ? "ok, notifikasi HP aktif" : "ok, notifikasi HP mati";
        }
        function ntfydelay(seconds: int): string {
            if (seconds < 5 || seconds > 3600) return "jeda harus 5-3600 detik";
            settings.ntfyDelay = seconds;
            return "ok";
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
    // Warna robot besar di panel terbuka mengikuti menu aktif; island tertutup tetap pilihan pengguna.
    readonly property var menuAvatars: ({agent: "white", work: "strobi", system: "green", notes: "citrus", music: "kirby", interview: "amber"})
    readonly property string menuAvatar: settings.avatarAuto ? (menuAvatars[groupOf(activeTab) || activeTab] || avatarModel) : avatarModel
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
    // Dinaikkan tiap isi catatan berubah: binding yang membaca notesModel.get() ikut diperbarui.
    property int notesRevision: 0

    // Warna kartu catatan ("" = netral).
    readonly property var noteColorKeys: ["", "amber", "rose", "sky", "lime", "violet"]
    function noteAccent(key) {
        return ({amber: "#fbbf24", rose: "#fb7185", sky: "#38bdf8", lime: "#a3e635", violet: "#a78bfa"})[key] || "#a3a3a3";
    }

    function noteIndex(id) {
        if (!id) return -1;
        for (let i = 0; i < notesModel.count; i++) {
            if (notesModel.get(i).id === id) return i;
        }
        return -1;
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

    // Spotify & Media State: MPRIS langsung dari D-Bus (realtime, tanpa polling proses).
    // Pemutar dipilih: yang sedang main lebih dulu, Spotify diutamakan, lalu yang metadatanya
    // paling lengkap. Chromium + plasma-browser-integration mengirim tab yang sama dua kali;
    // versi "chromium" tanpa artis & cover, jadi kalah dari versi plasma.
    readonly property MprisPlayer mediaPlayer: {
        const score = p => (p.isPlaying ? 8 : 0) + (/spotify/i.test(p.dbusName) ? 4 : 0)
                           + (p.trackArtist ? 2 : 0) + (p.trackArtUrl ? 1 : 0);
        let best = null;
        for (const p of Mpris.players.values) {
            if (!best || score(p) > score(best)) best = p;
        }
        return best;
    }
    readonly property bool mediaActive: mediaPlayer !== null && mediaPlayer.trackTitle !== ""
    readonly property bool mediaPlaying: mediaActive && mediaPlayer.isPlaying
    readonly property string mediaTitle: mediaActive ? mediaPlayer.trackTitle : "Tidak Ada Media"
    readonly property string mediaArtist: mediaActive ? mediaPlayer.trackArtist : ""
    readonly property string mediaArtUrl: mediaActive ? mediaPlayer.trackArtUrl : ""
    readonly property real mediaLength: mediaActive && mediaPlayer.lengthSupported ? mediaPlayer.length : 0
    property real mediaPosition: 0
    // Mini player di island tertutup hanya saat musik benar-benar diputar.
    readonly property bool showMiniPlayer: mediaPlaying && !islandMini

    // Posisi MPRIS tidak diperbarui otomatis; dibaca ulang berkala untuk progress & lirik.
    function syncMediaPosition() {
        mediaPosition = mediaPlayer && mediaPlayer.positionSupported ? mediaPlayer.position : 0;
    }
    onMediaPlayingChanged: syncMediaPosition()
    Timer {
        interval: 200
        running: root.mediaPlaying && !root.islandHidden
        repeat: true
        triggeredOnStart: true
        onTriggered: root.syncMediaPosition()
    }

    function mediaSeek(seconds) {
        if (!mediaPlayer || !mediaPlayer.canSeek) return;
        mediaPlayer.position = Math.max(0, Math.min(seconds, mediaLength || seconds));
        mediaPosition = mediaPlayer.position;
    }

    function formatTime(seconds) {
        const s = Math.max(0, Math.floor(seconds));
        return Math.floor(s / 60) + ":" + String(s % 60).padStart(2, "0");
    }

    // Warna aksen dari cover album (warna paling hidup, dicerahkan agar terbaca di latar gelap).
    ColorQuantizer {
        id: artQuantizer
        source: root.mediaArtUrl
        depth: 3
        rescaleSize: 64
    }
    readonly property color mediaAccent: {
        let best = null, bestScore = -1;
        for (const c of artQuantizer.colors) {
            const s = c.hslSaturation * (0.35 + c.hslLightness);
            if (s > bestScore) { best = c; bestScore = s; }
        }
        if (!best || best.hslSaturation < 0.12) return "#1db954";
        return Qt.hsla(Math.max(0, best.hslHue), Math.max(best.hslSaturation, 0.5),
                       Math.min(Math.max(best.hslLightness, 0.62), 0.78), 1);
    }

    // Visualizer: cava (output raw ASCII 0-100 per bar), hanya jalan saat musik diputar.
    property var vizBars: [0, 0, 0, 0, 0, 0]
    Process {
        id: cavaProcess
        command: ["cava", "-p", root.appDir + "cava.conf"]
        running: root.mediaPlaying && !root.islandHidden
        onRunningChanged: if (!running) root.vizBars = [0, 0, 0, 0, 0, 0]
        stdout: SplitParser {
            onRead: data => {
                const v = data.split(";");
                v.pop();
                if (v.length) root.vizBars = v.map(Number);
            }
        }
    }

    // Lirik dari LRCLIB (lrclib.net, gratis & tersinkron). Yang dikirim hanya judul,
    // artis, dan durasi lagu; hasil disimpan per sesi supaya tiap lagu diminta sekali.
    property var lyricLines: []        // [{t: detik, text}]; t = -1 bila tidak tersinkron
    property bool lyricSynced: false
    property string lyricStatus: ""    // "" | "loading" | "none" | "instrumental"
    property var lyricCache: ({})
    readonly property string mediaTrackKey: mediaActive ? mediaArtist + "\n" + mediaTitle : ""
    onMediaTrackKeyChanged: { lyricDebounce.interval = 400; lyricDebounce.restart(); }
    readonly property int lyricIndex: {
        if (!lyricSynced) return -1;
        const t = mediaPosition + 0.25;   // sedikit mendahului supaya terasa pas dengan vokal
        let i = -1;
        for (let k = 0; k < lyricLines.length && lyricLines[k].t <= t; k++) i = k;
        return i;
    }
    readonly property string currentLyric: lyricIndex >= 0 ? lyricLines[lyricIndex].text : ""

    property string lyricRetryKey: ""
    property int lyricRetries: 0
    Timer {
        id: lyricDebounce
        interval: 400   // panjang lagu dari MPRIS kadang menyusul sesudah judul
        onTriggered: root.loadLyrics()
    }

    // callback(data, failed): failed = gangguan jaringan/server (bukan "lirik tidak ada"),
    // supaya hasilnya tidak di-cache dan bisa dicoba lagi.
    function lrclibGet(path, callback) {
        const xhr = new XMLHttpRequest();
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE) return;
            let data = null;
            if (xhr.status === 200) {
                try { data = JSON.parse(xhr.responseText); } catch (e) {}
            }
            callback(data, xhr.status === 0 || xhr.status >= 500);
        };
        xhr.open("GET", "https://lrclib.net/api/" + path);
        xhr.send();
    }

    function loadLyrics() {
        const key = mediaTrackKey;
        if (!key) { applyLyrics(null, ""); return; }
        // Tanpa artis biasanya video browser biasa, bukan lagu: judulnya tidak dikirim.
        if (!mediaArtist) { applyLyrics(null, "none"); return; }
        if (lyricCache[key] !== undefined) { applyLyrics(lyricCache[key], "none"); return; }
        if (key !== lyricRetryKey) { lyricRetryKey = key; lyricRetries = 0; }
        lyricLines = [];
        lyricSynced = false;
        lyricStatus = "loading";
        const title = mediaTitle, artist = mediaArtist, dur = Math.round(mediaLength);
        const done = (rec, failed) => {
            if (failed && lyricRetries < 3) {
                // Gangguan jaringan: jangan anggap "tidak ada lirik", coba lagi sebentar lagi.
                lyricRetries++;
                lyricDebounce.interval = 3000 * lyricRetries;
                lyricDebounce.restart();
                return;
            }
            if (!failed) lyricCache[key] = rec;
            if (key === root.mediaTrackKey) root.applyLyrics(rec, failed ? "error" : "none");
        };
        let q = "track_name=" + encodeURIComponent(title) + "&artist_name=" + encodeURIComponent(artist);
        lrclibGet("get?" + q + (dur > 0 ? "&duration=" + dur : ""), (rec, failed) => {
            if (rec) { done(rec, false); return; }
            // Judul Spotify sering berekor "- Remastered 2011" / "(feat. X)": cari versi bersihnya.
            const clean = title.replace(/\s+-\s+.*$/, "").replace(/\s*[(\[](feat|ft|with)\.?[^)\]]*[)\]]/i, "");
            lrclibGet("search?track_name=" + encodeURIComponent(clean) + "&artist_name=" + encodeURIComponent(artist), (list, failed2) => {
                const found = Array.isArray(list) ? (list.find(r => r.syncedLyrics) || list[0] || null) : null;
                done(found, !found && (failed || failed2));
            });
        });
    }

    function applyLyrics(rec, emptyStatus) {
        lyricSynced = !!(rec && rec.syncedLyrics);
        if (lyricSynced) {
            lyricLines = parseLrc(rec.syncedLyrics);
        } else if (rec && rec.plainLyrics) {
            lyricLines = rec.plainLyrics.split("\n").map(text => ({t: -1, text: text.trim() || " "}));
        } else {
            lyricLines = [];
        }
        lyricStatus = lyricLines.length ? "" : (rec && rec.instrumental ? "instrumental" : emptyStatus);
    }

    // Cover album dengan sudut membulat (radius = setengah lebar → lingkaran).
    component RoundedArt: Item {
        id: art
        property alias source: artImg.source
        property real radius: 8
        property color placeholder: "#1a1a1a"
        Image {
            id: artImg
            anchors.fill: parent
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            sourceSize: Qt.size(art.width * 2, art.height * 2)
            visible: false
        }
        Rectangle {
            id: artMask
            anchors.fill: parent
            radius: art.radius
            visible: false
            layer.enabled: true
        }
        MultiEffect {
            anchors.fill: parent
            source: artImg
            visible: artImg.status === Image.Ready
            maskEnabled: true
            maskSource: artMask
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1.0
        }
        Rectangle {
            anchors.fill: parent
            radius: art.radius
            color: art.placeholder
            visible: artImg.status !== Image.Ready
            Text { anchors.centerIn: parent; text: "♪"; color: "#888"; font.pixelSize: Math.round(art.height * 0.42) }
        }
    }

    // Ikon kontrol media digambar sendiri supaya tidak berubah jadi emoji berwarna.
    component MediaGlyph: Shape {
        id: glyph
        property string kind: "play"   // play | pause | prev | next
        property color tint: "#fff"
        width: 12; height: 12
        preferredRendererType: Shape.CurveRenderer
        ShapePath {
            strokeWidth: -1
            fillColor: glyph.kind === "pause" ? "transparent" : glyph.tint
            // play: segitiga penuh; prev/next: segitiga + batang di ujung
            startX: glyph.kind === "prev" ? glyph.width : (glyph.kind === "next" ? 0 : 1); startY: 0
            PathLine { x: glyph.kind === "prev" ? 2.5 : (glyph.kind === "next" ? glyph.width - 2.5 : glyph.width); y: glyph.height / 2 }
            PathLine { x: glyph.kind === "prev" ? glyph.width : (glyph.kind === "next" ? 0 : 1); y: glyph.height }
        }
        ShapePath {
            strokeWidth: -1
            fillColor: glyph.kind === "play" ? "transparent" : glyph.tint
            startX: glyph.kind === "pause" ? 1.5 : (glyph.kind === "prev" ? 0 : glyph.width - 2); startY: 0
            PathLine { x: glyph.kind === "pause" ? 4.5 : (glyph.kind === "prev" ? 2 : glyph.width); y: 0 }
            PathLine { x: glyph.kind === "pause" ? 4.5 : (glyph.kind === "prev" ? 2 : glyph.width); y: glyph.height }
            PathLine { x: glyph.kind === "pause" ? 1.5 : (glyph.kind === "prev" ? 0 : glyph.width - 2); y: glyph.height }
        }
        ShapePath {
            strokeWidth: -1
            fillColor: glyph.kind === "pause" ? glyph.tint : "transparent"
            startX: glyph.width - 4.5; startY: 0
            PathLine { x: glyph.width - 1.5; y: 0 }
            PathLine { x: glyph.width - 1.5; y: glyph.height }
            PathLine { x: glyph.width - 4.5; y: glyph.height }
        }
    }

    function parseLrc(lrc) {
        const out = [];
        for (const raw of lrc.split("\n")) {
            const tags = raw.match(/\[\d+:\d+(?:\.\d+)?\]/g);
            if (!tags) continue;
            const text = raw.replace(/\[[^\]]*\]/g, "").trim() || "♪";
            for (const tag of tags) {
                const m = tag.match(/\[(\d+):(\d+(?:\.\d+)?)\]/);
                out.push({t: parseInt(m[1], 10) * 60 + parseFloat(m[2]), text: text});
            }
        }
        out.sort((a, b) => a.t - b.t);
        return out;
    }

    // Suasana Mochi saat santai: keringat bila CPU >= 90%, joget saat musik
    // diputar, mengantuk larut malam (23.00-05.00). "" = ekspresi biasa.
    property string moodOverride: ""          // dari 'qbot mood', untuk mencoba ekspresi
    readonly property string ambientExpression: {
        if (moodOverride) return moodOverride;
        if (sysCpu >= 90) return "sweat";
        if (mediaPlaying) return "dance";
        let h = parseInt(currentTimeHoursMins, 10);
        if (h >= 23 || h < 5) return "sleepy";
        return "";
    }

    // Data untuk suasana saat island tertutup (saat terbuka, tab-nya sendiri yang polling).
    Timer {
        interval: 15000
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: {
            if (root.islandExpanded) return;
            fetchSysInfoProcess.running = true;
        }
    }

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
        return root.theme.textDim;
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
        else if (type === "task_start" || type === "interview" || (type === "voice" && opts.expression === "wave")) playSound("pop");
        currentStatus = opts.title;
        activeDetail = opts.detail || "";
        statusColor = opts.color;
        let timers = {task_start: taskStartNotifyTimer, done: completionCollapseTimer,
                      agent_wait: agentNotifyTimer, info: infoNotifyTimer,
                      interview: interviewNotifyTimer, greet: greetNotifyTimer, voice: voiceNotifyTimer};
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
            armRemoteNotify(req.request_id);
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
                        "Status interview diperbarui", "Membuat jawaban…", "Status suara diperbarui", "Memproses perintah…"];
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
                               done: !!n.done, tag: root.noteType(n.text, n.tag),
                               title: typeof n.title === "string" ? n.title : "",
                               color: typeof n.color === "string" ? n.color : ""});
        }
        notesRevision++;
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
            if (settings.voice) sendBridgeCommand({ action: "voice_start" });
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
                root.armRemoteNotify("hermes:" + msg.request_id);
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

        case "VoiceStatus": {
            let prev = root.voiceState;
            root.voiceState = msg.state || "off";
            root.voiceMessage = msg.message || "";
            if (msg.state === "awake") {
                root.showNotification("voice", {title: "Ya? Aku dengar…", detail: "Ucapkan perintahmu", color: "#00f2fe", expression: "wave"});
            } else if (msg.state === "thinking") {
                root.showNotification("voice", {title: "🎙 " + (msg.message || ""), detail: "Memproses…", color: "#38bdf8", expression: "working"});
            } else if (msg.state === "error" && prev !== "error") {
                root.showActionToast(false, msg.message || "Perintah suara bermasalah");
            } else if (msg.state === "standby" && prev === "awake" && root.notifyType === "voice") {
                root.showNotification("voice", {title: "Tidak ada perintah", detail: "Panggil \"halo qbot\" lagi", color: root.theme.subtext0, expression: "sleepy"});
            }
            break;
        }

        case "VoiceReply":
            root.showNotification("voice", {title: msg.ok ? "QBot" : "QBot — gagal", detail: msg.text || "",
                color: msg.ok ? "#22c55e" : "#ef4444", expression: msg.ok ? "celebrate" : "dizzy"});
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

    // Pill perintah suara: tetap terbuka selama QBot menunggu perintah / berpikir / bicara.
    Timer {
        id: voiceNotifyTimer
        interval: 6000
        repeat: false
        onTriggered: {
            if (root.notifyType !== "voice") return;
            if (root.voiceState === "awake" || root.voiceState === "thinking" || root.voiceState === "speaking") {
                restart();
                return;
            }
            root.isNotifying = false;
            root.notifyType = "";
            root.restoreBaseline();
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
            arr.push({id: String(itm.id), text: itm.text, time: itm.time, done: !!itm.done, tag: root.noteType(itm.text, itm.tag),
                      title: itm.title || "", color: itm.color || ""});
        }
        notesRevision++;
        sendBridgeCommand({action: "notes_save", notes: arr});
    }

    function addNoteItem(txt, tag) {
        if (!txt || txt.trim().length === 0) return;
        let now = new Date();
        let timeStr = (now.getHours() < 10 ? "0" : "") + now.getHours() + ":" + (now.getMinutes() < 10 ? "0" : "") + now.getMinutes();
        let newId = String(Date.now());
        // Langsung insert di awal list UI
        notesModel.insert(0, {id: newId, text: txt.trim(), time: timeStr, done: false, tag: root.noteType(txt, tag), title: "", color: ""});
        saveNotesToFile();
    }

    // Catatan kosong untuk editor; baru disimpan ke file setelah diisi.
    function createNote(tag) {
        let now = new Date();
        let id = String(Date.now());
        notesModel.insert(0, {id: id, text: "", time: Qt.formatTime(now, "HH:mm"), done: false,
                              tag: tag, title: "", color: ""});
        notesRevision++;
        return id;
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

    // Git & Web Projects Portal State
    property var gitProjectsList: []
    property string activeGitProjectId: ""

    // Dev Server State (php artisan serve / npm run dev, dikelola bridge)
    property var devServers: []

    // Interview Assist (interview.py: rekam lawan bicara -> Whisper -> saran jawaban)
    property string interviewState: "idle"    // idle | loading | listening | error
    property string interviewSource: "system" // system (Zoom/Meet) | mic (tatap muka)
    property bool interviewAuto: true
    // Perintah suara: off | loading | standby | awake | thinking | speaking | error
    property string voiceState: "off"
    property string voiceMessage: ""
    readonly property bool voiceOn: voiceState !== "off" && voiceState !== "error"

    function setVoice(enabled) {
        settings.voice = enabled;
        sendBridgeCommand({ action: enabled ? "voice_start" : "voice_stop" });
    }
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

    // ── Konteks jendela fokus (Niri) ─────────────────────────────────────────
    // Browser fokus → island menyusut jadi garis tipis supaya tidak menutupi tab.
    // Jendela fullscreen (YouTube, game, dll) → island bersembunyi; hanya
    // approval/pertanyaan agent yang tetap muncul karena agent menunggu jawaban.
    property var niriWindows: ({})
    property var niriFocusedId: null
    property string focusedAppId: ""
    property bool focusedFullscreen: false
    readonly property bool browserFocused: /chrom|firefox|brave|zen|vivaldi|edge|librewolf|floorp|thorium|opera/i.test(focusedAppId)
    readonly property bool islandMini: browserFocused && !focusedFullscreen && !islandExpanded && !isNotifying
    readonly property bool islandHidden: focusedFullscreen && !islandExpanded
                                         && notifyType !== "approval" && notifyType !== "request"

    function handleNiriEvent(line) {
        let ev;
        try { ev = JSON.parse(line); } catch (e) { return; }
        if (ev.WindowsChanged) {
            let m = {};
            for (const w of ev.WindowsChanged.windows) {
                m[w.id] = w;
                if (w.is_focused) niriFocusedId = w.id;
            }
            niriWindows = m;
        } else if (ev.WindowOpenedOrChanged) {
            const w = ev.WindowOpenedOrChanged.window;
            niriWindows[w.id] = w;
            if (w.is_focused) niriFocusedId = w.id;
        } else if (ev.WindowClosed) {
            delete niriWindows[ev.WindowClosed.id];
            if (niriFocusedId === ev.WindowClosed.id) niriFocusedId = null;
        } else if (ev.WindowFocusChanged) {
            niriFocusedId = ev.WindowFocusChanged.id;
        } else if (ev.WindowLayoutsChanged) {
            for (const [id, layout] of ev.WindowLayoutsChanged.changes)
                if (niriWindows[id]) niriWindows[id].layout = layout;
        } else {
            return;
        }
        const w = niriFocusedId !== null ? niriWindows[niriFocusedId] : null;
        focusedAppId = w ? (w.app_id || "") : "";
        // Niri tidak punya flag fullscreen; jendela biasa selalu terpotong gaps,
        // jadi ukuran selebar layar penuh = fullscreen.
        const size = w && w.layout ? w.layout.window_size : null;
        focusedFullscreen = !!size && size[0] >= root.screen.width && size[1] >= root.screen.height;
    }

    onIslandHiddenChanged: if (islandHidden) islandExpanded = false

    Process {
        id: niriEventsProcess
        command: ["niri", "msg", "-j", "event-stream"]
        running: true
        stdout: SplitParser {
            onRead: data => root.handleNiriEvent(data)
        }
        onExited: niriRestartTimer.restart()
    }

    Timer {
        id: niriRestartTimer
        interval: 3000
        onTriggered: niriEventsProcess.running = true
    }

    // Mode mini: pointer yang sekadar lewat menuju tab browser tidak membuka island,
    // harus diam sebentar di atasnya.
    Timer {
        id: miniExpandTimer
        interval: 150
        onTriggered: {
            if (capsuleHover.hovered && !root.isNotifying) {
                root.islandExpanded = true;
            }
        }
    }

    // Dynamic Island Capsule
    Rectangle {
        id: islandCapsule
        anchors.top: parent.top
        anchors.topMargin: root.islandHidden ? -(height + 4) : 0
        anchors.horizontalCenter: parent.horizontalCenter
        Behavior on anchors.topMargin { NumberAnimation { duration: 260; easing.type: Easing.OutCubic } }
        opacity: root.islandHidden ? 0 : 1
        Behavior on opacity { NumberAnimation { duration: 200 } }

        width: {
            if (root.islandExpanded && !root.isNotifying) return 660;
            if (root.isNotifying) return (root.notifyType === "approval" || root.notifyType === "request") ? 600 : 500;
            if (root.islandMini) return 120;
            if (root.showMiniPlayer) return Math.min(440, standbyRow.implicitWidth + 32);
            return 240;
        }

        height: {
            if (root.islandExpanded && !root.isNotifying) return 300;
            if (root.notifyType === "request") return Math.min(404, requestCard.implicitHeight + 30);
            if (root.isNotifying) return (root.notifyType === "approval" || root.notifyType === "interview" || root.notifyType === "voice") ? 64 : 60;
            if (root.islandMini) return 8;
            return 44;
        }

        // Penerima tombol: event yang tidak dipakai TextField anak naik ke sini.
        focus: true
        Keys.onPressed: event => root.handleKey(event)

        topLeftRadius: 0
        topRightRadius: 0
        bottomLeftRadius: root.islandMini ? 4 : ((root.islandExpanded && !root.isNotifying) ? 26 : 22)
        bottomRightRadius: root.islandMini ? 4 : ((root.islandExpanded && !root.isNotifying) ? 26 : 22)

        color: root.theme.base
        // Border selalu netral: status (berhasil, approval, dll) cukup terlihat
        // dari isi notifikasinya, tanpa bingkai berwarna.
        border.color: root.theme.surface1
        border.width: 1.0

        Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.15 } }
        Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutBack; easing.overshoot: 1.05 } }

        // Bahu cekung kiri-kanan ala notch/Dynamic Island Mac: sudut atas tidak
        // lagi menyiku tajam, tapi melengkung menyatu ke tepi atas layar.
        property real shoulderRadius: root.islandMini ? 5 : ((root.islandExpanded && !root.isNotifying) ? 16 : 11)
        Behavior on shoulderRadius { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

        Repeater {
            model: [-1, 1]
            delegate: Shape {
                required property int modelData
                readonly property real r: islandCapsule.shoulderRadius
                readonly property real bw: islandCapsule.border.width
                // Lebih lebar bw+1 supaya menutup garis border kapsul di sepanjang bahu.
                width: r + bw + 1
                height: r
                x: modelData < 0 ? -r : islandCapsule.width - bw - 1
                y: 0
                z: 1
                transform: Scale { origin.x: width / 2; xScale: modelData < 0 ? 1 : -1 }
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeWidth: -1
                    fillColor: islandCapsule.color
                    startX: 0; startY: 0
                    PathArc { x: r; y: r; radiusX: r; radiusY: r; direction: PathArc.Clockwise }
                    PathLine { x: width; y: r }
                    PathLine { x: width; y: 0 }
                    PathLine { x: 0; y: 0 }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: islandCapsule.border.color
                    strokeWidth: bw
                    capStyle: ShapePath.FlatCap
                    startX: 0; startY: 0
                    PathArc { x: r + bw / 2; y: r; radiusX: r + bw / 2; radiusY: r; direction: PathArc.Clockwise }
                }
            }
        }

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
                    if (root.islandMini) {
                        miniExpandTimer.restart();
                    } else if (!root.isNotifying) {
                        root.islandExpanded = true;
                    }
                } else {
                    root.cursorLookX = 0.0;
                    root.cursorLookY = 0.0;
                    root.cursorOnRobot = false;
                    root.isAngry = false;
                    robotAngerCountdown.stop();
                    miniExpandTimer.stop();
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

        Timer {
            id: dizzyTimer
            interval: 3500 // Efek pusing bergetar selama 3.5 detik lalu reda
            repeat: false
            onTriggered: {
                root.isDizzy = false;
            }
        }

        Item {
            anchors.fill: parent
            anchors.margins: 8

            // 1. TAMPILAN STANDBY BIASA
            Row {
                id: standbyRow
                visible: !root.isNotifying && !root.islandExpanded && !root.islandMini
                anchors.centerIn: parent
                spacing: 12

                // Karakter Interaktif Bible Strong Avatar Lab (Diperbesar)
                QCoreBot {
                    size: 32
                    anchors.verticalCenter: parent.verticalCenter
                    avatarType: root.avatarModel
                    expression: root.avatarExpression !== "proud" ? root.avatarExpression
                                : (capsuleHover.hovered ? "wave" : (root.hermesWorking ? "working" : (root.ambientExpression || "idle")))
                    targetLookX: root.cursorLookX
                    targetLookY: root.cursorLookY
                }

                Text {
                    visible: !root.showMiniPlayer
                    text: "QBot"
                    color: "#ffffff"
                    font.pixelSize: 14
                    font.bold: true
                    font.weight: Font.Black
                    font.family: "Inter, sans-serif"
                    anchors.verticalCenter: parent.verticalCenter
                }

                // Mini player saat musik diputar: cover berputar, judul + baris lirik aktif, visualizer.
                Row {
                    visible: root.showMiniPlayer
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 9

                    RoundedArt {
                        id: miniArt
                        width: 26; height: 26; radius: 13
                        anchors.verticalCenter: parent.verticalCenter
                        source: root.mediaArtUrl
                        placeholder: root.theme.surface1
                        RotationAnimation on rotation {
                            running: root.showMiniPlayer
                            from: 0; to: 360; duration: 9000
                            loops: Animation.Infinite
                            onRunningChanged: if (!running) miniArt.rotation = 0
                        }
                    }

                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.min(190, Math.max(miniTitle.implicitWidth, miniSub.implicitWidth))
                        spacing: 0
                        Text {
                            id: miniTitle
                            width: parent.width
                            text: root.mediaTitle
                            color: "#ffffff"
                            elide: Text.ElideRight
                            font.pixelSize: 11; font.bold: true
                            font.family: "Inter, sans-serif"
                        }
                        Text {
                            id: miniSub
                            width: parent.width
                            text: root.currentLyric || root.mediaArtist
                            color: root.currentLyric ? root.mediaAccent : root.theme.subtext1
                            elide: Text.ElideRight
                            font.pixelSize: 10
                            font.family: "Inter, sans-serif"
                        }
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        height: 18
                        spacing: 2
                        Repeater {
                            model: root.vizBars
                            Rectangle {
                                required property var modelData
                                anchors.bottom: parent.bottom
                                width: 3; radius: 1.5
                                height: 3 + Math.min(100, modelData) / 100 * 15
                                color: root.mediaAccent
                                Behavior on height { NumberAnimation { duration: 60 } }
                            }
                        }
                    }
                }

                // Logo Hermes dengan cincin warna status koneksi/task.
                Rectangle {
                    visible: !root.showMiniPlayer
                    anchors.verticalCenter: parent.verticalCenter
                    width: 22; height: 22; radius: 11
                    color: "transparent"
                    border.color: root.theme.surface2
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
                        border.color: root.theme.text
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

                    QCoreBot {
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
                            color: root.theme.text
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
                            border.color: "transparent"
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
                        readonly property bool twoLines: root.notifyType === "approval" || root.notifyType === "interview" || root.notifyType === "voice"
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
                            color: root.notifyError ? root.theme.surface2 : root.theme.surface1
                            border.color: root.notifyError ? root.theme.surface2 : root.theme.surface2
                            border.width: 1.5
                            Text {
                                anchors.centerIn: parent
                                text: root.notifyError ? "✕" : "✓"
                                color: root.notifyError ? "#fca5a5" : root.theme.text
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
                        color: rejectHover.containsMouse ? root.theme.surface2 : root.theme.surface1
                        border.color: rejectHover.containsMouse ? root.theme.surface2 : root.theme.surface2
                        border.width: 1

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 4
                            Text { text: "✕"; color: root.theme.subtext1; font.pixelSize: 10; font.bold: true }
                            Text {
                                id: rejectText
                                text: root.decisionPending ? "Sending…" : "Reject"
                                color: root.theme.subtext1
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
                        color: runHover.containsMouse ? "#d4d4d4" : "#fafafa"
                        border.color: root.theme.surface2
                        border.width: 1

                        RowLayout {
                            anchors.centerIn: parent
                            spacing: 5
                            Text { text: "⚡"; font.pixelSize: 11 }
                            Text {
                                id: runText
                                text: root.decisionPending ? "Sending…" : "Run"
                                color: "#000000"
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
                        QCoreBot {
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
                                color: root.theme.surface2
                                Text {
                                    id: reqHeaderTxt
                                    anchors.centerIn: parent
                                    text: requestCard.question ? requestCard.question.header : ""
                                    color: root.theme.textDim
                                    font.pixelSize: 8; font.bold: true
                                }
                            }
                        }
                        Text {
                            text: requestCard.isPerm ? (requestCard.req ? (requestCard.req.title || "Butuh izin") : "")
                                  : "Pertanyaan" + (requestCard.req && requestCard.req.questions.length > 1
                                                    ? " " + (root.reqIndex + 1) + "/" + requestCard.req.questions.length : "")
                            color: root.theme.text
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
                    border.color: "transparent"
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
                                color: chosen ? root.theme.surface2 : (optionHover.containsMouse ? root.theme.surface0 : root.theme.surface0)
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
                                            color: optionRow.chosen ? root.theme.surface1 : root.theme.subtext1
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
                            {key: "deny", label: "Tolak", fg: root.theme.subtext1, bg: root.theme.surface1, border: root.theme.surface2},
                            {key: "always", label: "Selalu izinkan", fg: root.theme.textDim, bg: root.theme.surface1, border: root.theme.surface2},
                            {key: "allow", label: "Izinkan", fg: "#000000", bg: "#fafafa", border: "#fafafa"}
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
                        color: ready ? (nextHover.containsMouse ? "#d4d4d4" : "#fafafa") : root.theme.surface0
                        border.color: ready ? root.theme.surface2 : root.theme.surface1
                        Text {
                            id: nextTxt
                            anchors.centerIn: parent
                            text: nextBtn.last ? "Kirim" : "Lanjut"
                            color: nextBtn.ready ? "#000000" : root.theme.overlay
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

                // PANEL KIRI: AVATAR BESAR QBOT
                Rectangle {
                    Layout.preferredWidth: 168
                    Layout.fillHeight: true
                    radius: 14
                    color: "transparent"
                    border.width: 0
                    clip: true

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 8

                        Item { Layout.fillHeight: true }

                        // Avatar Besar di Sebelah Kiri
                        Item {
                            Layout.alignment: Qt.AlignHCenter
                            width: 130
                            height: 130

                            QCoreBot {
                                id: largeAvatar
                                anchors.centerIn: parent
                                size: 126
                                avatarType: root.menuAvatar
                                expression: root.isDizzy ? "dizzy" : (root.isAngry ? "angry" : (root.hermesWorking ? "working" : (root.ambientExpression || "proud")))
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

                            // Klik = putar 360° lalu pusing.
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    largeAvatar.poke();
                                    root.isAngry = false;
                                    root.isDizzy = true;
                                    dizzyTimer.restart();
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
                                    color: root.theme.subtext1
                                    font.pixelSize: 10
                                    font.bold: true
                                    font.family: "Inter, sans-serif"
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        Item { Layout.fillHeight: true }

                        // Quick Avatar Switcher (Klik untuk ganti model Avatar Lab)
                        Row {
                            Layout.alignment: Qt.AlignHCenter
                            spacing: 4

                            // Pelangi = warna robot mengikuti menu; warna lain = dipakai di semua menu.
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 13; height: 13; radius: 6.5
                                border.color: settings.avatarAuto ? root.theme.accent : root.theme.surface2
                                border.width: 1.5
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.0; color: "#00f2fe" }
                                    GradientStop { position: 0.35; color: "#22e57a" }
                                    GradientStop { position: 0.65; color: "#ffcf24" }
                                    GradientStop { position: 1.0; color: "#ff7ac8" }
                                }
                                ToolTip.visible: autoAvatarHover.containsMouse
                                ToolTip.delay: 400
                                ToolTip.text: "Warna robot mengikuti menu"
                                MouseArea {
                                    id: autoAvatarHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: settings.avatarAuto = true
                                }
                            }

                            Repeater {
                                model: ["white", "strobi", "nova", "citrus", "kirby"]
                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 13; height: 13; radius: 6.5
                                    color: {
                                        if (modelData === "white") return "#00f2fe";
                                        if (modelData === "strobi") return "#5b7fe5";
                                        if (modelData === "nova") return "#55b6c3";
                                        if (modelData === "citrus") return "#ffcf24";
                                        if (modelData === "kirby") return "#ffb6e0";
                                        return root.theme.subtext1;
                                    }
                                    border.color: !settings.avatarAuto && root.avatarModel === modelData ? root.theme.accent : root.theme.surface2
                                    border.width: 1.5

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -2
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            settings.avatar = modelData;
                                            settings.avatarAuto = false;
                                        }
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

                            // Perintah suara "halo qbot": nyala = mikrofon didengarkan (lokal).
                            Rectangle {
                                id: micToggle
                                width: 16; height: 16; radius: 8
                                readonly property color tint: root.voiceState === "error" ? "#ef4444"
                                                              : (root.voiceOn ? "#00f2fe" : root.theme.subtext0)
                                color: root.voiceOn ? Qt.rgba(0, 0.95, 1, 0.15) : root.theme.surface1
                                border.color: tint
                                border.width: 1.5
                                Rectangle {
                                    x: 6; y: 3; width: 4; height: 7; radius: 2
                                    color: micToggle.tint
                                }
                                Rectangle {
                                    x: 7.25; y: 10.5; width: 1.5; height: 2.5
                                    color: micToggle.tint
                                }
                                Rectangle {
                                    // Coret saat mati
                                    visible: !root.voiceOn
                                    anchors.centerIn: parent
                                    width: 13; height: 1.5; rotation: -45
                                    color: micToggle.tint
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.setVoice(!root.voiceOn)
                                }
                            }
                        }
                    }
                }

                // PANEL KANAN: TAB NAVIGASI & KONTEN (CATATAN / STATUS / 9ROUTER)
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // Lebar = sisa ruang island; isi tab yang lebar tidak boleh mendorong keluar.
                    Layout.preferredWidth: 1
                    clip: true
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

                        // Musik: muncul saat ada pemutar; titik aksen berdenyut selama diputar.
                        Rectangle {
                            id: musicNavBtn
                            visible: root.mediaActive || root.activeTab === "music"
                            readonly property bool active: root.activeTab === "music"
                            implicitWidth: musicNavRow.implicitWidth + 14
                            implicitHeight: 26
                            radius: 6
                            color: active ? root.theme.surface1 : (musicNavHover.containsMouse ? root.theme.surface0 : "transparent")
                            Row {
                                id: musicNavRow
                                anchors.centerIn: parent
                                spacing: 4
                                Rectangle {
                                    visible: root.mediaPlaying
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 6; height: 6; radius: 3
                                    color: root.mediaAccent
                                    SequentialAnimation on opacity {
                                        running: root.mediaPlaying
                                        loops: Animation.Infinite
                                        NumberAnimation { to: 0.35; duration: 600; easing.type: Easing.InOutSine }
                                        NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                                    }
                                }
                                Text {
                                    text: root.subTabs.length > 1 ? "♪" : "Musik"
                                    color: musicNavBtn.active ? "#fff" : root.theme.subtext0
                                    font.pixelSize: root.subTabs.length > 1 ? 12 : 10; font.bold: true
                                }
                            }
                            MouseArea {
                                id: musicNavHover
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectTab("music")
                            }
                        }

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

                // TAB MUSIK: NOW PLAYING + LIRIK TERSINKRON (LRCLIB)
                Item {
                    id: musicTab
                    visible: root.activeTab === "music"
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    // Latar: cover di-blur & digelapkan, sudut membulat.
                    Image {
                        id: musicBgArt
                        anchors.fill: parent
                        source: root.mediaArtUrl
                        fillMode: Image.PreserveAspectCrop
                        sourceSize: Qt.size(160, 160)
                        asynchronous: true
                        visible: false
                    }
                    Rectangle {
                        id: musicBgMask
                        anchors.fill: parent
                        radius: 14
                        visible: false
                        layer.enabled: true
                    }
                    Rectangle {
                        anchors.fill: parent
                        radius: 14
                        color: root.theme.mantle
                    }
                    MultiEffect {
                        anchors.fill: parent
                        source: musicBgArt
                        visible: musicTab.visible && musicBgArt.status === Image.Ready
                        // Tanpa padding: blur tidak melebar keluar dari kotak bermasker.
                        autoPaddingEnabled: false
                        blurEnabled: true
                        blur: 1.0
                        blurMax: 64
                        brightness: -0.42
                        saturation: 0.15
                        maskEnabled: true
                        maskSource: musicBgMask
                        maskThresholdMin: 0.5
                        maskSpreadAtMin: 1.0
                    }

                    Column {
                        visible: !root.mediaActive
                        anchors.centerIn: parent
                        spacing: 6
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "♪"; color: root.theme.subtext0; font.pixelSize: 28 }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Tidak ada musik diputar"; color: root.theme.subtext1; font.pixelSize: 12; font.bold: true }
                        Text { anchors.horizontalCenter: parent.horizontalCenter; text: "Putar lagu di Spotify, liriknya muncul di sini"; color: root.theme.subtext0; font.pixelSize: 10 }
                    }

                    RowLayout {
                        visible: root.mediaActive
                        anchors.fill: parent
                        anchors.margins: 12
                        spacing: 14

                        // Kiri: cover, judul, progress, kontrol
                        ColumnLayout {
                            Layout.preferredWidth: 140
                            Layout.maximumWidth: 140
                            Layout.fillHeight: true
                            spacing: 6

                            RoundedArt {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.preferredWidth: 108
                                Layout.preferredHeight: 108
                                radius: 10
                                source: root.mediaArtUrl
                                placeholder: root.theme.surface1
                                scale: root.mediaPlaying ? 1.0 : 0.92
                                Behavior on scale { NumberAnimation { duration: 300; easing.type: Easing.OutBack } }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: root.mediaTitle
                                color: "#ffffff"
                                elide: Text.ElideRight
                                font.pixelSize: 12; font.bold: true
                                font.family: "Inter, sans-serif"
                            }
                            Text {
                                Layout.fillWidth: true
                                Layout.topMargin: -5
                                text: root.mediaArtist
                                color: root.theme.subtext1
                                elide: Text.ElideRight
                                font.pixelSize: 10
                            }

                            // Progress: klik untuk lompat (bila pemutar mendukung seek).
                            Item {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 10
                                Rectangle {
                                    id: progressTrack
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width; height: 3; radius: 1.5
                                    color: Qt.rgba(1, 1, 1, 0.15)
                                    Rectangle {
                                        height: parent.height; radius: 1.5
                                        width: root.mediaLength > 0 ? parent.width * Math.min(1, root.mediaPosition / root.mediaLength) : 0
                                        color: root.mediaAccent
                                    }
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    enabled: root.mediaLength > 0 && root.mediaPlayer && root.mediaPlayer.canSeek
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: mouse => root.mediaSeek(mouse.x / width * root.mediaLength)
                                }
                            }
                            RowLayout {
                                Layout.fillWidth: true
                                Layout.topMargin: -4
                                Text { text: root.formatTime(root.mediaPosition); color: root.theme.subtext0; font.pixelSize: 9 }
                                Item { Layout.fillWidth: true }
                                Text { text: root.mediaLength > 0 ? root.formatTime(root.mediaLength) : ""; color: root.theme.subtext0; font.pixelSize: 9 }
                            }

                            Row {
                                Layout.alignment: Qt.AlignHCenter
                                spacing: 14
                                Repeater {
                                    model: ["prev", "toggle", "next"]
                                    Rectangle {
                                        id: ctrlBtn
                                        required property string modelData
                                        readonly property bool main: modelData === "toggle"
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: main ? 32 : 24; height: width; radius: width / 2
                                        color: main ? root.mediaAccent : (ctrlHover.containsMouse ? Qt.rgba(1, 1, 1, 0.12) : "transparent")
                                        scale: ctrlHover.pressed ? 0.88 : 1.0
                                        Behavior on scale { NumberAnimation { duration: 90 } }
                                        MediaGlyph {
                                            anchors.centerIn: parent
                                            anchors.horizontalCenterOffset: ctrlBtn.modelData === "toggle" && !root.mediaPlaying ? 1 : 0
                                            width: ctrlBtn.main ? 12 : 10; height: width
                                            kind: ctrlBtn.modelData === "toggle" ? (root.mediaPlaying ? "pause" : "play") : ctrlBtn.modelData
                                            tint: ctrlBtn.main ? "#000000" : "#ffffff"
                                        }
                                        MouseArea {
                                            id: ctrlHover
                                            anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                const p = root.mediaPlayer;
                                                if (!p) return;
                                                if (ctrlBtn.modelData === "prev") p.previous();
                                                else if (ctrlBtn.modelData === "next") p.next();
                                                else p.togglePlaying();
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Kanan: lirik bergulir, baris aktif di tengah & menyala.
                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true

                            ListView {
                                id: lyricView
                                anchors.fill: parent
                                clip: true
                                spacing: 7
                                model: root.lyricLines
                                currentIndex: root.lyricIndex
                                highlightRangeMode: root.lyricSynced ? ListView.ApplyRange : ListView.NoHighlightRange
                                preferredHighlightBegin: height * 0.36
                                preferredHighlightEnd: height * 0.36 + 24
                                highlightMoveDuration: 450
                                highlightMoveVelocity: -1
                                boundsBehavior: Flickable.StopAtBounds
                                // Ganti lagu: mulai lagi dari atas.
                                onModelChanged: positionViewAtBeginning()
                                header: Item { height: root.lyricSynced ? lyricView.height * 0.36 : 4 }
                                footer: Item { height: root.lyricSynced ? lyricView.height * 0.5 : 4 }

                                layer.enabled: true
                                layer.effect: MultiEffect {
                                    maskEnabled: true
                                    maskSource: lyricFade
                                    maskThresholdMin: 0.0
                                    maskSpreadAtMin: 1.0
                                }

                                delegate: Text {
                                    id: lyricLine
                                    required property var modelData
                                    required property int index
                                    readonly property bool current: index === root.lyricIndex
                                    width: ListView.view.width
                                    text: modelData.text
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: 15
                                    font.bold: true
                                    font.family: "Inter, sans-serif"
                                    transformOrigin: Item.Left
                                    scale: current || !root.lyricSynced ? 1.0 : 0.86
                                    color: current ? "#ffffff"
                                         : !root.lyricSynced ? root.theme.textDim
                                         : Qt.rgba(1, 1, 1, index < root.lyricIndex ? 0.3 : 0.45)
                                    style: current ? Text.Outline : Text.Normal
                                    styleColor: Qt.rgba(root.mediaAccent.r, root.mediaAccent.g, root.mediaAccent.b, 0.35)
                                    Behavior on scale { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
                                    Behavior on color { ColorAnimation { duration: 280 } }
                                    // Klik baris = lompat ke bagian lagu itu.
                                    MouseArea {
                                        anchors.fill: parent
                                        enabled: root.lyricSynced && lyricLine.modelData.t >= 0
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.mediaSeek(lyricLine.modelData.t)
                                    }
                                }
                            }

                            // Masker fade atas-bawah untuk lirik.
                            Rectangle {
                                id: lyricFade
                                anchors.fill: parent
                                visible: false
                                layer.enabled: true
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: "transparent" }
                                    GradientStop { position: 0.18; color: "black" }
                                    GradientStop { position: 0.82; color: "black" }
                                    GradientStop { position: 1.0; color: "transparent" }
                                }
                            }

                            Text {
                                visible: root.lyricStatus !== ""
                                anchors.centerIn: parent
                                text: root.lyricStatus === "loading" ? "Memuat lirik…"
                                    : root.lyricStatus === "instrumental" ? "♪  Instrumental"
                                    : root.lyricStatus === "error" ? "Gagal memuat lirik (jaringan)"
                                    : "Lirik tidak ditemukan"
                                color: root.theme.subtext1
                                font.pixelSize: 12; font.bold: true
                            }
                        }
                    }
                }

                // TAB 1: CATATAN — grid kartu ala notebook; klik kartu = editor (judul, isi, tipe, warna).
                ColumnLayout {
                    id: notesTabCol
                    visible: root.activeTab === "notes"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 8

                    property string filterTag: "all" // "all" | "cmd" | "task" | "note"
                    property bool confirmClear: false
                    property string editingId: ""     // id catatan yang dibuka di editor; "" = grid
                    readonly property int editingIndex: { root.notesRevision; return root.noteIndex(editingId); }
                    readonly property bool editing: editingIndex >= 0
                    // Indeks notesModel yang lolos filter, urutan sama dengan model (terbaru di atas).
                    readonly property var cards: {
                        root.notesRevision;
                        let out = [];
                        for (let i = 0; i < notesModel.count; i++) {
                            let n = notesModel.get(i);
                            if (filterTag === "all" || root.noteType(n.text, n.tag) === filterTag) out.push(i);
                        }
                        return out;
                    }

                    function openNote(id) {
                        editingId = id;
                        let i = root.noteIndex(id);
                        if (i < 0) return;
                        let n = notesModel.get(i);
                        noteEditor.loading = true;
                        noteTitleField.text = n.title || "";
                        noteBodyArea.text = n.text || "";
                        noteEditor.loading = false;
                        noteEditor.confirmDelete = false;
                        (n.title || n.text ? noteBodyArea : noteTitleField).forceActiveFocus();
                    }

                    function newNote() {
                        let tag = filterTag === "all" ? "note" : filterTag;
                        openNote(root.createNote(tag));
                    }

                    // Kembali ke grid; catatan yang dibiarkan kosong tidak disimpan.
                    function closeEditor() {
                        let i = editingIndex;
                        noteSaveTimer.stop();
                        if (i >= 0) {
                            let n = notesModel.get(i);
                            if (!n.title.trim() && !n.text.trim()) notesModel.remove(i);
                            root.saveNotesToFile();
                        }
                        editingId = "";
                        islandCapsule.forceActiveFocus();
                    }

                    Timer {
                        id: noteSaveTimer
                        interval: 600
                        onTriggered: root.saveNotesToFile()
                    }

                    // ── MODE GRID ──────────────────────────────────────────────
                    RowLayout {
                        visible: !notesTabCol.editing
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: [
                                { key: "all", label: "Semua" },
                                { key: "cmd", label: "Command" },
                                { key: "task", label: "Task" },
                                { key: "note", label: "Memo" }
                            ]
                            Rectangle {
                                required property var modelData
                                readonly property bool active: notesTabCol.filterTag === modelData.key
                                implicitWidth: filterChipTxt.implicitWidth + 16
                                implicitHeight: 22
                                radius: 11
                                color: active ? root.theme.surface1 : "transparent"
                                border.color: active ? root.theme.surface2 : root.theme.surface1
                                Text {
                                    id: filterChipTxt
                                    anchors.centerIn: parent
                                    text: parent.modelData.label
                                    color: parent.active ? "#ffffff" : root.theme.subtext0
                                    font.pixelSize: 9; font.bold: true
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: notesTabCol.filterTag = parent.modelData.key
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        // Klik pertama minta konfirmasi; klik kedua (≤3 dtk) baru menghapus.
                        Text {
                            visible: notesModel.count > 0
                            text: notesTabCol.confirmClear ? "Yakin hapus semua?" : "Hapus semua"
                            color: notesTabCol.confirmClear ? "#fca5a5" : (clearAllHover.containsMouse ? root.theme.textDim : root.theme.subtext0)
                            font.pixelSize: 9; font.bold: true
                            Layout.rightMargin: 4
                            MouseArea {
                                id: clearAllHover
                                anchors.fill: parent
                                anchors.margins: -4
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
                                onTriggered: notesTabCol.confirmClear = false
                            }
                        }

                        Rectangle {
                            implicitWidth: newNoteTxt.implicitWidth + 18
                            implicitHeight: 24
                            radius: 12
                            color: newNoteHover.containsMouse ? Qt.lighter(root.theme.surface2, 1.2) : root.theme.surface2
                            Text {
                                id: newNoteTxt
                                anchors.centerIn: parent
                                text: "+  Catatan baru"
                                color: "#ffffff"
                                font.pixelSize: 10; font.bold: true
                            }
                            MouseArea {
                                id: newNoteHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: notesTabCol.newNote()
                            }
                        }
                    }

                    GridView {
                        id: notesGrid
                        visible: !notesTabCol.editing
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: notesTabCol.cards
                        cellWidth: Math.floor(width / 3)
                        cellHeight: 98
                        boundsBehavior: Flickable.StopAtBounds
                        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                        Column {
                            anchors.centerIn: parent
                            visible: notesGrid.count === 0
                            spacing: 4
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: notesTabCol.filterTag === "cmd" ? "Belum ada command" : (notesTabCol.filterTag === "task" ? "Belum ada task" : (notesTabCol.filterTag === "note" ? "Belum ada memo" : "Belum ada catatan"))
                                color: root.theme.subtext1; font.pixelSize: 11; font.bold: true
                            }
                            Text {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Klik “+ Catatan baru” untuk mulai menulis"
                                color: root.theme.overlay; font.pixelSize: 9
                            }
                        }

                        delegate: Item {
                            id: noteCard
                            required property var modelData   // indeks di notesModel
                            readonly property var note: { root.notesRevision; return notesModel.get(modelData) || ({id: "", text: "", tag: "note", title: "", color: "", time: "", done: false}); }
                            readonly property string type: root.noteType(note.text, note.tag)
                            readonly property color accent: root.noteAccent(note.color)
                            // Tanpa judul: memo multi-baris memakai baris pertama sebagai judul,
                            // selain itu seluruh isi tampil sebagai teks kartu.
                            readonly property bool firstLineHeading: !note.title && type !== "cmd" && note.text.indexOf("\n") > 0
                            readonly property string heading: note.title || (firstLineHeading ? note.text.split("\n")[0] : "")
                            readonly property string preview: firstLineHeading ? note.text.split("\n").slice(1).join("\n") : note.text
                            width: notesGrid.cellWidth
                            height: notesGrid.cellHeight

                            Rectangle {
                                id: cardBody
                                anchors.fill: parent
                                anchors.margins: 4
                                radius: 10
                                color: Qt.tint(root.theme.surface0, Qt.rgba(noteCard.accent.r, noteCard.accent.g, noteCard.accent.b, note.color ? 0.16 : 0))
                                border.color: cardHover.hovered ? Qt.rgba(noteCard.accent.r, noteCard.accent.g, noteCard.accent.b, 0.7)
                                                                : Qt.rgba(noteCard.accent.r, noteCard.accent.g, noteCard.accent.b, note.color ? 0.3 : 0.08)
                                opacity: noteCard.note.done ? 0.55 : 1.0
                                scale: cardTap.pressed ? 0.97 : 1.0
                                Behavior on scale { NumberAnimation { duration: 90 } }
                                Behavior on border.color { ColorAnimation { duration: 150 } }
                                HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
                                MouseArea {
                                    id: cardTap
                                    anchors.fill: parent
                                    onClicked: notesTabCol.openNote(noteCard.note.id)
                                }

                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 9
                                    spacing: 3

                                    Text {
                                        visible: text !== ""
                                        text: noteCard.heading
                                        color: "#ffffff"
                                        font.pixelSize: 11; font.bold: true
                                        font.strikeout: !!noteCard.note.done
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Text {
                                        text: noteCard.preview
                                        color: noteCard.type === "cmd" ? root.theme.textDim : root.theme.subtext1
                                        font.pixelSize: noteCard.type === "cmd" ? 9 : 10
                                        font.family: noteCard.type === "cmd" ? "JetBrains Mono, monospace" : "Inter, sans-serif"
                                        wrapMode: noteCard.type === "cmd" ? Text.WrapAnywhere : Text.Wrap
                                        maximumLineCount: noteCard.heading ? 2 : 3
                                        font.bold: !noteCard.heading && noteCard.type !== "cmd"
                                        elide: Text.ElideRight
                                        lineHeight: 1.1
                                        Layout.fillWidth: true
                                    }
                                    Item { Layout.fillHeight: true }

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 5
                                        Rectangle {
                                            implicitWidth: cardTag.implicitWidth + 10
                                            implicitHeight: 14
                                            radius: 7
                                            color: Qt.rgba(noteCard.accent.r, noteCard.accent.g, noteCard.accent.b, 0.18)
                                            Text {
                                                id: cardTag
                                                anchors.centerIn: parent
                                                text: noteCard.type === "cmd" ? "Command" : (noteCard.type === "task" ? "Task" : "Memo")
                                                color: noteCard.note.color ? noteCard.accent : root.theme.textDim
                                                font.pixelSize: 8; font.bold: true
                                            }
                                        }
                                        Text {
                                            text: noteCard.note.time || ""
                                            color: root.theme.overlay; font.pixelSize: 8
                                        }
                                        Item { Layout.fillWidth: true }

                                        // Task: centang langsung dari kartu
                                        Rectangle {
                                            visible: noteCard.type === "task"
                                            width: 16; height: 16; radius: 5
                                            color: noteCard.note.done ? noteCard.accent : "transparent"
                                            border.color: noteCard.note.done ? noteCard.accent : root.theme.overlay
                                            Text {
                                                anchors.centerIn: parent
                                                visible: !!noteCard.note.done
                                                text: "✓"; color: "#000000"
                                                font.pixelSize: 10; font.bold: true
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                anchors.margins: -3
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.toggleNoteDone(noteCard.modelData)
                                            }
                                        }

                                        // Command: jalankan di terminal langsung dari kartu
                                        Rectangle {
                                            visible: noteCard.type === "cmd"
                                            width: 20; height: 20; radius: 10
                                            color: runHover.containsMouse ? "#ffffff" : root.theme.surface2
                                            MediaGlyph {
                                                anchors.centerIn: parent
                                                anchors.horizontalCenterOffset: 1
                                                width: 8; height: 8
                                                kind: "play"
                                                tint: runHover.containsMouse ? "#000000" : "#ffffff"
                                            }
                                            MouseArea {
                                                id: runHover
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.runCommandNote(noteCard.modelData)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ── MODE EDITOR ────────────────────────────────────────────
                    Rectangle {
                        id: noteEditor
                        visible: notesTabCol.editing
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 12

                        property bool loading: false
                        property bool confirmDelete: false
                        readonly property var note: { root.notesRevision; return notesTabCol.editing ? notesModel.get(notesTabCol.editingIndex) : null; }
                        readonly property string type: note ? root.noteType(note.text, note.tag) : "note"
                        readonly property color accent: root.noteAccent(note ? note.color : "")

                        color: Qt.tint(root.theme.surface0, Qt.rgba(accent.r, accent.g, accent.b, note && note.color ? 0.12 : 0))
                        border.color: Qt.rgba(accent.r, accent.g, accent.b, note && note.color ? 0.35 : 0.1)

                        function update(field, value) {
                            if (loading || !notesTabCol.editing) return;
                            notesModel.setProperty(notesTabCol.editingIndex, field, value);
                            root.notesRevision++;
                            noteSaveTimer.restart();
                        }

                        Timer {
                            id: deleteConfirmTimer
                            interval: 3000
                            onTriggered: noteEditor.confirmDelete = false
                        }

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 10
                            spacing: 6

                            // Toolbar: kembali · tipe · warna · aksi
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 6

                                Rectangle {
                                    implicitWidth: backRow.implicitWidth + 14
                                    implicitHeight: 22
                                    radius: 11
                                    color: backHoverN.containsMouse ? root.theme.surface2 : root.theme.surface1
                                    Text {
                                        id: backRow
                                        anchors.centerIn: parent
                                        text: "‹  Kembali"
                                        color: "#ffffff"; font.pixelSize: 9; font.bold: true
                                    }
                                    MouseArea {
                                        id: backHoverN
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: notesTabCol.closeEditor()
                                    }
                                }

                                Repeater {
                                    model: [
                                        { key: "note", label: "Memo" },
                                        { key: "task", label: "Task" },
                                        { key: "cmd", label: "Command" }
                                    ]
                                    Rectangle {
                                        required property var modelData
                                        readonly property bool active: noteEditor.type === modelData.key
                                        implicitWidth: typeTxt.implicitWidth + 14
                                        implicitHeight: 22
                                        radius: 11
                                        color: active ? Qt.rgba(noteEditor.accent.r, noteEditor.accent.g, noteEditor.accent.b, 0.22) : "transparent"
                                        border.color: active ? Qt.rgba(noteEditor.accent.r, noteEditor.accent.g, noteEditor.accent.b, 0.6) : root.theme.surface2
                                        Text {
                                            id: typeTxt
                                            anchors.centerIn: parent
                                            text: parent.modelData.label
                                            color: parent.active ? "#ffffff" : root.theme.subtext0
                                            font.pixelSize: 9; font.bold: true
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: noteEditor.update("tag", parent.modelData.key)
                                        }
                                    }
                                }

                                Rectangle { implicitWidth: 1; implicitHeight: 14; color: root.theme.surface2 }

                                Repeater {
                                    model: root.noteColorKeys
                                    Rectangle {
                                        required property string modelData
                                        readonly property bool active: (noteEditor.note ? noteEditor.note.color : "") === modelData
                                        width: 14; height: 14; radius: 7
                                        color: modelData ? root.noteAccent(modelData) : root.theme.surface2
                                        border.color: active ? "#ffffff" : "transparent"
                                        border.width: 2
                                        MouseArea {
                                            anchors.fill: parent
                                            anchors.margins: -2
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: noteEditor.update("color", parent.modelData)
                                        }
                                    }
                                }

                                Item { Layout.fillWidth: true }

                                Repeater {
                                    model: noteEditor.type === "cmd" ? ["run", "copy", "delete"] : ["copy", "delete"]
                                    Rectangle {
                                        id: edAction
                                        required property string modelData
                                        readonly property bool danger: modelData === "delete"
                                        property bool copied: false
                                        implicitWidth: edActionTxt.implicitWidth + 14
                                        implicitHeight: 22
                                        radius: 11
                                        color: danger && noteEditor.confirmDelete ? "#7f1d1d"
                                             : (edActionHover.containsMouse ? root.theme.surface2 : root.theme.surface1)
                                        Text {
                                            id: edActionTxt
                                            anchors.centerIn: parent
                                            text: edAction.modelData === "run" ? "▶  Jalankan"
                                                : edAction.modelData === "copy" ? (edAction.copied ? "✓ Tersalin" : "Salin")
                                                : (noteEditor.confirmDelete ? "Yakin hapus?" : "Hapus")
                                            color: edAction.danger ? (noteEditor.confirmDelete ? "#fecaca" : "#f87171") : "#ffffff"
                                            font.pixelSize: 9; font.bold: true
                                        }
                                        Timer { id: copiedTimer; interval: 1500; onTriggered: edAction.copied = false }
                                        MouseArea {
                                            id: edActionHover
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                if (edAction.modelData === "run") {
                                                    root.runCommandNote(notesTabCol.editingIndex);
                                                } else if (edAction.modelData === "copy") {
                                                    copyNoteProcess.command = ["python3", root.appDir + "bridge_client.py", "post", "/clipboard/copy",
                                                                               JSON.stringify({text: noteEditor.note.text})];
                                                    copyNoteProcess.running = true;
                                                    edAction.copied = true;
                                                    copiedTimer.restart();
                                                } else if (!noteEditor.confirmDelete) {
                                                    noteEditor.confirmDelete = true;
                                                    deleteConfirmTimer.restart();
                                                } else {
                                                    noteEditor.confirmDelete = false;
                                                    let i = notesTabCol.editingIndex;
                                                    notesTabCol.editingId = "";
                                                    root.deleteNoteItem(i);
                                                    islandCapsule.forceActiveFocus();
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            TextField {
                                id: noteTitleField
                                Layout.fillWidth: true
                                placeholderText: "Judul"
                                placeholderTextColor: root.theme.overlay
                                color: "#ffffff"
                                font.pixelSize: 15
                                font.bold: true
                                font.family: "Inter, sans-serif"
                                background: null
                                leftPadding: 2; rightPadding: 2; topPadding: 2; bottomPadding: 2
                                onTextChanged: noteEditor.update("title", text)
                                Keys.onReturnPressed: noteBodyArea.forceActiveFocus()
                                Keys.onEnterPressed: noteBodyArea.forceActiveFocus()
                                Keys.onEscapePressed: event => { notesTabCol.closeEditor(); event.accepted = true; }
                            }

                            Rectangle { Layout.fillWidth: true; implicitHeight: 1; color: Qt.rgba(1, 1, 1, 0.07) }

                            ScrollView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                TextArea {
                                    id: noteBodyArea
                                    placeholderText: noteEditor.type === "cmd" ? "Perintah terminal, mis. npm run dev"
                                                   : (noteEditor.type === "task" ? "Apa yang perlu dikerjakan?" : "Tulis catatan…")
                                    placeholderTextColor: root.theme.overlay
                                    color: root.theme.textDim
                                    font.pixelSize: noteEditor.type === "cmd" ? 11 : 12
                                    font.family: noteEditor.type === "cmd" ? "JetBrains Mono, monospace" : "Inter, sans-serif"
                                    wrapMode: TextEdit.Wrap
                                    selectByMouse: true
                                    background: null
                                    leftPadding: 2; rightPadding: 2; topPadding: 2
                                    onTextChanged: noteEditor.update("text", text)
                                    Keys.onEscapePressed: event => { notesTabCol.closeEditor(); event.accepted = true; }
                                }
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                Text {
                                    text: noteEditor.note ? "Dibuat " + (noteEditor.note.time || "-") : ""
                                    color: root.theme.overlay; font.pixelSize: 8
                                }
                                Item { Layout.fillWidth: true }
                                Text {
                                    text: noteSaveTimer.running ? "Menyimpan…" : "Tersimpan otomatis · Esc untuk kembali"
                                    color: root.theme.overlay; font.pixelSize: 8
                                }
                            }
                        }
                    }
                }

                // TAB AGENT: chip status tiap agent, sesi aktif, lalu riwayat.
                ColumnLayout {
                    id: agentTab
                    visible: root.activeTab === "agent"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignTop
                    Layout.bottomMargin: 4
                    spacing: 8

                    // Sesi diurutkan: butuh input > bekerja > error > selesai > idle, lalu yang terbaru.
                    readonly property var sortedSessions: {
                        const rank = {waiting: 5, working: 4, error: 3, done: 2, idle: 1};
                        return root.agentSessions.slice().sort((a, b) =>
                            ((rank[b.state] || 0) - (rank[a.state] || 0)) || ((b.updated || 0) - (a.updated || 0)));
                    }

                    // Baris 1: chip status Claude Code · Hermes · OpenCode + sakelar auto-izin
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Repeater {
                            model: ["claude", "hermes", "opencode"]

                            Rectangle {
                                id: agentChip
                                required property string modelData
                                readonly property bool isHermes: modelData === "hermes"
                                readonly property int count: root.agentSessions.filter(sess => sess.agent === modelData).length
                                // Hermes: koneksi bridge; Claude/OpenCode: status terpenting dari semua sesinya.
                                readonly property string state: isHermes
                                    ? (!root.hermesConnected ? "offline" : (root.hermesWorking ? "working" : "idle"))
                                    : root.agentAggregate(modelData)
                                readonly property color tint: state === "offline" ? "#ef4444"
                                    : (state === "none" ? root.theme.overlay : root.stateColor(state))
                                readonly property bool dim: state === "none"

                                implicitWidth: chipRow.implicitWidth + 16
                                implicitHeight: 28
                                radius: 14
                                color: root.theme.surface0
                                border.color: state === "waiting" ? "#f97316" : root.theme.surface1
                                opacity: dim ? 0.6 : 1.0
                                Behavior on border.color { ColorAnimation { duration: 200 } }

                                Row {
                                    id: chipRow
                                    anchors.centerIn: parent
                                    spacing: 6
                                    SourceLogo { kind: agentChip.modelData; size: 16; anchors.verticalCenter: parent.verticalCenter }
                                    Text {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: agentChip.isHermes ? "Hermes" : (agentChip.modelData === "claude" ? "Claude" : "OpenCode")
                                        color: root.theme.text; font.pixelSize: 10; font.bold: true
                                    }
                                    Rectangle {
                                        visible: !agentChip.dim
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 6; height: 6; radius: 3
                                        color: agentChip.tint
                                        SequentialAnimation on opacity {
                                            running: agentChip.state === "working" || agentChip.state === "waiting"
                                            loops: Animation.Infinite
                                            onRunningChanged: if (!running) parent.opacity = 1
                                            NumberAnimation { to: 0.3; duration: 600; easing.type: Easing.InOutSine }
                                            NumberAnimation { to: 1.0; duration: 600; easing.type: Easing.InOutSine }
                                        }
                                    }
                                    Text {
                                        // Agent tanpa sesi cukup logo + nama redup, tanpa label.
                                        visible: !agentChip.dim
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: agentChip.state === "offline" ? "Offline"
                                              : root.stateLabel(agentChip.state) + (agentChip.count > 1 ? " · " + agentChip.count : "")
                                        color: agentChip.dim ? root.theme.subtext0 : agentChip.tint
                                        font.pixelSize: 9; font.bold: true
                                    }
                                }

                                // Detail koneksi Hermes (pesan bridge mentah) cukup sebagai tooltip.
                                MouseArea {
                                    id: chipHover
                                    anchors.fill: parent
                                    hoverEnabled: agentChip.isHermes
                                }
                                ToolTip {
                                    visible: agentChip.isHermes && chipHover.containsMouse
                                    delay: 300
                                    text: !root.hermesConnected ? (root.hermesStatusMessage || "Menunggu koneksi Hermes…")
                                          : (root.hermesWorking ? (root.activeDetail || "Mengerjakan task…") : "Siap menerima prompt & task")
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        // Auto-izinkan perintah baca-saja (git status, ls, cat, …)
                        Row {
                            spacing: 6
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Auto-izin"
                                color: root.theme.subtext0; font.pixelSize: 9; font.bold: true
                            }
                            ToolTip.visible: autoSafeHover.hovered
                            ToolTip.delay: 400
                            ToolTip.text: "Izinkan otomatis perintah baca-saja (git status, ls, cat, …)"
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 26; height: 14; radius: 7
                                color: settings.autoSafe ? Qt.darker(root.theme.accent, 1.4) : root.theme.surface1
                                border.color: settings.autoSafe ? root.theme.accent : root.theme.surface2
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Rectangle {
                                    width: 10; height: 10; radius: 5
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: settings.autoSafe ? parent.width - width - 2 : 2
                                    color: settings.autoSafe ? "#ffffff" : root.theme.subtext0
                                    Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                }
                            }
                            TapHandler { onTapped: settings.autoSafe = !settings.autoSafe }
                            HoverHandler { id: autoSafeHover; cursorShape: Qt.PointingHandCursor }
                        }
                    }

                    // Baris 2: sesi aktif (maks. 2, yang paling butuh perhatian dulu)
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 4

                        Repeater {
                            model: agentTab.sortedSessions.slice(0, 2)

                            Rectangle {
                                id: sessRow
                                required property var modelData
                                readonly property color tint: root.stateColor(modelData.state)
                                Layout.fillWidth: true
                                Layout.preferredHeight: 38
                                radius: 8
                                color: root.theme.surface0
                                border.color: modelData.state === "waiting" ? "#f97316" : root.theme.surface1

                                // Garis status di kiri
                                Rectangle {
                                    x: 0; y: 8
                                    width: 3; height: parent.height - 16; radius: 1.5
                                    color: sessRow.tint
                                }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 10
                                    anchors.rightMargin: 10
                                    spacing: 8

                                    SourceLogo { kind: sessRow.modelData.agent; size: 18 }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 1
                                        Text {
                                            text: sessRow.modelData.project || "?"
                                            color: root.theme.text; font.pixelSize: 11; font.bold: true
                                            elide: Text.ElideRight; Layout.fillWidth: true
                                        }
                                        Text {
                                            visible: text !== ""
                                            text: sessRow.modelData.detail || sessRow.modelData.prompt || ""
                                            color: root.theme.subtext1; font.pixelSize: 9
                                            font.family: "JetBrains Mono, monospace"
                                            elide: Text.ElideMiddle; Layout.fillWidth: true
                                        }
                                    }

                                    Rectangle {
                                        implicitWidth: sessState.implicitWidth + 12
                                        implicitHeight: 16
                                        radius: 8
                                        color: Qt.rgba(sessRow.tint.r, sessRow.tint.g, sessRow.tint.b, 0.15)
                                        Text {
                                            id: sessState
                                            anchors.centerIn: parent
                                            text: root.stateLabel(sessRow.modelData.state)
                                            color: sessRow.tint; font.pixelSize: 8; font.bold: true
                                        }
                                    }

                                    Text {
                                        // currentTimeSecs: dependensi agar "x dtk" ikut berdetak
                                        text: root.currentTimeSecs !== "" ? root.agoText(sessRow.modelData.updated) : ""
                                        color: root.theme.overlay; font.pixelSize: 8
                                        Layout.preferredWidth: 34
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }
                            }
                        }

                        Text {
                            visible: root.agentSessions.length > 2
                            text: "+" + (root.agentSessions.length - 2) + " sesi lainnya"
                            color: root.theme.subtext0; font.pixelSize: 9
                            Layout.leftMargin: 4
                        }

                        Rectangle {
                            visible: root.agentSessions.length === 0
                            Layout.fillWidth: true
                            Layout.preferredHeight: 38
                            radius: 8
                            color: "transparent"
                            border.color: root.theme.surface1
                            Text {
                                anchors.centerIn: parent
                                text: "Belum ada sesi Claude Code / OpenCode yang aktif"
                                color: root.theme.overlay; font.pixelSize: 10
                            }
                        }
                    }

                    // Baris 3: riwayat task & keputusan izin, terbaru di atas.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        Text { text: "Riwayat"; color: root.theme.subtext1; font.pixelSize: 10; font.bold: true }
                        Item { Layout.fillWidth: true }
                        Text {
                            readonly property var today: (activity.daily || {})[root.dayKey(new Date())]
                            visible: !!today
                            text: today ? "Hari ini  " + today.done + " selesai · " + today.perms + " izin" + (today.errors ? " · " + today.errors + " gagal" : "") : ""
                            color: root.theme.subtext0; font.pixelSize: 9
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 8
                        color: root.theme.mantle
                        clip: true

                        ListView {
                            id: historyView
                            anchors.fill: parent
                            anchors.margins: 4
                            spacing: 0
                            clip: true
                            model: activity.history || []
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                            Text {
                                anchors.centerIn: parent
                                visible: historyView.count === 0
                                text: "Belum ada aktivitas tercatat"
                                color: root.theme.overlay
                                font.pixelSize: 10
                            }

                            delegate: Rectangle {
                                id: histRow
                                required property var modelData
                                readonly property color tint: root.activityColor(modelData.kind)
                                width: historyView.width - 6
                                height: 22
                                radius: 5
                                color: histHover.hovered ? root.theme.surface0 : "transparent"
                                HoverHandler { id: histHover }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 6
                                    anchors.rightMargin: 6
                                    spacing: 7
                                    Text {
                                        text: root.clockText(histRow.modelData.t)
                                        color: root.theme.overlay
                                        font.pixelSize: 9
                                        font.family: "JetBrains Mono, monospace"
                                        Layout.preferredWidth: 30
                                    }
                                    SourceLogo { kind: histRow.modelData.agent || "hermes"; size: 12 }
                                    Text {
                                        text: histRow.modelData.project || "—"
                                        color: root.theme.textDim; font.pixelSize: 9; font.bold: true
                                        elide: Text.ElideRight
                                        Layout.preferredWidth: 78
                                    }
                                    Rectangle {
                                        Layout.preferredWidth: 72
                                        implicitHeight: 15
                                        radius: 7.5
                                        color: Qt.rgba(histRow.tint.r, histRow.tint.g, histRow.tint.b, 0.14)
                                        Text {
                                            anchors.centerIn: parent
                                            width: parent.width - 8
                                            horizontalAlignment: Text.AlignHCenter
                                            text: root.activityLabel(histRow.modelData.kind)
                                            color: histRow.tint
                                            font.pixelSize: 8; font.bold: true
                                            elide: Text.ElideRight
                                        }
                                    }
                                    Text {
                                        text: histRow.modelData.text
                                        color: root.theme.subtext1
                                        font.pixelSize: 9
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    Text {
                                        visible: !!histRow.modelData.dur
                                        text: histRow.modelData.dur || ""
                                        color: root.theme.subtext0; font.pixelSize: 8
                                    }
                                }
                            }
                        }

                        // Fade bawah: baris terakhir tidak terlihat terpotong di tepi.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 18
                            radius: 8
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: "transparent" }
                                GradientStop { position: 1.0; color: root.theme.mantle }
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
                                Text { text: root.sysUptime; color: root.theme.text; font.pixelSize: 12; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
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
                                Text { text: "$" + root.usageCost.toFixed(2); color: root.theme.text; font.pixelSize: 13; font.bold: true }
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
                                Text { text: "" + root.usage60dRequests; color: root.theme.text; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Total Biaya (60d)"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: "$" + root.usage60dCost.toFixed(2); color: root.theme.text; font.pixelSize: 13; font.bold: true }
                            }
                        }

                        Rectangle {
                            Layout.fillWidth: true; height: 46; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            Column {
                                anchors.centerIn: parent; spacing: 1
                                Text { text: "Total Tokens (60d)"; color: root.theme.subtext0; font.pixelSize: 9 }
                                Text { text: root.formatTokens(root.usage60dTokens); color: root.theme.text; font.pixelSize: 13; font.bold: true }
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
                                border.color: "transparent"

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 8
                                    anchors.rightMargin: 8

                                    Rectangle {
                                        width: 6; height: 6; radius: 3
                                        color: modelData.name.indexOf("claude") !== -1 ? root.theme.subtext1 : root.theme.subtext1
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
                                        color: root.theme.text
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
                                color: !root.usageLoaded ? root.theme.subtext0 : root.theme.subtext0
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

                // TAB 4: QUICK TOOLS — tile aplikasi (robot berwarna per aplikasi), audio, suara notifikasi.
                ColumnLayout {
                    visible: root.activeTab === "tools"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.alignment: Qt.AlignTop
                    spacing: 8

                    Text { text: "Buka cepat"; color: root.theme.subtext1; font.pixelSize: 10; font.bold: true }

                    GridLayout {
                        columns: 4
                        Layout.fillWidth: true
                        columnSpacing: 6

                        Repeater {
                            model: [
                                {key: "editor", label: "VS Code", sub: "Editor kode", bot: "strobi"},
                                {key: "terminal", label: "Kitty", sub: "Terminal", bot: "white"},
                                {key: "files", label: "File", sub: "Jelajahi folder", bot: "amber"},
                                {key: "screenshot", label: "Screenshot", sub: "Pilih area", bot: "green"}
                            ]

                            Rectangle {
                                id: toolTile
                                required property var modelData
                                readonly property color tint: toolBot.neonColor
                                Layout.fillWidth: true
                                Layout.preferredWidth: 1
                                implicitHeight: 82
                                radius: 12
                                color: toolHover.containsMouse ? Qt.tint(root.theme.surface0, Qt.rgba(tint.r, tint.g, tint.b, 0.14)) : root.theme.surface0
                                border.color: toolHover.containsMouse ? Qt.rgba(tint.r, tint.g, tint.b, 0.6) : root.theme.surface1
                                scale: toolHover.pressed ? 0.96 : 1.0
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Behavior on border.color { ColorAnimation { duration: 150 } }
                                Behavior on scale { NumberAnimation { duration: 90 } }

                                Column {
                                    anchors.centerIn: parent
                                    spacing: 3
                                    QCoreBot {
                                        id: toolBot
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        size: 34
                                        avatarType: toolTile.modelData.bot
                                        expression: toolHover.containsMouse ? "happy" : "proud"
                                        targetLookX: root.cursorLookX
                                        targetLookY: root.cursorLookY
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: toolTile.modelData.label
                                        color: root.theme.text; font.pixelSize: 10; font.bold: true
                                    }
                                    Text {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: toolTile.modelData.sub
                                        color: root.theme.subtext0; font.pixelSize: 8
                                    }
                                }

                                MouseArea {
                                    id: toolHover
                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: root.launchTool(toolTile.modelData.key)
                                }
                            }
                        }
                    }

                    Text { text: "Suara"; color: root.theme.subtext1; font.pixelSize: 10; font.bold: true; topPadding: 2 }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        // Volume speaker: tombol bersegmen − · Mute · +
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: 40
                            radius: 10
                            color: root.theme.surface0
                            border.color: root.theme.surface1
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 6; spacing: 8
                                Image {
                                    source: "file:///usr/share/icons/Papirus/24x24/actions/audio-volume-high.svg"
                                    sourceSize: Qt.size(18, 18)
                                }
                                Column {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text { text: "Volume"; color: root.theme.text; font.pixelSize: 10; font.bold: true }
                                    Text { text: "PipeWire"; color: root.theme.subtext0; font.pixelSize: 8 }
                                }
                                Rectangle {
                                    implicitWidth: volSeg.implicitWidth
                                    implicitHeight: 28
                                    radius: 14
                                    color: root.theme.surface1
                                    clip: true
                                    Row {
                                        id: volSeg
                                        Repeater {
                                            model: [{key: "volume_down", label: "−5%"}, {key: "volume_mute", label: "Mute"}, {key: "volume_up", label: "+5%"}]
                                            Rectangle {
                                                required property var modelData
                                                required property int index
                                                width: index === 1 ? 50 : 42; height: 28
                                                color: segHover.containsMouse ? root.theme.surface2 : "transparent"
                                                Rectangle {
                                                    visible: parent.index > 0
                                                    width: 1; height: 14
                                                    anchors.verticalCenter: parent.verticalCenter
                                                    color: root.theme.overlay
                                                    opacity: 0.4
                                                }
                                                Text {
                                                    anchors.centerIn: parent
                                                    text: parent.modelData.label
                                                    color: parent.index === 1 ? root.theme.textDim : "#ffffff"
                                                    font.pixelSize: 10; font.bold: true
                                                }
                                                MouseArea {
                                                    id: segHover
                                                    anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                    onClicked: root.launchTool(parent.modelData.key)
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Suara notifikasi QBot (izin masuk, task selesai/gagal)
                        Rectangle {
                            Layout.preferredWidth: 150
                            implicitHeight: 40
                            radius: 10
                            color: root.theme.surface0
                            border.color: root.theme.surface1
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 10; spacing: 6
                                Column {
                                    Layout.fillWidth: true
                                    spacing: 0
                                    Text { text: "Notifikasi"; color: root.theme.text; font.pixelSize: 10; font.bold: true }
                                    Text { text: settings.sound ? "Bunyi menyala" : "Senyap"; color: root.theme.subtext0; font.pixelSize: 8 }
                                }
                                Rectangle {
                                    width: 30; height: 16; radius: 8
                                    color: settings.sound ? Qt.darker(root.theme.accent, 1.4) : root.theme.surface1
                                    border.color: settings.sound ? root.theme.accent : root.theme.surface2
                                    Behavior on color { ColorAnimation { duration: 150 } }
                                    Rectangle {
                                        width: 12; height: 12; radius: 6
                                        anchors.verticalCenter: parent.verticalCenter
                                        x: settings.sound ? parent.width - width - 2 : 2
                                        color: settings.sound ? "#ffffff" : root.theme.subtext0
                                        Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                    }
                                }
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

                    Item { Layout.fillWidth: true; Layout.fillHeight: true }
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
                        border.color: "transparent"
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
                                border.color: modelData.is_active ? root.theme.surface2 : root.theme.surface1
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
                                            color: root.theme.surface2
                                            Text {
                                                id: actLbl
                                                anchors.centerIn: parent
                                                text: "ACTIVE"
                                                color: root.theme.textDim
                                                font.pixelSize: 8
                                                font.bold: true
                                            }
                                        }

                                        // Branch Pill
                                        Rectangle {
                                            implicitWidth: bLbl.implicitWidth + 8
                                            height: 14
                                            radius: 3
                                            color: root.theme.surface1
                                            border.color: root.theme.surface2
                                            border.width: 1
                                            Text {
                                                id: bLbl
                                                anchors.centerIn: parent
                                                text: modelData.branch || "master"
                                                color: root.theme.textDim
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
                                            color: modelData.commits_today > 0 ? root.theme.surface1 : root.theme.surface1
                                            border.color: modelData.commits_today > 0 ? root.theme.surface2 : root.theme.surface2
                                            border.width: 1
                                            Text {
                                                id: cTodayLbl
                                                anchors.centerIn: parent
                                                text: modelData.commits_today > 0 ? (modelData.commits_today + " commit hari ini") : "0 commit"
                                                color: modelData.commits_today > 0 ? root.theme.textDim : root.theme.subtext0
                                                font.pixelSize: 8
                                                font.bold: true
                                            }
                                        }

                                        // Clean / Dirty Status
                                        Text {
                                            text: modelData.modified > 0 ? ("+" + modelData.modified + " modif") : "✓ clean"
                                            color: modelData.modified > 0 ? root.theme.textDim : root.theme.subtext0
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
                                            color: stgHover.containsMouse ? root.theme.surface2 : root.theme.surface1
                                            border.color: root.theme.surface2
                                            border.width: 1

                                            RowLayout {
                                                id: stgRow
                                                anchors.centerIn: parent
                                                spacing: 4
                                                Text {
                                                    text: "Staging"
                                                    color: root.theme.textDim
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
                                            color: prodHover.containsMouse ? root.theme.surface2 : root.theme.surface1
                                            border.color: root.theme.surface2
                                            border.width: 1

                                            RowLayout {
                                                id: prodRow
                                                anchors.centerIn: parent
                                                spacing: 4
                                                Text {
                                                    text: "Production"
                                                    color: root.theme.textDim
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
                        border.color: "transparent"
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
                                border.color: devRow.anyRunning ? "transparent" : root.theme.surface1
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
                                        color: devRow.php.running ? root.theme.surface1 : root.theme.surface0
                                        border.color: devRow.php.running ? root.theme.surface2 : root.theme.surface2
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "serve"
                                            color: devRow.php.running ? root.theme.textDim : root.theme.subtext1
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
                                        color: devRow.npm.running ? root.theme.surface1 : root.theme.surface0
                                        border.color: devRow.npm.running ? root.theme.surface2 : root.theme.surface2
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "npm dev"
                                            color: devRow.npm.running ? root.theme.textDim : root.theme.subtext1
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
                                                return devStartHover.containsMouse ? root.theme.surface2 : root.theme.surface1;
                                            return root.theme.surface0;
                                        }
                                        border.color: devRow.availableCount > devRow.runningCount ? root.theme.surface2 : root.theme.surface1
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "Start"
                                            color: devRow.availableCount > devRow.runningCount ? root.theme.textDim : root.theme.overlay
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
                                                return devStopHover.containsMouse ? root.theme.surface2 : root.theme.surface1;
                                            return root.theme.surface0;
                                        }
                                        border.color: devRow.runningCount > 0 ? root.theme.surface2 : root.theme.surface1
                                        border.width: 1
                                        Text {
                                            anchors.centerIn: parent
                                            text: "Stop"
                                            color: devRow.runningCount > 0 ? root.theme.subtext1 : root.theme.overlay
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
                    id: ivTab
                    visible: root.activeTab === "interview"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    Layout.bottomMargin: 4
                    spacing: 8

                    readonly property color stateTint: root.interviewState === "listening" ? (root.interviewSpeaking ? "#ef4444" : "#22c55e")
                                                     : root.interviewState === "loading" ? "#f59e0b"
                                                     : root.interviewState === "error" ? "#ef4444" : root.theme.overlay
                    // Layar sambutan selama belum ada sesi, transkrip, atau jawaban.
                    readonly property bool intro: !root.interviewRunning && root.interviewTranscript.length === 0
                                                  && root.interviewAnswers.length === 0
                    readonly property string profilePath: (root.interviewProfile || "~/.config/hermes-coucou/interview_profile.md")
                                                          .replace(/^\/home\/[^\/]+/, "~")

                    // Bar kontrol: status · sumber · auto · jawab · mulai/stop
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        Rectangle {
                            width: 8; height: 8; radius: 4
                            color: ivTab.stateTint
                            SequentialAnimation on opacity {
                                running: root.interviewRunning
                                loops: Animation.Infinite
                                onRunningChanged: if (!running) parent.opacity = 1
                                NumberAnimation { to: 0.3; duration: 650; easing.type: Easing.InOutSine }
                                NumberAnimation { to: 1.0; duration: 650; easing.type: Easing.InOutSine }
                            }
                        }
                        Text {
                            Layout.fillWidth: true
                            elide: Text.ElideRight
                            color: root.interviewState === "error" ? "#fca5a5" : root.theme.text
                            font.pixelSize: 10; font.bold: true
                            text: root.interviewState === "listening"
                                  ? (root.interviewThinking ? "Menyusun jawaban…" : root.interviewSpeaking ? "Pewawancara berbicara…" : "Mendengarkan")
                                  : root.interviewState === "loading" ? "Menyiapkan…"
                                  : root.interviewState === "error" ? (root.interviewMessage || "Gagal memulai")
                                  : "Siap"
                            ToolTip.visible: ivStatusHover.hovered && !!root.interviewMessage
                            ToolTip.text: root.interviewMessage
                            HoverHandler { id: ivStatusHover }
                        }

                        // Meter level audio: bukti suara benar-benar tertangkap
                        Row {
                            visible: root.interviewRunning
                            spacing: 2
                            Repeater {
                                model: 5
                                Rectangle {
                                    required property int index
                                    anchors.bottom: parent.bottom
                                    width: 3; radius: 1.5
                                    height: 4 + 10 * Math.max(0, Math.min(1, root.interviewLevel * 1.6 - index * 0.2))
                                    color: root.interviewSpeaking ? "#ef4444" : "#22c55e"
                                    Behavior on height { NumberAnimation { duration: 100 } }
                                }
                            }
                        }

                        // Sumber audio (terkunci selama sesi berjalan)
                        Rectangle {
                            implicitWidth: ivSrcRow.implicitWidth + 4
                            implicitHeight: 24
                            radius: 12
                            color: root.theme.surface0
                            border.color: root.theme.surface1
                            opacity: root.interviewRunning ? 0.6 : 1
                            Row {
                                id: ivSrcRow
                                anchors.centerIn: parent
                                spacing: 2
                                Repeater {
                                    model: [{ key: "system", label: "Online" }, { key: "mic", label: "Tatap muka" }]
                                    delegate: Rectangle {
                                        required property var modelData
                                        readonly property bool chosen: root.interviewSource === modelData.key
                                        width: ivSrcTxt.implicitWidth + 16; height: 20; radius: 10
                                        color: chosen ? root.theme.surface2 : "transparent"
                                        Text {
                                            id: ivSrcTxt
                                            anchors.centerIn: parent
                                            text: parent.modelData.label
                                            color: parent.chosen ? "#ffffff" : root.theme.subtext0
                                            font.pixelSize: 9; font.bold: true
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            enabled: !root.interviewRunning
                                            onClicked: root.interviewSource = parent.modelData.key
                                        }
                                    }
                                }
                            }
                        }

                        // Auto: saran jawaban otomatis setiap pertanyaan selesai
                        Row {
                            spacing: 5
                            Text { anchors.verticalCenter: parent.verticalCenter; text: "Auto"; color: root.theme.subtext0; font.pixelSize: 9; font.bold: true }
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 26; height: 14; radius: 7
                                color: root.interviewAuto ? Qt.darker(root.theme.accent, 1.4) : root.theme.surface1
                                border.color: root.interviewAuto ? root.theme.accent : root.theme.surface2
                                Rectangle {
                                    width: 10; height: 10; radius: 5
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: root.interviewAuto ? parent.width - width - 2 : 2
                                    color: root.interviewAuto ? "#ffffff" : root.theme.subtext0
                                    Behavior on x { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                                }
                            }
                            ToolTip.visible: ivAutoHover.hovered
                            ToolTip.delay: 400
                            ToolTip.text: "Buat saran jawaban otomatis setiap pertanyaan selesai"
                            HoverHandler { id: ivAutoHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    root.interviewAuto = !root.interviewAuto;
                                    if (root.interviewRunning)
                                        sendBridgeCommand({ action: "interview_auto", enabled: root.interviewAuto });
                                }
                            }
                        }

                        Rectangle {
                            visible: root.interviewRunning
                            readonly property bool usable: root.interviewTranscript.length > 0 && !root.interviewThinking
                            implicitWidth: 52; implicitHeight: 24; radius: 12
                            color: usable && jawabHover.containsMouse ? root.theme.surface2 : root.theme.surface1
                            opacity: usable ? 1 : 0.45
                            Text { anchors.centerIn: parent; text: "Jawab"; color: "#ffffff"; font.pixelSize: 9; font.bold: true }
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
                            implicitWidth: ivStartTxt.implicitWidth + 22
                            implicitHeight: 24
                            radius: 12
                            color: root.interviewRunning ? (ivStartHover.containsMouse ? "#991b1b" : "#7f1d1d")
                                                         : (ivStartHover.containsMouse ? "#fbbf24" : "#f59e0b")
                            Text {
                                id: ivStartTxt
                                anchors.centerIn: parent
                                text: root.interviewRunning ? "■  Stop" : "●  Mulai"
                                color: root.interviewRunning ? "#fecaca" : "#1c1917"
                                font.pixelSize: 9; font.bold: true
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

                    // Sambutan: cara pakai dalam tiga langkah
                    ColumnLayout {
                        visible: ivTab.intro
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 8

                        Column {
                            Layout.fillWidth: true
                            spacing: 2
                            Text { text: "Interview Assist"; color: "#ffffff"; font.pixelSize: 15; font.bold: true }
                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: "QBot mendengarkan pertanyaan pewawancara, lalu menyarankan jawaban sesuai profilmu."
                                color: root.theme.subtext1; font.pixelSize: 10
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 6
                            Repeater {
                                model: [
                                    {n: "1", title: "Pilih sumber", body: "Online untuk Zoom / Meet / Discord, Tatap muka memakai mic."},
                                    {n: "2", title: "Pakai headset", body: "Supaya suaramu sendiri tidak ikut terekam dan ditranskrip."},
                                    {n: "3", title: "Isi profil / CV", body: ivTab.profilePath}
                                ]
                                Rectangle {
                                    required property var modelData
                                    Layout.fillWidth: true
                                    Layout.preferredWidth: 1
                                    Layout.fillHeight: true
                                    radius: 10
                                    color: root.theme.surface0
                                    border.color: root.theme.surface1
                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        spacing: 4
                                        Rectangle {
                                            width: 20; height: 20; radius: 10
                                            color: Qt.rgba(0.96, 0.62, 0.04, 0.18)
                                            Text { anchors.centerIn: parent; text: modelData.n; color: "#fbbf24"; font.pixelSize: 10; font.bold: true }
                                        }
                                        Text { text: modelData.title; color: root.theme.text; font.pixelSize: 10; font.bold: true }
                                        Text {
                                            Layout.fillWidth: true
                                            text: modelData.body
                                            color: root.theme.subtext0
                                            font.pixelSize: 9
                                            font.family: modelData.n === "3" ? "JetBrains Mono, monospace" : "Inter, sans-serif"
                                            // Path boleh dipotong di mana saja; kalimat biasa per kata.
                                            wrapMode: modelData.n === "3" ? Text.WrapAnywhere : Text.Wrap
                                        }
                                        Item { Layout.fillHeight: true }
                                    }
                                }
                            }
                        }
                    }

                    // Sesi: kartu saran jawaban (kiri, utama) + transkrip (kanan)
                    RowLayout {
                        visible: !ivTab.intro
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        spacing: 6

                        // Kartu saran jawaban (terbaru; ‹ › untuk riwayat)
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: 10
                            color: root.theme.surface0
                            border.color: root.interviewThinking ? "#f59e0b" : root.theme.surface1
                            Behavior on border.color { ColorAnimation { duration: 200 } }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 10
                                spacing: 6

                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Rectangle {
                                        implicitWidth: ivAnsLbl.implicitWidth + 12
                                        implicitHeight: 16
                                        radius: 8
                                        color: Qt.rgba(0.96, 0.62, 0.04, 0.16)
                                        Text { id: ivAnsLbl; anchors.centerIn: parent; text: "Saran jawaban"; color: "#fbbf24"; font.pixelSize: 8; font.bold: true }
                                    }
                                    Item { Layout.fillWidth: true }
                                    Text {
                                        visible: root.interviewAnswers.length > 1
                                        text: "‹"
                                        color: root.interviewAnswerIndex < root.interviewAnswers.length - 1 ? root.theme.textDim : root.theme.surface2
                                        font.pixelSize: 14; font.bold: true
                                        MouseArea { anchors.fill: parent; anchors.margins: -5; cursorShape: Qt.PointingHandCursor
                                            onClicked: if (root.interviewAnswerIndex < root.interviewAnswers.length - 1) root.interviewAnswerIndex += 1 }
                                    }
                                    Text {
                                        visible: root.interviewAnswers.length > 1
                                        text: (root.interviewAnswerIndex + 1) + " / " + root.interviewAnswers.length
                                        color: root.theme.subtext0; font.pixelSize: 9
                                    }
                                    Text {
                                        visible: root.interviewAnswers.length > 1
                                        text: "›"
                                        color: root.interviewAnswerIndex > 0 ? root.theme.textDim : root.theme.surface2
                                        font.pixelSize: 14; font.bold: true
                                        MouseArea { anchors.fill: parent; anchors.margins: -5; cursorShape: Qt.PointingHandCursor
                                            onClicked: if (root.interviewAnswerIndex > 0) root.interviewAnswerIndex -= 1 }
                                    }
                                }

                                // Pertanyaan yang dijawab
                                Text {
                                    visible: !!root.interviewShownAnswer && !!root.interviewShownAnswer.question
                                    Layout.fillWidth: true
                                    text: root.interviewShownAnswer ? "“" + root.interviewShownAnswer.question + "”" : ""
                                    color: root.theme.subtext1
                                    font.pixelSize: 10; font.italic: true
                                    wrapMode: Text.Wrap
                                    maximumLineCount: 2
                                    elide: Text.ElideRight
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
                                        color: root.interviewShownAnswer && root.interviewShownAnswer.error ? "#fca5a5"
                                             : root.interviewShownAnswer ? root.theme.text : root.theme.subtext0
                                        selectionColor: root.theme.surface2
                                        font.pixelSize: root.interviewShownAnswer ? 14 : 11
                                        text: {
                                            let a = root.interviewShownAnswer;
                                            if (a) return a.error || a.text || "…";
                                            if (root.interviewThinking) return "Menyusun jawaban…";
                                            return "Menunggu pertanyaan dari pewawancara…";
                                        }
                                    }
                                }
                            }
                        }

                        // Transkrip lawan bicara (scroll otomatis ke bawah)
                        Rectangle {
                            Layout.preferredWidth: 150
                            Layout.fillHeight: true
                            radius: 10
                            color: root.theme.mantle
                            border.color: root.theme.surface0

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: 8
                                spacing: 4
                                Text { text: "Transkrip"; color: root.theme.subtext1; font.pixelSize: 9; font.bold: true }

                                ListView {
                                    id: ivTranscriptView
                                    Layout.fillWidth: true
                                    Layout.fillHeight: true
                                    spacing: 6
                                    clip: true
                                    model: root.interviewTranscript
                                    onCountChanged: positionViewAtEnd()

                                    Text {
                                        anchors.centerIn: parent
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        wrapMode: Text.Wrap
                                        visible: root.interviewTranscript.length === 0
                                        text: "Ucapan pewawancara muncul di sini"
                                        color: root.theme.overlay
                                        font.pixelSize: 9
                                    }

                                    delegate: Column {
                                        required property var modelData
                                        width: ivTranscriptView.width
                                        spacing: 1
                                        Text {
                                            text: modelData.time.slice(0, 5)
                                            color: root.theme.overlay
                                            font.pixelSize: 8
                                            font.family: "JetBrains Mono, monospace"
                                        }
                                        Text {
                                            width: parent.width
                                            wrapMode: Text.Wrap
                                            color: root.theme.textDim
                                            font.pixelSize: 10
                                            textFormat: Text.PlainText
                                            text: modelData.text
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

            } // Tutup Panel Kanan (ColumnLayout)
        } // Tutup RowLayout (Panel Kiri + Panel Kanan)
    }
}

        // Sapaan pembuka saat QBot pertama kali aktif (Welcome Wave)
        Timer {
            id: welcomeWaveTimer
            interval: 600
            repeat: false
            running: true
            property int tries: 0
            onTriggered: {
                // Tunggu settings & riwayat termuat (biasanya < 1 dtk).
                if ((!root.settingsReady || !root.activityReady) && tries++ < 10) { restart(); return; }
                root.greetText = root.greetingTitle();
                let today = root.dayKey(new Date());
                let summary = settings.greetedDay !== today ? root.lastDaySummary() : "";
                settings.greetedDay = today;
                if (summary) {
                    // Sekali per hari: pill yang terbaca walau island tertutup.
                    root.showNotification("greet", {title: root.greetText, detail: summary, color: "#22c55e", expression: "wave"});
                    return;
                }
                root.avatarExpression = "wave";
                root.currentStatus = root.greetText;
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
            if (root.currentStatus === root.greetText && !root.isNotifying) root.restoreBaseline();
        }
    }

    // Pill sapaan + ringkasan harian: cukup lama untuk dibaca.
    Timer {
        id: greetNotifyTimer
        interval: 7000
        repeat: false
        onTriggered: {
            if (root.notifyType === "greet") {
                root.isNotifying = false;
                root.notifyType = "";
                root.restoreBaseline();
            } else if (root.currentStatus === root.greetText) {
                root.restoreBaseline();
            }
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
