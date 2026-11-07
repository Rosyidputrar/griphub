# Riwayat Perubahan GripHub

Semua perubahan GripHub yang dirasakan pengguna, dari yang terbaru. Setiap versi dibagi menjadi:

- **Baru**: fitur yang sebelumnya tidak ada.
- **Ditingkatkan**: fitur yang sudah ada dan kini lebih baik, lebih cepat, atau lebih jelas.
- **Diperbaiki**: hal yang sebelumnya salah atau gagal.
- **Keamanan**: perlindungan data, akun, dan server.

Versi yang hanya berisi pemeliharaan (tes, proses build) ditandai begitu.

---

## Belum dirilis

### Baru
- **Router Pintar: "Otomatis (Pintar)" di pilihan model.** Chat yang memakainya memilih sendiri model termurah yang sanggup untuk tiap pesan, berdasarkan data GripHub Router tentang kemampuan dan harga terkini tiap model.
  - Gambar terlampir hanya dikirim ke model yang bisa membaca gambar; chat Coding hanya ke model yang bisa memakai tools.
  - Bila balasan gagal, terpotong, atau kamu bilang jawabannya salah, pesan berikutnya naik ke model yang lebih kuat.
  - Nama model yang benar-benar dipakai tetap tampil, dengan tanda kecil ✦ bahwa ia dipilih otomatis.
  - Setiap keputusan tercatat beserta alasan dan perkiraan biayanya: Pemakaian → Chat ini → Keputusan Router Pintar.
  - Memilih model sendiri menghentikan pilihan otomatis untuk chat itu. Bisa dimatikan, dan model tertentu bisa dikecualikan, di Pengaturan → Router Pintar.

---

## v1.0.133 (5 November 2026)

### Baru
- **Pengaturan → Status model.** Dua tab dengan angka dari GripHub Router, bukan perkiraan:
  - **Status**: model mana yang bekerja sekarang. Tiap model punya status (Bekerja, Lambat atau gagal, Mati, Sepi), persentase berhasil, dan deretan batang waktu yang menunjukkan kapan ia gagal. Ketuk sebuah model untuk waktu tunggu, kecepatan, dan penyebab gagalnya. Yang gagal dan sedang dipakai ada di atas; model yang tidak dipakai disembunyikan sampai diminta.
  - **Peringkat**: model mana yang paling banyak dipakai (24 jam, 7, 14, 30 hari, atau semua), dengan porsinya. Ini menunjukkan seberapa populer sebuah model, bukan seberapa bagus.
  - Angkanya milik semua pengguna router, bukan hanya kamu. Status memakai key GripHub yang tersimpan; peringkat tidak perlu key.
  - Kalau router tidak terjangkau, salinan terakhir tetap tampil dengan keterangan dari kapan.

### Ditingkatkan
- **Model kini punya logo pembuatnya.** Di daftar model, di pilihan model di chat, di Pemakaian, dan di layar Status model: Claude, GPT, Gemini, DeepSeek, GLM, Kimi, MiniMax, Qwen, Grok, serta Muse (Meta) dan Hy (Tencent). Sebelumnya semua model GripHub memakai satu ikon yang sama, atau tanpa ikon sama sekali.

## v1.0.131 (3 November 2026)

### Baru
- **Tombol + membuka dua pilihan: Chat dan Coding.**
  - **Chat** langsung memulai percakapan biasa, tanpa memilih folder. **Coding** membuka lembar untuk memilih proyek, seperti sebelumnya.
  - Tombol + berubah jadi silang, halaman di belakang meredup, dan pilihan muncul bergantian dari tombol. Kembali atau ketukan di luar menutup menu lebih dulu.
  - Bila **Kurangi animasi** aktif, pilihan langsung tampil tanpa gerak.

### Ditingkatkan
- **Lembar chat coding lebih sederhana.** Isinya kini hanya pilihan folder dan proyek, karena **Chat** sudah ada di menu +.

## v1.0.128 (3 November 2026)

### Baru
- **Chat biasa, terpisah dari chat coding.** Ketuk +, lalu pilih **Chat** untuk bertanya, mencari berita, atau minta bantuan menulis, seperti ChatGPT di web.
  - Agent di chat ini hanya punya pencarian web, baca halaman, baca lampiran, dan pembuat gambar (kalau aktif). Tanpa terminal, file proyek, todo, atau subagent, jadi pertanyaan biasa tidak lagi memicu banyak tool.
  - Satu jawaban paling banyak memakai beberapa pencarian. Lewat itu, agent diminta menjawab dengan yang sudah ada.
  - Jawaban yang memakai web menyebut sumbernya. Pencarian tampil sebagai satu kalimat, misalnya "Mencari di web ...", dan bisa diketuk untuk melihat detailnya.
  - Chat coding tetap seperti sebelumnya, di bawah bagian **Coding** pada lembar chat baru.
