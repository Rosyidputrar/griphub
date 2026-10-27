<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

**Pemakaian & kredit sesuai tagihan GripHub**
- Layar Pemakaian kini menampilkan angka asli dari akun GripHub kamu: saldo, kredit terpakai hari ini, tagihan per model, dan daftar request terakhir lengkap dengan biaya, token, dan tanda "Minimum" atau "Tidak ditagih".
- Peringatan saat kredit hampir habis, perkiraan sisa hari, dan tanggal kedaluwarsa kredit terdekat.
- Budget harian kini memakai tagihan asli hari ini (WIB), jadi berhenti tepat waktu.
- Perkiraan biaya jauh lebih akurat: token cache dan harga minimum per request kini ikut dihitung, sesuai cara GripHub menagih.
- Pemilih model menampilkan tarif, harga minimum per request, promo yang sedang berjalan, dan model yang sedang tidak tersedia.
- Daftar model GripHub diperbarui otomatis; ada juga tombol "Perbarui model". Model gambar tidak lagi muncul di pemilih model chat.
- Generate image menampilkan model dan harga per gambar langsung dari GripHub.
- Penghangatan cache otomatis dimatikan karena justru menambah biaya di GripHub.

**Subagent**
- Kartu subagent menampilkan model dan tingkat berpikir (reasoning) yang dipakai.
- Biaya subagent naik secara langsung di setiap langkah, dengan rincian request, token (termasuk cache), dan berapa request yang kena harga minimum. Batas biaya subagent kini berhenti tepat waktu.

**Chat**
- Tombol salin dan nama model hanya muncul setelah jawaban benar-benar selesai, tidak lagi di tengah pekerjaan agent.
- Tabel lebar di jawaban kini bisa digeser ke kiri dan kanan, tidak lagi dipaksa sempit sampai satu kata per baris.

## English

**Usage & credits that match GripHub's bill**
- The Usage screen now shows real figures from your GripHub account: balance, credits spent today, charges per model, and recent requests with their cost, tokens, and a "Minimum" or "Not charged" tag.
- A warning when credit runs low, an estimate of the days left, and the date of the next credit expiry.
- The daily budget now uses today's real charges (WIB), so it stops on time.
- Much more accurate cost estimates: cache tokens and each request's minimum price now count, the way GripHub bills.
- The model picker shows each model's rate, its per-request minimum, running promos, and models that are unavailable.
- GripHub's model list updates on its own, with an "Update models" button too. Image models no longer appear in the chat model picker.
- Generate image lists GripHub's image models with their price per image.
- Automatic cache warming is off, since on GripHub it added cost instead of saving it.

**Subagents**
- Subagent cards show the model and the thinking (reasoning) level in use.
- A subagent's cost now rises live with every step, with a breakdown of requests, tokens (cache included) and how many were billed at the minimum. The subagent cost limit now stops on time.

**Chat**
- The copy button and model name appear only once a reply is really finished, not in the middle of the agent's work.
- Wide tables in replies now scroll sideways instead of being squeezed to one word per line.
