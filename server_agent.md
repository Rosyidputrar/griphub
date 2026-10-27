# server_agent.md — GripHub: agent berjalan di VPS (porting dari CoderRa)

Status: rencana, belum ada kode. Disusun dari pembacaan kode GripHub (`main` 4d0333e) dan mode server CoderRa
(`seseegy/coderra` 5071362, dokumen `update_agent.md` plus kodenya). Mode server CoderRa sudah dipakai pemilik di
VPS sungguhan dan berjalan baik. Yang diambil hanya **cara kerja server**; fitur agent tetap milik GripHub karena lebih
maju (subagent asinkron, billing GripHub Router, approval, todo, GitHub sync, Cloudflare).

## 1. Tujuan dan keputusan

Agent (host Node + pi) bisa berjalan di VPS dan tetap bekerja saat HP mati atau app ditutup. App di HP menjadi klien
untuk chat, subagent, file, editor, preview, terminal, git, dan deploy. Mode di HP tetap ada dan tidak berubah.

| Topik | Keputusan |
| --- | --- |
| Pengguna | Satu pemilik, satu VPS, satu klien aktif (perangkat baru menendang yang lama) |
| Transport | SSH dengan kunci app ke daemon yang tetap hidup. Tidak ada port baru, relay, atau domain |
| Sumber kebenaran | VPS. File dibaca dan ditulis lewat RPC `fs_*`, bukan sync |
| User server | `griphub`, tanpa sudo. Bash agent di Podman rootless (`box`) |
| Mode HP | Dipertahankan, perilakunya identik (diuji: protokol stdio tanpa `seq`, tanpa buffer) |
| Basis kode | CoderRa sebagai **referensi dan sumber file berdiri sendiri**, bukan merge. `host.ts` beda ±1.650 baris, `agent_client.dart` hampir seluruhnya, subagent beda desain |

## 2. Arsitektur

```
App (Flutter) ── MethodChannel griphub/agent ──> Kotlin AgentRuntime
                                                  │ mode HP    : libnode.so host.mjs            (seperti sekarang)
                                                  │ mode server: ssh -F <cfg> griphub-vps .griphub/bin/griphub-attach
                                                  ▼
VPS, user griphub:  sshd ─> griphub-attach ─unix socket 0600─> griphub-hostd (systemd --user, Restart=always)
                                                                 ├─ host.mjs (pi, Guard, subagent, router, runs, ...)
                                                                 ├─ Hub: seq + ring buffer + resume (transport.ts)
                                                                 ├─ fs.ts, preview.ts, health.ts, notify.ts (ntfy)
                                                                 └─ bash agent ─> box ─> Podman rootless
```

Host di VPS adalah isi `agent.zip` dari APK yang disalin dengan `rsync`, jadi **versi host di VPS selalu sama dengan
versi APK** (sudah terbukti: `agent.zip` GripHub boot di Linux x86_64 dengan Node biasa).

## 3. Yang diambil dari CoderRa

### 3.1 Disalin hampir apa adanya (lalu diganti nama `coderra` → `griphub`, `ANDROPI_` → `GRIPHUB_`)

