# GripHub di server

Agent berjalan di server (VPS) milik Anda sendiri dan terus bekerja walau HP mati atau app ditutup. App di HP menjadi
klien: chat, subagent, file, editor, preview, terminal dan deploy, semuanya lewat satu koneksi SSH. Mode HP tetap ada.
Setiap pengguna GripHub memakai server-nya sendiri; developer app tidak menjalankan server apa pun.

```
HP (app) ──ssh──> server: sshd ──> griphub-attach ──soket unix──> host (systemd, user griphub)
                                                                     └─ perintah bash agent ──> box (Podman rootless)
```

- Satu akun server bernama `griphub`, **tanpa sudo**. Semua yang dikerjakan agent terjadi sebagai akun itu.
- Perintah `bash` agent berjalan di dalam **box**, container Podman rootless (root di dalam = `griphub` di luar).
- Server menyimpan semuanya: chat, subagent, berkas proyek, tugas latar belakang. GitHub sync mati di mode server;
  yang Anda lihat di app adalah yang ada di server.

Status: semua bagian sudah dibuat (fase 1–6 di `server_agent.md`): host, skrip server, layar **Agent server** di app,
file, pratinjau, terminal dan backup lewat server. Sedang diuji di VPS sungguhan (fase 7): checklist di
[`FIELD_TEST.md`](FIELD_TEST.md), laporan kondisi server dengan `sudo bash field-report.sh`.

Diadaptasi dari mode server CoderRa (`seseegy/coderra`, folder `server/`).

## Yang dibutuhkan

- Server Ubuntu atau Debian (diuji pada Ubuntu 24.04 dan Debian 13), x86_64 atau arm64, akses root.
- Minimal 2 core, 4 GB RAM, 20 GB disk. Host dibatasi 2 GB (subagent ikut di dalamnya) dan box 2 GB. Server lebih besar
  bisa diberi lebih banyak; lihat **Server yang lebih besar**.
- **Mesin yang boleh dikorbankan.** Box memakai jaringan server (`--network=host`) supaya server dev di dalamnya bisa
  dijangkau. Akibatnya agent di dalam box bisa menjangkau apa pun yang bisa dijangkau server itu. Jangan pasang di mesin
  yang menjalankan layanan lain yang tidak boleh disentuh agent.
- GripHub bisa berdampingan dengan CoderRa di server yang sama: akun, folder, soket dan layanan masing-masing terpisah.

## Memasang

File setup ikut di dalam app: tidak perlu repo, GitHub, atau unduhan lain.

1. **Di app:** Pengaturan → Data & keamanan → **Agent server**. Isi alamat server. App membuat kunci SSH miliknya dan
   menampilkan baris perintah, kira-kira:
   ```
   sh griphub-setup.sh --pubkey 'ssh-ed25519 AAAA… griphub-app' --address 'vps.contoh.com'
   ```
2. **Salin perintah setup** (tombol di bawah baris itu). Yang tersalin adalah satu tempelan: isi `griphub-setup.sh`
   (folder `server/` ini dalam satu file, ±20 KB) lalu baris perintah di atas.
3. **Di server**, sebagai root atau akun dengan sudo, tempel ke terminal (aplikasi SSH di HP pun bisa). Skrip
   membongkar file ke `~/griphub-server`, memeriksa SHA-256 setiap file (tempelan yang terpotong berhenti di sini dengan
   pesan "arrived damaged"), lalu menjalankan `bootstrap.sh` (beberapa menit: paket, Node.js, membangun image box).
   Aman diulang: akun, kunci dan pengaturan yang ada dipertahankan, sisanya diperbarui.

   Ingin melihat rencananya dulu? Jalankan baris perintah itu sekali lagi dengan `--dry-run` di ujungnya (tidak
   mengubah apa pun, tidak perlu root).

   Kalau menempel teks panjang di terminal Anda bermasalah: **Atau bagikan file setup** mengirim `griphub-setup.sh` ke
   aplikasi lain (mis. aplikasi SFTP) untuk diunggah ke server; jalankan baris perintahnya di folder yang sama.