- **Daftar chat bisa disaring** Semua / Chat / Coding. Penyaring muncul begitu kamu punya chat biasa.

## v1.0.126 (3 November 2026)

### Baru
- **Agent bisa membuat gambar langsung di chat.** Minta saja, misalnya "buatkan logo kedai kopi, 2 variasi", dengan model chat apa pun.
  - Secara bawaan dipakai model gambar termurah menurut tarif saat itu, promo ikut dihitung. Kalau kamu menyebut model tertentu, model itu yang dipakai.
  - Hasilnya gambar asli, bukan SVG, dan disimpan di folder `.images` proyek. Folder itu tidak ikut ke git.
- **Kartu gambar yang hidup.**
  - Selama gambar dibuat, kotaknya berkilau dalam ukuran akhirnya. Begitu jadi, gambar muncul halus satu per satu.
  - Ketuk untuk layar penuh. Tekan lama untuk simpan ke HP, bagikan, salin path, atau salin prompt.
- **Pengaturan → Gambar**, dengan batas sendiri:
  - sampai berapa kredit boleh tanpa bertanya (bawaan 10);
  - berapa gambar per permintaan (bawaan 4);
  - batas harian gambar (bawaan 50 kredit);
  - apa yang terjadi bila lewat batas: tanya dulu, pakai model termurah, atau tolak.

  Pemakaian gambar hari ini juga terlihat di sana.
- **Kartu "Buat gambar ini?"** muncul bila permintaan lewat batas. Kartu ini menampilkan model, jumlah gambar, dan perkiraan kreditnya. Sengaja tanpa tombol Selalu, dan mode Lewati semua izin pun tidak melewatinya.
- **Riwayat perubahan di dalam aplikasi.** Buka lewat Pengaturan → Tentang → Riwayat perubahan, atau tombol "Lihat riwayat perubahan" di lembar pembaruan.
  - Versi dipilih dari deretan tombol di atas yang bisa digeser. Di bawahnya tampil satu kartu berisi apa yang baru, ditingkatkan, diperbaiki, dan soal keamanan di versi itu.
  - Layar langsung membuka versi yang terpasang di HP, ditandai "Versi kamu".
  - Bisa dibuka tanpa internet.
- **Pengaturan → Tampilan → Kurangi animasi.** Saat aktif, layar dan lembar langsung muncul tanpa gerakan. Di HP bermemori kecil pengaturan ini otomatis aktif, dan tetap bisa dimatikan.

### Ditingkatkan
- **Perpindahan layar lebih utuh.**
  - Layar baru meluncur selebar layar dari kanan sambil muncul (250 ms), sementara layar di bawahnya meluncur penuh ke kiri.
  - Kembali adalah kebalikannya dan tanpa memudar: layar keluar utuh ke kanan, layar sebelumnya datang dari kiri.
  - Gestur kembali Android tetap sama, dan pindah tab di Beranda kini hanya memudar.
- **Kembali menutup lapisan paling atas dulu.** Urutannya: saran "/" dan "@" di atas kolom pesan (teks yang diketik tetap ada), lalu kolom cari di editor, lalu lembar yang ditarik penuh (kembali ke tinggi awalnya dulu). Baru setelah itu layarnya.
- **Lembar bawah bergerak dengan pegas tanpa memantul.**
  - Sentilan ringan ke bawah sudah cukup untuk menutup. Bila dilepas pelan, lembar berhenti di posisi terdekat.
  - Daftar di dalam lembar digulir ke atas dulu sebelum lembarnya ikut turun.
  - Sudut atas lembar menjadi siku saat lembar memenuhi layar.
- **Backup otomatis server hanya mengunduh yang berubah.**
  - Setiap file disimpan terpisah dan terenkripsi. Backup berikutnya cukup membawa file yang baru atau berubah ke HP, bukan seluruh backup lagi (sebelumnya puluhan MB setiap jam).
  - File yang isinya sama hanya disimpan sekali.
  - Unduhan yang terputus dilanjutkan dari titik terakhir.
  - Kartu backup menampilkan berapa yang diunduh, misalnya "diunduh 182 KB, hanya yang berubah".
  - Backup lama tetap bisa dipulihkan.
