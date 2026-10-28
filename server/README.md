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

1. **Di app:** Settings → Server agent. Isi alamat server. App membuat kunci SSH miliknya dan menampilkan perintah
   siap-salin, kira-kira:
   ```
   sudo ./bootstrap.sh --pubkey 'ssh-ed25519 AAAA… griphub-app' --address 'vps.contoh.com'
   ```
2. **Salin folder `server/` ini ke server** (seluruh folder; skrip memeriksa bahwa semua berkas ada):
   ```
   scp -r server/ root@vps.contoh.com:~/griphub-server
   ```
3. **Di server**, lihat dulu rencananya (tidak mengubah apa pun):
   ```
   cd ~/griphub-server
   bash bootstrap.sh --dry-run --pubkey '…' --address 'vps.contoh.com'
   ```
   Yang harus tampak: **tidak ada** peringatan `this script is written for Ubuntu and Debian`, dan baris `host key:`
   berisi kunci `ssh-ed25519 AAAA…`.
4. **Jalankan sungguhan** (beberapa menit: paket, Node.js, membangun image box):
   ```
   sudo bash bootstrap.sh --pubkey '…' --address 'vps.contoh.com'
   ```
   Aman diulang: akun, kunci dan pengaturan yang ada dipertahankan, sisanya diperbarui.
5. Skrip mencetak **setup code** (`griphub1:…`). Tempel di app, lalu **Install / update agent**: app menyalin host ke
   server dan menjalankannya.

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
| "tidak terjangkau" | alamat/port salah, firewall | `ssh -i kunci griphub@alamat` dari mesin lain; buka port SSH |
| "kunci ditolak" | skrip belum dijalankan dengan kunci app ini | jalankan ulang `bootstrap.sh` dengan perintah yang ditampilkan app |
| "host key tidak cocok" | server dipasang ulang, atau ada yang menyamar | **jangan lanjut** kecuali Anda memang memasang ulang; tempel setup code baru |
| "agent belum ada" / "tidak berjalan" | host belum disalin, atau layanan mati | **Install / update agent**; periksa log |
| `rootless podman does not work` saat bootstrap | Ubuntu 24.04+ membatasi user namespace lewat AppArmor | pastikan paket `apparmor` terpasang dan `/etc/apparmor.d/podman` ada dan dimuat (`aa-status`); jalankan ulang skrip |
| box: image belum dibangun | build gagal | **Rebuild the image** di app; lihat pesannya |
| layanan tidak jalan setelah reboot | lingering mati | `loginctl enable-linger griphub` |
| disk penuh | chat, backup, image | hapus backup lama di `~/workspace/backups`, `podman system prune` sebagai `griphub` |

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
