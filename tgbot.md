# tgbot.md — GripHub: kendalikan agent di server lewat bot Telegram milik sendiri

Status: **rancangan, belum diimplementasikan.** Disusun dari pembacaan kode GripHub (`main` 70009bd) dan dokumentasi resmi
Telegram Bot API yang dibaca pada 1 November 2026 (versi terbaru saat itu: **Bot API 10.3**, 24 Agustus 2026). Setiap fakta
Telegram di bawah ditandai **[dok]** bila dibaca di dokumentasi resminya, dan **[BELUM DIVERIFIKASI]** bila belum; yang
terakhir diuji lebih dulu di Fase 0 (bagian 14), sebelum ada kode yang bergantung padanya.

## 1. Tujuan dan keputusan

Pemilik server bisa memberi tugas ke agent, menyetujui aksi berisiko, melihat hasilnya, dan menghentikannya dari Telegram,
tanpa membuka aplikasi. Yang dikendalikan adalah **agent yang sama** yang dipakai aplikasi, bukan agent kedua.

| Topik | Keputusan |
| --- | --- |
| Siapa yang membuat bot | **Tiap pengguna membuat botnya sendiri** lewat @BotFather. Tidak ada bot bersama, relay, atau server milik GripHub. |
| Di mana bot berjalan | **Di dalam host** di server pengguna (`griphub-hostd`). Tidak ada proses, port, domain, atau paket baru. |
| Mode | **Hanya mode server.** Di HP, sistem Android mematikan proses latar sehingga bot tidak bisa diandalkan. |
| Cara menerima pesan | **Long polling** `getUpdates` ke `api.telegram.org`. Hanya butuh koneksi keluar HTTPS. Tanpa webhook. |
| Siapa yang boleh memerintah | **Satu akun Telegram** (satu `chat_id` pribadi), dipasangkan lewat kode sekali pakai dari aplikasi. |
| Bahasa bot | **Mengikuti bahasa aplikasi** (`id` atau `en`), disimpan host. |
| Streaming jawaban | **Draf animasi** (`sendRichMessageDraft`) lalu pesan permanen. Cadangan: pesan yang diedit. |
| Format jawaban | **Pesan kaya** (Markdown Telegram). Cadangan: HTML, lalu teks biasa. |
| Tombol | Persetujuan dengan **tombol berwarna** (hijau Izinkan, merah Tolak). Tombol cepat tetap di bawah kolom ketik. |
| Wewenang | Telegram **tidak bisa** menaikkan wewenang: tanpa "Selalu", tanpa "Bypass semua", tanpa menjawab persetujuan yang menyentuh rahasia. |
| Isi yang keluar ke Telegram | Jawaban agent boleh keluar dalam bentuk penuh, dengan peringatan di layar setup bahwa Telegram **tidak terenkripsi ujung ke ujung**. Rahasia disaring dulu (bagian 4.4). |

Yang **tidak** dikerjakan di versi pertama: lampiran dan foto dari Telegram ke agent, pesan suara, grup dan channel, lebih dari
satu akun, bot di mode HP, menjawab `Selalu` dari Telegram, mengganti mode persetujuan ke "Bypass semua".

## 2. Fakta kode yang menentukan rancangan (sudah diperiksa)

| Fakta | Lokasi | Akibat |
| --- | --- | --- |
| Semua record ke aplikasi lewat satu fungsi, `send(record)`. Di server ia memanggil `hub.emit()` lalu `notifyFor()`. | `agent/src/host.ts:184` | **Bot menjadi sink kedua di titik yang sama**, memakai aliran record yang sama dengan aplikasi. Tidak ada jalur data baru dan tidak ada logika kedua yang bisa menyimpang. |
| Event sesi pi dikirim sebagai `{type:"event", event}` setelah `wireEvent()`. `agent_done` dikirim di akhir giliran (dengan `retrying`). | `host.ts:305`, `host.ts:552`, `host.ts:590` | Bot membangun jawabannya dari `message_update`, `tool_execution_*`, `message_end`, `agent_done`, persis seperti aplikasi. |
| Host punya **satu sesi aktif global** (`session`). Memindahkan chat (`open_session`) ditolak saat agent bekerja (`assertIdle`). | `host.ts:515`, `host.ts:1582` | Aplikasi dan bot adalah dua pengendali **satu chat yang sama**. Memindah chat dari bot mengubah chat di aplikasi. Ditangani di 7.3. |
| `Hub` hanya melayani satu klien, klien baru menendang yang lama. | `transport.ts:22`, `transport.ts:263` | **Tidak berlaku untuk bot**, karena bot ada di dalam proses host dan memanggil `handle()` langsung. Bot tidak menendang aplikasi dan sebaliknya. |
| `prompt` saat agent sibuk masuk antrean (`followUp`) lewat `PromptQueue`. | `host.ts:1344`, `promptqueue.ts` | Pesan Telegram yang datang saat agent bekerja otomatis antre. Bot cukup memberi tahu posisinya. |
| Kartu persetujuan: `{type:"approval", approvalId, toolName, summary, reason, key, patch?}`. Jawaban: `approval_reply {approvalId, allow, always, key}`. Yang tertunda: `approvals_pending`. | `guard.ts:20`, `host.ts:1413` | Cukup untuk tombol Telegram. `always` tidak pernah dikirim dari Telegram. |
| Persetujuan subagent: `subagent_approval_request`, jawaban `subagent_approval_reply`. | `host.ts:276`, `host.ts:1443` | Diteruskan dengan cara yang sama. |
| Notifikasi ntfy sudah punya aturan "jangan kirim bila orang sedang melihat aplikasi" (`shouldSend`, `Hub.clientInBackground()`). | `notify.ts`, `transport.ts:296` | Pola yang sama dipakai untuk "hanya kirim saat aplikasi tidak dibuka". |
| Pengaturan di `integrations.json` terenkripsi (`secure.ts`). Kunci ditampilkan ke aplikasi hanya sebagai masker (`keys.brave` dst.). Validasi di `settings_set`. | `integrations.ts:214`, `integrations.ts:282`, `integrations.ts:336` | Token bot disimpan dan ditampilkan dengan pola yang sama. |
| `checkBudget()` dan `health.assertRoom()` dijalankan di `prompt`. Kesalahannya sudah terstruktur (kode dan data) sejak UX-09. | `host.ts:1348` | Pesan Telegram otomatis tunduk pada anggaran harian dan batas disk. Bot hanya menerjemahkan kodenya. |
| Host **tidak tahu bahasa aplikasi** (tidak ada `language` di pengaturan host). | `grep language agent/src` | Aplikasi harus mengirimnya (bagian 9). |
| Host berjalan langsung di VPS, bukan di dalam box. Agent (bash) berjalan di Podman dan **tidak mewarisi env host**. | `server_agent.md` bagian 2 | Koneksi keluar ke Telegram tidak melewati box, dan agent tidak bisa membaca token lewat env. |