- **Model Anthropic dan OpenAI di GripHub Router dipanggil dengan format aslinya**, tetap lewat router dan key GripHub yang sama. Hasilnya, fitur khas tiap model (misalnya cara berpikirnya) terbaca utuh.
- **Gambar ikut dihitung dalam batas harian akun**, baik yang dibuat agent maupun yang dari layar Buat gambar.

### Diperbaiki
- **Link di chat kini membuka alamat yang tertulis.** Karakter tak terlihat di dalam alamat, seperti spasi lebar nol, dibuang. Sebelumnya karakter itu bisa membuat link membuka halaman lain padahal tulisannya tampak sama.
- **Gambar yang gagal kini disebut jelas statusnya**: tidak ditagih, atau mungkin tetap ditagih (cek Pemakaian sebelum mencoba lagi). Tidak ada percobaan ulang otomatis yang diam-diam menambah biaya.

### Keamanan
- **Restore backup lebih aman.** Setiap bagian backup diperiksa keutuhannya dulu sebelum ada yang ditulis ke HP, dan tidak ada salinan tanpa enkripsi yang tertinggal di disk.
- **Nama file di backup server tidak membocorkan isinya.** Tanpa kunci backup, isi file tidak bisa ditebak dari namanya.

## v1.0.119 (1 November 2026)

### Ditingkatkan
- **Edit & kirim ulang pesan kini bertanya dulu.** Sebelumnya semua pesan sesudahnya langsung keluar dari chat dan dilupakan agent, tanpa pertanyaan dan tanpa undo.
- **Subagent pertama di setiap chat meminta persetujuan**, mengikuti mode persetujuan yang berlaku. Kartunya menampilkan tugas dan profil subagent-nya.
- **Tawaran batas harian setelah key GripHub pertama disimpan**: 10, 25, 50, atau 100 kredit (lengkap dengan nilai rupiahnya), atau tanpa batas. Baris Pemakaian & anggaran di Pengaturan kini jelas menyebut bila belum ada batas.

## v1.0.117 (1 November 2026)

### Keamanan
- **Agent tidak bisa menulis di luar folder proyek tanpa persetujuan.** Jalur berawalan `@`, `file://`, dan sejenisnya ditutup.
- **Git di folder proyek tidak lagi menjalankan program dari konfigurasi repo.**
- **Perintah di dalam box tidak bisa menimpa berkas server** (misalnya `authorized_keys`) lewat symlink tertanam.
- **Pengambilan halaman web oleh agent tidak menjangkau alamat privat**, jaringan lokal, atau metadata cloud, termasuk lewat redirect.
- **Review & commit punya kotak centang per file.** Commit hanya memuat file yang dicentang, jadi `.env` tidak ikut masuk tanpa sengaja.

### Ditingkatkan
- **Detail subagent tampil seperti chat**: pikiran, teks antar-langkah, tool, dan pesan antrean, berurutan dan mengikuti langkah terbaru. Penulisan file tampil baris demi baris saat terjadi, dan subagent bisa dibagikan sebagai Markdown.
- **Performa**: jawaban streaming tidak makin berat seiring panjangnya, diff ribuan baris langsung terbuka, dan daftar chat tetap ringan meski berisi ratusan chat.
- **Aksesibilitas**: animasi mengikuti pengaturan sistem "hapus animasi", dan pembaca layar membacakan pekerjaan agent serta status tool.
- **Agent yang macet dalam satu perulangan dimatikan otomatis** setelah dua menit, lalu layanannya dipulihkan.

### Diperbaiki
- **Akun dan pengaturan tidak lagi bisa hilang saat penyimpanan terpotong.** Ini berlaku untuk login, host SSH, MCP, jadwal, dan sinkron, yang kini ditulis utuh atau tidak sama sekali.
- **Persetujuan yang dijawab saat koneksi server putus tidak lagi hilang**; kartunya kembali ke antrean.
- **Kegagalan tombol Stop, mode Rencana, dan tingkat berpikir kini dilaporkan**, tidak diam saja.
- **Key GripHub yang salah ketik terbaca sebagai "key salah"**, bukan balasan HTTP mentah.
- **Backup otomatis server tidak lagi membengkak.** Folder berawalan titik (misalnya `.toolchains`) dan folder hasil build tidak ikut lagi.

