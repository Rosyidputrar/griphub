<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

- Chat panjang kini lebih hemat: begitu konteks melewati 300 ribu token, giliran lama otomatis diringkas dan giliran terbaru tetap utuh. Sebelumnya model berkonteks besar baru meringkas saat hampir mencapai batasnya sendiri, sehingga setiap pesan membaca ulang konteks yang sangat besar. Batasnya bisa diubah di Pengaturan → Usage → Ringkas chat pada (100 ribu sampai 500 ribu token, atau di batas model).
- Saat konteks diringkas, chat menampilkan "Meringkas konteks" dengan waktu yang berjalan, lalu berapa token yang dihemat (misalnya 320k → 24k token). Bila gagal, alasannya ditampilkan. Ketuk barisnya untuk penjelasan.
- Pesan yang dikirim saat konteks sedang diringkas kini menunggu sampai selesai, tidak lagi ditolak.
- Animasi memuat yang baru di seluruh aplikasi: komet yang berputar, besar saat satu layar menunggu data dan kecil di tombol atau baris. Warnanya menyesuaikan tema terang dan gelap, dan berhenti bergerak bila animasi dimatikan di sistem. Pembaca layar mengucapkan "Memuat…", lalu "Selesai" atau "Gagal".
- Memulihkan cadangan kini diakhiri tanda centang saat berhasil. Bila memulihkan cadangan, menyiapkan deploy, atau memulai chat gagal, dialognya menampilkan tanda silang sesaat sebelum alasannya muncul.

## English

- Long chats cost less: once the context passes 300k tokens, older turns are summarized automatically and the newest stay as they were. Large models used to summarize only close to their own limit, so every message re-read a huge context. Change the limit in Settings → Usage → Summarize the chat at (100k to 500k tokens, or at the model's limit).
- While the context is summarized, the chat shows "Summarizing the context" with a running clock, then how many tokens it saved (for example 320k → 24k tokens). A failure says why. Tap the line for what it means.
- A message sent while the context is being summarized now waits for it instead of being refused.
- A new loading animation across the app: circling comets, large when a whole screen is waiting and small on buttons and rows. The colours follow the light and dark themes, and it stands still when animations are turned off in the system. Screen readers say "Loading…", then "Done" or "Failed".
- Restoring a backup now ends with a check when it worked. When restoring a backup, preparing a deploy or starting a chat fails, the dialog shows a cross for a moment before saying why.