4. Skrip mencetak **setup code** (`griphub1:…`). Tempel di app, lalu **Pasang / perbarui agent**: app menyalin host ke
   server dan menjalankannya.

Dari salinan repo juga bisa: salin folder `server/` ke server lalu jalankan `sudo bash bootstrap.sh --pubkey '…'
--address '…'` di dalamnya (opsinya sama).

Opsi `bootstrap.sh`:

| Opsi | Arti |
| --- | --- |
| `--pubkey KEY` | kunci publik app (wajib) |
| `--address HOST` | nama/IP yang dipakai app; tanpa ini skrip menebak alamat pertama mesin |
| `--user NAMA` | akun yang dibuat (bawaan `griphub`); akun lain = agent lain di server yang sama |
| `--no-box` | tanpa Podman: perintah agent berjalan **langsung di server**, tanpa pembatas |
| `--node-version X.Y.Z` | Node.js yang dipasang bila sistem belum punya yang cukup baru |
| `--harden-ssh --admin-user NAMA` | matikan login password dan root; `NAMA` harus sudah punya kunci SSH (supaya Anda tidak terkunci) |
| `--dry-run` | hanya tampilkan rencana |

## Apa yang dibuat skrip

| Di mana | Apa |
| --- | --- |
| akun `griphub` | tanpa sudo; skrip memperingatkan bila akun ada di grup `sudo`, `docker`, `lxd`, `adm` |
| `loginctl enable-linger griphub` | layanan jalan tanpa ada yang login |
| `~/.griphub/bin/` | `griphub-attach`, `box` |
| `~/.griphub/box/Containerfile` | resep image box (Ubuntu 24.04 + git, build-essential, python3, ripgrep, …) |
| `~/.griphub/env` | `GRIPHUB_STORE_KEY`, kunci acak untuk token tersimpan (mode 600, tidak pernah diganti) |
| `~/.griphub/host/` | host Node; diisi app lewat **Install / update agent** |
| `~/.config/systemd/user/griphub-hostd.service` | layanan; `Restart=always`, batas memori 2 GB, tidak jalan sebelum host dipasang |
| `~/.ssh/authorized_keys` | kunci app dengan batasan: `restrict,pty,port-forwarding,permitopen="127.0.0.1:*",permitlisten="127.0.0.1:1"` |
| `~/.pi/agent/`, `~/workspace/` | state agent (chat, subagent) dan folder proyek |
| `~/.griphub/box-home/` | home milik box (git/ssh yang disalin, riwayat); dibuat saat box pertama dipakai |

Kunci app hanya boleh membuka terminal dan meneruskan port ke loopback server itu sendiri. Ia tidak bisa membuka port di
server (`-R`) atau menjangkau mesin lain lewat server.

## Yang aman, yang tidak

Dijaga:
- App memercayai **host key** yang ada di setup code (dipin; `StrictHostKeyChecking yes`), bukan "siapa pun yang menjawab".
- Agent tidak punya sudo. Pada tugas latar belakang, perintah berisiko (`rm -rf`, `git push`, `ssh`, `curl | sh`, …)
  **ditolak**, bukan ditanyakan, karena tidak ada yang mengawasi. Chat dan subagent tetap bertanya; persetujuan yang
  menunggu muncul lagi saat app tersambung, dan bisa dikirim sebagai notifikasi.
- Kunci SSH app dan `authorized_keys` tidak pernah disalin ke box.
- Preview halaman web dilindungi token acak di URL; berkas berawalan titik dan symlink keluar folder tidak disajikan.
- Disk di bawah 10 GB memberi peringatan; di bawah 5 GB prompt, tugas dan subagent baru ditolak.

Perlu Anda sadari:
- **Token GitHub/Vercel/Cloudflare dapat dibaca agent** di dalam box. Itu disengaja (agent perlu `git push` dan deploy).
  Pakai token dengan cakupan sekecil mungkin.