## v1.0.111 (31 Oktober 2026)

### Baru
- **Backup otomatis di HP.** Disimpan ke `Download/GripHub` tanpa API key, dan dilindungi kode pemulihan yang bisa dicatat.

### Ditingkatkan
- **Masuk ke GitHub dengan kode kini ditunggu oleh agent**, bukan oleh aplikasi. Proses ini tidak gagal lagi hanya karena aplikasi ditutup, layar ditinggalkan, atau Batal ditekan.
- **Layar Akun menyebut akun itu milik agent yang mana.** Agent HP dan agent server menyimpan akunnya sendiri-sendiri.

### Diperbaiki
- **Pratinjau halaman dan dev server di HP bisa dibuka.** Pratinjau ke `127.0.0.1` atau `localhost` tidak lagi ditolak Android.
- **Mode server: box yang macet ditolak dalam sekitar 30 detik** dengan pesan yang jelas, bukan menggantung. Ini terjadi bila container berstatus "Running" tapi tidak menjawab.

## v1.0.109 (31 Oktober 2026)

### Ditingkatkan
- **Batas ringkasan konteks mengikuti model.** Bawaannya 65% dari jendela konteks model yang dipakai (minimum 300 ribu token), bukan lagi satu angka untuk semua model. Masih bisa diubah di Pengaturan → Usage.

## v1.0.105 (31 Oktober 2026)

- Rilis pemeliharaan; tidak ada perubahan yang terlihat.

## v1.0.100 (31 Oktober 2026)

### Baru
- **Tugas → Pekerjaan latar.** Menampilkan pekerjaan latar dari semua chat beserta durasi dan tombol Berhenti. Paling banyak 6 pekerjaan latar berjalan bersamaan.
- **Panduan server**: entri baru untuk perintah yang macet saat box menyala, dengan langkah menghentikan atau mematikan box.

### Ditingkatkan
- **Baris "Konteks diringkas" menampilkan biaya ringkasannya** (misalnya ~0,42 kredit). Giliran lama yang sudah diringkas bisa dibaca lagi lewat "Baca giliran sebelumnya".
- **Akun → GitHub jujur soal masuk dengan kode.** Bila Client ID belum diisi, tertulis bahwa cara itu tidak bisa dipakai dan sebaiknya masuk lewat browser.
- **Animasi selesai (centang hijau)** kini berganti warna dulu, baru bergerak.

### Diperbaiki
- **Ringkasan yang gagal tidak dicoba ulang setiap giliran** sampai anggaran harian habis. Ringkasan dicoba lagi hanya setelah chat bertambah seperempat, dan berhenti setelah tiga kali gagal.
- **Mode server: chat yang sedang terbuka dibuka lagi setelah agent di server dimulai ulang**, tidak berganti ke chat kosong.
- **Subagent yang menunggu persetujuan berhenti menunggu saat batas waktunya habis**, dan menghapus chat ikut menghentikan subagent-nya.

## v1.0.94 (31 Oktober 2026)

### Diperbaiki
- **Antrean offline tidak lagi mengirim pesan yang sama dua kali**, dan pesan baru tidak bisa menyalip antrean.
- **Chat yang dibangun ulang karena perubahan pengaturan tetap berada di foldernya**; sebelumnya bisa terpental keluar folder.
- **Penyebutan `@` bekerja juga tanpa ripgrep.** Penjelajahan file kini membaca `.gitignore`.

## v1.0.92 (31 Oktober 2026)

- Rilis pemeliharaan; tidak ada perubahan yang terlihat.

## v1.0.90 (31 Oktober 2026)

### Baru
- **Ketik `@` di kolom chat untuk memilih file proyek.** Daftar file muncul sesuai ketikan, dan path-nya langsung masuk ke pesan.
- **Bagikan chat dari menu Project**: sebagai teks atau file Markdown, disalin, atau disimpan ke Download. Isinya pesan, jawaban agent, dan tool yang dipakai.
- **Review & commit.** Setelah agent selesai dan ada file berubah, chat menawarkan satu layar berisi:
  - semua file yang berubah beserta diff-nya;
  - pesan commit yang bisa diubah;
  - tombol Commit dan Commit dan push;
  - pilihan untuk membatalkan perubahan.

  Layar ini juga tersedia di menu Project.
