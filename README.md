<div align="center">

<img src="src-tauri/icons/128x128.png" width="96" alt="Ikon QBot">

# QBot

**Dynamic Island + maskot Mochi untuk Arch Linux (Niri / Wayland), terhubung ke Hermes Agent.**

Setujui izin agent, pantau sesi Claude Code / OpenCode / Hermes, jawab pertanyaan
agent, simpan catatan, dan bantu interview — langsung dari island di atas layar.

![Linux](https://img.shields.io/badge/Linux-Wayland-FCC624?logo=linux&logoColor=black)
![Quickshell](https://img.shields.io/badge/Quickshell-QML-41CD52?logo=qt)
![Python](https://img.shields.io/badge/Python-bridge-3776AB?logo=python&logoColor=white)
![License: MIT](https://img.shields.io/badge/license-MIT-green)

</div>

QBot adalah port dari [Coucou](docs/README-coucou-windows.md) (Mochi Dynamic
Island companion) agar berjalan native di **Arch Linux + Niri (Wayland)** dengan
backend integrasi **Hermes Agent**.

## Fitur

- **Approval Hermes** — tombol Reject / Run untuk request asli dari Hermes.
- **Status agent coding** — sesi Claude Code dan OpenCode: bekerja, butuh izin, selesai.
- **Jawab izin & pertanyaan** agent langsung dari island.
- **Interview Assist** — transkrip lokal (faster-whisper) + saran jawaban dari LLM.
- **Tab Status** — sistem, media (playerctl), catatan, screenshot, dev server.

## Arsitektur

```
run.sh
└── Quickshell (layer-shell overlay) → linux-app/HermesMochi.qml
    ├── BibleStrongAvatar.qml      karakter & animasi
    ├── mochi_bridge.py --stdio    bridge: HTTP lokal + WebSocket Hermes
    │     stdout = event NDJSON (langsung ke QML, tanpa polling /tmp)
    │     stdin  = perintah QML (decision, launch, media, notes)
    ├── bridge_client.py           klien HTTP ber-token (watcher & CLI)
    └── hermes_watcher.py          pantau SQLite Hermes → event
```

Catatan: implementasi aktif adalah Quickshell/QML. Electron (`electron-main.js`)
dan Tauri (`src-tauri/`) adalah jalur legacy yang tidak dipakai `run.sh`.

## Dependensi

Wajib:

- `quickshell`
- `python` (bridge & klien)
- `python-websockets` — **tanpa ini approval Hermes tidak tersambung**
  (`run.sh` otomatis memakai venv Hermes bila system python tidak punya)

Opsional / fitur:

- `python-psutil` — tab Status sistem
- `playerctl` — panel media
- `wl-clipboard` — salin catatan
- `grim` + `slurp` — tombol screenshot
- `lsof`, `pgrep` — deteksi proses Hermes

## Cara Menjalankan

```bash
git clone https://github.com/RiskiWahyuSaputra/Qbot.git
cd Qbot
./run.sh
```

`run.sh` memilih interpreter bridge (system python atau venv Hermes) lewat
`HERMES_COUCOU_PYTHON`, lalu menyalakan Quickshell. Peringatan dependensi
dicetak ke stderr bila ada yang kurang.

Preferensi (avatar, tab terakhir, dll.) tersimpan di
`~/.config/hermes-coucou/settings.json`.

## Hotkey & IPC

QBot bisa dikendalikan dari luar lewat IPC Quickshell:

```bash
QBOT=~/Projects/project-web/hermes-coucou/linux-app/HermesMochi.qml   # sesuaikan
qs -p $QBOT ipc call qbot toggle        # buka/tutup island
qs -p $QBOT ipc call qbot open          # buka (juga memberi fokus ke kartu izin)
qs -p $QBOT ipc call qbot close
qs -p $QBOT ipc call qbot tab status    # buka langsung ke tab tertentu
```

Contoh keybind Niri (`~/.config/niri/config.kdl`, di dalam `binds { }`):

```kdl
Mod+Space { spawn "qs" "-p" "/path/ke/Qbot/linux-app/HermesMochi.qml" "ipc" "call" "qbot" "toggle"; }
```

Island yang dibuka lewat hotkey langsung menerima keyboard; `Esc` menutupnya.

| Tombol | Di panel | Di kartu izin | Di kartu pertanyaan |
|---|---|---|---|
| `1`–`7` | pindah tab | – | pilih opsi |
| `←` `→` / `Tab` | tab sebelumnya/berikutnya | – | – |
| `Y` / `Enter` | – | Izinkan | `Enter` = Lanjut/Kirim |
| `N` | – | Tolak | – |
| `A` | – | Selalu izinkan (bila ditawarkan) | – |
| `T` | – | Jawab di terminal | Jawab di terminal |
| `Backspace` | – | – | pertanyaan sebelumnya |
| `Esc` | tutup island | lepas fokus | lepas fokus |

Kartu yang muncul sendiri menerima keyboard setelah diklik sekali, atau
langsung bila dibuka dengan `qbot open`.

## Approval Hermes

- Request approval **asli** datang dari WebSocket Hermes, punya
  `session_id` + `request_id`, dan menampilkan tombol **Reject / Run**.
- Keputusan hanya dianggap berhasil setelah Hermes mengirim ACK JSON-RPC yang
  terkorelasi. Bila gagal/timeout, tombol tetap terbuka dan status menunjukkan
  kegagalan — tidak pernah "Approved" palsu.
- Event demo (`send-event.py` / `test_approval_flow.py`) hanya tampil sebagai
  **info**, tanpa tombol, karena tidak ada request asli yang bisa dikonfirmasi.

## Status Agent Coding (Claude Code & OpenCode)

QBot memantau sesi Claude Code dan OpenCode: project, sedang bekerja /
butuh izin / selesai, dan tool terakhir.

```bash
python3 linux-app/agent_hooks_install.py              # pasang keduanya
python3 linux-app/agent_hooks_install.py --uninstall  # lepas entri QBot saja
# --claude atau --opencode untuk memilih salah satu
```

- **Claude Code**: hook di `~/.claude/settings.json` → `linux-app/claude_hook.py`
  (backup settings dibuat otomatis, hook milik kamu tidak disentuh).
- **OpenCode**: symlink `~/.config/opencode/plugins/coucou.js` →
  `linux-app/opencode/coucou.js`.
- Pill notifikasi menampilkan logo sumber (Hermes / Claude Code / OpenCode),
  chip project, titik animasi saat **task diterima**, centang + durasi saat
  **task selesai**, dan bar hitung mundur. Pill kecil menampilkan logo tiap agent
  dengan cincin warna status (biru bekerja, oranye butuh izin, hijau selesai).
- Tab **Status** → kartu *Agent Coding*: daftar sesi dan langkah terakhirnya.
- Hook/plugin tidak pernah menahan agent: timeout 0,4 dtk, error ditelan,
  selalu sukses walau QBot mati. Izin tetap dijawab di terminal.
- Logo ada di `linux-app/assets/` (diambil dari tema ikon lokal).

### Menjawab izin & pertanyaan dari island

Saat agent minta izin menjalankan sesuatu, atau mengajukan pertanyaan pilihan,
island menampilkan kartu interaktif:

- **Izin**: perintah yang akan dijalankan, tombol **Tolak / Selalu izinkan /
  Izinkan** ("Selalu" hanya muncul bila agent menawarkan aturan izin).
- **Pertanyaan**: pilihan bernomor (klik = jawab untuk single-select,
  checkbox + **Kirim** untuk multi-select), kolom **Jawaban lain…**, dan
  **Lanjut/Kembali** untuk beberapa pertanyaan sekaligus.
- **Jawab di terminal** selalu tersedia; banyak permintaan masuk antrean (1/N).
- Approval Hermes tetap didahulukan; kartu lain muncul lagi setelahnya.

| Agent | Izin | Pertanyaan |
|---|---|---|
| Claude Code | hook `PermissionRequest` | `AskUserQuestion` (hook `PreToolUse`) |
| OpenCode | event `permission.asked` | event `question.asked` |
| Hermes | approval (Run/Reject) | `clarify.request` |

Uji kartunya tanpa agent sungguhan (jawabanmu dicetak di terminal):

```bash
./test-request.py izin          # Tolak / Selalu izinkan / Izinkan
./test-request.py pertanyaan    # single-select
./test-request.py multi         # 2 pertanyaan: single + multi-select
./test-request.py bebas         # ketik jawaban sendiri
./test-request.py semua         # semuanya sekaligus (antrean 1/N)
# opsi: --agent opencode (logo), --tunggu 300
```

Claude Code menunggu jawaban island maksimal 90 detik (ubah dengan env
`HERMES_COUCOU_CLAUDE_WAIT` pada proses Claude Code); setelah itu, atau bila
QBot mati, Claude bertanya di terminal seperti biasa. OpenCode dan Hermes
tetap menampilkan prompt di TUI-nya sendiri; jawaban mana pun yang lebih dulu
dipakai dan kartu di island ikut tertutup.

## Interview Assist

Tab **Interview** merekam suara lawan bicara, menampilkan transkrip, lalu
menyarankan jawaban begitu lawan bicara selesai bertanya.

```
parec (PipeWire) -> deteksi jeda suara -> faster-whisper (lokal, CPU)
                 -> LLM OpenAI-compatible (default: model Hermes di 9router) -> island
```

- **Sistem**: rekam audio yang keluar dari speaker/headset (Zoom, Meet,
  Discord). Pakai **headset** supaya yang terekam hanya lawan bicara.
- **Mic**: interview tatap muka (mikrofon laptop menangkap semua orang).
- **Auto**: jawaban dibuat otomatis ~0,8 dtk setelah lawan bicara diam;
  basa-basi ("oke", "baik") dilewati. **Jawab** memaksa jawaban untuk
  ucapan terakhir. **‹ ›** melihat jawaban sebelumnya.
- Isi profil/CV + deskripsi pekerjaan di
  `~/.config/hermes-coucou/interview_profile.md` (template dibuat saat
  pertama Mulai). Tanpa profil, jawaban berisi `[isi: ...]` alih-alih mengarang.
- Transkrip + jawaban tersimpan di `~/.local/share/hermes-coucou/interviews/`.

Konfigurasi (env pada proses Quickshell/`run.sh`):

| Env | Default | Keterangan |
|---|---|---|
| `HERMES_COUCOU_INTERVIEW_WHISPER` | `small` | `base` lebih cepat, `medium` lebih akurat |
| `HERMES_COUCOU_INTERVIEW_LANG` | otomatis | mis. `en` / `id` agar deteksi bahasa tidak meleset |
| `HERMES_COUCOU_INTERVIEW_MODEL` | `ag/gemini-3.8-flash-low`, cadangan `model.default` Hermes | daftar dipisah koma, dicoba berurutan bila gagal |
| `HERMES_COUCOU_INTERVIEW_BASE_URL` / `_API_KEY` | dari `~/.hermes/config.yaml` (+ `.env`) | endpoint lain |

Butuh `faster-whisper`, `numpy`, `pyyaml` di python bridge (venv Hermes
sudah punya) dan `parec` (pipewire-pulse). Rekam percakapan hanya dengan
persetujuan pihak lain dan sesuai aturan yang berlaku.

## Mengirim Event Demo ke QBot

```bash
# Tool sedang berjalan
./send-event.py PreToolUse '{"tool_name": "bash", "tool_input": {"command": "git status"}}'

# Tampilan approval (info saja, tanpa tombol)
./send-event.py PermissionRequest '{"tool_name": "terminal", "message": "Dangerous command: rm -rf /tmp/demo_test"}'

# Sukses / Finish (Mochi lompat senang)
./send-event.py StopSuccess '{"message": "Deploy selesai!"}'
```

## Keamanan Lokal

- HTTP bridge hanya `127.0.0.1` dan wajib token acak per-run di
  `$XDG_RUNTIME_DIR/hermes-coucou/bridge.token` (mode 0600).
- Request dengan header `Origin` browser ditolak.
- `/launch` hanya menerima nama aksi terdaftar (editor, terminal, files,
  screenshot, volume, open_url, open_project) — tanpa shell bebas.
- Catatan disimpan atomik setelah validasi payload.

## Troubleshooting

| Gejala | Penyebab / solusi |
|---|---|
| Tombol approval tidak muncul | Bridge belum tersambung ke Hermes: cek `websockets` terpasang, `hermes_cli.main serve` berjalan |
| Status "Hermes Offline" | Proses Hermes tidak ditemukan atau token/port belum terbaca |
| Perintah ditolak 401 | Bridge lama masih jalan / token beda instance — lihat `pgrep -af mochi_bridge` |
| Port 4848 sudah terpakai | Matikan bridge lama sebelum menjalankan instance baru |
| Layout QML aneh | `qmllint --ignore-settings linux-app/HermesMochi.qml` |

Diagnostik bridge (termasuk alasan kegagalan approval) dicetak ke **stderr**,
terlihat di terminal tempat `./run.sh` dijalankan.

## Lisensi & Kredit

MIT. Berbasis [Coucou](docs/README-coucou-windows.md) — maskot Mochi dan desain
island berasal dari proyek tersebut.
