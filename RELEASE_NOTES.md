<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

**Baru**
- Pekerjaan latar: agent bisa menjalankan perintah panjang (build, test, instalasi besar) di latar lalu lanjut mengerjakan hal lain. Saat selesai, agent otomatis dipanggil kembali di chat yang sama dengan hasilnya, tanpa bubble dari kamu. Batas 60 menit, dan bisa dihentikan dari kartunya.
- Waktu kerja AI tampil live: teks biru berkilau di dekat jumlah token menghitung waktu selama agent bekerja; setelah selesai berubah hijau dan berhenti di waktu selesainya. Waktunya tetap tersimpan saat chat dibuka lagi.
- Tempel gambar: gambar yang kamu salin bisa ditempel ke kolom pesan (tekan lama → Tempel gambar, atau lewat tombol +), dan gambar dari keyboard langsung jadi lampiran.
- Gambar yang dibaca agent tampil sebagai thumbnail di kartu tool; ketuk untuk layar penuh.
- Git: ketuk file yang berubah untuk melihat isinya. Gambar tampil sebagai gambar, teks tampil penuh, file biner lain menyebut jenis dan ukurannya.
- Backup otomatis server: setiap jam bila ada perubahan, server membuat backup terenkripsi berisi semuanya (termasuk API key dan .git, tanpa dependensi). Backup terbaru dibawa ke HP saat aplikasi terbuka, dan ditawarkan untuk dipulihkan saat kamu kembali ke agent di HP. Nyalakan di Pengaturan → Backup & pulihkan.
- Panduan server dan box di dalam aplikasi: cara memasang, arti toggle box, arti indikator kesehatan, dan pemecahan masalah umum.

**Lebih jelas saat menunggu**
- Setiap aksi yang menunggu kini memberi tanda dan tidak bisa terpicu dua kali: kirim pesan, buka chat/proyek, deploy, pilih model, mode persetujuan, Sync GitHub, proyek baru, edit/fork pesan, serta aksi di Files, Templates, MCP dan Tasks.
- "Hentikan & pindah" menampilkan "Menghentikan agent…" dan memberi tahu bila agent tidak berhenti tepat waktu.
- Files tidak lagi menampilkan isi folder lama di bawah judul folder baru; Usage tidak lagi menampilkan angka periode lama di tab periode baru.
- Pilih model: sheet tetap terbuka sampai model tersimpan, dan kegagalan ditampilkan di sheet.
- Template dan server MCP yang gagal disimpan tidak lagi membuang isian kamu.

**Perbaikan**
- "Jalankan sekarang" di Tasks tidak lagi menulis "Masuk antrean" di atas pesan error.
- Git di proyek yang berada di subfolder repositori: diff, stage, unstage dan buang perubahan kini mengenai file yang benar.
- Tombol Pull/Push di layar Git tidak lagi terpotong di layar sempit atau dengan teks besar.

## English

**New**
- Background jobs: the agent can run a long command (a build, the test suite, a big install) in the background and go on with other work. When it ends, the agent is called back in the same chat with the result, with no message from you. 60-minute limit, and it can be stopped from its card.
- Live AI timer: a blue shimmering clock next to the tokens counts while the agent works; when it is done it turns green and stops at the time it took. The time stays with the chat.
- Paste pictures: a picture you copied can be pasted into the message field (long-press → Paste image, or from the + button), and a picture from the keyboard becomes an attachment.
- Pictures the agent reads show as thumbnails on the tool's card; tap for full screen.
- Git: tap a changed file to see its contents. Pictures show as pictures, text in full, other binaries say what they are and how big.
- Automatic server backup: every hour when something changed, the server makes an encrypted backup of everything (API keys and .git included, dependencies left out). The newest comes to the phone while the app is open, and is offered when you switch back to the agent on the phone. Turn it on in Settings → Backup & restore.
- A server and box guide in the app: how to set it up, what the box switch means, what the health table says, and common problems.

**Clearer while you wait**
- Every action that waits now shows it and cannot run twice: sending, opening a chat or project, deploying, picking a model, approval modes, GitHub sync, new projects, editing or forking a message, and actions in Files, Templates, MCP and Tasks.
- "Stop and switch" shows "Stopping the agent…" and tells you when the agent did not stop in time.
- Files no longer shows the old folder under the new folder's title; Usage no longer shows the old period's numbers under the new tab.
- Picking a model: the sheet stays open until the model is saved, and a failure is shown in the sheet.
- A template or MCP server that fails to save no longer loses what you typed.

**Fixes**
- "Run now" in Tasks no longer says "Queued" over an error.
- Git in a project inside a subfolder of a repository: diffs, stage, unstage and discard now reach the right files.
- The Pull/Push buttons on the Git screen no longer run off on a narrow screen or with large text.