## 3. Arsitektur

```
Telegram ◄──HTTPS──► api.telegram.org
                        ▲  long polling (keluar saja)
VPS, user griphub:      │
 griphub-hostd (host.mjs)
   ├─ send(record) ──► hub.emit() ──► aplikasi
   │        └────────► telegram.onRecord()          ◄── sink kedua, aliran record yang sama
   ├─ handle(cmd)  ◄── hub (aplikasi)
   │        ▲────────── telegram.command()          ◄── bot memanggil handle() langsung
   └─ telegram.ts
        ├─ TelegramApi    HTTP, batas laju, retry_after, 409/401/429, base URL bisa diganti untuk uji
        ├─ Poller         getUpdates, offset tersimpan, usia pesan, debounce, dedup update_id
        ├─ Pairing        kode 6 digit, jendela 5 menit, batas percobaan, tautan t.me/<bot>?start=<kode>
        ├─ Router         pesan → perintah host; tombol → persetujuan/stop
        ├─ Renderer       record → draf / pesan akhir / kartu persetujuan / pemberitahuan
        ├─ Formatter      sanitasi Markdown, redaksi rahasia, pemecahan, tangga cadangan format
        └─ Strings        tabel teks id/en
```

`telegram.ts` tidak mengimpor `host.ts`. Ia menerima satu objek `TelegramHost` (dependency injection), supaya bisa diuji tanpa
menjalankan host:

```ts
interface TelegramHost {
  command(cmd: { type: string; [k: string]: unknown }): Promise<unknown>; // = handle()
  settings(): TelegramSettings;                                           // dibaca setiap kali
  save(patch: Partial<TelegramSettings>): void;
  language(): "id" | "en";
  appInBackground(): boolean;                                             // = hub.clientInBackground()
  now(): number;
  log(line: string): void;
}
```

## 4. Model keamanan

Telegram memberi **wewenang mengeksekusi perintah di server**. Seluruh bagian ini ada untuk membatasi apa yang bisa terjadi
kalau akun Telegram, token bot, atau teks yang dibaca agent jatuh ke tangan yang salah.

### 4.1 Ancaman dan penangkalnya

| Ancaman | Penangkal |
| --- | --- |
| Orang asing menemukan bot dan memberi perintah | Hanya `chat_id` yang terpasang yang dilayani. Pesan dari ID lain **tidak dijawab sama sekali**. Hanya chat `private` dengan `chat.id == from.id`. Grup, supergrup, channel, dan `edited_message` diabaikan. |
| Menebak kode pairing | Kode 6 digit dari `crypto.randomInt`, berlaku **5 menit**, **sekali pakai**, **5 percobaan salah** menutup jendelanya, dibandingkan dengan `timingSafeEqual`. Jendela hanya dibuka dari aplikasi. Setelah ada yang terpasang, pairing mati sampai pengguna memutuskannya. |
| Akun Telegram pemilik diambil alih | Tidak bisa dicegah sepenuhnya. Dibatasi: tidak ada "Selalu", tidak ada "Bypass", persetujuan rahasia tidak bisa dijawab, dan **mode "Bypass semua" menolak prompt dari Telegram** (4.3). Aplikasi punya tombol Putuskan yang langsung menghentikan bot. |
| Token bot bocor | Disimpan terenkripsi (`secure.ts`), tidak pernah dikirim balik ke aplikasi (hanya masker `1234…:AAH…`), disaring dari log dan pesan error (4.4). Token yang bocor memungkinkan orang lain **membaca** balasan, tetapi bukan **memerintah** (itu tetap dikunci `chat_id`). Aplikasi menjelaskan cara mencabutnya (`/revoke` di BotFather). |
| Pesan lama dijalankan setelah host mati dan hidup lagi | Pesan lebih tua dari **120 detik** (`message.date`) ditolak dengan "Pesan ini sudah X menit, kirim lagi bila masih perlu". `update_id` terakhir disimpan. Tombol milik persetujuan yang sudah mati dijawab "tidak berlaku". |
| Prompt injection menyuruh agent membocorkan data lewat jawabannya | Jawaban disaring sebelum dikirim: embed media, tautan `tg://`, dan tag HTML mentah dibuang, tautan menjadi teks kode yang tidak bisa diketuk (4.2). Redaksi rahasia (4.4). |
| Tombol persetujuan ditekan dua kali, atau ditekan orang lain di chat yang sama | `callback_query.from.id` harus sama dengan akun terpasang. Tiap persetujuan punya status (`open`, `answered`) di memori, dan jawaban kedua diabaikan dengan "sudah dijawab". |
| Telegram memuat tautan (pratinjau) dan itu membocorkan data | Tautan tidak dikirim sebagai tautan aktif (4.2), dan `skip_entity_detection: true` mencegah deteksi URL otomatis. **[BELUM DIVERIFIKASI]** apakah pesan kaya membuat pratinjau tautan; ditutup lewat aturan di atas apa pun jawabannya. |
| Bot dibanjiri pesan sampah | Pesan dari ID tak dikenal dibuang tanpa balasan. Dari ID terpasang: maksimal 20 pesan per menit, selebihnya "Terlalu cepat". |
| Spoofing teks (karakter bidi, tanpa lebar) | Karakter kontrol Unicode (U+200B–U+200F, U+202A–U+202E, U+2066–U+2069) dibuang dari teks agent sebelum dikirim. |
| Dua host memakai token yang sama | Telegram membalas 409. Bot berhenti dengan status `conflict` dan pesan jelas (bagian 6). |

### 4.2 Aturan penyaringan jawaban agent (sebelum dikirim)

Berlaku untuk teks dari agent, bukan untuk teks yang dibuat bot sendiri. Diterapkan hanya **di luar blok kode**:

