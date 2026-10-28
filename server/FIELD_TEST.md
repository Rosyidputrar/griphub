# Uji lapangan mode server (fase 7)

Checklist untuk menguji GripHub di VPS sungguhan (`agentai`: 4 CPU, RAM 8 GB, disk 100 GB) sebelum PR #9 digabung ke
`main`. Label tombol ditulis dalam bahasa Indonesia app (dengan teks Inggrisnya dalam kurung). Centang yang lulus, catat yang tidak (langkah, apa yang terlihat, jam). Di akhir, kirim **output
`field-report.sh`** dan catatan itu; perbaikannya dikerjakan dari situ.

Latar belakang dan keputusan desain: `server_agent.md`. Cara pasang yang lengkap: `server/README.md`.

## 0. Persiapan

- [ ] **APK dari PR #9**: GitHub → Actions → run "Release APK" terbaru untuk PR #9 → bagian *Artifacts* →
      `griphub-pr-9` (zip berisi APK per ABI). Pasang `griphub-…-arm64-v8a.apk` (HP modern). Ditandatangani dengan kunci
      rilis yang sama, jadi terpasang di atas versi yang ada tanpa menghapus data.
- [ ] **Folder `server/` ke VPS**: repo ini privat, jadi salin dari komputer Anda (atau unduh ZIP branch
      `ccr-691d6b80-o39hpy` dari GitHub lalu ekstrak):
      ```
      scp -r server/ root@agentai:~/griphub-server
      ```
- [ ] Catat kondisi awal di VPS: `free -m`, `df -h /`, dan apakah CoderRa sedang berjalan.

## 1. Pasang

- [ ] App: Pengaturan (Settings) → Data & keamanan → **Agent server** (Server agent) → isi alamat VPS → salin perintah yang ditampilkan.
- [ ] VPS: `cd ~/griphub-server && bash bootstrap.sh --dry-run --pubkey '…' --address '…'`. Tidak ada peringatan
      "written for Ubuntu and Debian"; ada baris `host key:`.
- [ ] VPS: `sudo bash bootstrap.sh --pubkey '…' --address '…'`. Selesai tanpa error; mencetak `griphub1:…`.
      Catat berapa lama (paket, Node, image box).
- [ ] App: tempel setup code → **Tes koneksi** (Test connection) → "Tersambung. Agent belum dipasang di server…".
- [ ] App: **Pasang / perbarui agent** (Install / update agent) → selesai; **Pakai agent server** (Use the server agent) → chip di chat berubah menjadi **Server**.
- [ ] Bila CoderRa terpasang: CoderRa tetap tersambung dan bekerja seperti biasa setelah langkah ini.

## 2. Chat

- [ ] Kirim chat sederhana ("buat file hello.txt berisi halo"). Jawaban mengalir; file muncul di **Files**.
- [ ] Ganti model; biaya per giliran dan kredit tampil seperti di mode HP.
- [ ] Tutup app sepenuhnya (geser dari recent apps) saat agent bekerja pada tugas panjang, buka lagi 2 menit
      kemudian: chat menyusul tanpa pesan ganda, agent tetap bekerja selama app tertutup.

## 3. Koneksi putus-sambung

- [ ] Saat agent bekerja, nyalakan mode pesawat 30 detik, lalu matikan. Banner "Menyambung ulang" (Reconnecting) muncul lalu hilang;
      tidak ada pesan ganda atau hilang.
- [ ] Ulangi dengan mode pesawat 5 menit (lebih lama dari buffer replay): app memuat ulang chat (resync), hasilnya
      lengkap.
- [ ] Pindah Wi-Fi ↔ data seluler di tengah tugas: sama seperti di atas.

## 4. Approval dan notifikasi

- [ ] Agent server → **Notifikasi**: nyalakan. Pasang app **ntfy** di HP dan langganan topik yang ditampilkan.
- [ ] Minta sesuatu yang perlu persetujuan (mis. `git push` atau `rm -rf build`), lalu tutup app sebelum kartu
      approval muncul. Notifikasi "Approval needed" datang (judul notifikasi memang berbahasa Inggris); buka app → kartu approval ada → jawab → agent lanjut.
- [ ] Notifikasi "Agent finished" datang saat tugas selesai dengan app tertutup, dan **tidak** datang saat app terbuka.
- [ ] Isi notifikasi hanya judul umum; tidak ada nama proyek atau isi chat.

## 5. Subagent paralel dan memori