- Box berbagi jaringan server (lihat atas). Server dev sebaiknya mendengarkan `127.0.0.1`, bukan `0.0.0.0`
  (catatan agent sudah menyebutkannya).
- Kunci privat app disimpan di penyimpanan privat app **tanpa passphrase**. HP yang dibobol berarti akses ke server.
- Topik ntfy adalah rahasia: siapa pun yang tahu topiknya bisa membaca dan mengirim ke topik itu. Pesannya hanya judul
  generik ("Agent finished"), tanpa nama proyek atau isi. Notifikasi mati sampai Anda menyalakannya.
- Dengan `--no-box`, atau bila box dimatikan di app, perintah agent berjalan **langsung** sebagai `griphub`.

## Sehari-hari

- **Memperbarui agent:** pasang APK baru, lalu **Install / update agent**. Daemon dijalankan ulang setelah semua
  subagent dan tugas selesai; server tidak perlu disentuh.
- **Log:** sebagai root,
  ```
  journalctl _SYSTEMD_USER_UNIT=griphub-hostd.service -n 100 --no-pager
  ```
- **Memulai ulang / melihat status** sebagai `griphub`:
  ```
  runuser -u griphub -- env XDG_RUNTIME_DIR=/run/user/$(id -u griphub) systemctl --user restart griphub-hostd
  runuser -u griphub -- env XDG_RUNTIME_DIR=/run/user/$(id -u griphub) systemctl --user status griphub-hostd
  ```
- **Pengaturan lanjutan** (tambahkan baris `NAMA=nilai` ke `~/.griphub/env`, lalu restart layanan):

  | Variabel | Arti | Bawaan |
  | --- | --- | --- |
  | `GRIPHUB_DISK_WARN_BYTES`, `GRIPHUB_DISK_MIN_BYTES` | ambang disk | 10 GB, 5 GB |
  | `GRIPHUB_MEMORY_WARN_BYTES` | ambang peringatan memori host | 1,6 GB |

  Batas memori/CPU box ada di `~/.griphub/box.conf` (`BOX_MEMORY=2g`, `BOX_SWAP=3g`, `BOX_CPUS=1.5`) dan berlaku saat
  container dibuat lagi (**Reset the box** di app).

## Backup otomatis

Dinyalakan dari app (Pengaturan → Backup & pulihkan → **Backup otomatis server**). App membuat kunci acak 32 byte,
menyimpannya di HP bersama profil server, dan memberikannya ke server. Setiap jam, bila ada perubahan, daemon menulis
`~/.griphub/backups/auto-<waktu>.ghb`, dan tiga yang terbaru disimpan.

- **Isi:** data agent (chat, skill, prompt, jadwal), rahasia yang tersimpan (API key, token, server MCP) dalam bentuk
  terdekripsi *di dalam* arsip terenkripsi, seluruh workspace beserta `.git` dan dotfile, serta kunci deploy
  `~/.ssh/id_ed25519`. Yang tidak ikut: dependensi dan cache (`node_modules`, `.venv`, `__pycache__`, `.gradle`, …),
  riwayat undo (`checkpoints`), `authorized_keys`, dan file di atas 512 MB (dicatat di `manifest.json`).
- **Format:** `GHB1` | iv 12 byte | zip terenkripsi AES-256-GCM | tag 16 byte. Arsip ditulis langsung dalam keadaan
  terenkripsi; tidak ada salinan plaintext di disk.
- **Kunci:** server butuh kunci itu untuk menulis backup, dan server memang memegang semua datanya. Kunci melindungi
  salinan yang keluar dari server atau HP. Mematikan backup otomatis menghapus salinan di server; salinan di HP tetap ada.
- **Memulihkan:** saat kembali ke agent di HP, app menawarkan backup terbaru. Path workspace server dipetakan ke
  workspace HP, rahasia dienkripsi ulang dengan kunci HP, dan pengaturan milik mesin (DNS, Linux, zona waktu, ntfy)
  tetap milik HP. Kunci SSH HP tidak ditimpa bila sudah ada.

