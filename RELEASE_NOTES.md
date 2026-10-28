<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

**Baru: agent di server sendiri (VPS)**
- Agent kini bisa berjalan di VPS milik Anda, 24 jam: tetap bekerja saat app ditutup atau HP mati. Buka Pengaturan → Agent di VPS / server.
- Pemasangan tanpa mengunduh apa pun. Salin satu perintah dari app, tempel di terminal server (Ubuntu atau Debian), lalu tempel kode setup yang dicetaknya ke app. Langkahnya bernomor. Server langsung dites, dan agent baru bisa dipakai setelah terpasang dengan benar.
- Chat, file, editor, pratinjau HTML, dev server, terminal, backup, dan lampiran semuanya bekerja di server. Chat di HP dan chat di server terpisah, dan Anda bisa beralih bolak-balik kapan saja.
- Saat koneksi putus, app menyambung ulang sendiri dan menyusul chat tanpa pesan ganda. Pekerjaan agent di server tidak terhenti. Tab terminal tetap hidup di server; tekan Sambungkan lagi untuk kembali ke sesi yang sama.
- Perintah agent berjalan di dalam box (container di server), bukan langsung di server. Bila box belum dibangun, app menunjukkannya beserta tombol Bangun box.
- Notifikasi lewat app ntfy saat app tertutup: persetujuan diperlukan, agent selesai, tugas selesai. Notifikasi hanya berisi judul umum, tanpa isi chat. Ada tombol Kirim notifikasi uji.
- Kartu kesehatan server, daftar periksa, dan panduan "Bila ada masalah" langsung di app.
- Tugas terjadwal mengikuti jam HP. Bila agent di server lebih lama dari app, muncul banner dengan tombol Perbarui.
- Saat beralih, app menyebut apa yang tidak ikut pindah (model, kunci API, akun) dan memperingatkan bila agent di HP sedang bekerja.

**Lainnya**
- Saat file yang sedang diedit diubah agent, kini ada tombol Salin editan saya sebelum memilih Muat ulang atau Timpa.
- Pemilih folder menampilkan status memuat, dan pesan dengan tombol Coba lagi bila folder tidak bisa dibuka.
- Istilah dalam bahasa Indonesia dibuat lebih konsisten.

## English

**New: the agent on your own server (VPS)**
- The agent can now run on your own VPS, around the clock: it keeps working when the app is closed or the phone is off. Open Settings → Agent on a VPS / server.
- Setup needs no downloads. Copy one command from the app, paste it into the server's terminal (Ubuntu or Debian), then paste the setup code it prints back into the app. The steps are numbered. The server is tested right away, and the agent can only be switched on once it is installed properly.
- Chats, files, the editor, HTML previews, dev servers, the terminal, backups and attachments all work on the server. Phone chats and server chats are kept apart, and you can switch back and forth at any time.
- When the connection drops, the app reconnects by itself and catches up on the chat without duplicates. The agent's work on the server carries on. Terminal tabs stay alive on the server; tap Reconnect to return to the same session.
- The agent's commands run inside a box (a container on the server), not on the server itself. If the box is not built yet, the app says so and offers a Build the box button.
- Notifications through the ntfy app while the app is closed: approval needed, agent finished, task finished. They carry only a generic title, never chat content. There is a Send a test notification button.
- A server health card, a checklist and a "When something goes wrong" guide, right in the app.
- Scheduled tasks follow the phone's clock. When the server's agent is older than the app, a banner offers to update it.
- Switching says what does not come along (models, API keys, accounts) and warns when the phone's agent is still working.

**Other**
- When the agent changes a file you are editing, there is now a Copy my edits button before you choose Reload or Overwrite.
- The folder picker shows when it is loading, and an error with Try again when a folder cannot be opened.
- More consistent Indonesian wording.