1. Embed media (`![alt](url)`, `![](url)`) diganti teks kode `url`. Telegram tidak mengambil apa pun.
2. Setiap tautan `[teks](url)` menjadi `teks` dan `` `url` `` (tidak bisa diketuk). Pengaturan "Tautan bisa diketuk" (bawaan **mati**) mengembalikannya untuk tautan `https://` tanpa query dan tanpa fragmen.
3. Tautan `tg://...` dibuang seluruhnya.
4. `<` di-escape menjadi `&lt;`, supaya agent tidak bisa menyuntikkan `<tg-button-row>`, `<tg-thinking>`, `<tg-collage>`, atau `<details>`. Pembungkus `<details>` dibuat oleh bot sendiri.
5. `$` di-escape menjadi `\$` (agar harga tidak dibaca sebagai rumus), `||` dan `==` di-escape (agar tidak menjadi spoiler atau penanda).
6. Tabel dengan lebih dari 20 kolom, atau sel berisi baris baru, menjadi blok kode.
7. Karakter kontrol Unicode dibuang.
8. `skip_entity_detection: true` selalu dikirim, supaya `/etc/passwd`, `@types/node`, `#123`, dan `$USD` tidak menjadi perintah, mention, hashtag, atau cashtag.

### 4.3 Wewenang Telegram

| Tindakan | Dari Telegram |
| --- | --- |
| Kirim prompt, `/stop`, `/new` | Boleh |
| Izinkan atau tolak persetujuan biasa | Boleh, per kejadian |
| "Selalu" | **Tidak ada tombolnya** |
| Persetujuan yang menyentuh rahasia (`secretReadRisk`) | **Tanpa tombol**: "Buka aplikasi untuk menjawab" |
| Mengubah mode persetujuan | `/mode` hanya mengetatkan: `ask_all` atau `ask_risky`. Tidak pernah `auto` |
| Prompt saat mode global **Bypass semua** | **Ditolak** dengan penjelasan, kecuali pengguna menyalakan "Izinkan Telegram saat Bypass" di aplikasi (bawaan mati) |
| Menghapus chat, mengubah pengaturan, anggaran, kunci | Tidak ada perintahnya |

### 4.4 Redaksi rahasia

Sebelum teks apa pun dikirim ke Telegram (jawaban, kartu persetujuan, pesan error, log), `Formatter.redact()` mengganti dengan
`•••`:

- nilai persis dari rahasia yang tersimpan di host: token bot, key GripHub Router, token GitHub/Vercel/Cloudflare, kunci
  pencarian, kunci penyimpanan (`GRIPHUB_STORE_KEY`);
- pola umum: `ghp_…`, `github_pat_…`, `sk-…`, `AKIA…`, `xox[abp]-…`, `-----BEGIN … PRIVATE KEY-----` sampai
  `END`, `\d{8,10}:[A-Za-z0-9_-]{35}` (bentuk token bot).

URL API Telegram berisi token (`https://api.telegram.org/bot<TOKEN>/…`), jadi **setiap pesan error dari `fetch` disaring**
sebelum masuk log atau ke aplikasi. Ini diuji dengan token palsu yang dimasukkan ke error buatan.

## 5. Pairing dan penyimpanan

### 5.1 Data

Disimpan di `integrations.json` (terenkripsi), tampil ke aplikasi sebagai objek `telegram` yang tidak memuat token:

| Kolom | Isi |
| --- | --- |
| `telegramToken` (rahasia) | Token dari BotFather. Disimpan setelah `getMe` berhasil |
| `telegramBot` | `{id, username, name}` dari `getMe` |
| `telegramChatId`, `telegramUserId` | Akun terpasang. Kosong = belum dipasangkan |
| `telegramPairedName` | Nama yang tampil di aplikasi ("Rosyid") |
| `telegramEnabled` | Bot menyala atau dimatikan tanpa menghapus token |
| `telegramSendFull` | Kirim jawaban lengkap (bawaan hidup) atau hanya ringkasan 600 karakter |
| `telegramOnlyWhenAway` | Hanya kirim saat aplikasi tidak dibuka (bawaan hidup) |
| `telegramLinks` | Tautan bisa diketuk (bawaan mati) |
| `telegramAllowBypass` | Izinkan prompt saat mode Bypass (bawaan mati) |
| `language` | `id` atau `en`, dikirim aplikasi (bagian 9) |
| `telegramFormat` | `rich`, `html`, atau `plain`: hasil uji kemampuan |
| `telegramDraft` | `true` bila draf didukung |

`update_id` terakhir **tidak** disimpan di sini (ditulis tiap pesan, terlalu sering untuk file terenkripsi). Ia ada di
`~/.griphub/telegram.json`, berkas kecil tanpa rahasia, ditulis atomik.

Kode pairing hanya ada di memori. Host yang mati membatalkan pairing yang sedang berjalan, dan itu memang yang diinginkan.

### 5.2 Alur

1. **Token.** Aplikasi mengirim `telegram_set_token {token}`. Host memeriksa bentuknya, memanggil `getMe`, lalu `deleteWebhook
   {drop_pending_updates:true}` (webhook yang tertinggal menyebabkan 409). Berhasil: token disimpan, poller dimulai, jawabannya
   `{bot}`. Gagal: `invalid` (401) atau `unreachable`.
2. **Mulai pairing.** `telegram_pair_start` membuat kode, jawabannya `{code, expiresAt, link}` dengan `link` =
   `https://t.me/<bot>?start=<kode>`. Ketuk tautan itu di Telegram menampilkan tombol START dan otomatis mengirim
   `/start <kode>`; tanpa mengetik. `/pair <kode>` juga diterima.
3. **Terpasang.** Pesan itu harus datang dari chat `private`. Host mencatat `chatId`, `userId`, nama, menutup jendela, mengirim
   pesan sambutan lewat tangga format (sekaligus **uji kemampuan**, 8.6), memasang tombol cepat, dan mengirim record `telegram`
   ke aplikasi.
4. **Salah kode.** Hanya saat jendela terbuka, dibalas "Kode salah (sisa N percobaan)". Percobaan ke-5 menutup jendela.
   Di luar jendela, `/start` dan `/pair` dari siapa pun tidak dijawab.
5. **Putuskan.** `telegram_unpair` menghapus `chatId` dan `userId`, mengirim "Terputus" ke akun lama, dan membatalkan semua
   persetujuan yang tertunda di Telegram. `telegram_forget` menghapus token dan menghentikan poller.
6. **Ganti token.** Menempel token baru menghentikan poller lama, menghapus pairing, dan memulai dari langkah 1.

Bot **tidak pernah memanggil** `logOut` atau `close`: keduanya memindahkan bot dari `api.telegram.org` dan memutus pengguna.

## 6. Polling

`getUpdates {offset, timeout:30, allowed_updates:["message","callback_query","stopped_message_generation"]}` dengan timeout HTTP
40 detik. `stopped_message_generation` adalah nama kolom `Update` untuk tombol Stop di draf **[dok]**.

