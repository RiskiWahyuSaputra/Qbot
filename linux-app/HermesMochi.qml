import QtQml
import QtQuick
import QtQuick.Effects
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Quickshell.Services.Mpris
import Quickshell.Services.Pipewire
import Quickshell.Services.UPower
import Quickshell.Bluetooth

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
    onIslandExpandedChanged: if (!islandExpanded && !quickNote && notifyType !== "request" && notifyType !== "approval") kbdMode = false
    onNotifyTypeChanged: if (notifyType !== "request" && notifyType !== "approval" && !islandExpanded && !quickNote) kbdMode = false
    property bool isNotifying: false
    property string notifyType: "" // "done" | "approval"
    property string activeTab: "notes" // Default tab Catatan; dipulihkan dari settings saat dimuat
    onActiveTabChanged: if (settingsReady) settings.tab = activeTab

    // Preferensi pengguna, tersimpan di ~/.config/hermes-coucou/settings.json
    // (bertahan setelah restart, tidak seperti PersistentProperties).
    property bool settingsReady: false
    // Tab dikelompokkan supaya navigasi muat di island.
    readonly property var tabGroups: [
        {key: "agent", label: "Agent", tabs: [{key: "agent", label: "Agent"}]},
        {key: "work", label: "Kerja", tabs: [{key: "dev", label: "Dev Server"}]},
        {key: "system", label: "Sistem", tabs: [{key: "status", label: "Status"}, {key: "tools", label: "Tools"}]},
        {key: "notes", label: "Catatan", tabs: [{key: "notes", label: "Catatan"}]}
    ]
    readonly property var tabKeys: ["agent", "dev", "status", "tools", "notes", "music"]
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

    function activityGlyph(kind) {
        if (kind === "start") return "→";
        if (kind === "error" || kind === "deny") return "✕";
        return "✓";
    }
    function activityLabel(kind) {
        return {start: "Task diterima", done: "Selesai", error: "Gagal", allow: "Diizinkan", auto: "Auto-izin",
                deny: "Ditolak", always: "Selalu diizinkan", answer: "Dijawab"}[kind] || kind;
    }

    function activityColor(kind) {
        if (kind === "error" || kind === "deny") return "#ef4444";
        if (kind === "done") return "#22c55e";
        if (kind === "start") return "#38bdf8";
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
                     overlay: "#404040", subtext0: "#848484", subtext1: "#a3a3a3", textDim: "#d4d4d4", text: "#fafafa", accent: "#ffffff"},
        zinc:       {label: "Zinc", base: "#0a0a0c", mantle: "#121215", surface0: "#18181b", surface1: "#27272a", surface2: "#3f3f46",
                     overlay: "#52525b", subtext0: "#8f8f96", subtext1: "#a4a4ad", textDim: "#d4d4d8", text: "#f4f4f5", accent: "#38bdf8"},
        catppuccin: {label: "Catppuccin", base: "#11111b", mantle: "#181825", surface0: "#1e1e2e", surface1: "#313244", surface2: "#45475a",
                     overlay: "#585b70", subtext0: "#969cb6", subtext1: "#abb3ce", textDim: "#bac2de", text: "#cdd6f4", accent: "#cba6f7"},
        tokyonight: {label: "Tokyo Night", base: "#16161e", mantle: "#1a1b26", surface0: "#1f2335", surface1: "#292e42", surface2: "#3b4261",
                     overlay: "#545c7e", subtext0: "#8e96bf", subtext1: "#a2acd6", textDim: "#a9b1d6", text: "#c0caf5", accent: "#7aa2f7"},
        gruvbox:    {label: "Gruvbox", base: "#1d2021", mantle: "#282828", surface0: "#32302f", surface1: "#3c3836", surface2: "#504945",
                     overlay: "#665c54", subtext0: "#b1a28a", subtext1: "#c9b99b", textDim: "#d5c4a1", text: "#ebdbb2", accent: "#fabd2f"},
        nord:       {label: "Nord", base: "#242933", mantle: "#2e3440", surface0: "#3b4252", surface1: "#434c5e", surface2: "#4c566a",
                     overlay: "#616e88", subtext0: "#b6becc", subtext1: "#d1d8e4", textDim: "#d8dee9", text: "#eceff4", accent: "#88c0d0"}
    })
    readonly property var themeNames: ["noir", "zinc", "catppuccin", "tokyonight", "gruvbox", "nord"]
    readonly property var theme: themePresets[settings.theme] || themePresets.noir

    function cycleTheme() {
        let i = themeNames.indexOf(settings.theme);
        settings.theme = themeNames[(i + 1) % themeNames.length];
    }

    readonly property string uiFont: "Roboto"
    readonly property string monoFont: "JetBrainsMono Nerd Font"

    // HUD sistem: tampil sebentar di capsule. Mode bar bila level >= 0 (volume,
    // brightness), selain itu mode teks (charger, baterai, Bluetooth).
    property bool hudVisible: false
    property string hudIcon: ""
    property string hudText: ""
    property real hudLevel: -1
    property string hudValue: ""
    property color hudTint: theme.accent
    property bool hudDim: false
    property bool hudAlert: false             // alert tetap tampil walau aplikasi fullscreen
    property bool hudArmed: false             // keadaan awal hanya dicatat, bukan ditampilkan
    readonly property bool hudOn: hudVisible && !islandExpanded && !isNotifying && !quickNote

    // Catatan cepat: hotkey -> capsule jadi kolom teks, Enter simpan, Esc tutup (draf tetap ada).
    property bool quickNote: false
    property bool notesLoaded: false          // saveNotesToFile menulis seluruh model; jangan simpan sebelum termuat

    function openQuickNote() {
        if (notifyType === "approval" || notifyType === "request") return "ada kartu izin yang menunggu";
        if (quickNote) {
            closeQuickNote();
            return "ok";
        }
        islandExpanded = false;
        isNotifying = false;
        notifyType = "";
        hudVisible = false;
        quickNote = true;
        kbdMode = true;
        Qt.callLater(() => quickNoteField.forceActiveFocus());
        return "ok";
    }

    function closeQuickNote() {
        quickNote = false;
        kbdMode = false;
        islandCapsule.forceActiveFocus();
        quickNoteRelease.restart();
    }

    function submitQuickNote() {
        let text = quickNoteField.text.trim();
        if (!text) {
            closeQuickNote();
            return;
        }
        if (!notesLoaded) return;
        addNoteItem(text);
        quickNoteField.text = "";
        closeQuickNote();
        showHud({icon: papirusIcon("actions", "document-save"), text: "Catatan tersimpan",
                 value: noteType(text, "") === "cmd" ? "Command" : "Memo"});
    }

    // Kartu izin ditahan selama mengetik supaya huruf yang diketik tidak menjadi jawaban,
    // lalu muncul setelah keyboard dilepas compositor.
    Timer {
        id: quickNoteRelease
        interval: 150
        onTriggered: root.refreshRequestView()
    }
    // Izin yang menunggu punya batas waktu: tutup bila pengguna berhenti mengetik.
    Timer {
        id: quickNoteIdle
        interval: 20000
        running: root.quickNote && root.agentRequests.length > 0
        onTriggered: root.closeQuickNote()
    }

    function papirusIcon(group, name) {
        return "file:///usr/share/icons/Papirus/24x24/" + group + "/" + name + ".svg";
    }

    function showHud(opts) {
        hudIcon = opts.icon;
        hudText = opts.text || "";
        hudLevel = opts.level === undefined ? -1 : opts.level;
        hudValue = opts.value || "";
        hudTint = opts.tint || theme.accent;
        hudDim = !!opts.dim;
        hudAlert = !!opts.alert;
        hudVisible = true;
        hudTimer.interval = opts.duration || 1500;
        hudTimer.restart();
    }

    Timer {
        id: hudTimer
        interval: 1500
        onTriggered: root.hudVisible = false
    }
    Timer {
        interval: 3000
        running: true
        onTriggered: root.hudArmed = true
    }

    // Volume: membaca sink default PipeWire, jadi ikut bereaksi pada perubahan
    // dari mana saja (tombol keyboard lewat inir, wpctl, tab Tools, aplikasi lain).
    readonly property PwNode audioSink: Pipewire.defaultAudioSink
    readonly property bool audioReady: !!audioSink && audioSink.ready && !!audioSink.audio
    property int volumeSinkId: -1
    property real volumeLevel: 0
    property bool volumeMuted: false
    readonly property string volumeLabel: volumeMuted ? "Mute" : Math.round(volumeLevel * 100) + "%"

    // Sink baru (awal jalan, ganti perangkat) hanya dicatat; HUD muncul saat nilainya berubah.
    function syncVolume() {
        if (!audioReady) return;
        let vol = audioSink.audio.volume;
        let muted = audioSink.audio.muted;
        let changed = volumeSinkId === audioSink.id
                      && (Math.abs(vol - volumeLevel) > 0.001 || muted !== volumeMuted);
        volumeSinkId = audioSink.id;
        volumeLevel = vol;
        volumeMuted = muted;
        if (changed) {
            showHud({icon: papirusIcon("panel", "audio-volume-" + (muted ? "muted" : vol < 0.34 ? "low" : vol < 0.67 ? "medium" : "high")),
                     level: Math.min(1, vol), value: volumeLabel, dim: muted});
        }
    }
    onAudioReadyChanged: syncVolume()
    onAudioSinkChanged: syncVolume()

    PwObjectTracker { objects: root.audioSink ? [root.audioSink] : [] }
    Connections {
        target: root.audioReady ? root.audioSink.audio : null
        function onVolumeChanged() { root.syncVolume(); }
        function onMutedChanged() { root.syncVolume(); }
    }

    // Brightness: file sysfs tidak mengirim notifikasi perubahan, jadi dibaca berkala.
    property string backlightDir: ""
    property real brightnessMax: 0
    property real brightnessLevel: -1

    function syncBrightness(raw) {
        if (!(raw >= 0) || brightnessMax <= 0) return;
        let level = raw / brightnessMax;
        let changed = brightnessLevel >= 0 && Math.abs(level - brightnessLevel) > 0.002;
        brightnessLevel = level;
        if (changed && hudArmed) {
            showHud({icon: papirusIcon("apps", "brightness-systray"), level: level, value: Math.round(level * 100) + "%"});
        }
    }

    Process {
        command: ["sh", "-c", "for d in /sys/class/backlight/*; do [ -r \"$d/brightness\" ] && echo \"$d\" && cat \"$d/max_brightness\" && break; done"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                let lines = text.trim().split("\n");
                if (lines.length < 2) return;
                root.brightnessMax = Number(lines[1]) || 0;
                root.backlightDir = lines[0];
            }
        }
    }
    FileView {
        id: brightnessFile
        path: root.backlightDir ? root.backlightDir + "/brightness" : ""
        printErrors: false
        onLoaded: root.syncBrightness(Number(text().trim()))
    }
    Timer {
        interval: 250
        repeat: true
        running: root.backlightDir !== ""
        onTriggered: brightnessFile.reload()
    }

    // Baterai & charger (UPower).
    readonly property var batteryDevice: UPower.displayDevice
    readonly property bool batteryReady: !!batteryDevice && batteryDevice.ready && batteryDevice.isLaptopBattery
    readonly property var batteryAlertSteps: [20, 10, 5]
    property bool powerKnown: false
    property bool powerPlugged: false
    property int batteryAlertedAt: 101        // ambang terendah yang sudah diperingatkan

    function batteryIcon(pct, charging) {
        let step = String(Math.min(100, Math.floor(pct / 10) * 10)).padStart(3, "0");
        return papirusIcon("panel", "battery-" + step + (charging ? "-charging" : ""));
    }

    function applyPower(plugged, pct) {
        if (!powerKnown || !hudArmed) {
            powerKnown = true;
            powerPlugged = plugged;
            batteryAlertedAt = plugged ? 101 : batteryAlertSteps.reduce((low, step) => pct <= step ? step : low, 101);
            return;
        }
        if (plugged !== powerPlugged) {
            powerPlugged = plugged;
            if (plugged) batteryAlertedAt = 101;
            showHud({icon: batteryIcon(pct, plugged), text: plugged ? "Mengisi daya" : "Memakai baterai",
                     value: pct + "%", tint: plugged ? "#22c55e" : theme.accent, duration: 2500});
            if (plugged) playSound("pop");
            return;
        }
        if (plugged) return;
        if (pct > batteryAlertSteps[0]) batteryAlertedAt = 101;
        let step = batteryAlertSteps.reduce((low, s) => pct <= s ? s : low, 101);
        if (step < batteryAlertedAt) {
            batteryAlertedAt = step;
            showHud({icon: batteryIcon(pct, false), text: "Baterai lemah", value: pct + "%",
                     tint: pct <= 10 ? "#ef4444" : "#f59e0b", alert: true, duration: 5000});
            playSound("request");
        }
    }
    function syncPower() {
        if (batteryReady) applyPower(!UPower.onBattery, Math.round(batteryDevice.percentage * 100));
    }
    onBatteryReadyChanged: syncPower()
    onHudArmedChanged: syncPower()
    Connections {
        target: UPower
        function onOnBatteryChanged() { root.syncPower(); }
    }
    Connections {
        target: root.batteryDevice
        function onPercentageChanged() { root.syncPower(); }
    }

    // Bluetooth: tampil saat perangkat tersambung atau terputus.
    function applyBluetooth(name, connected, battery, icon) {
        if (!hudArmed) return;
        showHud({icon: (icon || "").indexOf("audio") === 0 ? papirusIcon("devices", "audio-headset") : papirusIcon("panel", "bluetooth-active"),
                 text: (name || "Perangkat") + (connected ? " tersambung" : " terputus"),
                 value: connected && battery >= 0 ? Math.round(battery * 100) + "%" : "",
                 dim: !connected, duration: 2500});
    }
    Instantiator {
        model: Bluetooth.devices
        delegate: Connections {
            required property BluetoothDevice modelData
            target: modelData
            function onConnectedChanged() {
                root.applyBluetooth(modelData.name || modelData.deviceName, modelData.connected,
                                    modelData.batteryAvailable ? modelData.battery : -1, modelData.icon);
            }
        }
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
            if (root.quickNote) root.closeQuickNote();
            root.kbdMode = true;
            if (root.notifyType !== "request" && root.notifyType !== "approval") {
                root.isNotifying = false;
                root.notifyType = "";
                root.islandExpanded = true;
            }
        }
        function close(): void {
            if (root.quickNote) root.closeQuickNote();
            root.kbdMode = false;
            root.islandExpanded = false;
        }
        // Ringkasan state sebagai JSON, untuk skrip / status bar.
        function status(): string {
            return JSON.stringify({expanded: root.islandExpanded, keyboard: root.kbdMode, tab: root.activeTab,
                                   notify: root.notifyType, pending: root.agentRequests.length,
                                   hermes: root.hermesConnected, sessions: root.agentSessions.length});
        }
        // Catatan cepat; panggil lagi untuk menutup.
        function note(): string {
            return root.openQuickNote();
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
        else if (key === "dev") sendBridgeCommand({ action: "dev_status" });
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
    // (Y/N), dan panel (1-4 grup, ←→ / Tab pindah tab, Esc tutup).
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
    readonly property var menuAvatars: ({agent: "white", work: "strobi", system: "green", notes: "citrus", music: "kirby"})
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

    // System Monitor State (untuk Tab Status)
    property int sysCpu: 0
    property int sysRamPercent: 0
    property string sysRamUsed: "0 GB"
    property string sysRamTotal: "0 GB"
    property string sysUptime: "-"
    property string sysKernel: "-"
    property int sysProcesses: 0
    property int sysDiskPercent: 0
    property string sysDiskUsed: "0 GB"
    property string sysDiskTotal: "0 GB"
    property string sysDiskFree: "0 GB"

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
            UiText { anchors.centerIn: parent; text: "♪"; color: "#888"; font.pixelSize: Math.round(art.height * 0.42) }
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
        if (quickNote) {
            if (type !== "approval") return;
            closeQuickNote();
        }
        if ((notifyType === "approval" || notifyType === "request") && type !== "approval") return;
        if (type === "done") playSound(opts.error ? "error" : "done");
        else if (type === "approval" || type === "agent_wait") playSound("request");
        else if (type === "task_start" || (type === "voice" && opts.expression === "wave")) playSound("pop");
        currentStatus = opts.title;
        activeDetail = opts.detail || "";
        statusColor = opts.color;
        let timers = {task_start: taskStartNotifyTimer, done: completionCollapseTimer,
                      agent_wait: agentNotifyTimer, info: infoNotifyTimer,
                      greet: greetNotifyTimer, voice: voiceNotifyTimer};
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
        if (notifyType === "approval" || quickNote) return;
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
                        "Membuat jawaban…", "Status suara diperbarui", "Memproses perintah…"];
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
        notesLoaded = true;
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

        case "DevServerDied":
            root.devServerDied(msg);
            break;

        case "DevServerStatus":
            root.devServers = Array.isArray(msg.projects) ? msg.projects : [];
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
                    root.sysDiskPercent = s.disk_percent || 0;
                    root.sysDiskUsed = s.disk_used || "0 GB";
                    root.sysDiskTotal = s.disk_total || "0 GB";
                    root.sysDiskFree = s.disk_free || "0 GB";
                } catch(e) {}
            }
        }
    }

    // Dev Server State (php artisan serve / npm run dev, dikelola bridge)
    property var devServers: []

    // Perintah suara: off | loading | standby | awake | thinking | speaking | error
    property string voiceState: "off"
    property string voiceMessage: ""
    readonly property bool voiceOn: voiceState !== "off" && voiceState !== "error"

    function setVoice(enabled) {
        settings.voice = enabled;
        sendBridgeCommand({ action: enabled ? "voice_start" : "voice_stop" });
    }

    // Tab Status ikut segar selama terbuka (sebelumnya hanya saat tab diklik).
    Timer {
        interval: 3000
        running: root.islandExpanded && !root.isNotifying && root.activeTab === "status"
        repeat: true
        onTriggered: fetchSysInfoProcess.running = true
    }

    function launchTool(name) {
        sendBridgeCommand({action: "launch", name: name});
    }

    // ---- Dev Server helpers ----
    // Server yang mati sendiri; Stop dari island tidak sampai ke sini.
    function devServerDied(msg) {
        playSound("error");
        showNotification("info", {title: "Dev server mati", detail: (msg.name || msg.project) + " · " + (msg.label || msg.service),
                                  color: "#ef4444", expression: "dizzy"});
    }

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
    readonly property bool islandMini: browserFocused && !focusedFullscreen && !islandExpanded && !isNotifying && !hudVisible && !quickNote
    readonly property bool islandHidden: focusedFullscreen && !islandExpanded
                                         && notifyType !== "approval" && notifyType !== "request"
                                         && !(hudOn && hudAlert) && !quickNote

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
            if (root.quickNote) return 440;
            if (root.islandExpanded && !root.isNotifying) return 660;
            if (root.isNotifying) return (root.notifyType === "approval" || root.notifyType === "request") ? 600 : 500;
            if (root.hudOn) return root.hudLevel >= 0 ? 240 : Math.min(360, hudRow.implicitWidth + 36);
            if (root.islandMini) return 120;
            if (root.showMiniPlayer) return Math.min(440, standbyRow.implicitWidth + 32);
            return 240;
        }

        height: {
            if (root.quickNote) return 44;
            if (root.islandExpanded && !root.isNotifying) return 300;
            if (root.notifyType === "request") return Math.min(404, requestCard.implicitHeight + 30);
            if (root.isNotifying) return (root.notifyType === "approval" || root.notifyType === "voice") ? 64 : 60;
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
                    if (root.islandMini) {
                        miniExpandTimer.restart();
                    } else if (!root.isNotifying && !root.quickNote) {
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
                visible: !root.isNotifying && !root.islandExpanded && !root.islandMini && !root.hudOn && !root.quickNote
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

                UiText {
                    visible: !root.showMiniPlayer
                    text: "QBot"
                    color: "#ffffff"
                    font.pixelSize: 14
                    font.bold: true
                    font.weight: Font.Black
                    font.family: root.uiFont
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
                        UiText {
                            id: miniTitle
                            width: parent.width
                            text: root.mediaTitle
                            color: "#ffffff"
                            elide: Text.ElideRight
                            font.pixelSize: 12; font.bold: true
                            font.family: root.uiFont
                        }
                        UiText {
                            id: miniSub
                            width: parent.width
                            text: root.currentLyric || root.mediaArtist
                            color: root.currentLyric ? root.mediaAccent : root.theme.subtext1
                            elide: Text.ElideRight
                            font.pixelSize: 11
                            font.family: root.uiFont
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

            // HUD SISTEM: bar (volume, brightness) atau teks (charger, baterai, Bluetooth).
            RowLayout {
                id: hudRow
                visible: root.hudOn
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 10

                Image {
                    Layout.preferredWidth: 18
                    Layout.preferredHeight: 18
                    sourceSize: Qt.size(18, 18)
                    source: root.hudIcon
                }
                Rectangle {
                    visible: root.hudLevel >= 0
                    Layout.fillWidth: true
                    implicitHeight: 6
                    radius: 3
                    color: root.theme.surface2
                    Rectangle {
                        height: parent.height
                        radius: 3
                        width: parent.width * Math.max(0, root.hudLevel)
                        color: root.hudDim ? root.theme.subtext0 : root.hudTint
                        Behavior on width { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                    }
                }
                UiText {
                    visible: root.hudLevel < 0
                    Layout.fillWidth: true
                    text: root.hudText
                    color: root.hudDim ? root.theme.subtext1 : root.theme.text
                    font.pixelSize: 12
                    font.bold: true
                    elide: Text.ElideRight
                }
                UiText {
                    visible: text !== ""
                    Layout.preferredWidth: root.hudLevel >= 0 ? 38 : implicitWidth
                    horizontalAlignment: Text.AlignRight
                    text: root.hudValue
                    color: root.hudDim ? root.theme.subtext1 : (root.hudLevel >= 0 ? root.theme.text : root.hudTint)
                    font.pixelSize: 12
                    font.bold: true
                }
            }

            // CATATAN CEPAT: capsule menjadi kolom teks.
            RowLayout {
                visible: root.quickNote
                anchors.fill: parent
                anchors.leftMargin: 10
                anchors.rightMargin: 10
                spacing: 8

                Image {
                    Layout.preferredWidth: 16
                    Layout.preferredHeight: 16
                    sourceSize: Qt.size(16, 16)
                    source: root.papirusIcon("actions", "document-edit")
                }
                TextField {
                    id: quickNoteField
                    renderType: Text.NativeRendering
                    font.hintingPreference: Font.PreferFullHinting
                    font.family: root.uiFont
                    font.pixelSize: 13
                    font.weight: Font.Medium
                    Layout.fillWidth: true
                    placeholderText: "Catatan cepat…"
                    placeholderTextColor: root.theme.subtext0
                    color: root.theme.text
                    background: null
                    leftPadding: 0; rightPadding: 0; topPadding: 2; bottomPadding: 2
                    onTextChanged: if (quickNoteIdle.running) quickNoteIdle.restart()
                    Keys.onReturnPressed: root.submitQuickNote()
                    Keys.onEnterPressed: root.submitQuickNote()
                    Keys.onEscapePressed: event => { root.closeQuickNote(); event.accepted = true; }
                }
                UiText {
                    readonly property bool warn: root.agentRequests.length > 0 || !root.notesLoaded
                    text: !root.notesLoaded ? "Memuat catatan…"
                        : root.agentRequests.length > 0 ? "Izin menunggu"
                        : quickNoteField.text.trim() ? (root.noteType(quickNoteField.text, "") === "cmd" ? "Command" : "Memo") + " · Enter"
                        : "Esc"
                    color: warn ? "#f97316" : root.theme.subtext0
                    font.pixelSize: 10
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
                            UiText {
                                id: srcChipTxt
                                anchors.centerIn: parent
                                text: root.agentName(root.notifySource).toUpperCase()
                                color: root.sourceColor(root.notifySource)
                                font.pixelSize: 10
                                font.bold: true
                                font.letterSpacing: 0.6
                            }
                        }

                        UiText {
                            text: root.currentStatus
                            color: root.theme.text
                            font.pixelSize: 13
                            font.weight: Font.ExtraBold
                            font.family: root.uiFont
                        }

                        Rectangle {
                            visible: root.notifyProject !== ""
                            implicitWidth: projChipTxt.implicitWidth + 10
                            implicitHeight: 15
                            radius: 4
                            color: root.theme.surface0
                            border.color: "transparent"
                            UiText {
                                id: projChipTxt
                                anchors.centerIn: parent
                                text: "▸ " + root.notifyProject
                                color: root.theme.subtext1
                                font.pixelSize: 10
                                font.bold: true
                                font.family: root.monoFont
                            }
                        }

                        Item { Layout.fillWidth: true }
                    }

                    UiText {
                        Layout.fillWidth: true
                        text: root.activeDetail
                        color: root.theme.textDim
                        font.pixelSize: 11
                        // Command approval: sampai 2 baris.
                        readonly property bool twoLines: root.notifyType === "approval" || root.notifyType === "voice"
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
                            UiText {
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

                        UiText {
                            visible: root.notifyDuration !== ""
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: "⏱ " + root.notifyDuration
                            color: root.theme.subtext0
                            font.pixelSize: 10
                            font.bold: true
                        }
                    }

                    Rectangle {
                        visible: root.notifyType === "agent_wait"
                        anchors.centerIn: parent
                        width: 44; height: 22; radius: 6
                        color: "#1c1917"
                        border.color: "#f97316"
                        UiText {
                            anchors.centerIn: parent
                            text: ">_"
                            color: "#fdba74"
                            font.pixelSize: 12
                            font.bold: true
                            font.family: root.monoFont
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
                            UiText { text: "✕"; color: root.theme.subtext1; font.pixelSize: 11; font.bold: true }
                            UiText {
                                id: rejectText
                                text: root.decisionPending ? "Sending…" : "Reject"
                                color: root.theme.subtext1
                                font.pixelSize: 12
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
                            UiText { text: "⚡"; font.pixelSize: 12 }
                            UiText {
                                id: runText
                                text: root.decisionPending ? "Sending…" : "Run"
                                color: "#000000"
                                font.pixelSize: 12
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
                                UiText {
                                    id: reqSrcTxt
                                    anchors.centerIn: parent
                                    text: root.agentName(root.notifySource).toUpperCase()
                                    color: root.sourceColor(root.notifySource)
                                    font.pixelSize: 10; font.bold: true; font.letterSpacing: 0.6
                                }
                            }
                            Rectangle {
                                visible: root.notifyProject !== ""
                                implicitWidth: reqProjTxt.implicitWidth + 10; implicitHeight: 15; radius: 4
                                color: root.theme.surface0; border.color: root.theme.surface1
                                UiText {
                                    id: reqProjTxt
                                    anchors.centerIn: parent
                                    text: "▸ " + root.notifyProject
                                    color: root.theme.subtext1
                                    font.pixelSize: 10; font.bold: true; font.family: root.monoFont
                                }
                            }
                            Rectangle {
                                visible: requestCard.question !== null && requestCard.question.header !== ""
                                implicitWidth: reqHeaderTxt.implicitWidth + 10; implicitHeight: 15; radius: 4
                                color: root.theme.surface2
                                UiText {
                                    id: reqHeaderTxt
                                    anchors.centerIn: parent
                                    text: requestCard.question ? requestCard.question.header : ""
                                    color: root.theme.textDim
                                    font.pixelSize: 10; font.bold: true
                                }
                            }
                        }
                        UiText {
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
                        UiText {
                            id: queueTxt
                            anchors.centerIn: parent
                            text: "1/" + root.agentRequests.length + " antrean"
                            color: root.theme.textDim; font.pixelSize: 10; font.bold: true
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
                    UiText {
                        id: permDetail
                        anchors.fill: parent
                        anchors.margins: 8
                        text: requestCard.req ? (requestCard.req.detail || "-") : ""
                        color: root.theme.textDim
                        font.pixelSize: 12
                        font.family: root.monoFont
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        maximumLineCount: 5
                        elide: Text.ElideRight
                    }
                }

                // ---- PERTANYAAN: teks + pilihan ----
                UiText {
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
                                        UiText {
                                            anchors.centerIn: parent
                                            text: optionRow.chosen ? "✓" : (optionRow.index + 1)
                                            color: optionRow.chosen ? root.theme.surface1 : root.theme.subtext1
                                            font.pixelSize: 10; font.bold: true
                                        }
                                    }

                                    Column {
                                        width: parent.width - 26
                                        spacing: 1
                                        UiText {
                                            width: parent.width
                                            text: optionRow.modelData.label
                                            color: root.theme.text
                                            font.pixelSize: 12; font.bold: true
                                            elide: Text.ElideRight
                                        }
                                        UiText {
                                            visible: text !== ""
                                            width: parent.width
                                            text: optionRow.modelData.description || ""
                                            color: root.theme.subtext1
                                            font.pixelSize: 10
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
                        renderType: Text.NativeRendering
                        font.hintingPreference: Font.PreferFullHinting
                        font.family: root.uiFont
                        id: requestCustomInput
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        verticalAlignment: TextInput.AlignVCenter
                        placeholderText: "Jawaban lain… (Enter untuk kirim)"
                        placeholderTextColor: root.theme.subtext0
                        color: "#ffffff"
                        font.pixelSize: 12
                        background: null
                        enabled: !root.reqSending
                        onAccepted: root.reqAdvance()
                    }
                }

                UiText {
                    visible: root.reqError !== ""
                    Layout.fillWidth: true
                    text: "⚠ " + root.reqError
                    color: "#f87171"
                    font.pixelSize: 11
                    wrapMode: Text.WordWrap
                }

                // Footer tombol
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6

                    UiText {
                        text: "Jawab di terminal"
                        color: termLink.containsMouse ? root.theme.textDim : root.theme.subtext0
                        font.pixelSize: 11
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

                    UiText {
                        visible: islandCapsule.activeFocus && !root.reqSending
                        text: requestCard.isPerm
                              ? "⌨ Y izinkan · N tolak" + (requestCard.req && requestCard.req.can_always ? " · A selalu" : "") + " · T terminal"
                              : "⌨ 1-9 pilih · Enter lanjut · T terminal"
                        color: root.theme.subtext0
                        font.pixelSize: 10
                    }

                    UiText {
                        visible: root.reqSending
                        text: "Mengirim…"
                        color: root.theme.accent
                        font.pixelSize: 11
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
                            UiText {
                                id: permBtnTxt
                                anchors.centerIn: parent
                                text: permBtn.modelData.label
                                color: permBtn.modelData.fg
                                font.pixelSize: 12; font.bold: true
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
                        UiText { id: backTxt; anchors.centerIn: parent; text: "Kembali"; color: root.theme.textDim; font.pixelSize: 12; font.bold: true }
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
                        UiText {
                            id: nextTxt
                            anchors.centerIn: parent
                            text: nextBtn.last ? "Kirim" : "Lanjut"
                            color: nextBtn.ready ? "#000000" : root.theme.overlay
                            font.pixelSize: 12; font.bold: true
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

                            UiText {
                                text: "QBot"
                                color: "#ffffff"
                                font.pixelSize: 14
                                font.weight: Font.Black
                                font.family: root.uiFont
                                anchors.horizontalCenter: parent.horizontalCenter
                            }

                            Row {
                                // Status koneksi Hermes tidak ditampilkan; titik di chip Agent sudah cukup.
                                visible: root.currentStatus !== "Hermes Offline" && root.currentStatus !== "Menghubungi Hermes…"
                                anchors.horizontalCenter: parent.horizontalCenter
                                spacing: 5
                                Rectangle {
                                    width: 6; height: 6; radius: 3; color: root.statusColor
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                UiText {
                                    text: root.currentStatus
                                    color: root.theme.subtext1
                                    font.pixelSize: 11
                                    font.bold: true
                                    font.family: root.uiFont
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
                                UiText {
                                    anchors.centerIn: parent
                                    text: "◐"
                                    color: root.theme.accent
                                    font.pixelSize: 11
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

                // PANEL KANAN: TAB NAVIGASI & KONTEN (CATATAN / STATUS / TOOLS)
                ColumnLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    // Lebar = sisa ruang island; isi tab yang lebar tidak boleh mendorong keluar.
                    Layout.preferredWidth: 1
                    clip: true
                    spacing: 8

                    // Navigasi: 4 grup + sub-tab grup aktif sebaris.
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
                                implicitWidth: groupTxt.implicitWidth + 10
                                implicitHeight: 26
                                radius: 6
                                color: active ? root.theme.surface1 : (groupHover.containsMouse ? root.theme.surface0 : "transparent")
                                UiText {
                                    id: groupTxt
                                    anchors.centerIn: parent
                                    text: groupBtn.modelData.label
                                    color: groupBtn.active ? "#fff" : root.theme.subtext0
                                    font.pixelSize: 12; font.bold: true
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
                                implicitWidth: subTxt.implicitWidth + 10
                                implicitHeight: 20
                                radius: 10
                                color: active ? Qt.darker(root.theme.accent, 2.8) : "transparent"
                                border.color: active ? Qt.darker(root.theme.accent, 1.6) : root.theme.surface1
                                UiText {
                                    id: subTxt
                                    anchors.centerIn: parent
                                    text: subBtn.modelData.label
                                    color: subBtn.active ? root.theme.text : root.theme.subtext1
                                    font.pixelSize: 10; font.bold: true
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
                            implicitWidth: musicNavRow.implicitWidth + 10
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
                                UiText {
                                    text: root.subTabs.length > 1 ? "♪" : "Musik"
                                    color: musicNavBtn.active ? "#fff" : root.theme.subtext0
                                    font.pixelSize: root.subTabs.length > 1 ? 12 : 11; font.bold: true
                                }
                            }
                            MouseArea {
                                id: musicNavHover
                                anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: root.selectTab("music")
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
                        UiText { anchors.horizontalCenter: parent.horizontalCenter; text: "♪"; color: root.theme.subtext0; font.pixelSize: 28 }
                        UiText { anchors.horizontalCenter: parent.horizontalCenter; text: "Tidak ada musik diputar"; color: root.theme.subtext1; font.pixelSize: 12; font.bold: true }
                        UiText { anchors.horizontalCenter: parent.horizontalCenter; text: "Putar lagu di Spotify, liriknya muncul di sini"; color: root.theme.subtext0; font.pixelSize: 11 }
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

                            UiText {
                                Layout.fillWidth: true
                                text: root.mediaTitle
                                color: "#ffffff"
                                elide: Text.ElideRight
                                font.pixelSize: 12; font.bold: true
                                font.family: root.uiFont
                            }
                            UiText {
                                Layout.fillWidth: true
                                Layout.topMargin: -5
                                text: root.mediaArtist
                                color: root.theme.subtext1
                                elide: Text.ElideRight
                                font.pixelSize: 11
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
                                UiText { text: root.formatTime(root.mediaPosition); color: root.theme.subtext1; font.pixelSize: 11 }
                                Item { Layout.fillWidth: true }
                                UiText { text: root.mediaLength > 0 ? root.formatTime(root.mediaLength) : ""; color: root.theme.subtext1; font.pixelSize: 11 }
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
                                    font.family: root.uiFont
                                    transformOrigin: Item.Left
                                    scale: current || !root.lyricSynced ? 1.0 : 0.86
                                    color: current ? "#ffffff"
                                         : !root.lyricSynced ? root.theme.textDim
                                         : Qt.rgba(1, 1, 1, index < root.lyricIndex ? 0.55 : 0.72)
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

                            UiText {
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
                        spacing: 8

                        HoverHandler { id: notesHeadHover }

                        NoteSegments {
                            theme: root.theme
                            items: [
                                { key: "all", label: "Semua" },
                                { key: "cmd", label: "Command" },
                                { key: "task", label: "Task" },
                                { key: "note", label: "Memo" }
                            ]
                            current: notesTabCol.filterTag
                            onPicked: key => notesTabCol.filterTag = key
                        }

                        Item { Layout.fillWidth: true }

                        // Jumlah catatan; aksi hapus baru muncul saat header disorot.
                        // Klik pertama minta konfirmasi; klik kedua (≤3 dtk) baru menghapus.
                        UiText {
                            visible: notesModel.count > 0
                            readonly property bool armed: notesHeadHover.hovered || notesTabCol.confirmClear
                            text: notesTabCol.confirmClear ? "Yakin hapus semua?"
                                : (notesHeadHover.hovered ? "Hapus semua" : notesTabCol.cards.length + " catatan")
                            color: notesTabCol.confirmClear || clearAllHover.containsMouse ? "#f87171" : root.theme.subtext0
                            font.pixelSize: 11
                            MouseArea {
                                id: clearAllHover
                                anchors.fill: parent
                                anchors.margins: -4
                                enabled: parent.armed
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

                        // Catatan baru
                        Rectangle {
                            implicitWidth: 26
                            implicitHeight: 26
                            radius: 13
                            color: root.theme.accent
                            scale: newNoteHover.pressed ? 0.92 : (newNoteHover.containsMouse ? 1.06 : 1.0)
                            Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
                            Rectangle { anchors.centerIn: parent; width: 12; height: 2; radius: 1; color: root.theme.base }
                            Rectangle { anchors.centerIn: parent; width: 2; height: 12; radius: 1; color: root.theme.base }
                            MouseArea {
                                id: newNoteHover
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: notesTabCol.newNote()
                            }
                        }
                    }

                    Item {
                        visible: !notesTabCol.editing
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        GridView {
                            id: notesGrid
                            anchors.fill: parent
                            anchors.leftMargin: -3
                            anchors.rightMargin: -3
                            clip: true
                            model: notesTabCol.cards
                            cellWidth: Math.floor(width / 2)
                            cellHeight: 86
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar {
                                policy: ScrollBar.AsNeeded
                                background: null
                                contentItem: Rectangle {
                                    implicitWidth: 3
                                    radius: 2
                                    color: root.theme.surface2
                                    opacity: parent.active ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 180 } }
                                }
                            }

                            delegate: Item {
                                id: noteCard
                                required property var modelData   // indeks di notesModel
                                readonly property var note: { root.notesRevision; return notesModel.get(modelData) || ({id: "", text: "", tag: "note", title: "", color: "", time: "", done: false}); }
                                readonly property string type: root.noteType(note.text, note.tag)
                                readonly property color accent: root.noteAccent(note.color)
                                // Tanpa judul: baris pertama jadi judul, kecuali command yang tampil utuh.
                                readonly property bool firstLineHeading: !note.title && type !== "cmd"
                                readonly property var lines: note.text.split("\n")
                                readonly property string heading: note.title || (firstLineHeading ? lines[0] : "")
                                readonly property string preview: firstLineHeading ? lines.slice(1).join(" ").trim() : note.text
                                width: notesGrid.cellWidth
                                height: notesGrid.cellHeight

                                Rectangle {
                                    id: cardBody
                                    anchors.fill: parent
                                    anchors.margins: 3
                                    radius: 14
                                    color: Qt.tint(cardHover.hovered ? root.theme.surface1 : root.theme.surface0,
                                                   Qt.rgba(noteCard.accent.r, noteCard.accent.g, noteCard.accent.b, noteCard.note.color ? 0.09 : 0))
                                    opacity: noteCard.note.done ? 0.5 : 1.0
                                    scale: cardTap.pressed ? 0.98 : 1.0
                                    Behavior on scale { NumberAnimation { duration: 90 } }
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    HoverHandler { id: cardHover; cursorShape: Qt.PointingHandCursor }
                                    MouseArea {
                                        id: cardTap
                                        anchors.fill: parent
                                        onClicked: notesTabCol.openNote(noteCard.note.id)
                                    }

                                    ColumnLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12
                                        anchors.topMargin: 9
                                        anchors.bottomMargin: 8
                                        spacing: 2

                                        UiText {
                                            visible: text !== ""
                                            text: noteCard.heading
                                            color: root.theme.text
                                            font.pixelSize: 12; font.bold: true
                                            font.strikeout: !!noteCard.note.done
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            maximumLineCount: noteCard.preview ? 1 : 2
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        UiText {
                                            visible: text !== ""
                                            text: noteCard.preview
                                            color: noteCard.type === "cmd" ? root.theme.textDim : root.theme.subtext1
                                            font.pixelSize: 11
                                            font.family: noteCard.type === "cmd" ? root.monoFont : root.uiFont
                                            font.weight: Font.Normal
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            maximumLineCount: noteCard.heading ? 2 : 3
                                            elide: Text.ElideRight
                                            Layout.fillWidth: true
                                        }
                                        Item { Layout.fillHeight: true }

                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 6
                                            Rectangle {
                                                visible: !!noteCard.note.color
                                                width: 6; height: 6; radius: 3
                                                color: noteCard.accent
                                            }
                                            UiText {
                                                text: (noteCard.type === "cmd" ? "Command" : (noteCard.type === "task" ? "Task" : "Memo"))
                                                      + (noteCard.note.time ? "  ·  " + noteCard.note.time : "")
                                                color: root.theme.subtext0
                                                font.pixelSize: 10
                                            }
                                            Item { Layout.fillWidth: true; implicitHeight: 16 }

                                            // Task: centang langsung dari kartu
                                            Rectangle {
                                                visible: noteCard.type === "task"
                                                width: 16; height: 16; radius: 8
                                                color: noteCard.note.done ? root.theme.accent : "transparent"
                                                border.color: noteCard.note.done ? root.theme.accent : root.theme.subtext0
                                                UiText {
                                                    anchors.centerIn: parent
                                                    visible: !!noteCard.note.done
                                                    text: "✓"; color: root.theme.base
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
                                                width: 18; height: 18; radius: 9
                                                color: runHover.containsMouse ? root.theme.accent : root.theme.surface2
                                                MediaGlyph {
                                                    anchors.centerIn: parent
                                                    anchors.horizontalCenterOffset: 1
                                                    width: 7; height: 7
                                                    kind: "play"
                                                    tint: runHover.containsMouse ? root.theme.base : root.theme.text
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

                        Column {
                            anchors.centerIn: parent
                            visible: notesGrid.count === 0
                            spacing: 4
                            UiText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: notesTabCol.filterTag === "cmd" ? "Belum ada command" : (notesTabCol.filterTag === "task" ? "Belum ada task" : (notesTabCol.filterTag === "note" ? "Belum ada memo" : "Belum ada catatan"))
                                color: root.theme.subtext1; font.pixelSize: 12; font.bold: true
                            }
                            UiText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Tekan + untuk mulai menulis"
                                color: root.theme.subtext0; font.pixelSize: 11
                            }
                        }

                        // Kartu memudar di tepi bawah, menandakan daftar masih bisa digulir.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 26
                            visible: notesGrid.count > 0 && !notesGrid.atYEnd
                            gradient: Gradient {
                                GradientStop { position: 0; color: Qt.rgba(root.theme.base.r, root.theme.base.g, root.theme.base.b, 0) }
                                GradientStop { position: 1; color: root.theme.base }
                            }
                        }
                    }

                    // ── MODE EDITOR ────────────────────────────────────────────
                    Rectangle {
                        id: noteEditor
                        visible: notesTabCol.editing
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        Layout.bottomMargin: 4
                        radius: 16

                        property bool loading: false
                        property bool confirmDelete: false
                        readonly property var note: { root.notesRevision; return notesTabCol.editing ? notesModel.get(notesTabCol.editingIndex) : null; }
                        readonly property string type: note ? root.noteType(note.text, note.tag) : "note"
                        readonly property color accent: root.noteAccent(note ? note.color : "")

                        color: Qt.tint(root.theme.surface0, Qt.rgba(accent.r, accent.g, accent.b, note && note.color ? 0.09 : 0))
                        Behavior on color { ColorAnimation { duration: 160 } }

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
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            anchors.topMargin: 10
                            anchors.bottomMargin: 9
                            spacing: 6

                            // Toolbar: kembali · tipe · aksi
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8

                                Rectangle {
                                    implicitWidth: 26
                                    implicitHeight: 26
                                    radius: 13
                                    color: backHoverN.containsMouse ? root.theme.surface2 : root.theme.surface1
                                    Behavior on color { ColorAnimation { duration: 120 } }
                                    UiText {
                                        anchors.centerIn: parent
                                        anchors.horizontalCenterOffset: -1
                                        anchors.verticalCenterOffset: -1
                                        text: "‹"
                                        color: root.theme.text; font.pixelSize: 17; font.bold: true
                                    }
                                    MouseArea {
                                        id: backHoverN
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: notesTabCol.closeEditor()
                                    }
                                }

                                NoteSegments {
                                    theme: root.theme
                                    color: root.theme.surface1
                                    items: [
                                        { key: "note", label: "Memo" },
                                        { key: "task", label: "Task" },
                                        { key: "cmd", label: "Command" }
                                    ]
                                    current: noteEditor.type
                                    onPicked: key => noteEditor.update("tag", key)
                                }

                                Item { Layout.fillWidth: true }

                                Repeater {
                                    model: noteEditor.type === "cmd" ? ["run", "copy", "delete"] : ["copy", "delete"]
                                    Rectangle {
                                        id: edAction
                                        required property string modelData
                                        readonly property bool danger: modelData === "delete"
                                        property bool copied: false
                                        implicitWidth: edActionTxt.implicitWidth + 16
                                        implicitHeight: 26
                                        radius: 13
                                        color: danger && noteEditor.confirmDelete ? "#7f1d1d"
                                             : (edActionHover.containsMouse ? root.theme.surface2 : "transparent")
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                        UiText {
                                            id: edActionTxt
                                            anchors.centerIn: parent
                                            text: edAction.modelData === "run" ? "Jalankan"
                                                : edAction.modelData === "copy" ? (edAction.copied ? "Tersalin" : "Salin")
                                                : (noteEditor.confirmDelete ? "Yakin hapus?" : "Hapus")
                                            color: edAction.danger ? (noteEditor.confirmDelete ? "#fecaca" : "#f87171") : root.theme.textDim
                                            font.pixelSize: 11
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
                                renderType: Text.NativeRendering
                                font.hintingPreference: Font.PreferFullHinting
                                id: noteTitleField
                                Layout.fillWidth: true
                                Layout.topMargin: 2
                                placeholderText: "Judul"
                                placeholderTextColor: root.theme.subtext0
                                color: root.theme.text
                                font.pixelSize: 16
                                font.bold: true
                                font.family: root.uiFont
                                background: null
                                leftPadding: 2; rightPadding: 2; topPadding: 2; bottomPadding: 2
                                onTextChanged: noteEditor.update("title", text)
                                Keys.onReturnPressed: noteBodyArea.forceActiveFocus()
                                Keys.onEnterPressed: noteBodyArea.forceActiveFocus()
                                Keys.onEscapePressed: event => { notesTabCol.closeEditor(); event.accepted = true; }
                            }

                            ScrollView {
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                clip: true
                                TextArea {
                                    renderType: Text.NativeRendering
                                    font.hintingPreference: Font.PreferFullHinting
                                    id: noteBodyArea
                                    placeholderText: noteEditor.type === "cmd" ? "Perintah terminal, mis. npm run dev"
                                                   : (noteEditor.type === "task" ? "Apa yang perlu dikerjakan?" : "Tulis catatan…")
                                    placeholderTextColor: root.theme.subtext0
                                    color: root.theme.textDim
                                    font.pixelSize: noteEditor.type === "cmd" ? 12 : 13
                                    font.weight: Font.Medium
                                    font.family: noteEditor.type === "cmd" ? root.monoFont : root.uiFont
                                    wrapMode: TextEdit.Wrap
                                    selectByMouse: true
                                    background: null
                                    leftPadding: 2; rightPadding: 2; topPadding: 2
                                    onTextChanged: noteEditor.update("text", text)
                                    Keys.onEscapePressed: event => { notesTabCol.closeEditor(); event.accepted = true; }
                                }
                            }

                            // Footer: warna · status simpan
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 2

                                Repeater {
                                    model: root.noteColorKeys
                                    Item {
                                        required property string modelData
                                        readonly property bool active: (noteEditor.note ? noteEditor.note.color : "") === modelData
                                        implicitWidth: 18
                                        implicitHeight: 18
                                        Rectangle {
                                            anchors.fill: parent
                                            radius: 9
                                            color: "transparent"
                                            border.width: parent.active ? 1 : 0
                                            border.color: root.theme.textDim
                                        }
                                        Rectangle {
                                            anchors.centerIn: parent
                                            width: 10; height: 10; radius: 5
                                            color: parent.modelData ? root.noteAccent(parent.modelData) : root.theme.overlay
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: noteEditor.update("color", parent.modelData)
                                        }
                                    }
                                }

                                Item { Layout.fillWidth: true }

                                UiText {
                                    text: (noteEditor.note && noteEditor.note.time ? noteEditor.note.time + "  ·  " : "")
                                          + (noteSaveTimer.running ? "Menyimpan…" : "Tersimpan")
                                    color: root.theme.subtext0; font.pixelSize: 10
                                }
                            }
                        }
                    }
                }

                // TAB AGENT: status agent ringkas, satu sesi utama (gaya live activity), lalu riwayat.
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
                    readonly property var mainSession: sortedSessions.length > 0 ? sortedSessions[0] : null

                    // Baris 1: logo tiap agent + titik status, lalu sakelar auto-izin
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        // Satu baki untuk semua agent, seirama dengan filter tab Catatan.
                        Rectangle {
                            implicitWidth: agentTray.implicitWidth + 4
                            implicitHeight: 26
                            radius: 13
                            color: root.theme.surface0

                            Row {
                                id: agentTray
                                anchors.centerIn: parent

                        Repeater {
                            model: ["claude", "hermes", "opencode"]

                            Rectangle {
                                id: agentChip
                                required property string modelData
                                readonly property bool isHermes: modelData === "hermes"
                                readonly property int count: root.agentSessions.filter(sess => sess.agent === modelData).length
                                readonly property int stateCount: root.agentSessions.filter(sess => sess.agent === modelData && sess.state === state).length
                                // Hermes: koneksi bridge; Claude/OpenCode: status terpenting dari semua sesinya.
                                readonly property string state: isHermes
                                    ? (!root.hermesConnected ? "offline" : (root.hermesWorking ? "working" : "idle"))
                                    : root.agentAggregate(modelData)
                                readonly property color tint: state === "offline" ? "#ef4444"
                                    : (state === "none" ? root.theme.overlay : root.stateColor(state))
                                readonly property bool dim: state === "none"

                                width: chipRow.implicitWidth + 14
                                height: 22
                                radius: 11
                                color: agentChip.state === "waiting" ? Qt.rgba(0.976, 0.451, 0.086, 0.16)
                                     : (chipHover.containsMouse ? root.theme.surface1 : "transparent")
                                Behavior on color { ColorAnimation { duration: 200 } }

                                Row {
                                    id: chipRow
                                    anchors.centerIn: parent
                                    spacing: 5
                                    opacity: agentChip.dim ? 0.45 : 1.0
                                    SourceLogo { kind: agentChip.modelData; size: 14; anchors.verticalCenter: parent.verticalCenter }
                                    Rectangle {
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
                                    UiText {
                                        // Label hanya untuk yang butuh perhatian; sisanya cukup titik + tooltip.
                                        visible: agentChip.state === "waiting" || agentChip.state === "error"
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.stateLabel(agentChip.state) + (agentChip.stateCount > 1 ? " · " + agentChip.stateCount : "")
                                        color: agentChip.tint
                                        font.pixelSize: 11
                                    }
                                }

                                MouseArea {
                                    id: chipHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                }
                                ToolTip {
                                    visible: chipHover.containsMouse
                                    delay: 300
                                    text: root.agentName(agentChip.modelData) + " — " + (agentChip.isHermes
                                          ? (!root.hermesConnected ? (root.hermesStatusMessage || "Menunggu koneksi Hermes…")
                                             : (root.hermesWorking ? (root.activeDetail || "Mengerjakan task…") : "Siap menerima prompt & task"))
                                          : (agentChip.dim ? "Tidak ada sesi" : root.stateLabel(agentChip.state)
                                             + " · " + agentChip.count + " sesi"))
                                }
                            }
                        }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        // Auto-izinkan perintah baca-saja (git status, ls, cat, …)
                        Row {
                            spacing: 7
                            UiText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Auto-izin"
                                color: settings.autoSafe ? root.theme.text : root.theme.subtext0
                                font.pixelSize: 11
                            }
                            ToolTip.visible: autoSafeHover.hovered
                            ToolTip.delay: 400
                            ToolTip.text: "Izinkan otomatis perintah baca-saja (git status, ls, cat, …)"
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 28; height: 16; radius: 8
                                color: settings.autoSafe ? "#22c55e" : root.theme.surface1
                                Behavior on color { ColorAnimation { duration: 180 } }
                                Rectangle {
                                    width: 12; height: 12; radius: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    x: settings.autoSafe ? parent.width - width - 2 : 2
                                    color: settings.autoSafe ? "#ffffff" : root.theme.subtext1
                                    Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                }
                            }
                            TapHandler { onTapped: settings.autoSafe = !settings.autoSafe }
                            HoverHandler { id: autoSafeHover; cursorShape: Qt.PointingHandCursor }
                        }
                    }

                    // Baris 2: kartu sesi utama (yang paling butuh perhatian)
                    Rectangle {
                        id: mainCard
                        readonly property var sess: agentTab.mainSession
                        readonly property color tint: sess ? root.stateColor(sess.state) : root.theme.overlay
                        readonly property bool live: !!sess && (sess.state === "working" || sess.state === "waiting")
                        Layout.fillWidth: true
                        Layout.preferredHeight: 58
                        radius: 14
                        color: sess && sess.state === "waiting" ? Qt.rgba(0.976, 0.451, 0.086, 0.12) : root.theme.surface0
                        Behavior on color { ColorAnimation { duration: 200 } }

                        RowLayout {
                            visible: !!mainCard.sess
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 10

                            // Logo dalam cincin status; cincin berdenyut saat sesi aktif.
                            Item {
                                implicitWidth: 34; implicitHeight: 34
                                Rectangle {
                                    anchors.fill: parent
                                    radius: 17
                                    color: root.theme.base
                                    border.width: 1.5
                                    border.color: mainCard.tint
                                    SequentialAnimation on border.color {
                                        running: mainCard.live
                                        loops: Animation.Infinite
                                        ColorAnimation { to: Qt.rgba(mainCard.tint.r, mainCard.tint.g, mainCard.tint.b, 0.25); duration: 700; easing.type: Easing.InOutSine }
                                        ColorAnimation { to: mainCard.tint; duration: 700; easing.type: Easing.InOutSine }
                                    }
                                }
                                SourceLogo { anchors.centerIn: parent; kind: mainCard.sess ? mainCard.sess.agent : "claude"; size: 18 }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                UiText {
                                    text: mainCard.sess ? (mainCard.sess.project || "?") : ""
                                    color: root.theme.text; font.pixelSize: 13; font.bold: true
                                    elide: Text.ElideRight; Layout.fillWidth: true
                                }
                                UiText {
                                    visible: text !== ""
                                    text: mainCard.sess ? (mainCard.sess.detail || mainCard.sess.prompt || "") : ""
                                    color: root.theme.subtext1; font.pixelSize: 11
                                    font.family: root.monoFont
                                    elide: Text.ElideMiddle; Layout.fillWidth: true
                                }
                            }

                            // Status + umur sesi bertumpuk di kanan
                            ColumnLayout {
                                spacing: 3
                                UiText {
                                    Layout.alignment: Qt.AlignRight
                                    text: mainCard.sess ? root.stateLabel(mainCard.sess.state) : ""
                                    color: mainCard.tint; font.pixelSize: 11; font.bold: true
                                }
                                UiText {
                                    Layout.alignment: Qt.AlignRight
                                    // currentTimeSecs: dependensi agar "x dtk" ikut berdetak
                                    text: mainCard.sess && root.currentTimeSecs !== "" ? root.agoText(mainCard.sess.updated) : ""
                                    color: root.theme.subtext0; font.pixelSize: 10
                                }
                            }
                        }

                        Column {
                            visible: !mainCard.sess
                            anchors.centerIn: parent
                            spacing: 3
                            UiText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Belum ada sesi aktif"
                                color: root.theme.text; font.pixelSize: 12; font.bold: true
                            }
                            UiText {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: "Jalankan Claude Code atau OpenCode, statusnya muncul di sini"
                                color: root.theme.subtext0; font.pixelSize: 11
                            }
                        }
                    }

                    // Sesi lain cukup sebaris: logo · project · titik status
                    Row {
                        visible: agentTab.sortedSessions.length > 1
                        Layout.leftMargin: 12
                        spacing: 14

                        Repeater {
                            model: agentTab.sortedSessions.slice(1, 3)

                            Row {
                                id: otherSess
                                required property var modelData
                                spacing: 5
                                SourceLogo { kind: otherSess.modelData.agent; size: 12; anchors.verticalCenter: parent.verticalCenter }
                                UiText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.min(implicitWidth, 110)
                                    text: otherSess.modelData.project || "?"
                                    color: root.theme.textDim; font.pixelSize: 11
                                    elide: Text.ElideRight
                                }
                                UiText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: root.stateLabel(otherSess.modelData.state)
                                    color: root.stateColor(otherSess.modelData.state); font.pixelSize: 10
                                }
                            }
                        }
                        UiText {
                            visible: agentTab.sortedSessions.length > 3
                            text: "+" + (agentTab.sortedSessions.length - 3) + " lainnya"
                            color: root.theme.subtext0; font.pixelSize: 11
                        }
                    }

                    // Baris 3: riwayat task & keputusan izin, terbaru di atas.
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: 2
                        Layout.leftMargin: 12
                        Layout.rightMargin: 12
                        UiText {
                            text: "Riwayat"
                            color: root.theme.subtext1; font.pixelSize: 11; font.bold: true
                        }
                        Item { Layout.fillWidth: true }
                        UiText {
                            readonly property var today: (activity.daily || {})[root.dayKey(new Date())]
                            visible: !!today
                            text: today ? "Hari ini  " + today.done + " selesai · " + today.perms + " izin" + (today.errors ? " · " + today.errors + " gagal" : "") : ""
                            color: root.theme.subtext0; font.pixelSize: 10
                        }
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true

                        ListView {
                            id: historyView
                            anchors.fill: parent
                            spacing: 0
                            clip: true
                            model: activity.history || []
                            boundsBehavior: Flickable.StopAtBounds
                            ScrollBar.vertical: ScrollBar {
                                policy: ScrollBar.AsNeeded
                                background: null
                                contentItem: Rectangle {
                                    implicitWidth: 3
                                    radius: 2
                                    color: root.theme.surface2
                                    opacity: parent.active ? 1 : 0
                                    Behavior on opacity { NumberAnimation { duration: 180 } }
                                }
                            }

                            // Baris: ikon status · logo · project · teks ...... label · durasi · jam
                            delegate: Rectangle {
                                id: histRow
                                required property var modelData
                                readonly property color tint: root.activityColor(modelData.kind)
                                // Mulai & selesai sudah jelas dari ikon; label hanya untuk kejadian lain.
                                readonly property bool notable: modelData.kind !== "start" && modelData.kind !== "done"
                                width: historyView.width
                                height: 24
                                radius: 8
                                color: histHover.hovered ? root.theme.surface0 : "transparent"
                                HoverHandler { id: histHover }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 12
                                    anchors.rightMargin: 12
                                    spacing: 7
                                    UiText {
                                        text: root.activityGlyph(histRow.modelData.kind)
                                        color: histRow.tint
                                        font.pixelSize: 11; font.bold: true
                                        horizontalAlignment: Text.AlignHCenter
                                        Layout.preferredWidth: 12
                                    }
                                    SourceLogo { kind: histRow.modelData.agent || "hermes"; size: 13 }
                                    UiText {
                                        text: histRow.modelData.project || "—"
                                        color: root.theme.textDim; font.pixelSize: 11
                                        elide: Text.ElideRight
                                        Layout.preferredWidth: 78
                                    }
                                    UiText {
                                        text: histRow.modelData.text
                                        color: root.theme.subtext1
                                        font.pixelSize: 11
                                        font.weight: Font.Normal
                                        elide: Text.ElideRight
                                        Layout.fillWidth: true
                                    }
                                    UiText {
                                        visible: histRow.notable
                                        text: root.activityLabel(histRow.modelData.kind)
                                        color: histRow.tint
                                        font.pixelSize: 10
                                    }
                                    UiText {
                                        visible: !!histRow.modelData.dur
                                        text: histRow.modelData.dur || ""
                                        color: root.theme.subtext0; font.pixelSize: 10
                                    }
                                    UiText {
                                        text: root.clockText(histRow.modelData.t)
                                        color: root.theme.subtext0
                                        font.pixelSize: 10
                                        horizontalAlignment: Text.AlignRight
                                    }
                                }
                            }
                        }

                        UiText {
                            anchors.centerIn: parent
                            visible: historyView.count === 0
                            text: "Belum ada aktivitas tercatat"
                            color: root.theme.subtext0
                            font.pixelSize: 11
                        }

                        // Fade bawah: baris terakhir larut ke latar island, tidak terpotong kasar.
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: 22
                            visible: historyView.count > 0 && !historyView.atYEnd
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: Qt.rgba(root.theme.base.r, root.theme.base.g, root.theme.base.b, 0) }
                                GradientStop { position: 1.0; color: root.theme.base }
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
                    UiText {
                        text: "RESOURCE SISTEM (ARCH LINUX)"
                        color: root.theme.subtext0
                        font.pixelSize: 11
                        font.bold: true
                        topPadding: 2
                    }

                    // Kartu 2: Metrik RAM & Uptime
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        // CPU Usage Card
                        Rectangle {
                            Layout.fillWidth: true; height: 58; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 4
                                RowLayout {
                                    UiText { text: "CPU"; color: root.theme.subtext1; font.pixelSize: 11 }
                                    Item { Layout.fillWidth: true }
                                    UiText { text: root.sysCpu + "%"; color: root.sysCpu > 85 ? "#ef4444" : "#a78bfa"; font.pixelSize: 11; font.bold: true }
                                }
                                Rectangle {
                                    Layout.fillWidth: true; height: 4; radius: 2; color: root.theme.surface1
                                    Rectangle {
                                        width: parent.width * Math.min(1, root.sysCpu / 100.0)
                                        height: parent.height; radius: 2
                                        color: root.sysCpu > 85 ? "#ef4444" : "#a78bfa"
                                    }
                                }
                                UiText { text: root.sysProcesses + " proses"; color: root.theme.subtext1; font.pixelSize: 11 }
                            }
                        }

                        // RAM Usage Card
                        Rectangle {
                            Layout.fillWidth: true; height: 58; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 4
                                RowLayout {
                                    UiText { text: "RAM Terpakai"; color: root.theme.subtext1; font.pixelSize: 11 }
                                    Item { Layout.fillWidth: true }
                                    UiText { text: "" + root.sysRamPercent + "%"; color: root.sysRamPercent > 85 ? "#ef4444" : root.theme.accent; font.pixelSize: 11; font.bold: true }
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
                                UiText { text: root.sysRamUsed + " / " + root.sysRamTotal; color: root.theme.subtext1; font.pixelSize: 11 }
                            }
                        }

                        // Uptime Card
                        Rectangle {
                            Layout.fillWidth: true; height: 58; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                            ColumnLayout {
                                anchors.fill: parent; anchors.margins: 8; spacing: 2
                                UiText { text: "System Uptime"; color: root.theme.subtext1; font.pixelSize: 11 }
                                UiText { text: root.sysUptime; color: root.theme.text; font.pixelSize: 12; font.bold: true; elide: Text.ElideRight; Layout.fillWidth: true }
                                UiText { text: root.sysKernel; color: root.theme.subtext1; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
                            }
                        }
                    }

                    // Kartu Penyimpanan: sisa ruang partisi root (/)
                    Rectangle {
                        id: diskCard
                        Layout.fillWidth: true; height: 50; radius: 8; color: root.theme.surface0; border.color: root.theme.surface1
                        readonly property color diskColor: root.sysDiskPercent > 90 ? "#ef4444" : (root.sysDiskPercent > 75 ? "#f59e0b" : "#22c55e")
                        ColumnLayout {
                            anchors.fill: parent; anchors.margins: 8; spacing: 4
                            RowLayout {
                                UiText { text: "Penyimpanan (/)"; color: root.theme.subtext1; font.pixelSize: 11 }
                                Item { Layout.fillWidth: true }
                                UiText { text: "Sisa " + root.sysDiskFree; color: diskCard.diskColor; font.pixelSize: 11; font.bold: true }
                            }
                            Rectangle {
                                Layout.fillWidth: true; height: 4; radius: 2; color: root.theme.surface1
                                Rectangle {
                                    width: parent.width * Math.min(1, root.sysDiskPercent / 100.0)
                                    height: parent.height; radius: 2
                                    color: diskCard.diskColor
                                }
                            }
                            UiText { text: root.sysDiskUsed + " / " + root.sysDiskTotal + " terpakai (" + root.sysDiskPercent + "%)"; color: root.theme.subtext1; font.pixelSize: 11 }
                        }
                    }

                    // Spacer bawah agar menempel ke atas
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

                    UiText { text: "Buka cepat"; color: root.theme.subtext1; font.pixelSize: 11; font.bold: true }

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
                                    UiText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: toolTile.modelData.label
                                        color: root.theme.text; font.pixelSize: 11; font.bold: true
                                    }
                                    UiText {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        text: toolTile.modelData.sub
                                        color: root.theme.subtext1; font.pixelSize: 10
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

                    UiText { text: "Suara"; color: root.theme.subtext1; font.pixelSize: 11; font.bold: true; topPadding: 2 }

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
                                    UiText { text: "Volume"; color: root.theme.text; font.pixelSize: 11; font.bold: true }
                                    UiText { text: root.audioReady ? root.volumeLabel : "PipeWire"; color: root.theme.subtext1; font.pixelSize: 10 }
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
                                                UiText {
                                                    anchors.centerIn: parent
                                                    text: parent.modelData.label
                                                    color: parent.index === 1 ? root.theme.textDim : "#ffffff"
                                                    font.pixelSize: 11; font.bold: true
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
                                    UiText { text: "Notifikasi"; color: root.theme.text; font.pixelSize: 11; font.bold: true }
                                    UiText { text: settings.sound ? "Bunyi menyala" : "Senyap"; color: root.theme.subtext1; font.pixelSize: 10 }
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

                // TAB 6: DEV SERVER (php artisan serve + npm run dev per project)
                ColumnLayout {
                    visible: root.activeTab === "dev"
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    spacing: 6

                    UiText {
                        text: "DEV SERVERS"
                        color: root.theme.subtext0
                        font.pixelSize: 11
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

                            UiText {
                                anchors.centerIn: parent
                                visible: root.devServers.length === 0
                                text: root.bridgeReady ? "Tidak ada project dev server" : "Bridge belum siap…"
                                color: root.theme.subtext0
                                font.pixelSize: 12
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
                                            UiText {
                                                text: modelData.name
                                                color: "#ffffff"
                                                font.pixelSize: 12
                                                font.bold: true
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                        }

                                        UiText {
                                            Layout.fillWidth: true
                                            elide: Text.ElideRight
                                            color: root.theme.subtext1
                                            font.pixelSize: 11
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
                                        UiText {
                                            anchors.centerIn: parent
                                            text: "serve"
                                            color: devRow.php.running ? root.theme.textDim : root.theme.subtext1
                                            font.pixelSize: 11
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
                                        UiText {
                                            anchors.centerIn: parent
                                            text: "npm dev"
                                            color: devRow.npm.running ? root.theme.textDim : root.theme.subtext1
                                            font.pixelSize: 11
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
                                        UiText {
                                            anchors.centerIn: parent
                                            text: "Start"
                                            color: devRow.availableCount > devRow.runningCount ? root.theme.textDim : root.theme.overlay
                                            font.pixelSize: 11
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
                                        UiText {
                                            anchors.centerIn: parent
                                            text: "Stop"
                                            color: devRow.runningCount > 0 ? root.theme.subtext1 : root.theme.overlay
                                            font.pixelSize: 11
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