| Asal CoderRa | Isi | Catatan untuk GripHub |
| --- | --- | --- |
| `agent/src/transport.ts` | `Hub`, `LineBuffer`, `RestartGate`, `listenOnSocket`, `stdioConn` | `REPLAYED_TYPES` diubah (bagian 4.1) |
| `agent/src/fs.ts` | `fs_*` dengan pagar root, unggah berpotongan, `expectMtime` | Root: workspace (rw), `agentDir/skills` (ro) |
| `agent/src/preview.ts` | Server statis 127.0.0.1 + token | — |
| `agent/src/podmanbox.ts` | Box di balik `container_*` | Juga untuk wrangler Cloudflare (4.8) |
| `agent/src/health.ts`, `notify.ts` | Penjaga disk/memori, ntfy | Ditambah jenis notifikasi subagent (4.3) |
| `agent/src/agents-file.ts` | Teks `AGENTS.md` HP vs server | Teks HP GripHub harus identik byte per byte dengan sekarang |
| `server/` | `bootstrap.sh`, `*-attach`, unit systemd, `box/`, test bootstrap | Prefix setup code `griphub1:` |
| `lib/agent/agent_backend.dart` | `AgentBackend`, `PlatformBackend`, `ProcessBackend` | Channel tetap `griphub/agent` |
| `lib/agent/agent_fs.dart`, `remote_fs.dart` | `AgentFs`, `LocalFs`, `RemoteFs` | — |
| `lib/agent/remote_profile.dart`, `remote_mode.dart`, `port_forward.dart` | Setup code, kunci, ssh config, install rsync, forward | Alias `griphub-vps`, berkas `~/.ssh/griphub_*` |
| `lib/ui/server_screen.dart`, `box_screen.dart`, `transfer_dialog.dart` | Layar Server agent, box, progres transfer | Disesuaikan ke `kit.dart`/`i18n.dart` GripHub (ID + EN) |
| Test: transport, fs, preview, attach, sshd asli, `ProcessBackend` | | Dijalankan di CI GripHub |

### 3.2 Ditulis ulang di kode GripHub (pola dari CoderRa)

- `host.ts`: `send()` → `hub.emit()`, opsi `--listen` / `GRIPHUB_LISTEN`, `GRIPHUB_MODE`, `case` baru, `main()` bercabang
  stdio/socket, shutdown bersih, penanda `running`.
- `AgentClient`: reconnect dengan backoff 1/2/4/8/16/30 s, `resume {since, epoch}`, dedup `seq`, `kicked`, jawaban `ping`
  dengan flag latar belakang, `ConnectionState`, panggilan saat putus gagal `offline`/`connection_lost`.
- `AgentController`: `resync()` saat `gap` (bagian 4.2), `BootStatus` tanpa layar gagal penuh saat menyambung ulang.
- Kotlin `AgentRuntime.startRemote(argv, env)` dan `appInfo` (tanpa `GRIPHUB_STORE_KEY` ke proses ssh).

### 3.3 Tidak dibawa

| CoderRa | Alasan |
| --- | --- |
| Update APK lewat host (fase 8 CoderRa) | GripHub mengunduh APK lewat Android DownloadManager di HP; masalahnya tidak ada |
| Tool `tasks` dan `subagent` CoderRa | GripHub punya `todo_write` dan subagent asinkron yang lebih lengkap |
| Provider gratis Zelai, login flow CoderRa | Di luar cakupan; GripHub terkunci ke GripHub Router |
| `longtask.ts` (supervisor 24 jam) | Ditunda ke fase opsional (bagian 6, fase 8) setelah mode server stabil |

## 4. Benturan dengan fitur GripHub dan keputusannya

### 4.1 Replay dan volume record subagent

Masalah: subagent GripHub mengirim satu `subagent_event` per delta streaming (`subagent.ts:567`). Bila ikut ring buffer
(5.000 record / 20 MB), beberapa subagent aktif bisa mendorong keluar riwayat chat utama dan memaksa `gap`.

Keputusan:
- **Di-replay**: `event`, `approval`, `approval_dismiss`, `task`, `runs`, `run_finished`, `agent_done`, `dev_server`,
  `tunnel`, `notice`, `state`, `error`, `mcp`, plus khas GripHub: `subagent_started`, `subagent_status`,
  `subagent_queued`, `subagent_finished`, `subagent_approval_request`, `subagent_approval_dismiss`, `integrations`,
  `sync`, `models_changed`.
- **Tidak di-replay**: `subagent_event` (delta), `auth_*` (alur login hidup), `ping`/`pong`.
- Setiap `resume` (bukan hanya saat `gap`) diikuti `refreshSubagents()` (`subagent_list`, sudah ada di
  `agent_controller.dart:129`) supaya kartu subagent kembali utuh dari snapshot. Transkrip tool subagent ada di
  `toolCalls` pada record, jadi delta yang terlewat tidak hilang permanen.
