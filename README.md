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
| `build` | Membuat patch versi berikutnya dari satu checkout proyek ke `agentkit`. Hanya pemelihara, selalu lokal. |
| `apply` | Memasang patch proyek yang dipilih sampai versi terbaru. |
| `verify` | Memeriksa isi terhadap manifest, hook, exclusion lokal, dan skill. |
| `status` | Menampilkan versi terpasang dan versi sumber. |
| `help` | Menampilkan bantuan. |

Opsi penting: `--local`, `--dry-run`, `--overwrite`, `--note`, `--root`,
`--target`, `--agentkit`, `--base-url`, dan `--branch`.

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

