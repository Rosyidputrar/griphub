<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

- Chat panjang kini lebih hemat: begitu konteks melewati 300 ribu token, giliran lama otomatis diringkas dan giliran terbaru tetap utuh. Sebelumnya model berkonteks besar baru meringkas saat hampir mencapai batasnya sendiri, sehingga setiap pesan membaca ulang konteks yang sangat besar. Batasnya bisa diubah di Pengaturan → Usage → Ringkas chat pada (100 ribu sampai 500 ribu token, atau di batas model).
- Saat konteks diringkas, chat menampilkan "Meringkas konteks" dengan waktu yang berjalan, lalu berapa token yang dihemat (misalnya 320k → 24k token). Bila gagal, alasannya ditampilkan. Ketuk barisnya untuk penjelasan.
- Pesan yang dikirim saat konteks sedang diringkas kini menunggu sampai selesai, tidak lagi ditolak.
- Animasi memuat yang baru di seluruh aplikasi: komet yang berputar, besar saat satu layar menunggu data dan kecil di tombol atau baris. Warnanya menyesuaikan tema terang dan gelap, dan berhenti bergerak bila animasi dimatikan di sistem. Pembaca layar mengucapkan "Memuat…", lalu "Selesai" atau "Gagal".
- Memulihkan cadangan kini diakhiri tanda centang saat berhasil. Bila memulihkan cadangan, menyiapkan deploy, atau memulai chat gagal, dialognya menampilkan tanda silang sesaat sebelum alasannya muncul.
- Pesan error kini ditulis dengan bahasa yang mudah dipahami: koneksi putus atau terlalu lama memberi tahu apa yang perlu dilakukan, dan teks teknis tidak lagi tampil. Error yang memenuhi layar (Usage, Box, Template) punya tombol Coba lagi.
- Lebih mudah disentuh: tombol kecil di kolom chat, header beranda, pilihan segmen, dan chip di Buat gambar kini punya area sentuh 48 dp tanpa berubah tampilan.
- Pembaca layar kini menyebut nama setiap sakelar (misalnya "Kunci aplikasi, sakelar, aktif"), bukan hanya "sakelar".
- Teks merah, hijau, dan oranye di mode terang lebih pekat sehingga mudah dibaca.
- Bilah navigasi beranda tidak lagi terpotong di layar HP yang sempit (320 dp).
- Teks yang belum diterjemahkan di Cari, Git, dan Sinkron GitHub kini berbahasa Indonesia.
- Kartu persetujuan untuk mengedit atau menulis file kini menampilkan perubahannya (baris yang dihapus dan ditambah) sebelum kamu mengizinkan. Perubahan yang panjang bisa dibuka utuh di halaman sendiri. Berlaku juga untuk persetujuan subagent.
- Ketik @ di kolom chat untuk memilih file proyek: daftar file muncul sesuai ketikan, dan path-nya langsung masuk ke pesan.
- Bagikan chat: dari menu Project, chat bisa dibagikan sebagai teks atau file Markdown, disalin, atau disimpan ke Download. Isinya pesan, jawaban agent, dan tool yang dipakai.
- Tombol Tolak/Selalu/Izinkan tidak lagi terpotong di layar sempit dengan teks besar.
- Review & commit: setelah agent selesai dan ada file yang berubah, chat menawarkan "Review & commit". Satu layar menampilkan semua file yang berubah beserta diff-nya, pesan commit yang ditulis agent (bisa diubah), serta tombol Commit atau Commit dan push. Membatalkan perubahan agent juga bisa dari layar yang sama. Tersedia juga di menu Project.
- Mode server: pesan yang dikirim saat koneksi ke server putus kini disimpan dan dikirim otomatis begitu tersambung lagi, berurutan, alih-alih gagal. Pesan ini tetap tersimpan walau aplikasi ditutup. Bila server menolaknya (misalnya budget habis), alasannya ditampilkan dengan tombol Kirim lagi, dan pesan sesudahnya menunggu. Membatalkannya mengembalikan teksnya ke kolom chat.
- Files bisa diurutkan menurut nama, terakhir diedit, terbesar, atau jenis, dengan pilihan folder tetap di atas. Chip di bawah judul menyaring satu jenis file: folder, kode, gambar, dokumen, data, arsip, atau media. Hanya jenis yang ada di folder itu yang muncul.

## English

- Long chats cost less: once the context passes 300k tokens, older turns are summarized automatically and the newest stay as they were. Large models used to summarize only close to their own limit, so every message re-read a huge context. Change the limit in Settings → Usage → Summarize the chat at (100k to 500k tokens, or at the model's limit).
- While the context is summarized, the chat shows "Summarizing the context" with a running clock, then how many tokens it saved (for example 320k → 24k tokens). A failure says why. Tap the line for what it means.
- A message sent while the context is being summarized now waits for it instead of being refused.
- A new loading animation across the app: circling comets, large when a whole screen is waiting and small on buttons and rows. The colours follow the light and dark themes, and it stands still when animations are turned off in the system. Screen readers say "Loading…", then "Done" or "Failed".
- Restoring a backup now ends with a check when it worked. When restoring a backup, preparing a deploy or starting a chat fails, the dialog shows a cross for a moment before saying why.
- Error messages are in plain words: a lost or slow connection says what to do, and technical text no longer shows. An error that fills a screen (Usage, Box, Templates) has a Try again button.
- Easier to tap: the small buttons in the chat box, the home header, segmented choices and the chips in Generate image now have a 48 dp touch area, without looking any different.
- Screen readers say what each switch is for (for example "App lock, switch, on"), not just "switch".
- Red, green and orange text in light mode is deeper and easier to read.
- The home navigation bar no longer overflows on narrow (320 dp) phones.
- Text left in English in Search, Git and GitHub sync is now translated.
- The approval card for editing or writing a file now shows the change (lines removed and added) before you allow it. A long change opens whole on its own page. Subagent approvals show it too.
- Type @ in the chat box to pick a project file: matching files show as you type, and the path goes into your message.
- Share a chat: from the Project menu, share it as text or a Markdown file, copy it, or save it to Downloads. It holds the messages, the agent's answers and the tools it used.
- Deny/Always/Allow no longer break apart on a narrow screen with large text.
- Review & commit: when the agent finishes and files changed, the chat offers "Review & commit". One screen shows every changed file with its diff, a commit message the agent writes (yours to edit), and Commit or Commit and push. Undoing the agent's changes is on the same screen. Also in the Project menu.
- Server mode: a message sent while the connection to the server is down is now kept and sent by itself, in order, once it is back, instead of failing. It is kept even if the app is closed. If the server refuses it (no budget left, for example), it says why with Send again, and the messages after it wait. Cancelling it puts its text back in the chat box.
- Files can be sorted by name, recently edited, largest or type, with folders kept on top or not. Chips under the title show one kind of file: folders, code, images, documents, data, archives or media. Only the kinds the folder has appear.
