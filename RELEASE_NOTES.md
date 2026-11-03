<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

- Agent kini bisa membuat gambar langsung di chat. Minta saja, misalnya "buatkan logo kedai kopi, 2 variasi", dengan model chat apa pun. Secara bawaan dipakai model gambar termurah (menurut tarif saat itu, termasuk promo), kecuali kamu menyebut modelnya. Hasilnya berupa gambar asli (bukan SVG), disimpan di folder `.images` proyek.
- Selama gambar dibuat, kotaknya berkilau dengan ukuran akhirnya, lalu gambar muncul halus begitu jadi, satu per satu. Ketuk untuk layar penuh; tekan lama untuk simpan ke HP, bagikan, salin path, atau salin prompt. Bila animasi dikurangi di HP, gambar langsung tampil.
- Gambar yang gagal disebut jelas: tidak ditagih, atau mungkin tetap ditagih (cek Pemakaian sebelum mencoba lagi). Tidak ada percobaan ulang otomatis.
- Pengaturan baru, Gambar, punya batas sendiri: sampai berapa kredit tanpa bertanya (bawaan 10), berapa gambar per permintaan (bawaan 4), batas harian gambar (bawaan 50 kredit), dan apa yang terjadi bila lewat batas (tanya dulu, pakai termurah, atau tolak). Di sana juga terlihat pemakaian gambar hari ini.
- Bila lewat batas, muncul kartu "Buat gambar ini?" dengan model, jumlah, dan perkiraan kreditnya. Kartu ini sengaja tanpa Selalu, dan mode Lewati semua izin tidak melewatinya.
- Gambar kini ikut dihitung dalam batas harian akun, baik dari agent maupun dari layar Buat gambar.
- Model Anthropic dan OpenAI di GripHub Router kini dipanggil dengan format aslinya masing-masing, tetap lewat router dan key GripHub yang sama.
- Perpindahan layar kini lebih utuh: layar baru meluncur penuh dari kanan sambil muncul (250 ms), layar di bawahnya meluncur penuh ke kiri. Kembali adalah kebalikannya, tanpa memudar: layar keluar utuh ke kanan, layar sebelumnya datang dari kiri. Gestur kembali Android tetap sama. Pindah tab di Beranda kini hanya memudar.
- Kembali selalu menutup lapisan paling atas lebih dulu: saran "/" dan "@" di atas kolom pesan (teksnya tetap), kolom cari di editor, dan lembar yang ditarik penuh (kembali ke tinggi awalnya dulu), baru kemudian layarnya.
- Lembar bawah kini bergerak dengan pegas tanpa memantul. Sentilan ringan ke bawah sudah cukup untuk menutup, dan bila dilepas pelan lembar berhenti di posisi terdekat. Daftar di dalam lembar digulir ke atas dulu sebelum lembarnya ikut turun, dan sudut atasnya menjadi siku saat lembar memenuhi layar.
- Pengaturan baru di Tampilan: Kurangi animasi. Otomatis aktif di HP bermemori kecil; layar dan lembar langsung muncul tanpa gerakan.
- Backup otomatis server kini hanya mengunduh yang berubah. Setiap file disimpan terpisah dan terenkripsi, jadi backup berikutnya cukup membawa file yang baru atau berubah ke HP, bukan seluruh backup lagi. Unduhan yang terputus dilanjutkan dari titik terakhir. Backup lama tetap bisa dipulihkan.
- Link di chat kini membuka alamat yang tertulis. Karakter tak terlihat di dalam alamat (misalnya spasi lebar nol) dibuang, karena sebelumnya bisa membuka halaman lain.
- Riwayat perubahan kini ada di dalam aplikasi: Pengaturan → Tentang → Riwayat perubahan, atau tombol "Lihat riwayat perubahan" di lembar pembaruan. Pilih versi dari deretan di atas untuk melihat apa yang baru, ditingkatkan, diperbaiki, dan soal keamanan di versi itu. Layar langsung membuka versi yang terpasang (ditandai "Versi kamu"), dan bisa dibuka tanpa internet.


## English

- The agent can now make pictures right in the chat. Just ask, for example "make a coffee shop logo, 2 variations", with any chat model. By default it uses the cheapest picture model (at the current rate, promos included) unless you name one. The result is a real picture (not SVG), saved in the project's `.images` folder.
- While a picture is made, its tile shimmers at its final size, then the picture comes in smoothly as soon as it is done, one by one. Tap for full screen; long-press to save to the phone, share, copy the path or copy the prompt. With reduced animations on the phone, pictures show at once.
- A picture that fails says so plainly: not billed, or maybe billed (check Usage before trying again). Nothing is retried on its own.
- A new Settings screen, Pictures, has its own limits: up to how many credits without asking (10 by default), how many pictures per request (4), a daily picture limit (50 credits), and what happens over a limit (ask first, use the cheapest, or refuse). It also shows today's picture spending.
- Over a limit, a "Make these pictures?" card shows the model, the count and the estimated credits. It has no Always on purpose, and Bypass all permissions does not skip it.
- Pictures now count toward the account's daily limit, from the agent and from the Generate image screen.
- Anthropic and OpenAI models on GripHub Router are now called in their own formats, still through the router with the same GripHub key.
- Moving between screens now feels whole: a new screen slides in fully from the right while it appears (250 ms), and the one under it slides fully to the left. Going back is the mirror image, with no fade: the screen leaves whole to the right and the previous one comes in from the left. Android's back gesture is unchanged. Switching Home tabs now only fades.
- Back always closes the top layer first: the "/" and "@" suggestions over the message field (the text stays), the editor's find bar, and a sheet pulled up to full height (back to its first height first), and only then the screen.
- Bottom sheets now move on springs that never bounce. A light flick down is enough to close one, and let go slowly it settles at the nearest place. A list inside scrolls back to its top before the sheet follows the finger down, and the top corners square off as a sheet fills the screen.
- A new setting in Appearance: Reduce animations. On by default on phones with little memory; screens and sheets then appear at once.
- Automatic server backups now download only what changed. Each file is stored on its own, encrypted, so the next backup brings only new or changed files to the phone instead of the whole backup again. A download that was cut off picks up where it stopped. Older backups still restore.
- Links in the chat now open the address they show. Invisible characters inside an address (such as a zero-width space) are removed; before, they could open a different page.
- The changelog is now inside the app: Settings → About → Changelog, or "See the changelog" on the update sheet. Pick a version from the row at the top to see what is new, improved, fixed and security-related in it. It opens on the version installed (marked "Your version") and works offline.