- **Mode server: pesan yang dikirim saat koneksi putus disimpan** dan dikirim otomatis berurutan begitu tersambung lagi. Pesan tetap tersimpan walau aplikasi ditutup. Bila server menolak, alasannya tampil dengan tombol Kirim lagi.

### Ditingkatkan
- **Kartu persetujuan edit/tulis file menampilkan perubahannya** (baris ditambah dan dihapus) sebelum kamu mengizinkan. Perubahan panjang bisa dibuka utuh di halaman sendiri, termasuk untuk persetujuan subagent.
- **Files bisa diurutkan** (nama, terakhir diedit, terbesar, jenis) dan disaring per jenis file dengan chip.

### Diperbaiki
- **Tombol Tolak, Selalu, dan Izinkan tidak lagi terpotong** di layar sempit dengan teks besar.

## v1.0.85 (31 Oktober 2026)

### Ditingkatkan
- **Pesan error ditulis ulang dengan bahasa yang mudah dipahami.** Saat koneksi putus atau terlalu lama, aplikasi memberi tahu apa yang perlu dilakukan, dan teks teknis tidak tampil lagi. Error layar penuh (Usage, Box, Template) punya tombol Coba lagi.
- **Lebih mudah disentuh dan dibaca:**
  - tombol kecil di kolom chat, header beranda, pilihan segmen, dan chip Buat gambar punya area sentuh 48 dp;
  - pembaca layar menyebut nama setiap sakelar, dan mengucapkan "Selesai" atau "Gagal" dari simbolnya;
  - teks merah, hijau, dan oranye di mode terang lebih pekat;
  - ekor animasi memuat lebih terang di halaman gelap.
- **Layar Cari, Git, dan Sinkron GitHub kini sepenuhnya berbahasa Indonesia.**

### Diperbaiki
- **Bilah navigasi beranda tidak lagi terpotong** di layar 320 dp.

## v1.0.83 (30 Oktober 2026)

### Baru
- **Chat panjang diringkas otomatis.** Begitu konteks melewati 300 ribu token, giliran lama menjadi ringkasan dan giliran terbaru tetap utuh. Batasnya bisa diubah di Pengaturan → Usage (100–500 ribu token, atau mengikuti batas model).
- **Animasi memuat baru di seluruh aplikasi**: komet yang berputar.
  - Komet besar dipakai saat satu layar menunggu data, komet kecil di tombol atau baris.
  - Warnanya mengikuti tema, dan animasinya berhenti bila animasi dimatikan di sistem.

### Ditingkatkan
- **Saat meringkas, chat menampilkan "Meringkas konteks"** dengan waktu berjalan, lalu jumlah token yang dihemat (misalnya 320k → 24k). Ketuk barisnya untuk penjelasan.
- **Pesan yang dikirim saat meringkas menunggu sampai selesai**, tidak lagi ditolak.
- **Memulihkan cadangan, menyiapkan deploy, dan memulai chat diakhiri tanda centang (berhasil) atau silang (gagal)** sesaat sebelum dialog tertutup.
- **Pekerjaan latar lebih tertib**: catatannya dibatasi, ada batas per chat, dan hasilnya tetap sampai walau pengiriman sempat gagal.

### Diperbaiki
- **Jam pada giliran yang berhenti atau gagal menyatakan statusnya**, bukan "Selesai" berwarna hijau.
- **Salinan sementara dari tempel dan bagikan dibersihkan dari cache setelah sehari**, dan sisa berkas restore dibersihkan saat aplikasi dibuka.

## v1.0.80 (30 Oktober 2026)

### Baru
- **Pekerjaan latar.** Agent bisa menjalankan perintah panjang (build, test, instalasi besar) di latar lalu lanjut mengerjakan hal lain.
  - Saat selesai, agent otomatis dipanggil kembali di chat yang sama dengan hasilnya, tanpa perlu pesan dari kamu.
  - Batasnya 60 menit, dan pekerjaan bisa dihentikan dari kartunya.
- **Waktu kerja AI tampil langsung di chat.** Teks biru berkilau menghitung waktu selama agent bekerja, lalu berubah hijau dan berhenti di waktu selesai. Waktunya tetap tersimpan saat chat dibuka lagi.
- **Tempel gambar ke kolom pesan**: tekan lama → Tempel gambar, atau lewat tombol +. Gambar dari keyboard langsung jadi lampiran.
- **Gambar yang dibaca agent tampil sebagai thumbnail di kartu tool**; ketuk untuk layar penuh.
- **Backup otomatis server**, setiap jam bila ada perubahan.
  - Terenkripsi, dan berisi semuanya: termasuk API key dan `.git`, tanpa dependensi.
  - Backup terbaru dibawa ke HP, dan ditawarkan untuk dipulihkan saat kembali ke agent HP.
