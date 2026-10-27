<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

**Chat**
- Biaya setiap jawaban kini terlihat di samping tombol salin dan nama model: jumlah token dan perkiraan kredit untuk satu giliran. Biaya subagent ditampilkan terpisah. Ketuk untuk melihat rinciannya: jumlah request, token (termasuk cache), kredit, dan rupiah.
- Teks panjang yang ditempel (lebih dari 1.000 karakter atau 15 baris) kini otomatis menjadi lampiran "Konten yang ditempel", jadi kolom ketik dan chat tetap rapi. Ketuk lampirannya untuk melihat isinya, atau pilih "Tempel sebagai teks".
- Aplikasi tidak lagi menjadi berat saat agent menulis file panjang (misalnya halaman HTML). Selama menulis, yang ditampilkan hanya baris-baris terbaru beserta jumlah baris dan ukurannya; isi lengkapnya muncul setelah selesai. Live preview tetap tersedia.

**Subagent**
- Pesan yang diantrekan ke subagent yang sedang berjalan kini benar-benar terkirim. Sebelumnya subagent malah berhenti dengan status gagal.
- Subagent tidak lagi dinyatakan gagal saat koneksi sempat terputus lalu berhasil dicoba ulang.

**GitHub**
- Login GitHub tidak lagi berhenti bekerja setelah beberapa jam dengan error "401 Bad credentials": sesi diperpanjang otomatis. Jika login sudah tidak berlaku, layar Akun menampilkannya dengan tombol "Masuk lagi".
- Repository dengan nama yang sama dari pemilik berbeda (misalnya milikmu dan repo tempat kamu menjadi collaborator) tidak lagi tertukar. Masing-masing di-clone ke foldernya sendiri dan dibuka dengan benar.
- Repository yang sudah ada di HP kini bisa ditarik perubahannya (lengkap dengan jumlah commit baru) dan pindah branch langsung dari daftar repository, termasuk branch yang baru dibuat di GitHub.

**Tasks**
- Task yang sudah selesai, gagal, atau dibatalkan bisa digeser ke kiri atau kanan untuk dihapus, dengan tombol Urungkan.

**Lainnya**
- Tombol pada notifikasi bawah (seperti Urungkan, Buka, Lihat) kini terbaca di tema gelap.

## English

**Chat**
- Each reply now shows what it cost next to the copy button and model name: tokens and estimated credits for the turn, with subagents shown apart. Tap it for the breakdown: requests, tokens (cache included), credits and rupiah.
- Pasting long text (over 1,000 characters or 15 lines) now attaches it as "Pasted content", so the message box and the chat stay tidy. Tap it to see the text, or choose "Paste as text".
- The app no longer slows down while the agent writes a long file (such as an HTML page). While writing, only the newest lines show, with the line count and size; the full file shows once it's done. Live preview still works.

**Subagents**
- A message queued for a running subagent is now actually sent; it used to make the subagent stop as failed.
- A subagent is no longer reported as failed when the connection dropped and the retry succeeded.

**GitHub**
- GitHub sign-in no longer stops working after a few hours with "401 Bad credentials": the session renews itself. When a sign-in is no longer valid, Accounts says so, with a "Sign in again" button.
- Repositories with the same name from different owners (say, yours and one you collaborate on) are no longer mixed up. Each is cloned into its own folder and opens correctly.
- A repository already on the phone can now pull the latest changes (showing how many new commits) and switch branch right from the repository list, including branches created on GitHub since.

**Tasks**
- Finished, failed or cancelled tasks swipe away in either direction, with Undo.

**Other**
- Snackbar buttons (Undo, Open, View) are now readable in the dark theme.
