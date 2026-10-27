# Update tanpa install APK (OTA agent host)

Status: rancangan, belum diimplementasikan.

## Ringkasan

Hanya bagian JavaScript dan data yang bisa diperbarui tanpa APK. UI Flutter dan binari native tetap lewat APK.

| Bagian | Lokasi | Tanpa APK? |
|---|---|---|
| Agent host (`agent/src` → `agent.zip`): subagent, tools, integrasi GitHub/Vercel/Cloudflare, web search, guard | `assets/agent.zip`, diekstrak ke `filesDir/agent` | Bisa |
| Data: skills, template, tabel harga | file biasa | Bisa |
| UI Flutter (Dart AOT → `libapp.so`) | di dalam APK | Tidak (kecuali code push pihak ketiga seperti Shorebird) |
| Binari native (`jniLibs/`: node, git, ssh, proot) dan Kotlin | di dalam APK | Tidak: Android hanya mengizinkan exec dari native lib dir APK |

Fondasinya sudah ada: `AgentRuntime.extractAssets` mengekstrak `agent.zip` ke folder staging lalu menukarnya secara atomik setiap `agent.stamp` berubah. Yang kurang: sumber kedua, yaitu zip hasil unduhan di `filesDir`.

## Alur

1. **Rilis (CI).** `release.yml` juga menghasilkan `agent-<hostVersion>.zip` dan `agent-manifest.json`:
   ```json
   {
     "hostVersion": "1.0.40",
     "protocol": 3,
     "minAppVersion": "1.0.35",
     "sha256": "<hash zip>",
     "url": "https://github.com/seseegy/griphub-releases/releases/download/v1.0.40/agent-1.0.40.zip"
   }
   ```
   Manifest ditandatangani dengan kunci Ed25519 khusus (`agent-manifest.json.sig`), terpisah dari keystore APK.

2. **Cek update.** Aplikasi membaca manifest dari rilis terbaru (jalur yang sama dengan `Updater` APK), lalu:
   - memverifikasi tanda tangan memakai public key yang tertanam di APK;
   - memeriksa `protocol`: host baru dipasang hanya jika versi protokolnya didukung UI Dart yang terpasang;
   - memeriksa `minAppVersion` terhadap versi APK.

3. **Unduh.** Zip diunduh ke `filesDir/agent-updates/`, lalu `sha256`-nya dicocokkan dengan manifest.

4. **Pasang.** Ekstrak ke `agent.new` (cek zip-slip seperti sekarang), tukar, lalu restart host hanya saat agent idle: tidak streaming, tidak ada subagent atau background run aktif.

5. **Rollback otomatis.** Jika host baru tidak mengirim `ready` dalam N detik atau mengirim `fatal`:
   - kembali ke versi sebelumnya, atau ke host bawaan APK;
   - simpan versi itu di daftar blokir agar tidak dicoba lagi.

6. **Prioritas versi.** Pakai yang lebih baru antara host bawaan APK dan host unduhan, supaya update APK tidak tertimpa OTA yang lebih lama.

## Versi protokol

UI Dart dan host bicara lewat JSONL (`agent_client.dart` ↔ `host.ts`). Banyak perubahan menyentuh keduanya (contoh: `toolCallId`/`stopCode` pada perbaikan subagent), jadi:

- `hello` mengembalikan `protocol` (integer, naik setiap kali kontrak record/command berubah);
- Dart mendeklarasikan rentang protokol yang didukung;
- perubahan yang menaikkan protokol di luar rentang itu tetap dikirim lewat APK.

## Keamanan

- Host memegang token GitHub/Vercel/Cloudflare dan SSH key pengguna. Jalur OTA sama dengan jalur menjalankan kode jarak jauh, jadi:
  - wajib verifikasi tanda tangan; SHA-256 dari rilis yang sama hanya membuktikan file utuh, bukan file asli;
  - kunci penandatangan disimpan terpisah dan ketat (bukan di secrets yang sama dengan `RELEASES_TOKEN`);
  - unduh hanya lewat HTTPS dari URL yang ada di manifest bertanda tangan.
- Host harus murni JS, tanpa modul native `.node`. `build.mjs` sudah membuang `prebuilds`.

## Google Play

Kebijakan Play melarang mengunduh kode eksekusi dari luar Play. Pengecualian untuk kode di interpreter ada, tetapi Node dengan akses file dan jaringan termasuk area abu-abu. Keputusan:

- OTA hanya aktif di flavor `full` (rilis GitHub);
- flavor `play` tetap update lewat Play Store.

## Batasan

- Perubahan UI, Kotlin, atau binari native tetap butuh APK.
- Install APK selalu butuh konfirmasi pengguna; Android tidak mengizinkan instalasi diam-diam untuk aplikasi biasa.

## Langkah implementasi

1. Versi protokol di `hello` dan pengecekannya di Dart.
2. Rollback ke host bawaan APK bila host gagal start (berguna walau OTA belum ada).
3. `AgentRuntime`: sumber kedua `filesDir/agent-updates`, pemilihan versi, daftar blokir.
4. CI: build `agent-<versi>.zip`, manifest, tanda tangan Ed25519.
5. Dart: cek, unduh, verifikasi, pasang saat idle, tampilkan status di Settings → About.
6. Tes: verifikasi tanda tangan (valid/palsu), protokol tidak cocok, rollback saat host gagal.