- **Panduan server dan box kini ada di dalam aplikasi.**

### Ditingkatkan
- **Git: ketuk file yang berubah untuk melihat isinya.** Gambar tampil sebagai gambar, teks tampil penuh, dan file biner disebut jenis serta ukurannya.
- **Setiap aksi yang menunggu memberi tanda dan tidak bisa terpicu dua kali**, misalnya kirim pesan, deploy, pilih model, dan Sync GitHub.
- **"Hentikan & pindah" menampilkan "Menghentikan agent…"** selama prosesnya.

### Diperbaiki
- **Diff, stage, unstage, dan buang perubahan kini benar untuk proyek di subfolder repositori.**
- **Tombol Pull dan Push tidak lagi terpotong.**

## v1.0.77 (29 Oktober 2026)

### Baru
- **Link di bubble chat bisa diketuk.** Sebelum dibuka di browser ada konfirmasi, dan domain bisa ditandai "Selalu percayai" (dikelola di Pengaturan → Domain terpercaya).

### Ditingkatkan
- **Proses berpikir agent tampil sebagai pratinjau 3 baris.** Ketuk untuk membuka sampai 12 baris yang bisa digulir sampai akhir.
- **Pesan yang dikirim saat agent masih bekerja langsung tampil** dengan label "Menunggu giliran", dan bisa dibatalkan.
- **Teks tempelan 10 baris atau lebih otomatis menjadi lampiran.**

## v1.0.75 (28 Oktober 2026)

### Ditingkatkan
- **Perbarui di server ikut memperbarui berkas box**, tidak hanya agent.
  - Agent dijalankan ulang setelah pekerjaan yang sedang berjalan selesai.
  - Bila penyalinan pembaruan terputus, versi lama tetap dianggap terpasang, jadi Perbarui aman dicoba lagi.
- **Tombol "Salin editan saya" saat file yang sedang diedit diubah agent**, tersedia sebelum memilih Muat ulang atau Timpa.
- **Pemilih folder menampilkan status memuat** dan tombol Coba lagi.
- **Istilah bahasa Indonesia dibuat lebih konsisten.**

### Diperbaiki
- **Mode server: perintah di dalam box tidak lagi macet** setelah box pertama kali dibuat.
- **Box tetap hidup saat agent di server dijalankan ulang atau diperbarui.**

## v1.0.73 (28 Oktober 2026)

### Baru
- **Agent di server sendiri (VPS).** Agent bisa berjalan 24 jam di VPS milikmu, dan tetap bekerja saat aplikasi ditutup atau HP mati. Buka Pengaturan → Agent di VPS / server.
- **Pemasangan tanpa mengunduh apa pun**:
  1. salin satu perintah dari aplikasi;
  2. tempel di terminal server (Ubuntu/Debian);
  3. tempel kode setup yang dicetak server ke aplikasi.

  Server langsung dites sebelum agent dipakai.
- **Semua fitur bekerja di server**: chat, file, editor, pratinjau HTML, dev server, terminal, backup, dan lampiran.
- **Chat HP dan chat server terpisah** dan bisa dialihkan bolak-balik.
- **Koneksi yang putus disambung ulang sendiri**, lalu chat menyusul tanpa pesan ganda.
- **Perintah agent berjalan di dalam box**, yaitu container terpisah di server.
- **Notifikasi lewat aplikasi ntfy saat aplikasi tertutup.** Isinya judul umum saja, tanpa isi chat.
- **Kartu kesehatan server, daftar periksa, dan panduan "Bila ada masalah"** langsung di aplikasi.

## v1.0.65 (28 Oktober 2026)

- Rilis persiapan mode server; fiturnya diumumkan di v1.0.73.

## v1.0.63 (28 Oktober 2026)

- Rilis persiapan mode server; fiturnya diumumkan di v1.0.73.

## v1.0.54 (28 Oktober 2026)

### Baru
- **Biaya setiap jawaban terlihat** di samping tombol salin dan nama model: token dan perkiraan kredit untuk satu giliran, dengan biaya subagent terpisah. Ketuk untuk rincian request, token termasuk cache, kredit, dan rupiah.
- **Tasks: geser task yang selesai, gagal, atau dibatalkan ke kiri atau kanan untuk menghapusnya**, dengan tombol Urungkan.
- **Repo yang sudah ada di HP bisa ditarik perubahannya dan pindah branch** langsung dari daftar repository.

