<!-- Catatan rilis: tulis hanya perubahan yang dirasakan pengguna, tanpa nama repo/branch/PR. Isi file ini dipakai sebagai body rilis. -->

## Bahasa Indonesia

- Agent kini bisa membuat gambar langsung di chat. Minta saja, misalnya "buatkan logo kedai kopi, 2 variasi", dengan model chat apa pun. Secara bawaan dipakai model gambar termurah (menurut tarif saat itu, termasuk promo), kecuali kamu menyebut modelnya. Hasilnya berupa gambar asli (bukan SVG), disimpan di folder `.images` proyek.
- Selama gambar dibuat, kotaknya berkilau dengan ukuran akhirnya, lalu gambar muncul halus begitu jadi, satu per satu. Ketuk untuk layar penuh; tekan lama untuk simpan ke HP, bagikan, salin path, atau salin prompt. Bila animasi dikurangi di HP, gambar langsung tampil.
- Gambar yang gagal disebut jelas: tidak ditagih, atau mungkin tetap ditagih (cek Pemakaian sebelum mencoba lagi). Tidak ada percobaan ulang otomatis.
- Pengaturan baru, Gambar, punya batas sendiri: sampai berapa kredit tanpa bertanya (bawaan 10), berapa gambar per permintaan (bawaan 4), batas harian gambar (bawaan 50 kredit), dan apa yang terjadi bila lewat batas (tanya dulu, pakai termurah, atau tolak). Di sana juga terlihat pemakaian gambar hari ini.
- Bila lewat batas, muncul kartu "Buat gambar ini?" dengan model, jumlah, dan perkiraan kreditnya. Kartu ini sengaja tanpa Selalu, dan mode Lewati semua izin tidak melewatinya.
- Gambar kini ikut dihitung dalam batas harian akun, baik dari agent maupun dari layar Buat gambar.
- Model Anthropic dan OpenAI di GripHub Router kini dipanggil dengan format aslinya masing-masing, tetap lewat router dan key GripHub yang sama.

## English

- The agent can now make pictures right in the chat. Just ask, for example "make a coffee shop logo, 2 variations", with any chat model. By default it uses the cheapest picture model (at the current rate, promos included) unless you name one. The result is a real picture (not SVG), saved in the project's `.images` folder.
- While a picture is made, its tile shimmers at its final size, then the picture comes in smoothly as soon as it is done, one by one. Tap for full screen; long-press to save to the phone, share, copy the path or copy the prompt. With reduced animations on the phone, pictures show at once.
- A picture that fails says so plainly: not billed, or maybe billed (check Usage before trying again). Nothing is retried on its own.
- A new Settings screen, Pictures, has its own limits: up to how many credits without asking (10 by default), how many pictures per request (4), a daily picture limit (50 credits), and what happens over a limit (ask first, use the cheapest, or refuse). It also shows today's picture spending.
- Over a limit, a "Make these pictures?" card shows the model, the count and the estimated credits. It has no Always on purpose, and Bypass all permissions does not skip it.
- Pictures now count toward the account's daily limit, from the agent and from the Generate image screen.
- Anthropic and OpenAI models on GripHub Router are now called in their own formats, still through the router with the same GripHub key.