- Test: 3 subagent aktif mengalirkan ribuan delta selama klien putus; setelah resume, chat utama tidak `gap` dan kartu
  subagent sesuai snapshot.

### 4.2 Approval yang tertunda saat HP offline

Masalah: `Guard` GripHub hanya menyimpan resolver (`guard.ts:75`), dan snapshot subagent hanya membawa status
`waiting_approval` tanpa isi permintaannya. Setelah `gap`, kartu approval tidak bisa dipulihkan dan agent atau subagent
menunggu selamanya.

Keputusan:
- `Guard.pendingApprovals()` menyimpan record lengkapnya (seperti CoderRa `guard.ts:108`).
- `SubagentManager`: record subagent membawa `approval` yang sedang menunggu (id, tool, ringkasan, alasan, key) dan
  `subagent_list` ikut mengirimnya; Dart `SubagentState` membaca field itu.
- Perintah `approvals_pending` mengembalikan approval chat **dan** subagent. `resync()` memanggilnya.
- Test: approval muncul saat klien tidak tersambung, buffer dibuang (`gap`), lalu approval tetap bisa dijawab dari app.

### 4.3 Notifikasi saat app tertutup

Sekarang notifikasi dibuat oleh HP (`home_shell.dart` untuk `agent_done`, `SubagentNotifier` untuk subagent), jadi di mode
server app yang tertutup tidak tahu apa-apa.

Keputusan: host mengirim ntfy (`notify.ts`) bila tidak ada klien atau klien di latar belakang, judul generik tanpa isi:
"Agent selesai", "Butuh persetujuan", "Subagent selesai", "Subagent gagal", "Subagent butuh persetujuan",
"Task selesai/gagal", "Disk hampir penuh", "Host dimulai ulang". Toggle notifikasi subagent yang sudah ada di Settings
(`subagentNotify*`) juga dipatuhi host. Saat app di depan, notifikasi lokal tetap seperti sekarang.

### 4.4 GitHub sync

`sync.ts` menyalin chat dan proyek antar-HP lewat repo `griphub-sync`. Di mode server VPS adalah sumber kebenaran.
Keputusan: sync **mati** di host mode server (layar Sync menjelaskan alasannya). Pindah data HP ↔ server lewat backup.

### 4.5 Kunci, token, dan provider

API key GripHub Router, token GitHub/Vercel/Cloudflare, dan search key disimpan host di VPS, terenkripsi dengan
`GRIPHUB_STORE_KEY` dari `~/.griphub/env` (0600, dibuat sekali oleh bootstrap, tidak pernah diganti). Pertama kali masuk
mode server, onboarding "Hubungkan model" muncul seperti install baru (semua lewat perintah host yang sudah ada).
Opsional nanti: "Salin akun dari HP" lewat backup terenkripsi.