## Server yang lebih besar

Contoh untuk server 4 core / 8 GB (mis. `agentai`): host 3 GB, box 4 GB.

```
# sebagai root
runuser -u griphub -- env XDG_RUNTIME_DIR=/run/user/$(id -u griphub) systemctl --user edit griphub-hostd
```
isi:
```
[Service]
Environment=NODE_OPTIONS=--max-old-space-size=2560
Environment=GRIPHUB_MEMORY_WARN_BYTES=2684354560
MemoryMax=3G
```
lalu `~/.griphub/box.conf` milik `griphub`:
```
BOX_MEMORY=4g
BOX_SWAP=5g
BOX_CPUS=3
```
Restart layanan, dan **Reset the box** di app supaya batas box yang baru berlaku.

## Bila ada masalah

| Gejala | Kemungkinan penyebab | Coba |
| --- | --- | --- |
| "tidak terjangkau" | alamat/port salah, firewall, HP offline | `ssh -i kunci griphub@alamat` dari mesin lain; buka port SSH |
| "kunci ditolak" | skrip belum dijalankan dengan kunci app ini | jalankan ulang `bootstrap.sh` dengan perintah yang ditampilkan app |
| "host key tidak cocok" | server dipasang ulang, atau ada yang menyamar | **jangan lanjut** kecuali Anda memang memasang ulang; tempel setup code baru |
| "agent belum ada" / "tidak berjalan" | host belum disalin, atau layanan mati | **Install / update agent**; periksa log |
| `rootless podman does not work` saat bootstrap | Ubuntu 24.04+ membatasi user namespace lewat AppArmor | pastikan paket `apparmor` terpasang dan `/etc/apparmor.d/podman` ada dan dimuat (`aa-status`); jalankan ulang skrip |
| box: image belum dibangun | build gagal | **Rebuild the image** di app; lihat pesannya |
| layanan tidak jalan setelah reboot | lingering mati | `loginctl enable-linger griphub` |
| disk penuh | chat, backup, image | hapus backup lama di `~/workspace/backups`, `podman system prune` sebagai `griphub` |

## HP hilang

Kunci app ada di HP; siapa pun yang memegang HP itu (tanpa kunci layar) bisa menyambung ke agent. Di server, sebagai
root:

```
sed -i '/ griphub-app$/d' /home/griphub/.ssh/authorized_keys
```

Itu menghapus kunci app (baris yang berakhiran `griphub-app`). Lalu siapkan HP baru: di app, **Pengaturan > Agent di
VPS / server**, salin perintah setup, tempel di server, tempel kode setup-nya di app. Chat dan proyek tetap di server.

## Menghapus

Ini menghapus semua milik agent (chat, proyek di `~/workspace`, box). Ambil backup dulu.

```
runuser -u griphub -- env XDG_RUNTIME_DIR=/run/user/$(id -u griphub) systemctl --user disable --now griphub-hostd
loginctl disable-linger griphub
userdel -r griphub
rm -rf /opt/node-v* /opt/node /usr/local/bin/{node,npm,npx}   # hanya bila Node ini dipasang oleh skrip dan tidak dipakai CoderRa
```

## Yang sudah dan belum diuji

- `bootstrap.sh` dijalankan sungguhan di container Ubuntu 24.04 dan Debian 13 (paket, akun, Node, kunci, setup code, aman
  diulang, akun kedua). systemd dan Podman diganti tiruan di sana.
- Rantai `ssh → sshd → griphub-attach → daemon`, batasan kunci app, dan host key yang dipin diuji dengan sshd asli.
- Layanan systemd user diuji dengan systemd asli (start, batas memori, `host_restart`, mati lalu dihidupkan lagi, stop
  bersih, diam sebelum host dipasang).
- **Belum:** box dengan Podman sungguhan, `--harden-ssh`, AppArmor, dan server sungguhan. Itu diuji di fase 7.
