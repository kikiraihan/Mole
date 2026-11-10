# GitHub Actions di fork ini

Dicatat 2026-11-10.

## Latar

Repo ini fork dari [tw93/Mole](https://github.com/tw93/Mole). GitHub pernah mematikan **semua** workflow di fork ini ("Workflows on this fork have been disabled"), sehingga build MoleApp untuk PR #9 dan merge-nya ke `main` (1.6.0) tidak pernah jalan. Workflow lalu diaktifkan ulang, dan yang hanya relevan untuk upstream dimatikan manual lewat UI.

Mematikan lewat UI (bukan menghapus file `.yml`) dipilih supaya sinkronisasi dengan upstream tidak konflik, dan workflow bisa dinyalakan lagi kapan saja.

## Status workflow

| Workflow | File | Status | Alasan |
|---|---|---|---|
| Build MoleApp (macOS Indicator & App) | `macos-app.yml` | **Aktif** | Build dan rilis MoleApp (`app-v*`) |
| Check | `check.yml` | Aktif | Lint dan audit kode CLI |
| Validation | `test.yml` | Aktif | Tes Bats Mole CLI (runner macOS) |
| Secrets | `secrets.yml` | Aktif | Scan gitleaks, murah (Linux) |
| Bundle Drift Audit | `bundle_audit.yml` | Dimatikan | Audit bulanan aplikasi bawaan macOS untuk upstream; membuat issue otomatis |
| CodeQL | `codeql.yml` | Dimatikan | Analisis keamanan kode CLI, mingguan + tiap push |
| Nix | `nix.yml` | Dimatikan | Paket Nix milik upstream |
| Release | `release.yml` | Dimatikan | Rilis Mole CLI upstream (tag `V*`) + PR ke Homebrew dengan token yang tidak ada di fork. Bisa terpicu tak sengaja kalau tag upstream ikut di-push |
| Update Contributors | `update-contributors.yml` | Dimatikan | Job-nya hanya jalan di `tw93/Mole`; di fork selalu *skipped* |

### Catatan Check & Validation

- Filter `paths` keduanya diawali `'**'`, jadi perubahan di `macos-app/**` (Swift) pun ikut memicunya.
- Validation memakai runner macOS. Kalau repo menjadi **private**, menit macOS dihitung 10× menit Linux. Matikan keduanya bila kode CLI (`lib/`, `bin/`, `cmd/`) tidak diubah dan menit Actions mulai terbatas.

## Cara menyalakan / mematikan

**Lewat web:** Actions → pilih workflow di sidebar kiri → tombol **⋯** di kanan atas → **Disable workflow**. Untuk menyalakan lagi: buka workflow yang berlabel *Disabled* → **Enable workflow**.

**Lewat Terminal** (perlu `gh` yang sudah login):

```bash
gh workflow list --all -R kikiraihan/Mole
gh workflow disable <file>.yml -R kikiraihan/Mole
gh workflow enable <file>.yml -R kikiraihan/Mole
```

Kalau GitHub kembali menampilkan layar "Workflows on this fork have been disabled", klik **I understand my workflows, go ahead and re-enable them**, lalu cek ulang status di atas: tombol itu bisa menyalakan lagi semua workflow.

## Build dan rilis MoleApp

Aturan di `macos-app.yml`:

| Pemicu | Build | Rilis |
|---|---|---|
| Push ke `main` yang menyentuh `macos-app/**` | Ya | Ya, otomatis `app-v<versi>` bila tag versi di `Info.plist` belum ada |
| Push tag `app-v*` | Ya | Ya, untuk tag itu |
| Push ke `claude/**`, pull request | Ya | Tidak |
| **Run workflow** manual (`workflow_dispatch`) di `main` | Ya | Ya, bila tag versi di `Info.plist` belum ada (sejak 2026-11-10) |
| **Run workflow** manual di branch lain | Ya | Tidak |

Push yang terjadi saat workflow mati **tidak** dijalankan ulang oleh GitHub (contoh: merge 1.6.0 pada 2026-11-10). Untuk menyusul, cukup Actions → Build MoleApp → **Run workflow** di `main`:

```bash
gh workflow run macos-app.yml --ref main -R kikiraihan/Mole
```

Build jalan, lalu rilis `app-v<versi>` dibuat bila tag itu belum ada. Kalau versinya sudah dirilis, run ini hanya build (aman untuk sekadar mengecek kompilasi).

Cara lain, push tag secara manual:

```bash
git fetch origin main && git tag app-v1.6.0 origin/main && git push origin app-v1.6.0
```

Catatan: langkah smoke test (membuka app) memakai `continue-on-error`, jadi rilis tetap terbit walau app gagal berjalan di CI. Coba artefak build di Mac bila perubahannya besar.

## Sinkronisasi dengan upstream

- Jangan push tag `V*` dari upstream ke fork ini (`git push --tags` setelah fetch upstream). Release sudah dimatikan, tapi tag itu tidak berguna di sini dan akan memicu Release lagi kalau suatu saat dinyalakan.
- Workflow upstream yang baru akan ikut masuk saat sinkronisasi dan langsung aktif. Setelah sinkronisasi, cek daftar workflow dan matikan yang tidak perlu, lalu perbarui tabel di atas.