| Situasi | Perilaku |
| --- | --- |
| Normal | Proses tiap update berurutan, simpan `update_id + 1` setelah selesai, dedup `update_id` (200 terakhir di memori) |
| Start | Update yang ada ditarik dan yang lebih tua dari 120 detik dibuang (4.1). Update `callback_query` yang persetujuannya sudah tidak ada dijawab "tidak berlaku" |
| Teks panjang | Klien Telegram memecah tempelan >4096 karakter menjadi beberapa pesan beruntun. Pesan dari akun yang sama dalam **1,2 detik** digabung menjadi satu prompt |
| 409 | Ada `getUpdates` lain atau webhook. Status `conflict`, coba lagi tiap 30 detik, pesan di aplikasi: "Token ini dipakai server lain. Satu token hanya untuk satu server" |
| 401 | Token dicabut. Status `invalid`, poller berhenti, aplikasi diberi tahu |
| 429 | Tidur sebesar `retry_after`, lalu lanjut |
| Jaringan putus | Backoff 1 s sampai maksimum 60 s, status `offline` setelah 3 kegagalan, kembali `ok` saat berhasil |
| Host berhenti | Poller dihentikan bersih (`AbortController`), tidak ada permintaan yatim |

Permintaan keluar dibatasi oleh `Limiter` per chat: **jarak minimal 1 detik** antar kirim, edit, dan draf **[dok: FAQ
Bot, "tidak lebih dari satu pesan per detik per chat"]**. Prioritas: persetujuan dan pesan akhir lebih dulu, draf paling bawah
dan hanya yang terbaru yang dipertahankan (draf bersifat sementara). Selama diblokir 429, draf perantara dibuang.

## 7. Perintah dan alur pesan

### 7.1 Perintah

Tombol cepat tetap di bawah kolom ketik (`ReplyKeyboardMarkup`, dipasang saat pairing): **Chat baru · Status · Stop**.

| Pesan | Perintah host | Catatan |
| --- | --- | --- |
| Teks biasa | `prompt {text}` | Saat agent bekerja, `prompt` masuk antrean otomatis. Bot membalas "Masuk antrean (n)" |
| `/stop` atau tombol Stop | `abort` | Sama dengan tombol Stop bawaan draf |
| `/new` atau tombol Chat baru | `new_session` | Ditolak saat agent bekerja ("Agent masih bekerja") |
| `/status` atau tombol Status | `state`, `session_stats`, `usage`, `subagent_list` | Model, mode persetujuan, anggaran hari ini, subagent yang berjalan, nama chat |
| `/mode` | `settings_set {approvalMode}` | Hanya `ask_all` atau `ask_risky` (4.3). Ini pengaturan global yang sama dengan di aplikasi (`applySettings` mengisi `guard.mode`), jadi perubahannya terlihat di aplikasi juga |
| `/chats`, `/open N` | `sessions`, `open_session` | **Fase 3**, bergantung pada record `session_changed` (7.3) |
| `/help`, `/start` (sudah terpasang) | — | Tiga baris, tidak ada daftar panjang |
| Foto, dokumen, suara | — | "Lampiran belum didukung di versi ini" |

### 7.2 Antrean dan pesan yang datang bersamaan dengan aplikasi

Aplikasi dan bot mengirim ke `PromptQueue` yang sama, urutannya FIFO. Kalau pesan Telegram masuk saat pengguna mengetik di
aplikasi, keduanya tetap benar. Bot menandai pesan yang berasal dari aplikasi sebagai "(dari aplikasi)" hanya bila
berbeda dari yang ia kirim sendiri, supaya riwayat di Telegram tidak membingungkan.

### 7.3 Chat aktif itu global

Host punya **satu** sesi terbuka, dan `/open` mengubahnya untuk aplikasi juga. Aplikasi hari ini mengikuti perubahan
sesi hanya lewat balasan perintahnya sendiri; record `state` hanya dikirim host setelah pergantian ke model cadangan
(`host.ts:840`), bukan setiap kali sesi berganti. Maka:

- Fase 1 dan 2: bot hanya bekerja di **chat yang sedang terbuka**; `/new` didukung, `/chats` dan `/open` belum.
- Fase 3: host menambah record **`session_changed {sessionFile, name}`** yang dikirim `openSession` setiap kali sesi berganti,
  dari mana pun asalnya. Aplikasi menanganinya (memuat ulang chat) dan bot memakainya untuk memberi label. Tanpa record
  ini `/open` tidak diaktifkan.
- Setiap balasan diawali nama chat hanya bila lebih dari satu chat punya pekerjaan berjalan (subagent, run, job), supaya
  jawaban tidak tertukar.

## 8. Tampilan di Telegram

### 8.1 Satu giliran, dari prompt sampai jawaban

```
Pengguna: "Perbaiki tes yang gagal di proyek site"
   │
   ▼ agent_start
Draf #7  ─ ◔ Berpikir…  · 3d                         [ Stop ]  ← can_stop (tombol bawaan Telegram)
   ▼ message_update(thinking/text), tool_execution_*
Draf #7  ─ ✓ membaca 4 berkas
           ✓ npm test (gagal, 2 tes)
           … mengedit src/app.ts
           Saya menemukan dua penyebab. Yang pertama …   ← teks jawaban mengalir
   ▼ agent_done (retrying=false)
Pesan permanen (sendRichMessage):
           ## Hasil
           Dua tes gagal karena …
           ```diff
           - const a = 1;
           + const a = 2;
           ```
           ▸ 6 langkah · 1m 12d · ~0,42 kredit      ← <details> terlipat
           3 file berubah
```

### 8.2 Draf

- Satu `draft_id` bukan nol per giliran. Perubahan dengan `draft_id` yang sama dianimasikan **[dok]**.
- Isi: blok "Berpikir…" selama belum ada teks, tiga langkah tool terakhir, lalu teks jawaban yang sedang ditulis.
- Pembaruan digabung tiap **1,2 detik** (8.4). Teks draf dibatasi 3.800 karakter terakhir (draf hanya pratinjau).
- Draf **hanya bertahan 30 detik** bila tidak diperbarui **[dok]**, sedangkan tool seperti `npm test` bisa diam beberapa menit.
  Maka host mengirim ulang draf dengan waktu berjalan **tiap 12 detik** selama giliran masih berjalan.
