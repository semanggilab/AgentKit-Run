# WebCore2 AgentKit Runner

Peluncur untuk memasang dan memelihara berkas konteks agen pada banyak kelompok
proyek. Skrip ini tidak melakukan commit, push, fetch, ataupun mencampur isi proyek.

```
WebCore2/
├── AgentKit-Run/  ← repo ini: run.sh, run.ps1, config/<GROUP>.txt
└── <repo data dan checkout proyek masing-masing grup>
```

Setiap grup didefinisikan dalam `config/<GROUP>.txt`:

- `BASE` — URL repo Git data agentkit untuk grup tersebut, tanpa branch
- `BRANCH` — branch data opsional; bila kosong, branch default remote dideteksi
- `PROJECT` — daftar proyek yang diizinkan, dipisahkan koma

Contoh yang tersedia: `kaderkita` dan `webcore2`. Setiap proyek tetap mempunyai
konfigurasi dan riwayat patch sendiri dalam repo data kelompoknya.

## Menjalankan

Di macOS, Linux, WSL2, atau Git Bash:

```bash
bash AgentKit-Run/run.sh webcore2 mpdn status --local
bash AgentKit-Run/run.sh webcore2 pwskia apply --local
bash AgentKit-Run/run.sh kaderkita CMS build --local --note "tambah skill X"
```

Skrip menerima nama proyek dalam huruf besar atau kecil. Jalankan dari folder induk,
dari folder proyek, atau berikan `--root`, `--target`, dan `--agentkit`.

PowerShell (memerlukan Git Bash atau WSL2):

```powershell
& .\AgentKit-Run\run.ps1 webcore2 mpdn status --local
```

Pemakaian jarak jauh memuat konfigurasi grup dari repositori GitHub ini:

```bash
curl -fsSL https://raw.githubusercontent.com/semanggilab/AgentKit-Run/refs/heads/main/run.sh \
  | bash -s -- <GROUP> <PROJECT> <COMMAND> [opsi]
```

## Perintah

| Perintah | Kegunaan |
|---|---|
| `init` | Menyiapkan checkout baru: membuat folder tiap proyek grup di folder induk, `git clone` sesuai bagian `[repo]` di `agentkit/projects/<PROJECT>.conf`, lalu `apply` di tiap folder. Tanpa PROJECT = seluruh grup (`run.sh webcore2 init`); `run.sh webcore2 init mpdn` = satu proyek. |
| `build` | Membuat patch versi berikutnya dari satu checkout proyek ke `agentkit`. Hanya pemelihara, selalu lokal. |
| `apply` | Memasang patch proyek yang dipilih sampai versi terbaru. |
| `verify` | Memeriksa isi terhadap manifest, hook, exclusion lokal, dan skill. |
| `status` | Menampilkan versi terpasang dan versi sumber. |
| `help` | Menampilkan bantuan. |

Opsi penting: `--local`, `--dry-run`, `--overwrite`, `--note`, `--root`,
`--target`, `--agentkit`, `--base-url`, dan `--branch`.

## Perintah `init`

```bash
bash AgentKit-Run/run.sh webcore2 init            # semua proyek grup
bash AgentKit-Run/run.sh webcore2 init mpdn       # satu proyek
bash AgentKit-Run/run.sh webcore2 init --dry-run  # simulasi
```

Dari folder induk kosong, online: `curl -fsSL .../run.sh | bash -s -- webcore2 init`.
Urutannya per proyek: ambil `projects/<PROJECT>.conf` dari repo data, buat `<root>/<PROJECT>`,
`git clone` repo root (key `root`), `git clone` setiap repo anak (key lain), lalu `apply`. Folder yang sudah berisi repo Git tidak di-clone ulang (apply tetap
dijalankan, jadi `init` aman diulang); folder yang ada, tidak kosong, dan bukan repo Git dilewati.
Kegagalan satu proyek tidak menghentikan proyek lain; kode keluar 1 bila ada yang gagal.

Daftar repo ada di bagian `[repo]` pada `agentkit/projects/<PROJECT>.conf`. Key `root` = repo root checkout;
key lain = path relatif terhadap root checkout (boleh diberi tanda kutip), nilainya URL repo anak. Baris `#` dan kosong diabaikan:

```ini
[repo]
root = https://gitlab.com/webcore2/main-prod.git
"modules/mpdn" = https://gitlab.com/webcore2/app-mpdn.git
"resources" = https://gitlab.com/webcore/res-clipone.git
"resources/dore" = https://gitlab.com/webcore/res-dore.git
```

Induk di-clone lebih dulu dari anak (`resources` sebelum `resources/dore`, apa pun urutan barisnya). PATH yang
absolut, memuat `..`, atau berkarakter aneh ditolak. Folder yang sudah repo Git dilewati; folder tidak kosong
yang bukan repo Git dilaporkan gagal tanpa menghentikan repo lain. Tanpa key `root`, proyek dilaporkan gagal; tanpa repo anak, hanya
repo root yang di-clone.

URL tidak boleh memuat token/kredensial (ditolak). Clone memakai kredensial git yang ada
(`glab auth login`, `gh auth login`, credential helper) tanpa prompt. Repo yang tidak tercantum di `[repo]`
(mis. domain server) di-clone terpisah, mis. dengan `webcorecli`; setelah itu jalankan `verify`.

## Data privat dan token

Skrip membentuk URL unduhan dari `BASE` dan `BRANCH`: GitLab memakai
`<BASE>/-/raw/<BRANCH>`, sedangkan GitHub memakai URL raw yang setara. `BASE` boleh
berupa URL repo GitLab/GitHub atau `raw.githubusercontent.com`; jangan sertakan branch.
Jika `BRANCH` tidak diisi, runner memakai symbolic `HEAD` remote untuk mendeteksi branch
default. Gunakan `--branch` atau `AGENTKIT_BRANCH` untuk menggantikannya.

Untuk GitLab, token
dicari sebagai `AGENTKIT_TOKEN`, `GITLAB_TOKEN`, `CI_JOB_TOKEN`, `glab auth token`,
lalu kredensial Git. Untuk GitHub, fallback `GITHUB_TOKEN`, `GH_TOKEN`, `gh auth token`,
dan kredensial Git tersedia.

Untuk pemeliharaan lokal, gunakan `--local`; tidak ada token maupun unduhan yang
diperlukan. Jika struktur folder berbeda, gunakan `--agentkit /path/ke/agentkit`.

## Menambah kelompok proyek

Tambahkan `config/<GROUP>.txt` ke AgentKit-Run:

```text
BASE=https://gitlab.com/organisasi/agentkit
BRANCH=main
PROJECT=aplikasi-a,aplikasi-b
```

Setelah konfigurasi dipublikasikan, grup langsung tersedia untuk `run.sh` dan `run.ps1`.