### Ditingkatkan
- **Teks panjang yang ditempel** (lebih dari 1.000 karakter atau 15 baris) otomatis menjadi lampiran "Konten yang ditempel", agar kolom ketik tetap rapi.
- **Aplikasi tidak lagi berat saat agent menulis file panjang.** Selama menulis, yang tampil hanya baris terbaru beserta jumlah baris dan ukurannya.
- **Tombol notifikasi bawah (Urungkan, Buka, Lihat) terbaca di tema gelap.**

### Diperbaiki
- **Pesan yang diantrekan ke subagent yang sedang berjalan benar-benar terkirim.** Sebelumnya subagent malah berhenti dengan status gagal.
- **Subagent tidak lagi dinyatakan gagal saat koneksi sempat putus** lalu berhasil dicoba ulang.
- **Login GitHub tidak lagi berhenti bekerja setelah beberapa jam** (error "401 Bad credentials").
  - Sesi diperpanjang otomatis.
  - Layar Akun menampilkan tombol "Masuk lagi" bila sesi sudah tidak berlaku, dan tidak lagi mengklaim push aktif.
- **Repo bernama sama dari pemilik berbeda tidak lagi tertukar.**

## v1.0.51 (27 Oktober 2026)

### Baru
- **Layar Pemakaian menampilkan angka asli akun GripHub**:
  - saldo, kredit terpakai hari ini, dan tagihan per model;
  - daftar request terakhir lengkap dengan biaya, token, dan tanda "Minimum" atau "Tidak ditagih";
  - peringatan kredit hampir habis, perkiraan sisa hari, dan tanggal kedaluwarsa kredit terdekat.

### Ditingkatkan
- **Anggaran harian memakai tagihan asli hari ini (WIB)**, sehingga berhenti tepat waktu.
- **Perkiraan biaya jauh lebih akurat**: token cache dan harga minimum per request ikut dihitung.
- **Penghangatan cache otomatis dimatikan**, karena justru menambah biaya.
- **Pemilih model menampilkan informasi lengkap**: tarif, harga minimum per request, promo berjalan, dan model yang sedang tidak tersedia.
  - Daftar model diperbarui otomatis, dan ada tombol "Perbarui model".
- **Buat gambar menampilkan model dan harga per gambar.**
- **Kartu subagent menampilkan model dan tingkat berpikir yang dipakai.** Biayanya naik langsung di setiap langkah lengkap dengan rincian, dan batas biayanya berhenti tepat waktu.
- **Tabel lebar di jawaban bisa digeser kiri-kanan.**

### Diperbaiki
- **Tombol salin dan nama model hanya muncul setelah jawaban benar-benar selesai.**

## v1.0.49 (27 Oktober 2026)

### Ditingkatkan
- **Kartu subagent muncul tepat di tempat agent memanggilnya di chat.**
  - Statusnya jelas: berjalan, minta persetujuan, antre, menghentikan, selesai, gagal, atau berhenti, dengan animasi halus.
  - Persetujuan bisa dijawab langsung dari kartu (Tolak, Selalu, Izinkan).
  - Detailnya menampilkan waktu, token, dan perkiraan biaya.
- **Pengaturan subagent diperbarui**:
  - batas waktu bisa "Tanpa batas";
  - nilai kustom menerima desimal kredit;
  - persetujuan bisa "Sama dengan chat";
  - ada notifikasi baru "Subagent berjalan".
- **Berpindah atau membuat chat saat agent masih bekerja meminta konfirmasi**, tidak lagi menghentikan pekerjaan diam-diam.
- **Editor memperingatkan bila file diubah agent** sebelum kamu menyimpan.
- **"Batalkan perubahan" menampilkan file yang akan dihapus**, dan kamu bisa memilih mana yang tetap disimpan.

### Keamanan
- **Deploy lewat SSH tidak lagi mengunggah file rahasia** seperti `.env` dan dotfile lain. Sebelum mulai, muncul konfirmasi berisi server, folder, dan file yang tidak diunggah.

### Diperbaiki
- **Memasang ulang atau mengganti container Linux tidak lagi menghapus container lama** bila unduhan gagal.

## v1.0.47 (27 Oktober 2026)