Refresh token GitHub (PR #8) berjalan di host, jadi otomatis ikut. Timer 10 menit menjaga token tetap segar 24 jam.

### 4.6 Lampiran dan teks tempelan

`preparePrompt` (`chat_extras.dart`) menyalin lampiran ke `$cwd/.attachments` di HP. Di mode server: unggah lewat
`AgentFs.upload` dengan progres dan batal; gambar tetap base64 di prompt. `pasted-text.txt` ikut jalur ini.
Chip "Konten yang ditempel" dan viewer lampiran membaca lewat `agent.fs`. Drafts tetap lokal di HP.

### 4.7 Preview HTML, live preview, dev server

- File HTML: `preview_serve` + forward `ssh -L` → `HtmlPreviewScreen.openUrl` (aset relatif ikut).
- Live preview saat agent menulis tetap dari teks streaming (`_LiveTail`/`_htmlSource`, PR #8), tidak butuh file.
- Dev server: banner `dev_server` membuka forward ke port VPS. Batas CoderRa berlaku: hanya 127.0.0.1 (Vite perlu
  `--host 127.0.0.1`); dicatat di teks `AGENTS.md` server.

### 4.8 Container, Cloudflare, dan shell

- `container.ts` (proot) tidak dipakai di server; `PodmanBox` mengambil alih `container_*`.
- `integrations.ts:847` menjalankan wrangler lewat `GRIPHUB_ROOTFS` (proot). Di server diarahkan ke `box -c`.
- `mcp.ts:86` `/system/bin/sh` → `/bin/sh` di server. DNS bawaan `system` (bukan DoH Cloudflare) di server.

### 4.9 Lain-lain

| Hal | Keputusan |
| --- | --- |
| `keepAlive`/`setBusy` (foreground service HP) | Tidak dipanggil di mode server; agent hidup di VPS |
| Layar Terminal (`terminal_pane.dart`, `flutter_pty`) | Mode server: `ssh -tt` ke sesi **tmux** `griphub-sh-N` / `griphub-box-N` |
| Run background tanpa pengawasan | Mode `deny_risky` di host (pola CoderRa), juga untuk subagent saat tidak ada klien |
| Daily budget, biaya per giliran, usage | Jalan di host, tidak berubah |
| Pindah mode | Chat HP dan chat server terpisah (`agentDir` masing-masing); indikator "HP / Server" di header chat |
| Versi host vs APK | `hello_server.hostVersion` dibandingkan `agent.stamp`; beda → banner "Perbarui agent di server" |

## 5. Layar yang membaca disk HP (diaudit dengan grep, diverifikasi saat dikerjakan)

| Layar | Pemakaian `dart:io` | Perubahan |
| --- | --- | --- |
| `files_screen.dart` | 18 | Semua lewat `agent.fs`; gambar `Image.memory`; impor = unggah; bagikan/simpan = unduh dulu |
| `editor_screen.dart` | 3 | `fs.read`/`fs.write` + dialog konflik (`expectMtime`) |
| `folder_picker.dart` | 3 | Async, hanya root VPS, `git` dari `fs_list` |
| `chat_extras.dart` | 7 | Lampiran dan teks tempelan diunggah (4.6) |
| `message_views.dart` | 3 | Preview lewat server (4.7) |
| `image_gen_screen.dart` | 10 | Simpan hasil gambar lewat `fs.write` di workspace VPS |
| `deploy_sheet.dart` | 3 | Diaudit: kemungkinan hanya path string untuk host |
| `attachment_viewer.dart`, `skills_screen.dart`, `new_chat_sheet.dart`, `home_shell.dart` (quick start) | 1 masing-masing | `agent.fs` |
| `terminal_screen.dart`, `terminal_pane.dart` | 3 | 4.9 |
| `drafts.dart`, `theme.dart`, `todos.dart`, `sent_attachments.dart` | — | Tetap lokal (data milik app, bukan workspace) |

## 6. Fase

Setiap fase berakhir dengan PR sendiri, CI hijau, dan kondisi selesai yang bisa diperiksa. Perkiraan dari bacaan kode.

| Fase | Isi | Selesai bila | Perkiraan |
| --- | --- | --- | --- |
| 1 | Host: `transport.ts`, `send`→`emit`, `--listen`, `resume`, `kicked`, `ping`, `host_restart`; `REPLAYED_TYPES` GripHub (4.1); `pendingApprovals` chat + subagent (4.2) | Test Node: putus/resume tanpa duplikat, gap, kick, banjir `subagent_event` tidak mendorong keluar chat, approval tertunda bisa dijawab setelah gap; mode stdio identik (semua test lama lulus) | 3 hari |
| 2 | Host mode server: `agents-file`, MCP shell, DNS, `PodmanBox` + wrangler via box, `health`, `notify` + notifikasi subagent, sync mati, `deny_risky`, `fs.ts`, `preview.ts` | Test Node per modul; host asli sebagai daemon menjawab `hello`/`fs_*`/`preview_serve`; teks `AGENTS.md` HP identik byte per byte | 3–4 hari |
| 3 | `server/`: bootstrap, attach, unit, box, test bootstrap di container | `bootstrap.sh --dry-run` bersih, shellcheck bersih, attach diuji dengan sshd asli | 1 hari |
| 4 | Dart transport: `AgentBackend`, `AgentClient` reconnect, `resync` (+ `refreshSubagents`, approvals, runs, integrations), Kotlin `startRemote`/`appInfo`, `RemoteProfile`/`RemoteMode`, layar Server agent, indikator koneksi | Test Dart melawan daemon Node asli lewat attach + sshd asli: putus berulang tanpa duplikat; subagent dan approval pulih; FakeHost lama tetap jalan; golden layar baru | 4–5 hari |
| 5 | `AgentFs`/`RemoteFs` di semua layar bagian 5; unggah lampiran dan teks tempelan | Test layar dijalankan dua kali (LocalFs dan RemoteFs ke daemon asli); golden; dialog konflik editor | 5 hari |
| 6 | Preview + forward, dev server, terminal tmux, backup unduh/unggah | Rantai penuh app → ssh → daemon → preview dengan CSS relatif; tmux bertahan setelah koneksi dibunuh | 3 hari |
| 7 | Uji di VPS sungguhan (pemilik): bootstrap, install agent dari app, chat, subagent paralel, approval saat offline, notifikasi, deploy, 24 jam | Checklist uji lapangan lulus; catatan memori/disk | 1–2 hari + soak |
| 8 (opsional) | Operasi panjang: `longtask`, retry/fallback run headless, lanjut otomatis setelah crash, bar "Lanjutkan" | Test Node dengan model tiruan (pola CoderRa `pi_e2e`) | 3–4 hari |

Total inti (fase 1–7): sekitar 3 minggu kerja.

## 7. Strategi uji

- Node (`agent/test`): test CoderRa untuk transport/fs/preview/attach dibawa dan disesuaikan; test baru untuk 4.1 dan 4.2;
  daemon asli sebagai proses; sshd asli di loopback dengan opsi kunci dari `bootstrap.sh`.
- Dart: `ProcessBackend` menjalankan daemon Node asli; FakeHost lama dipertahankan untuk mode HP; golden layar baru
  (terang/gelap, EN/ID, 320 dp × 1,3).
- CI: workflow test GripHub menjalankan `npm test` dan `flutter test` (sekarang hanya build APK).
- Mutasi: setiap pengaman (dedup, `REPLAYED_TYPES`, pagar root, approval pending, StrictHostKeyChecking) dibuang sekali
  untuk memastikan test gagal.

## 8. Risiko dan yang belum diverifikasi

- Volume record subagent di jaringan seluler buruk (4.1): diukur di fase 1 dengan banjir sintetis.
- Memori VPS dengan beberapa subagent paralel (semua dalam satu heap host): diukur di fase 7; batas paralel subagent
  (`MAX_RUNNING = 3`) mungkin perlu diturunkan di server 4 GB.
- Tes CoderRa belum dijalankan di sesi ini (pengaman sesi menolak menjalankan kode repo lain). Kode CoderRa dibaca,
  bukan dieksekusi; test yang dibawa akan dijalankan di repo GripHub.
- Kotlin GripHub (`AgentRuntime.kt`) berbeda dari CoderRa (paket `id.griphub.agent`); `startRemote` ditulis ulang, bukan disalin.

## 9. Pertanyaan terbuka untuk pemilik

1. Nama user dan folder di server: `griphub` dan `~/.griphub` (usulan), atau tetap `coderra` agar VPS yang sudah ada
   bisa dipakai ulang?
2. VPS yang dipakai sekarang untuk CoderRa: dipasang ulang untuk GripHub, atau GripHub di VPS terpisah?
3. ntfy: pakai `ntfy.sh` atau server sendiri?
4. Fase 8 (supervisor 24 jam): ikut sekarang atau setelah fase 7?
