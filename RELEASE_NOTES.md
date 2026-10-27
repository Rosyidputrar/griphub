<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

**Subagent**
- Kartu subagent kini muncul tepat di tempat agent memanggilnya di chat, dengan status yang jelas (berjalan, minta persetujuan, antre, menghentikan, selesai, gagal, berhenti) dan animasi yang halus.
- Persetujuan subagent bisa dijawab langsung dari kartu: Tolak, Selalu, atau Izinkan.
- Detail subagent menampilkan waktu, token, dan perkiraan biaya; laporan tampil rapi (judul, tabel, daftar) dan bisa disalin.
- Pengaturan subagent diperbarui: batas waktu kini bisa "Tanpa batas", nilai kustom terisi otomatis dan menerima desimal untuk kredit, persetujuan bisa "Sama dengan chat", dan ada notifikasi baru "Subagent berjalan".
- Notifikasi subagent kini mengikuti bahasa aplikasi, langsung memakai pengaturan Anda sejak aplikasi dibuka, dan juga muncul saat aplikasi di latar belakang.
- Banner subagent di chat lain bisa memilih chat tujuan bila ada beberapa.
- Tampilan tetap rapi di layar kecil dan ukuran teks besar.

**Perbaikan penting**
- Deploy lewat SSH tidak lagi mengunggah file rahasia seperti `.env` dan dotfile lain, dan kini menampilkan konfirmasi (server, folder, file yang tidak diunggah) sebelum mulai.
- Memasang ulang atau mengganti container Linux tidak lagi menghapus container lama bila unduhan gagal.
- Pindah atau membuat chat saat agent masih bekerja kini meminta konfirmasi, tidak lagi menghentikan pekerjaan diam-diam.
- Model cadangan tidak lagi berjalan di chat yang salah setelah Anda berpindah chat.
- Editor memperingatkan bila file diubah oleh agent sebelum Anda menyimpan: pilih Muat ulang atau Timpa.
- "Batalkan perubahan" kini menampilkan file yang akan dihapus dan Anda bisa memilih file yang tetap disimpan.
- File yang diganti nama kini bisa di-stage dan dilihat diff-nya di layar Git.
- Keterangan backup kini sesuai dengan isinya (pengaturan aplikasi, key, dan token tidak disertakan).

## English

**Subagents**
- Subagent cards now appear right where the agent called them in the chat, with clear states (in progress, needs approval, queued, stopping, finished, failed, stopped) and smooth animations.
- Subagent approvals can be answered straight from the card: Deny, Always or Allow.
- Subagent details show time, tokens and estimated cost; the report is properly formatted (headings, tables, lists) and can be copied.
- Subagent settings refreshed: the time limit can be "No limit", the custom value is prefilled and accepts decimals for credits, approvals can follow the chat, and there is a new "Subagent running" notification.
- Subagent notifications now follow the app language, use your settings from the moment the app opens, and also appear while the app is in the background.
- The banner for subagents in other chats lets you pick which chat to open when there are several.
- Layouts stay tidy on small screens and with large text.

**Important fixes**
- SSH deploys no longer upload secret files such as `.env` or other dotfiles, and now ask for confirmation (server, folder, files left out) before starting.
- Reinstalling or switching the Linux container no longer wipes the old one when the download fails.
- Switching or creating a chat while the agent is working now asks first instead of silently stopping the work.
- A fallback model no longer continues in the wrong chat after you switch chats.
- The editor warns when the agent changed a file before you save: choose Reload or Overwrite.
- "Undo these changes" now lists the files it will delete, and you can keep any of them.
- Renamed files can now be staged and diffed in the Git screen.
- The backup description now matches what it contains (app settings, keys and tokens are not included).