### Diperbaiki
- **Subagent kini bisa digunakan.** Sebelumnya agent menjawab bahwa tool-nya tidak tersedia; sekarang perintah itu benar-benar menjalankan subagent di dalam chat.

### Ditingkatkan
- **Layar pengaturan subagent lebih rapi**: pilihan terpilih lebih jelas, teks lebih mudah dibaca, kata "kredit" konsisten, dan tata letak lebih rapat (termasuk mode compact).

## v1.0.42 (27 Oktober 2026)

### Baru
- **Subagent diperkenalkan**: agent bisa membagi pekerjaan ke subagent yang berjalan sendiri, lengkap dengan kartu, pengaturan, dan notifikasinya. Baru berfungsi penuh sejak v1.0.47.

## v1.0.40 (26 Oktober 2026)

### Ditingkatkan
- **Catatan rilis kini ditulis khusus untuk pengguna** dan dimulai dari rilis ini, bukan lagi dihasilkan otomatis.

## v1.0.39 (26 Oktober 2026)

### Ditingkatkan
- Pembaruan antarmuka chat dan agent, serta lampiran yang terkirim kini tampil benar di chat.

## v1.0.13 (26 Oktober 2026)

### Ditingkatkan
- **Agent diberi batasan per request**, agar riset tidak berputar tanpa henti.
- **APK kini diterbitkan dari halaman rilis publik**, sehingga pembaruan di aplikasi mengambil dari sana.

---

# Build awal

Build pertama GripHub sebelum rilis publik. Penomorannya terpisah dari daftar di atas, jadi versi seperti v1.0.13 dan v1.0.35 di sini berbeda isinya dengan versi bernomor sama di atas.

## v1.0.35 (26 Oktober 2026)

### Ditingkatkan
- **Animasi gerak di chat**: status agent, baris tool, dan kartu persetujuan kini dianimasikan dengan durasi dan kurva yang sama (cepat 150 ms, normal 240 ms).

## v1.0.33 (26 Oktober 2026)

### Ditingkatkan
- **Chat dipoles menyeluruh**: teks diterjemahkan, kolom ketik dirapikan, dan tombol Stop tetap bisa ditekan selama agent bekerja.
- **Layar tools dirapikan dan diterjemahkan.**
- **Kontras teks di atas warna aksen diperbaiki.**
- **Tab Chat/Proyek, pemilih model, dan istilah proyek dibuat konsisten.**

## v1.0.31 (26 Oktober 2026)

### Baru
- **Kartu repo**: repo dan branch tampil di kartu konteks, dengan tombol untuk repo aktif.
- **Status CI tampil di header repo.**
- **Tombol jalankan ulang perintah terakhir di terminal.**

### Ditingkatkan
- **Repo terakhir tetap aktif, dan chip repo aktif tampil di semua layar**, dengan drawer repo dan header konteks yang sama di setiap layar.
- **Pesan sukses dan error tampil langsung di terminal dan chat.**
- **Panel detail repo dirapikan.**

## v1.0.29 (25 Oktober 2026)

### Baru
- **Model favorit**: bagian "Favorit" di atas pemilih model dan tanda bintang di setiap baris model. Pilihan tersimpan di HP.

## v1.0.28 (25 Oktober 2026)

### Ditingkatkan
- **Gestur kembali: halaman yang digeser kembali bergeser penuh sampai keluar layar**, tidak lagi berhenti di tengah lalu hilang.

## v1.0.26 (25 Oktober 2026)

### Baru
- **Mesin pencari TinyFish** sebagai penyedia pencarian web untuk agent.

### Ditingkatkan
- **Riwayat terminal bisa diketuk untuk diedit dulu** sebelum dijalankan, dan tampilannya menampilkan teks penuh.
- **Prompt terminal dijaga** agar tidak terkirim tanpa sengaja.
- **Layar lisensi dihapus dari Pengaturan.**

## v1.0.24 (25 Oktober 2026)

### Baru
- **Layar sambutan bergeser** saat pertama membuka GripHub.

## v1.0.18 (25 Oktober 2026)

### Ditingkatkan
- **Paket perbaikan besar hasil audit menyeluruh** atas build awal (tahap 1–5).
- **Sisa identitas aplikasi lama dibersihkan**, dan nama file APK kini berawalan `griphub-`.

## v1.0.13 (25 Oktober 2026)

### Baru
- **Build pertama GripHub.** Estimasi biaya pemakaian dihitung dari harga GripHub.