- [ ] Jalankan `sudo bash field-report.sh --since "10 minutes ago"` di VPS: catat `MemoryCurrent` sebagai awal.
- [ ] Minta 3 subagent paralel (mis. tiga analisis repo berbeda). Kartu subagent bergerak; catat `MemoryPeak` dari
      `field-report.sh` setelahnya (batas 2 GB).
- [ ] Saat subagent bekerja, putuskan HP (mode pesawat 2 menit): setelah tersambung, status subagent benar,
      laporan lengkap.
- [ ] Subagent yang minta approval saat app tertutup: notifikasi "Subagent needs approval", kartunya muncul saat app
      dibuka.

## 6. File, editor, lampiran

- [ ] Files: buat folder, ganti nama, duplikat, hapus; impor file dari HP (progres tampil); bagikan file ke app lain.
- [ ] Editor: buka file, ubah, simpan. Lalu minta agent mengubah file yang sama selagi editor terbuka dan belum
      disimpan → simpan → dialog "File berubah di disk" → coba **Muat ulang** dan **Timpa**.
- [ ] Lampirkan foto dan PDF ke chat: dialog "Mengirim file" tampil; agent bisa membaca PDF-nya; thumbnail dan
      viewer lampiran di pesan bekerja.
- [ ] Tempel teks panjang → jadi lampiran "Konten yang ditempel" → terkirim.

## 7. Pratinjau dan dev server

- [ ] Minta agent membuat halaman HTML dengan `style.css` terpisah dan gambar. Pratinjau dari kartu tool, dari Files,
      dan dari editor (sebelum disimpan): gaya dan gambar ikut tampil.
- [ ] Minta agent menjalankan dev server (Vite: `npm run dev -- --host 127.0.0.1`). Banner dev server muncul →
      **Pratinjau** → situs tampil di HP. Ubah kode → reload menampilkan perubahan.

## 8. Terminal

- [ ] Buka Terminal: prompt berbentuk `<folder> $` di folder proyek; `git status`, `ll` bekerja.
- [ ] Jalankan `top` (atau `sleep 600`), mode pesawat 1 menit, kembali: tab tersambung ke sesi yang sama
      (`top` masih jalan).
- [ ] Tutup app, buka lagi Terminal: tab bergabung ke sesi tmux yang sama.
- [ ] Tab **Shell Linux (box)**: masuk ke container box; `node -v` dan `git` ada.
- [ ] Tutup tab: di VPS `sudo -u griphub tmux ls` tidak lagi menampilkan sesi itu.

## 9. Backup

- [ ] **Buat backup** (dengan file workspace) → **Unduh ke HP ini** → file ada di Downloads dan bisa dibuka sebagai zip.
- [ ] **Pilih file** zip itu dari HP → **Pulihkan** → "N file dipulihkan"; salinan `.restore-…` di
      `~/workspace/backups` di VPS hilang setelahnya.

## 10. Deploy

- [ ] Deploy ke Cloudflare (atau Vercel / server SSH yang biasa Anda pakai) dari proyek uji. Build berjalan di box;
      URL hasil bisa dibuka.

## 11. Update agent saat sibuk

- [ ] Saat agent atau subagent bekerja, tekan **Pasang / perbarui agent**. Pesan menyebut agent akan restart setelah
      pekerjaan selesai; pekerjaan tidak terpotong; setelahnya versi baru aktif ("Sudah terbaru").

## 12. Kembali ke mode HP

- [ ] **Pakai agent di HP ini** (Use the agent on this phone): chat HP lama masih ada dan terpisah dari chat server; Terminal membuka shell HP.
- [ ] Kembali ke server: chat server, sesi tmux, dan approval yang menunggu muncul lagi.

## 13. Soak 24 jam

- [ ] Biarkan agent menyala 24 jam (boleh dengan satu tugas terjadwal atau run latar belakang yang jalan berkala).
- [ ] Lalu di VPS:
      ```
      sudo bash ~/griphub-server/field-report.sh --since "24 hours ago" > griphub-report.txt
      ```
      Periksa isinya, lalu kirim. Yang dilihat: `NRestarts`, `MemoryPeak`, OOM kill, peringatan di log, ukuran
      data, dan kondisi CoderRa di sebelahnya.

## Yang dikirim balik

1. `griphub-report.txt` dari langkah 13 (dan laporan lain yang Anda ambil di tengah jalan).
2. Daftar langkah yang gagal: nomor, apa yang terlihat, kira-kira jam berapa.
3. Tangkapan layar bila tampilannya aneh (pratinjau, terminal, banner koneksi).