- Draf hanya untuk chat pribadi **[dok]**, dan memang itu satu-satunya chat yang dilayani.
- `can_stop: true` menampilkan tombol Stop. Menekannya menghasilkan update `stopped_message_generation` dan bot menjalankan `abort`.
- Selesai: pesan permanen dikirim (`sendRichMessage`). Draf lenyap sendiri. Bot **tidak** bergantung pada penghapusan draf.
- Bila `sendRichMessageDraft` ditolak (uji kemampuan gagal atau kesalahan sementara): turun ke **pesan status yang diedit**
  (`editMessageText`, satu pesan, tombol Stop inline), dengan jarak edit yang sama.

### 8.3 Pesan akhir

- Isi: jawaban agent (disaring, 4.2) + satu blok `<details>` terlipat berisi langkah-langkah ("6 langkah · 1m 12d ·
  ~0,42 kredit"), di dalamnya satu baris per tool dengan ✓ atau ✗. Keluaran tool **tidak** ikut.
- Daftar tugas agent (`todo_write`) tampil sebagai daftar tugas Markdown (`- [x]`, `- [ ]`) di atas jawaban bila ada.
- Jawaban lebih dari 30.000 karakter dipecah di batas blok (aturan di 8.5).
- Giliran gagal: pesan dengan ⚠, alasan manusiawi, dan tombol **Coba lagi** (`retry`).
- Dihentikan pengguna: "Dihentikan" di akhir bagian yang sudah ditulis.

### 8.4 Persetujuan

```
⚠ Perlu izin
Menjalankan di "site"
┌──────────────────────────────┐
│ rm -rf build && flutter build │
└──────────────────────────────┘
Alasan: Perintah ini bisa menghapus data
[ Izinkan ]  [ Tolak ]        ← hijau / merah (style: success / danger) [dok]
```

- `reply_markup`: `InlineKeyboardMarkup`, tombol `style:"success"` dan `style:"danger"` **[dok 9.4]**. `callback_data` =
  `a:<approvalId>:y` atau `:n`, jauh di bawah batas 64 byte.
- Edit/tulis file: nama file, jumlah baris, dan paling banyak 40 baris diff dalam blok kode `diff`; selebihnya "…dan N baris lagi".
- Bash: perintah dalam blok kode, maksimum 600 karakter lalu dipotong.
- Setelah ditekan: `answerCallbackQuery` segera, lalu pesan diedit menjadi "Diizinkan ✓" atau "Ditolak ✗" dan tombolnya
  dinonaktifkan atau dihapus. Tekanan kedua dijawab "Sudah dijawab".
- `approval_dismiss` dari host (dijawab dari aplikasi, atau dibatalkan): pesan diedit "Dijawab di aplikasi" atau "Dibatalkan".
- Persetujuan rahasia: tanpa tombol, teks "Ini menyangkut berkas rahasia. Buka aplikasi untuk menjawab."
- Persetujuan subagent sama, dengan label "Subagent" dan tugasnya.
- Saat bot (di-restart) tidak lagi punya persetujuan itu: tombol lama dijawab "Permintaan ini sudah tidak berlaku".

### 8.5 Format dan batas

- Jalur utama: `sendRichMessage` dengan `rich_message.markdown`, `skip_entity_detection:true`. Batas **[dok]**: **32.768**
  karakter, **500** blok, **16** tingkat bersarang, **50** media, **20** kolom tabel. Bot memakai 30.000 karakter dan 450
  blok sebagai batas aman, dan memecah di batas paragraf. Blok kode tidak dipecah di tengah: ia ditutup dan dibuka lagi dengan
  bahasa yang sama.
- Cadangan 1 (HTML): `sendMessage` dengan `parse_mode:"HTML"`: `<b> <i> <s> <code> <pre><code class="language-x">` dan
  `<blockquote expandable>` **[dok 7.4]**, batas 4.096 karakter, pemecahan di batas baris.
- Cadangan 2 (teks biasa): Markdown dibuang, batas 4.096.
- Turun satu tingkat otomatis bila API menolak pesan itu (kesalahan 400 yang menyebut format). Tiga kali berturut-turut
  menurunkan `telegramFormat` dan memberi tahu aplikasi.

### 8.6 Uji kemampuan (saat pairing dan dari tombol "Kirim pesan uji")

Urutan, hasilnya disimpan di `telegramFormat` dan `telegramDraft`:

1. `sendRichMessage` berisi judul, daftar tugas, tabel kecil, dan blok kode → berhasil: `rich`.
2. Gagal → `sendMessage` HTML → berhasil: `html`. Gagal → `plain`.
3. `sendRichMessageDraft` dengan `draft_id` uji → berhasil: `telegramDraft = true`.

Aplikasi menampilkan hasilnya ("Pesan kaya: aktif · Streaming: aktif") supaya pengguna tahu mengapa tampilannya sederhana.
**[BELUM DIVERIFIKASI]** versi aplikasi Telegram mana yang menampilkan pesan kaya; dokumentasi tidak menyebutnya, jadi
perilaku di klien lama hanya terlihat dari uji di perangkat asli (Fase 0).

### 8.7 Pemberitahuan lain

Diteruskan dengan sakelar yang sama dengan ntfy dan notifikasi subagent yang sudah ada: `run_finished`, `job` selesai atau
gagal, `subagent_finished` (selesai, gagal, kena batas), dan `notice` penting (anggaran hampir habis). Dua pemberitahuan
dari jenis yang sama dalam 60 detik digabung. Bot **tidak** mengirim "Agent selesai" terpisah: jawaban akhir sudah itu.

## 9. Bahasa

Aplikasi mengirim bahasanya setiap tersambung: `settings_set {language}` (kolom baru `language`, nilai `id` atau `en`),
dan saat pengguna mengganti bahasa. Host memakainya untuk semua teks bot. Sebelum ada nilainya, bot memakai
`from.language_code` dari Telegram (`id` → `id`, selain itu `en`).

Tabel teks (`Strings`) kunci → `id` / `en`, di `telegram.ts`, ±45 teks. Kunci tidak boleh bocor ke pengguna: tes memastikan
tiap kunci punya kedua bahasa dan tiap `{n}` terisi.

| Kunci | id | en |
| --- | --- | --- |
| `welcome` | Terhubung ✓. Kirim tugas apa saja ke sini. | Connected ✓. Send any task here. |
| `thinking` | Berpikir… | Thinking… |
| `working` | Bekerja · {t} | Working · {t} |
| `steps` | {n} langkah · {t} | {n} steps · {t} |
| `queued` | Masuk antrean ({n}) | Queued ({n}) |
| `approval.title` | ⚠ Perlu izin | ⚠ Needs approval |
| `approval.allow` / `.deny` | Izinkan / Tolak | Allow / Deny |
| `approval.allowed` / `.denied` | Diizinkan ✓ / Ditolak ✗ | Allowed ✓ / Denied ✗ |
| `approval.answered` | Dijawab di aplikasi | Answered in the app |
| `approval.gone` | Permintaan ini sudah tidak berlaku | This request is no longer valid |
| `approval.secret` | Ini menyangkut berkas rahasia. Buka aplikasi untuk menjawab. | This involves a secrets file. Open the app to answer. |
| `stopped` | Dihentikan | Stopped |
| `retry` | Coba lagi | Try again |
| `busy` | Agent masih bekerja | The agent is still working |
| `old` | Pesan ini sudah {n} menit, kirim lagi bila masih perlu. | This message is {n} minutes old; send it again if still needed. |
| `bypass` | Mode Bypass semua aktif, jadi prompt dari Telegram ditolak. Ubah mode di aplikasi. | Bypass-all mode is on, so prompts from Telegram are refused. Change the mode in the app. |
| `budget` | Anggaran harian habis ({a} dari {b} kredit) | Daily budget reached ({a} of {b} credits) |
| `nomodel` | Belum ada model. Buka aplikasi untuk menghubungkan key. | No model yet. Open the app to connect a key. |
| `attach` | Lampiran belum didukung di versi ini. | Attachments are not supported in this version. |
| `toofast` | Terlalu cepat, coba lagi sebentar. | Too fast, try again in a moment. |
| `pair.bad` | Kode salah (sisa {n} percobaan). | Wrong code ({n} tries left). |
| `unpaired` | Terputus. Bot ini tidak lagi menerima perintah dari akun ini. | Disconnected. This bot no longer takes commands from this account. |
| `btn.new` / `.status` / `.stop` | Chat baru / Status / Stop | New chat / Status / Stop |

## 10. Aplikasi (UI/UX)

### 10.1 Letak

`ServerScreen` (`lib/ui/server_screen.dart`) punya bagian bernomor dan bagian **Notifikasi** (ntfy, `server_screen.dart:1334`).
Bagian baru **Telegram** diletakkan tepat di bawahnya: satu `SettingsRow` yang menampilkan status ("Belum diatur", "Terhubung ke
@namabot", "Bermasalah") dan membuka layar `TelegramScreen` (`lib/ui/telegram_screen.dart`). Bagian ini hanya tampil di mode
server, dan **terkunci** ("Perbarui server dulu") bila host belum menyebut kemampuan `telegram`.

Kemampuan itu dikirim host di balasan `hello` sebagai `capabilities: ["telegram"]`, bukan perbandingan nomor versi, supaya
tidak rapuh.

### 10.2 Empat keadaan layar

**a. Belum diatur.** Tiga langkah bernomor (gaya "1 · Set up the server"):

- *1 · Buat bot.* Tombol "Buka @BotFather" (membuka `https://t.me/BotFather`). Tiga baris: kirim `/newbot`, beri nama, salin
  token. Tulisan: "Token ini memberi akses penuh ke bot kamu: jangan dibagikan."
- *2 · Tempel token.* Satu kolom dengan tombol Tempel. Tombol "Periksa" memanggil `telegram_set_token`. Berhasil:
  "Bot @namabot siap" dengan centang. Gagal: "Token ditolak. Periksa bahwa tersalin utuh" (pola error key GripHub, tanpa teks mentah).
- *3 · Hubungkan Telegram kamu.* Baru muncul setelah langkah 2. Kode 6 digit besar, hitung mundur 5 menit, tombol "Buka bot"
  (tautan `t.me/<bot>?start=<kode>`, jadi tinggal menekan START). Kode kedaluwarsa: "Buat kode baru".

**b. Menunggu pairing.** "Menunggu pesan dari Telegram…" dengan indikator kecil. Begitu `/start` diterima, layar berpindah
sendiri ke keadaan c (record `telegram` dari host).

**c. Terhubung.** Satu kartu: nama bot, nama akun terpasang, "Aktif" dengan titik hijau, dan hasil uji kemampuan ("Pesan kaya:
aktif · Streaming: aktif"). Di bawahnya:

- Sakelar "Kirim jawaban lengkap agent" (mati = ringkasan).
- Sakelar "Hanya kirim saat aplikasi tidak dibuka".
- Sakelar "Tautan bisa diketuk" (dengan keterangan alasannya).
- Sakelar "Izinkan Telegram saat mode Bypass" (bawaan mati, keterangan: berisiko).
- Tombol "Kirim pesan uji" dan "Putuskan" (danger, dengan konfirmasi).
- Peringatan tetap, bukan dialog: "Pesan Telegram tidak terenkripsi ujung ke ujung."

**d. Bermasalah.** Tiap penyebab punya kalimat dan satu tombol:

| Status host | Pesan | Tombol |
| --- | --- | --- |
| `offline` | Server tidak bisa menghubungi Telegram | Coba lagi |
| `conflict` | Token ini dipakai server lain. Satu token hanya untuk satu server | Pakai token lain |
| `invalid` | Token dicabut atau salah | Tempel token baru |
| `paused` (dimatikan) | Bot dimatikan | Nyalakan |

### 10.3 Teks aplikasi

Semua lewat `tr()` dengan kunci bahasa Inggris persis, ID dan EN, dicek `i18n_dups.py` dan `i18n_literals_test.dart`.

### 10.4 Golden dan tes widget

Empat keadaan × (terang EN, gelap ID, 320 dp teks 1,6×), ditambah: kode kedaluwarsa, token ditolak, konfirmasi Putuskan,
keadaan terkunci. Setiap layar lolos `collectLayoutErrors` (overflow menggagalkan tes).

## 11. Protokol host ↔ aplikasi

Perintah baru (`handle()` di `host.ts`), semuanya hanya di mode server (`server === true`), selain itu `Error("Only on a server")`:

| Perintah | Isi | Balasan |
| --- | --- | --- |
| `telegram_status` | — | `{configured, bot, paired:{name}, status, format, draft, settings:{…}, pairing:{expiresAt}|null}` |
| `telegram_set_token` | `{token}` | `{bot}` atau error `invalid` / `unreachable` |
| `telegram_pair_start` | — | `{code, expiresAt, link}` |
| `telegram_pair_cancel` | — | status |
| `telegram_unpair` | — | status |
| `telegram_forget` | — | status |
| `telegram_configure` | `{enabled?, sendFull?, onlyWhenAway?, links?, allowBypass?}` | status |
| `telegram_test` | — | `{format, draft}` hasil uji kemampuan |

Record baru: `{type:"telegram", status:{…}}` (kolom yang sama dengan `telegram_status`), **ditambahkan ke `REPLAYED_TYPES`**
(`transport.ts`) supaya aplikasi yang tersambung ulang melihat statusnya. Record lain yang disentuh: `session_changed` (7.3, Fase 3).

`settings_set` menerima `language`. `publicSettings()` **tidak pernah** memuat `telegramToken`; ia memuat `telegramToken:
<masker>` atau `null`.

## 12. Rencana berkas

| Berkas | Perubahan |
| --- | --- |
| `agent/src/telegram.ts` (baru) | Layanan: Api, Poller, Pairing, Router, Renderer, Strings |
| `agent/src/telegram-format.ts` (baru) | Formatter: sanitasi, redaksi, pemecahan, konversi HTML dan teks, tanpa efek samping (mudah diuji) |
| `agent/src/host.ts` | Membuat layanan di mode server, `send()` memanggil `telegram.onRecord`, perintah baru, `capabilities` di `hello`, `session_changed` (Fase 3) |
| `agent/src/integrations.ts` | Kolom `telegram*` dan `language`, validasi di `settings_set`, masker di `publicSettings()` |
| `agent/src/transport.ts` | `telegram` masuk `REPLAYED_TYPES` |
| `agent/test/telegram-*.test.mjs`, `agent/test/fake-telegram.mjs` (baru) | Bagian 15 |
| `lib/agent/telegram.dart` (baru) | Model status dan pemanggilan perintah |
| `lib/ui/telegram_screen.dart` (baru), `lib/ui/server_screen.dart` | Layar dan baris di bagian Notifikasi |
| `lib/ui/i18n.dart` | Teks bagian 10 |
| `lib/agent/agent_controller.dart` | Kirim `language` saat tersambung dan saat berganti |
| `test/golden/telegram_*` | Bagian 10.4 |
| `RELEASE_NOTES.md` | Butir ID dan EN |

Tidak ada perubahan di `server/bootstrap.sh`, unit systemd, atau box: bot ikut versi host dan terpasang bersama pembaruan server yang
sudah ada.

## 13. Memperbarui dan menonaktifkan

- Bot **ikut versi host**. Server yang belum diperbarui tidak punya bot, dan aplikasi menguncinya (10.1).
- Mematikan: `telegram_configure {enabled:false}` menghentikan poller tetapi menyimpan token dan pairing.
- Menghapus: `telegram_forget`. Tidak ada jejak di server selain berkas `telegram.json` yang ikut dihapus.
- Memulihkan cadangan server **tidak** memulihkan token Telegram ke server lain (cadangan otomatis memuat `integrations.json`
  terenkripsi dengan kunci server asal). Pengguna menempel token lagi di server baru, dan itu disengaja: satu token hanya
  untuk satu server.

## 14. Fase

| Fase | Isi | Selesai bila |
| --- | --- | --- |
| **0. Uji kemampuan nyata** | Skrip kecil di server uji: `getMe`, `sendRichMessage` (Markdown, tabel, kode, `<details>`), `sendRichMessageDraft` dengan `can_stop`, update `stopped_message_generation`, pratinjau tautan, `sendMessageDraft` di chat pribadi biasa, tombol `style`, batas laju sebenarnya (burst 429). Diuji di Telegram Android terbaru **dan** satu versi lama | Tabel hasil di bagian 17 diisi. Rancangan 8 disesuaikan dengan hasilnya sebelum Fase 1 |
| **1. Inti host** | `telegram.ts` (Api, Poller, Pairing), `telegram-format.ts`, perintah `telegram_*`, `prompt`, `/stop`, `/new`, status, tombol cepat, bahasa | Tes dengan Telegram palsu lolos: pairing, penolakan orang asing, pesan lama, gabung pesan, 409/401/429, prompt sampai balasan teks akhir |
| **2. Persetujuan** | Kartu dengan tombol berwarna, status per persetujuan, rahasia tanpa tombol, `approval_dismiss`, subagent, mode Bypass | Tes: ketuk ganda, penekan lain, persetujuan mati, rahasia, mode `auto` |
| **3. Penampilan** | Draf, heartbeat, pesan akhir dengan `<details>`, tangga cadangan, pemecahan, pemberitahuan lain, `session_changed`, `/chats`, `/open` | Tes rekaman record nyata → panggilan API yang diharapkan; fuzz formatter |
| **4. Aplikasi** | `TelegramScreen`, empat keadaan, golden, kunci versi, teks | `flutter analyze` bersih, golden terang/gelap/320 dp, tes alur dengan `FakeHost` |
| **5. Pengerasan dan uji lapangan** | Dokumen langkah BotFather di layar, cek log tanpa token, uji server asli satu minggu | `server/FIELD_TEST.md` bagian Telegram terisi pemilik |

Satu PR per fase, tiap fase dengan cek mutasi seperti pekerjaan sebelumnya, dan `RELEASE_NOTES.md` hanya memuat perubahan fase itu.

## 15. Strategi uji

**Telegram palsu** (`agent/test/fake-telegram.mjs`): server HTTP lokal di `127.0.0.1:<port acak>` yang meniru `getMe`,
`getUpdates` (long poll sungguhan, 409 bila ada pemanggil kedua), `deleteWebhook`, `sendMessage`, `sendRichMessage`,
`sendRichMessageDraft`, `sendMessageDraft`, `editMessageText`, `answerCallbackQuery`, `sendChatAction`; bisa disuruh
membalas 429 dengan `retry_after`, 401, atau memutus koneksi. Mencatat semua panggilan. Alamat API diganti lewat env
`GRIPHUB_TELEGRAM_API` **milik proses host** (agent di box tidak mewarisinya, bagian 2).

| Tes | Yang dikunci |
| --- | --- |
| Pairing | kode benar memasangkan; kode salah ×5 menutup jendela; kode kedaluwarsa; kode dipakai dua kali; grup/channel/`edited_message` diabaikan; ID asing tidak dijawab sama sekali |
| Wewenang | tidak ada `always`; rahasia tanpa tombol; mode `auto` menolak prompt; `/mode` tidak bisa ke `auto` |
| Poller | offset tersimpan dan dipulihkan; pesan > 120 detik ditolak; gabung pesan 1,2 detik; dedup; 409/401/429/jaringan; berhenti bersih tanpa handle bocor (`report-handles.mjs`) |
| Persetujuan | satu kartu per persetujuan; jawaban kedua diabaikan; penekan lain ditolak; `approval_dismiss` mengedit pesan; kartu mati dijawab "tidak berlaku"; subagent |
| Penampilan | rekaman record sebuah giliran (dari fixture) → urutan draf, heartbeat tiap 12 detik, pesan akhir; batas 1 pesan/detik; draf dibuang saat 429; turun ke pesan yang diedit; pemecahan tanpa memotong blok kode |
| Formatter | sifat: keluaran **tidak pernah** memuat `![`, `tg://`, `<tg-`, `<details` selain buatan bot, `$` tak ter-escape, karakter bidi; tabel >20 kolom → kode; panjang ≤ batas; **fuzz** dengan 5.000 masukan acak |
| Redaksi | token bot, key router, token GitHub, kunci penyimpanan dan semua pola 4.4 tidak pernah ada di keluaran, di log, atau di error `fetch` |
| Bahasa | tiap kunci ada di `id` dan `en`; `{n}` terisi; berganti bahasa dari aplikasi berlaku di pesan berikutnya |
| Protokol | `telegram_*` hanya di server; `telegramToken` tidak pernah ada di `publicSettings()`; record `telegram` ikut replay |
| Aplikasi | empat keadaan, golden, kunci versi, teks i18n, alur "token → kode → terhubung" dengan `FakeHost` |

Cek mutasi: untuk tiap penjaga keamanan (kunci `chat_id`, usia pesan, redaksi, escape `<`, pembuangan media, tombol `always`,
penolakan di mode Bypass, cek `from.id` pada tombol), tes harus gagal bila penjaganya dicabut.

## 16. Risiko dan yang belum diverifikasi

| Risiko | Kemungkinan | Penanganan |
| --- | --- | --- |
| Pesan kaya tampil rusak di aplikasi Telegram lama | Sedang. Dokumentasi tidak menyebut versi klien | Uji kemampuan saat pairing, tangga cadangan, dan Fase 0 di perangkat nyata |
| `sendMessageDraft` hanya jalan di mode topik forum (sumber pihak ketiga) atau di chat pribadi biasa (dokumen resmi) | Rendah | Diuji di Fase 0; cadangan ke pesan yang diedit sudah dirancang |
| Draf lenyap saat tool diam lama | Pasti terjadi tanpa penanganan | Heartbeat 12 detik (8.2) |
| Pesan kaya membuat pratinjau tautan sehingga Telegram mengambil URL | Tidak diketahui | Tautan tidak dikirim sebagai tautan aktif apa pun jawabannya (4.2); Fase 0 mengujinya |
| Bot dan aplikasi berebut chat aktif | Pasti terjadi | Hanya chat terbuka sampai ada `session_changed` (7.3) |
| Akun Telegram pemilik diambil alih | Rendah, dampak besar | Wewenang terbatas (4.3), tombol Putuskan, penolakan di mode Bypass. Tidak bisa dihilangkan, hanya dibatasi |
| Token bocor lewat log atau error | Sedang bila lengah | Redaksi pada semua keluaran, tes dengan token palsu (4.4) |
| Telegram tidak terjangkau dari server (diblokir atau jaringan) | Rendah di VPS luar negeri | Status `offline` dengan penjelasan; tidak memengaruhi agent atau aplikasi |
| Batas laju 1 pesan/detik membuat draf terlihat patah-patah | Sedang | Penggabungan 1,2 detik, hanya draf terbaru yang dipertahankan, uji burst nyata di Fase 0 |
| Dokumentasi berubah lagi (Bot API bergerak cepat: 9.3 sampai 10.3 dalam delapan bulan) | Tinggi | Semua pemanggilan lewat `TelegramApi` satu lapis; tangga cadangan membuat fitur baru bisa gagal tanpa merusak pengiriman |

## 17. Hasil Fase 0 (diisi saat dikerjakan)

| Pertanyaan | Hasil |
| --- | --- |
| Pesan kaya tampil benar di Telegram Android terbaru? | |
| Pesan kaya di klien lama: tampil apa? | |
| `sendRichMessageDraft` di chat pribadi biasa: jalan? | |
| `sendMessageDraft` di chat pribadi biasa: jalan? | |
| Heartbeat draf: seberapa sering agar tidak lenyap? | |
| `stopped_message_generation` sampai ke `getUpdates`? Kolomnya apa persis? | |
| `style` tombol tampil di klien lama? | |
| Pratinjau tautan pada pesan kaya? | |
| Burst: berapa pesan/draf per detik sebelum 429? | |
| `callback_data` berformat `a:<id>:y` aman? | |

## 18. Pertanyaan terbuka untuk pemilik

1. **Tautan:** bawaan "tidak bisa diketuk" (aman, sedikit merepotkan) sudah sesuai, atau tautan `https://` bersih boleh langsung aktif?
2. **Mode Bypass:** prompt dari Telegram ditolak saat mode Bypass sudah sesuai, atau tidak perlu dibatasi sama sekali?
3. **Ringkasan atau penuh:** jawaban penuh dikirim secara bawaan (dengan peringatan), atau bawaannya ringkasan 600 karakter?
4. **Pemberitahuan:** bila Telegram aktif, ntfy tetap menyala bersamaan, atau Telegram menggantikannya?
5. **Lampiran:** foto dari Telegram ke agent (`images` di `prompt`) layak dikerjakan sesudah Fase 5, atau tidak diperlukan?

## 19. Referensi

Dokumentasi resmi, dibaca 1 November 2026:

- Changelog: https://core.telegram.org/bots/api-changelog (Bot API 9.3 `sendMessageDraft`, 9.4 `style` tombol, 9.5 draf untuk semua bot, 10.1 pesan kaya, 10.2 blok baru dan pesan sementara, 10.3 `can_stop`, `stopped_message_generation`)
- `sendMessageDraft`: https://core.telegram.org/bots/api/methods/sendmessagedraft.md
- `sendRichMessage`: https://core.telegram.org/bots/api/methods/sendrichmessage.md
- `sendRichMessageDraft`: https://core.telegram.org/bots/api/methods/sendrichmessagedraft.md
- Pesan kaya, sintaks dan batas: https://core.telegram.org/bots/api/rich-messages.md
- `InlineKeyboardButton`: https://core.telegram.org/bots/api/types/inlinekeyboardbutton.md
- Batas laju: https://core.telegram.org/bots/faq.md ("My bot is hitting limits")

Di repo ini: `server_agent.md` (arsitektur server), `agent/src/host.ts`, `agent/src/guard.ts`, `agent/src/transport.ts`,
`agent/src/notify.ts`, `agent/src/integrations.ts`, `lib/ui/server_screen.dart`.
