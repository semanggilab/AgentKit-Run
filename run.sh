#!/usr/bin/env bash
# =============================================================================
# AgentKit Runner — distribusi berkas agent lokal (CLAUDE.md, AGENTS.md,
# kilo.jsonc, .agents/, .claude/, .codex/, .kilo/, docs/, .docker/) tanpa
# melewati Git repo proyek.
#
# Skrip ini ada di repo publik AgentKit-Run. Konfigurasi grup ada di config/<GROUP>.txt;
# BASE pada konfigurasi menentukan repo data patch untuk grup tersebut.
#
# Pemakaian online (macOS, Linux, WSL2, Git Bash):
#   curl -fsSL https://raw.githubusercontent.com/semanggilab/AgentKit-Run/refs/heads/main/run.sh \
#     | bash -s -- <GROUP> <PROJECT> <COMMAND> [opsi]
#
#   GROUP   : nama berkas config/<GROUP>.txt di repo agentkit-run
#   PROJECT : salah satu nilai PROJECT pada konfigurasi grup
#   COMMAND : build | apply | verify | status | help
#
# Opsi:
#   --root DIR       folder induk proyek dan repo data (default: dideteksi dari folder kerja)
#   --target DIR     folder repo proyek tujuan (default: <root>/<PROJECT>)
#   --agentkit DIR   folder data agentkit lokal (default: <root>/agentkit)
#   --local          apply/verify/status membaca data dari agentkit lokal, bukan unduhan
#   --base-url URL   URL repo data (menggantikan BASE pada konfigurasi grup)
#   --branch NAME    branch data (menggantikan BRANCH pada konfigurasi grup)
#   --dry-run        apply: simulasi tanpa mengubah berkas
#   --overwrite      apply: samakan berkas dengan versi terbaru (berkas lokal dicadangkan)
#   --note TEKS      build: catatan versi untuk CHANGELOG
#   --force          build: izinkan build dari Windows (bit eksekusi tidak andal)
#
# Variabel lingkungan: AGENTKIT_TOKEN, GITLAB_TOKEN, CI_JOB_TOKEN, GITHUB_TOKEN, GH_TOKEN,
# AGENTKIT_BASE_URL, AGENTKIT_RUN_URL, AGENTKIT_ROOT, AGENTKIT_SOURCE=local.
#
# Script ini tidak pernah menjalankan commit, push, atau fetch pada repo proyek.
# Perubahan di .git/ proyek hanya: hooks/ (lewat .agents/install-git-hooks.sh),
# blok "# BEGIN agent-kit" di info/exclude, dan status/cadangan di <git-dir>/agent-kit/.
# =============================================================================

AK_VERSION="3.1.0"
# Konfigurasi grup diambil dari repo agentkit-run; BASE untuk data ditentukan oleh tiap grup.
AK_DEFAULT_RUN_BASE="https://raw.githubusercontent.com/semanggilab/AgentKit-Run/refs/heads/main"
AK_BLOCK_BEGIN="# BEGIN agent-kit"
AK_BLOCK_END="# END agent-kit"
AK_HARD='BEGIN [A-Z ]*PRIVATE KEY|glpat-[A-Za-z0-9_-]{16,}|AKIA[0-9A-Z]{16}|AES_(SECRET_KEY|INITIALIZATION_VECTOR)=[A-Za-z0-9+/]{16,}|[ps]k\.eyJ[A-Za-z0-9_-]{20,}|storePassword *= *[^ ]{4,}'
AK_SOFT='(PASSWORD|PASSWD|SECRET|TOKEN|API_KEY)[A-Za-z_]*[[:space:]]*[:=][[:space:]]*[^[:space:]]+|\$2[aby]\$[0-9]{2}\$'

# ----------------------------------------------------------------- utilitas
ak_say()  { printf '%s\n' "$*"; }
ak_warn() { printf 'PERINGATAN: %s\n' "$*" >&2; }
ak_die()  { printf 'GAGAL: %s\n' "$*" >&2; exit 1; }

ak_is_windows() {
  case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

ak_sha() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

ak_vname() { printf 'v%04d' "$1"; }

ak_git() {   # git sebagai mesin diff/patch murni, kebal konfigurasi pengguna
  git -c core.autocrlf=false -c core.safecrlf=false -c core.quotepath=false \
      -c color.ui=false -c diff.external= -c core.pager=cat "$@"
}

ak_mktemp() {
  AK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/agentkit.XXXXXX")" || ak_die "tidak bisa membuat folder sementara"
  AK_TMP="$(cd "$AK_TMP" && pwd -P)"
  trap 'rm -rf "$AK_TMP"' EXIT
  # Jangan biarkan git menemukan repo di atas folder sementara.
  GIT_CEILING_DIRECTORIES="$(dirname "$AK_TMP")"; export GIT_CEILING_DIRECTORIES
}

ak_match() {   # $1=path, $2=daftar pola (baris); '*' juga melewati '/'
  _p="$1"
  while IFS= read -r _pat; do
    [ -z "$_pat" ] && continue
    # shellcheck disable=SC2254
    case "$_p" in $_pat) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

# ----------------------------------------------------------------- konfigurasi & sumber
ak_conf_section() {   # $1=berkas, $2=nama bagian
  awk -v s="[$2]" '
    /^\[/ { on = ($0 == s); next }
    on && NF && $0 !~ /^[[:space:]]*#/ { sub(/[[:space:]]+$/, ""); print }' "$1"
}

ak_group_value() {   # $1=KEY, $2=file KEY=VALUE
  awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); sub(/[[:space:]]+$/, ""); print; exit }' "$2"
}

ak_load_group() {
  case "$AK_GROUP" in ''|*[!A-Za-z0-9_-]*) ak_die "GROUP tidak valid: $AK_GROUP" ;; esac
  AK_GROUP_CONF="$AK_TMP/group.txt"
  _script_dir=""
  if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    _script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
  fi
  if [ -n "$_script_dir" ] && [ -f "$_script_dir/config/$AK_GROUP.txt" ]; then
    cp "$_script_dir/config/$AK_GROUP.txt" "$AK_GROUP_CONF"
  else
    command -v curl >/dev/null 2>&1 || ak_die "curl tidak ditemukan; dibutuhkan untuk memuat config/$AK_GROUP.txt"
    curl -fsSL "$AK_RUN_BASE/config/$AK_GROUP.txt" -o "$AK_GROUP_CONF" 2>/dev/null \
      || ak_die "konfigurasi grup tidak ditemukan: $AK_RUN_BASE/config/$AK_GROUP.txt"
  fi
  AK_GROUP_BASE="$(ak_group_value BASE "$AK_GROUP_CONF")"
  AK_GROUP_BRANCH="$(ak_group_value BRANCH "$AK_GROUP_CONF")"
  AK_GROUP_PROJECTS="$(ak_group_value PROJECT "$AK_GROUP_CONF")"
  [ -n "$AK_GROUP_BASE" ] || ak_die "BASE tidak ada dalam config/$AK_GROUP.txt"
  [ -n "$AK_GROUP_PROJECTS" ] || ak_die "PROJECT tidak ada dalam config/$AK_GROUP.txt"
}

ak_remote_url() {   # URL repo untuk git ls-remote dari BASE
  _repo="${AK_DATA_REPO%/}"
  case "$_repo" in
    https://raw.githubusercontent.com/*)
      _path="${_repo#https://raw.githubusercontent.com/}"
      printf 'https://github.com/%s.git\n' "$_path"
      ;;
    https://github.com/*|https://gitlab.com/*)
      printf '%s.git\n' "${_repo%.git}"
      ;;
    *) printf '%s\n' "$_repo" ;;
  esac
}

ak_default_branch() {
  _remote="$(ak_remote_url)"
  _head="$(env GIT_TERMINAL_PROMPT=0 git ls-remote --symref "$_remote" HEAD 2>/dev/null | awk '/^ref: refs\/heads\// { sub(/^ref: refs\/heads\//, "", $2); print $2; exit }')"
  [ -n "$_head" ] || ak_die "tidak bisa mendeteksi branch default dari $_remote; isi BRANCH pada config/$AK_GROUP.txt atau pakai --branch"
  printf '%s\n' "$_head"
}

ak_resolve_data_source() {
  AK_DATA_REPO="${AK_BASE:-$AK_GROUP_BASE}"
  AK_DATA_REPO="${AK_DATA_REPO%/}"
  [ -n "$AK_DATA_REPO" ] || ak_die "BASE tidak ada dalam config/$AK_GROUP.txt"
  AK_BRANCH="${AK_BRANCH:-$AK_GROUP_BRANCH}"
  if [ -z "$AK_BRANCH" ] && [ "$AK_SOURCE" != local ]; then AK_BRANCH="$(ak_default_branch)"; fi
  [ -n "$AK_BRANCH" ] || AK_BRANCH="local"
  case "$AK_BRANCH" in *[!A-Za-z0-9._/-]*|'') ak_die "BRANCH tidak valid: $AK_BRANCH" ;; esac
  case "$AK_DATA_REPO" in
    https://raw.githubusercontent.com/*) AK_BASE="$AK_DATA_REPO/$AK_BRANCH" ;;
    https://github.com/*)
      AK_BASE="https://raw.githubusercontent.com/${AK_DATA_REPO#https://github.com/}/$AK_BRANCH"
      ;;
    https://gitlab.com/*) AK_BASE="$AK_DATA_REPO/-/raw/$AK_BRANCH" ;;
    *) ak_die "BASE harus URL repo GitHub/GitLab atau raw.githubusercontent.com: $AK_DATA_REPO" ;;
  esac
}

ak_resolve_project() {
  _wanted="$(printf '%s' "$AK_PROJECT" | tr '[:upper:]' '[:lower:]')"
  _found=""
  _oldifs="$IFS"; IFS=,
  for _candidate in $AK_GROUP_PROJECTS; do
    _candidate="$(printf '%s' "$_candidate" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ "$(printf '%s' "$_candidate" | tr '[:upper:]' '[:lower:]')" = "$_wanted" ] && { _found="$_candidate"; break; }
  done
  IFS="$_oldifs"
  [ -n "$_found" ] || ak_die "PROJECT '$AK_PROJECT' tidak terdaftar dalam grup $AK_GROUP (tersedia: $AK_GROUP_PROJECTS)"
  AK_PROJECT="$_found"
}

ak_fetch() {   # $1=path relatif di agentkit, $2=tujuan; kode 1 bila tidak ada
  if [ "$AK_SOURCE" = "local" ]; then
    [ -f "$AK_DIR/$1" ] || return 1
    cp "$AK_DIR/$1" "$2"
  else
    ak_token
    if [ -n "$AK_TOKEN" ]; then
      if ak_is_gitlab_base; then
        if [ "${AK_TOKEN_KIND:-}" = job ]; then
          curl -fsSL -H "JOB-TOKEN: $AK_TOKEN" "$AK_BASE/$1" -o "$2" 2>/dev/null
        else
          curl -fsSL -H "PRIVATE-TOKEN: $AK_TOKEN" "$AK_BASE/$1" -o "$2" 2>/dev/null
        fi
      else
        curl -fsSL -H "Authorization: token $AK_TOKEN" "$AK_BASE/$1" -o "$2" 2>/dev/null
      fi
    else
      curl -fsSL "$AK_BASE/$1" -o "$2" 2>/dev/null
    fi
  fi
}

ak_is_github_base() {
  case "$AK_BASE" in https://raw.githubusercontent.com/*|https://api.github.com/*|https://github.com/*) return 0 ;; esac
  return 1
}

ak_is_gitlab_base() {
  case "$AK_BASE" in https://gitlab.com/*|https://*/api/v4/*) return 0 ;; esac
  return 1
}

# Token untuk repo privat. Urutan: AGENTKIT_TOKEN / GITLAB_TOKEN / CI_JOB_TOKEN, lalu (hanya bila
# sumbernya GitLab) `glab auth token`, lalu kredensial GitLab yang tersimpan di git (Keychain macOS,
# Git Credential Manager, dsb.). Tidak pernah memunculkan prompt dan tidak pernah dicetak.
ak_token() {
  [ -n "${AK_TOKEN_DONE:-}" ] && return 0
  AK_TOKEN_DONE=1
  if ak_is_gitlab_base; then
    if [ -n "${AGENTKIT_TOKEN:-}" ]; then AK_TOKEN="$AGENTKIT_TOKEN"; AK_TOKEN_SRC="AGENTKIT_TOKEN"; AK_TOKEN_KIND=private; return 0; fi
    if [ -n "${GITLAB_TOKEN:-}" ]; then AK_TOKEN="$GITLAB_TOKEN"; AK_TOKEN_SRC="GITLAB_TOKEN"; AK_TOKEN_KIND=private; return 0; fi
    if [ -n "${CI_JOB_TOKEN:-}" ]; then AK_TOKEN="$CI_JOB_TOKEN"; AK_TOKEN_SRC="CI_JOB_TOKEN"; AK_TOKEN_KIND=job; return 0; fi
    if command -v glab >/dev/null 2>&1; then
      AK_TOKEN="$(glab auth token 2>/dev/null </dev/null)"
      [ -n "$AK_TOKEN" ] && { AK_TOKEN_SRC="glab auth token"; AK_TOKEN_KIND=private; return 0; }
    fi
    _host="gitlab.com"
  elif ak_is_github_base; then
    if [ -n "${AGENTKIT_TOKEN:-}" ]; then AK_TOKEN="$AGENTKIT_TOKEN"; AK_TOKEN_SRC="AGENTKIT_TOKEN"; return 0; fi
    if [ -n "${GITHUB_TOKEN:-}" ]; then AK_TOKEN="$GITHUB_TOKEN"; AK_TOKEN_SRC="GITHUB_TOKEN"; return 0; fi
    if [ -n "${GH_TOKEN:-}" ]; then AK_TOKEN="$GH_TOKEN"; AK_TOKEN_SRC="GH_TOKEN"; return 0; fi
    _host="github.com"
  else
    AK_TOKEN_SRC=""; return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    AK_TOKEN="$(gh auth token --hostname "$_host" 2>/dev/null </dev/null)"
    [ -n "$AK_TOKEN" ] && { AK_TOKEN_SRC="gh auth token"; return 0; }
  fi
  AK_TOKEN="$(printf 'protocol=https\nhost=%s\n\n' "$_host" \
    | env -u GIT_ASKPASS -u SSH_ASKPASS GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never \
      git -c credential.interactive=false credential fill 2>/dev/null | sed -n 's/^password=//p')"
  if [ -n "$AK_TOKEN" ]; then AK_TOKEN_SRC="kredensial git $_host"; else AK_TOKEN_SRC=""; fi
  return 0
}

ak_load_conf() {
  AK_CONF="$AK_TMP/project.conf"
  if ! ak_fetch "projects/$AK_PROJECT.conf" "$AK_CONF"; then
    if [ "$AK_SOURCE" = local ]; then
      ak_die "konfigurasi projects/$AK_PROJECT.conf tidak ditemukan di $AK_DIR"
    elif [ -z "$AK_TOKEN" ]; then
      ak_die "tidak bisa mengambil $AK_BASE/projects/$AK_PROJECT.conf. Data agent-kit ada di repo privat GitLab.
  Pilih salah satu: (1) login glab sekali: glab auth login; (2) export AGENTKIT_TOKEN=<PAT GitLab, read_repository untuk repo agentkit>;
  (3) simpan kredensial gitlab.com di git (Keychain/Git Credential Manager), atau (4) pakai --local bila folder agentkit ada di samping proyek."
    else
      ak_die "tidak bisa mengambil $AK_BASE/projects/$AK_PROJECT.conf dengan token dari $AK_TOKEN_SRC (token kedaluwarsa atau tanpa akses ke repo agentkit?)"
    fi
  fi
  C_IDENTIFY="$(ak_conf_section "$AK_CONF" identify)"
  C_INCLUDE="$(ak_conf_section "$AK_CONF" include)"
  C_EXCLUDE="$(ak_conf_section "$AK_CONF" exclude)"
  C_SECRET="$(ak_conf_section "$AK_CONF" secret)"
  C_SEED="$(ak_conf_section "$AK_CONF" seed)"
  C_BLOCK="$(ak_conf_section "$AK_CONF" exclude_block)"
}

ak_latest() {   # mencetak versi terbaru (angka) atau 0
  if ak_fetch ".agent-kit/dist/$AK_PROJECT/LATEST" "$AK_TMP/LATEST"; then
    tr -dc '0-9' < "$AK_TMP/LATEST" | sed 's/^0*//; s/^$/0/'
  else
    echo 0
  fi
}

# ----------------------------------------------------------------- lokasi
ak_resolve_paths() {
  _cwd="$(pwd -P)"
  if [ -z "$AK_ROOT" ]; then
    if [ -n "${AGENTKIT_ROOT:-}" ]; then AK_ROOT="$AGENTKIT_ROOT"
    elif [ -d "$_cwd/$AK_PROJECT" ] || [ -d "$_cwd/agentkit" ] || [ -d "$_cwd/AgentKit" ] || [ -d "$_cwd/agentkit-run" ] || [ -d "$_cwd/AgentKit-Run" ]; then AK_ROOT="$_cwd"
    else
      _base="$(basename "$_cwd")"
      if [ "$_base" = "$AK_PROJECT" ] || [ "$_base" = "agentkit" ] || [ "$_base" = "AgentKit" ] || [ "$_base" = "agentkit-run" ] || [ "$_base" = "AgentKit-Run" ] || [ -d "$_cwd/../$AK_PROJECT" ]; then
        AK_ROOT="$(cd "$_cwd/.." && pwd -P)"
      else
        AK_ROOT="$_cwd"
      fi
    fi
  fi
  AK_ROOT="$(cd "$AK_ROOT" 2>/dev/null && pwd -P)" || ak_die "folder induk tidak ditemukan: $AK_ROOT"
  [ -n "$AK_TARGET" ] || AK_TARGET="$AK_ROOT/$AK_PROJECT"
  if [ -z "$AK_DIR" ]; then
    if [ -d "$AK_ROOT/agentkit" ]; then AK_DIR="$AK_ROOT/agentkit"
    elif [ -d "$AK_ROOT/AgentKit" ]; then AK_DIR="$AK_ROOT/AgentKit"
    else AK_DIR="$AK_ROOT/agentkit"; fi
  fi
  [ -d "$AK_TARGET" ] && AK_TARGET="$(cd "$AK_TARGET" && pwd -P)"
  [ -d "$AK_DIR" ] && AK_DIR="$(cd "$AK_DIR" && pwd -P)"
}

ak_check_target() {
  [ -d "$AK_TARGET" ] || ak_die "folder proyek tidak ditemukan: $AK_TARGET (pakai --target atau --root)"
  _missing=""
  while IFS= read -r _f; do
    [ -z "$_f" ] && continue
    [ -e "$AK_TARGET/$_f" ] || _missing="$_missing $_f"
  done <<EOF
$C_IDENTIFY
EOF
  [ -z "$_missing" ] || ak_die "$AK_TARGET tidak terlihat seperti repo $AK_PROJECT (tidak ada:$_missing)"
  AK_GITDIR="$(git -C "$AK_TARGET" rev-parse --absolute-git-dir 2>/dev/null)" \
    || ak_die "$AK_TARGET bukan repo Git"
  _common="$(cd "$AK_TARGET" && git rev-parse --git-common-dir 2>/dev/null)"
  AK_COMMON="$(cd "$AK_TARGET" && cd "$_common" && pwd -P)"
  AK_STATE="$AK_GITDIR/agent-kit/state"
}

ak_installed_version() {
  if [ -f "$AK_STATE" ]; then
    _p="$(sed -n 's/^project=//p' "$AK_STATE")"
    [ "$_p" = "$AK_PROJECT" ] || ak_die "repo ini tercatat terpasang agent-kit proyek '$_p', bukan $AK_PROJECT"
    sed -n 's/^version=//p' "$AK_STATE"
  else
    echo 0
  fi
}

ak_write_state() {   # $1=versi, $2=sumber
  mkdir -p "$(dirname "$AK_STATE")"
  {
    echo "project=$AK_PROJECT"
    echo "version=$1"
    echo "updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')"
    echo "source=$2"
    echo "tool=$AK_VERSION"
  } > "$AK_STATE"
}

# ----------------------------------------------------------------- koleksi berkas (build)
ak_collect() {   # menulis daftar ke $AK_TMP/{payload,seed,secret,links}.lst
  : > "$AK_TMP/payload.lst"; : > "$AK_TMP/seed.lst"; : > "$AK_TMP/secret.lst"; : > "$AK_TMP/links.lst"
  (
    cd "$AK_TARGET" || exit 1
    # Folder dengan pola "<folder>/*" dipangkas agar find tidak menelusuri worktree/backup besar.
    _fargs=()
    while IFS= read -r _pat; do
      case "$_pat" in
        *'/*')
          _d="${_pat%/\*}"
          case "$_d" in
            *'*'*|*'?'*|*'['*) ;;
            *) if [ ${#_fargs[@]} -gt 0 ]; then _fargs+=(-o); fi
               _fargs+=(-path "$_d") ;;
          esac ;;
      esac
    done <<EOF
$C_EXCLUDE
EOF
    while IFS= read -r _inc; do
      [ -z "$_inc" ] && continue
      if [ -L "$_inc" ]; then echo "L $_inc"
      elif [ -f "$_inc" ]; then echo "F $_inc"
      elif [ -d "$_inc" ]; then
        if [ ${#_fargs[@]} -gt 0 ]; then
          find "$_inc" \( "${_fargs[@]}" \) -prune -o \( -type f -o -type l \) -print
        else
          find "$_inc" \( -type f -o -type l \) -print
        fi | while IFS= read -r _f; do
          if [ -L "$_f" ]; then echo "L $_f"; else echo "F $_f"; fi
        done
      fi
    done <<EOF
$C_INCLUDE
EOF
  ) > "$AK_TMP/raw.lst"
  LC_ALL=C sort -u "$AK_TMP/raw.lst" | while IFS= read -r _line; do
    _kind="${_line%% *}"; _rel="${_line#* }"
    ak_match "$_rel" "$C_EXCLUDE" && continue
    if [ "$_kind" = "L" ]; then echo "$_rel" >> "$AK_TMP/links.lst"; continue; fi
    if ak_match "$_rel" "$C_SECRET"; then echo "$_rel" >> "$AK_TMP/secret.lst"; continue; fi
    if ak_match "$_rel" "$C_SEED"; then echo "$_rel" >> "$AK_TMP/seed.lst"; continue; fi
    echo "$_rel" >> "$AK_TMP/payload.lst"
  done
}

ak_stage() {   # salin payload ke $1 dengan mode 644/755
  mkdir -p "$1"
  while IFS= read -r _rel; do
    mkdir -p "$1/$(dirname "$_rel")"
    cp "$AK_TARGET/$_rel" "$1/$_rel" || ak_die "gagal menyalin $_rel"
    if [ -x "$AK_TARGET/$_rel" ]; then chmod 755 "$1/$_rel"; else chmod 644 "$1/$_rel"; fi
  done < "$AK_TMP/payload.lst"
}

ak_manifest() {   # $1=folder -> manifest di stdout: "<sha256> <x|-> <path>"
  (
    cd "$1" || exit 1
    find . -type f -print | sed 's#^\./##' | LC_ALL=C sort | while IFS= read -r _f; do
      if [ -x "$_f" ]; then _x=x; else _x=-; fi
      printf '%s %s %s\n' "$(ak_sha "$_f")" "$_x" "$_f"
    done
  )
}

ak_reconstruct() {   # $1=folder kosong, $2=versi akhir; menerapkan v0001..$2
  mkdir -p "$1"
  _ri=1
  while [ "$_ri" -le "$2" ]; do
    _rv="$(ak_vname "$_ri")"
    _rpf="$AK_TMP/chain-$_rv.patch"
    [ -f "$_rpf" ] || ak_fetch ".agent-kit/dist/$AK_PROJECT/$_rv.patch" "$_rpf" || ak_die "patch $_rv tidak ditemukan"
    if [ -s "$_rpf" ]; then
      (cd "$1" && ak_git apply -p1 --whitespace=nowarn "$_rpf") || ak_die "rantai patch rusak di $_rv"
    fi
    _ri=$((_ri + 1))
  done
}

# ----------------------------------------------------------------- .git/info/exclude
ak_write_exclude_block() {   # $1=dry-run(0/1)
  _ex="$AK_COMMON/info/exclude"
  mkdir -p "$AK_COMMON/info"
  [ -f "$_ex" ] || : > "$_ex"
  AK_LIST="$C_BLOCK" awk -v b="$AK_BLOCK_BEGIN" -v e="$AK_BLOCK_END" '
    BEGIN { n = split(ENVIRON["AK_LIST"], a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") want[a[i]] = 1 }
    index($0, b) == 1 { skip = 1; next }
    skip && index($0, e) == 1 { skip = 0; next }
    skip { next }
    ($0 in want) { next }
    { lines[++m] = $0 }
    END { while (m > 0 && lines[m] ~ /^[[:space:]]*$/) m--; for (i = 1; i <= m; i++) print lines[i] }' "$_ex" > "$AK_TMP/exclude.new"
  {
    [ -s "$AK_TMP/exclude.new" ] && echo ""
    echo "$AK_BLOCK_BEGIN (lokal, tidak ikut ke origin; dikelola agent-kit)"
    printf '%s\n' "$C_BLOCK"
    echo "$AK_BLOCK_END"
  } >> "$AK_TMP/exclude.new"
  if ! cmp -s "$AK_TMP/exclude.new" "$_ex"; then
    if [ "$1" = 1 ]; then ak_say "  [simulasi] blok exclude akan ditulis: $_ex"
    else cp "$AK_TMP/exclude.new" "$_ex"; ak_say "  blok exclude ditulis: $_ex"; fi
  fi
}

ak_post_install() {
  if [ -f "$AK_TARGET/.agents/link-claude-skills.sh" ]; then
    _out="$(cd "$AK_TARGET" && bash .agents/link-claude-skills.sh 2>&1)"; _rc=$?
    ak_say "  symlink skill: $( [ $_rc = 0 ] && echo OK || echo "kode $_rc")"
    printf '%s\n' "$_out" | sed 's/^/      /'
  fi
  if [ -f "$AK_TARGET/.agents/install-git-hooks.sh" ]; then
    _out="$(cd "$AK_TARGET" && bash .agents/install-git-hooks.sh --force 2>&1)"; _rc=$?
    ak_say "  hook git: $( [ $_rc = 0 ] && echo OK || echo "kode $_rc")"
    printf '%s\n' "$_out" | sed 's/^/      /'
  fi
}

ak_backup() {   # $1=path relatif
  [ -e "$AK_TARGET/$1" ] || return 0
  _b="$AK_GITDIR/agent-kit/backups/$AK_STAMP/$1"
  mkdir -p "$(dirname "$_b")"
  cp -p "$AK_TARGET/$1" "$_b"
}

ak_install_seeds() {   # $1=dry-run
  while IFS= read -r _s; do
    [ -z "$_s" ] && continue
    [ -e "$AK_TARGET/$_s" ] && continue
    if ak_fetch ".agent-kit/dist/$AK_PROJECT/seed/$_s" "$AK_TMP/seed.tmp"; then
      if [ "$1" = 1 ]; then ak_say "  [simulasi] seed akan dibuat: $_s"
      else mkdir -p "$AK_TARGET/$(dirname "$_s")"; cp "$AK_TMP/seed.tmp" "$AK_TARGET/$_s"; ak_say "  seed dibuat: $_s"; fi
    fi
  done <<EOF
$C_SEED
EOF
}

# ----------------------------------------------------------------- build
ak_cmd_build() {
  [ -d "$AK_DIR" ] || ak_die "folder agentkit lokal tidak ditemukan: $AK_DIR (clone repo privat agentkit ke <root>/agentkit, di samping folder proyek)"
  if ak_is_windows && [ "$AK_FORCE" != 1 ]; then
    ak_die "build dari Windows tidak menjaga bit eksekusi skrip; jalankan di macOS/Linux/WSL2 (atau --force)"
  fi
  AK_SOURCE=local
  ak_load_conf
  ak_check_target
  _dist="$AK_DIR/.agent-kit/dist/$AK_PROJECT"
  _prev="$(ak_latest)"
  ak_say "Build $AK_PROJECT dari $AK_TARGET (versi terakhir: $(ak_vname "$_prev"))"

  ak_collect
  [ -s "$AK_TMP/payload.lst" ] || ak_die "tidak ada berkas untuk dipaketkan"
  ak_stage "$AK_TMP/work/b"
  _hard="$(cd "$AK_TMP/work/b" && grep -rnIE "$AK_HARD" . 2>/dev/null | cut -d: -f1,2 | sed 's#^\./##')"
  [ -z "$_hard" ] || ak_die "pola rahasia ditemukan (isi tidak ditampilkan): $(printf '%s ' $_hard)"
  _soft="$(cd "$AK_TMP/work/b" && grep -rniIE "$AK_SOFT" . 2>/dev/null | cut -d: -f1,2 | sed 's#^\./##' | LC_ALL=C sort)"

  # Rekonstruksi versi sebelumnya dari rantai patch dan cocokkan dengan manifest-nya.
  ak_reconstruct "$AK_TMP/work/a" "$_prev"
  if [ "$_prev" -gt 0 ]; then
    ak_manifest "$AK_TMP/work/a" > "$AK_TMP/prev.manifest"
    cmp -s "$AK_TMP/prev.manifest" "$_dist/$(ak_vname "$_prev").manifest" \
      || ak_die "rekonstruksi $(ak_vname "$_prev") tidak sama dengan manifest-nya (dist rusak?)"
  fi

  (cd "$AK_TMP/work" && ak_git diff --no-index --binary --no-renames --no-ext-diff --no-textconv --no-prefix a b) \
    > "$AK_TMP/new.patch"
  _rc=$?
  [ "$_rc" -le 1 ] || ak_die "git diff gagal (kode $_rc)"

  # Seed selalu diperbarui (tidak menaikkan versi).
  while IFS= read -r _s; do
    [ -z "$_s" ] && continue
    mkdir -p "$_dist/seed/$(dirname "$_s")"
    cp "$AK_TARGET/$_s" "$_dist/seed/$_s"
  done < "$AK_TMP/seed.lst"

  if [ ! -s "$AK_TMP/new.patch" ]; then
    ak_say "Tidak ada perubahan sejak $(ak_vname "$_prev"); versi baru tidak dibuat."
    [ "$_prev" -gt 0 ] && ak_write_state "$_prev" "build"
    return 0
  fi

  _new=$((_prev + 1)); _v="$(ak_vname "$_new")"
  ak_manifest "$AK_TMP/work/b" > "$AK_TMP/new.manifest"
  # Uji rantai lengkap dari nol sebelum menulis ke dist.
  cp "$AK_TMP/new.patch" "$AK_TMP/chain-$_v.patch"
  ak_reconstruct "$AK_TMP/work/c" "$_new"
  ak_manifest "$AK_TMP/work/c" > "$AK_TMP/check.manifest"
  cmp -s "$AK_TMP/check.manifest" "$AK_TMP/new.manifest" || ak_die "uji rantai v0001..$_v gagal; dist tidak diubah"

  mkdir -p "$_dist"
  cp "$AK_TMP/new.patch" "$_dist/$_v.patch"
  cp "$AK_TMP/new.manifest" "$_dist/$_v.manifest"
  if [ -n "$_soft" ]; then
    { echo "# Baris berpola kredensial yang ikut terpaket di $_v (nilai tidak ditulis)"; printf '%s\n' "$_soft"; } > "$_dist/$_v.laporan.txt"
  fi
  _stat="$(cd "$AK_TMP" && ak_git apply --stat --summary new.patch 2>/dev/null)"
  _head="$(git -C "$AK_TARGET" rev-parse --abbrev-ref HEAD 2>/dev/null)@$(git -C "$AK_TARGET" rev-parse --short HEAD 2>/dev/null)"
  {
    [ -f "$_dist/CHANGELOG.md" ] || printf '# CHANGELOG agent-kit %s\n\nSetiap versi adalah patch dari versi sebelumnya; `apply` menerapkan v0001 sampai versi terbaru secara berurutan.\n' "$AK_PROJECT"
    echo ""
    echo "## $_v — $(date '+%Y-%m-%d %H:%M %z')"
    echo ""
    echo "- Catatan: ${AK_NOTE:-(tanpa catatan)}"
    echo "- Sumber: $AK_PROJECT branch \`$_head\`, dibangun oleh \`$(id -un 2>/dev/null || echo ?)\` dengan run.sh $AK_VERSION"
    echo "- Berkas: $(wc -l < "$AK_TMP/new.manifest" | tr -d ' ') terpaket"
    if [ -s "$AK_TMP/secret.lst" ]; then echo "- Dikecualikan (rahasia/lokal): $(tr '\n' ' ' < "$AK_TMP/secret.lst")"; fi
    if [ -s "$AK_TMP/seed.lst" ]; then echo "- Seed (dipasang bila belum ada): $(tr '\n' ' ' < "$AK_TMP/seed.lst")"; fi
    if [ -n "$_soft" ]; then echo "- Baris berpola kredensial: $(printf '%s\n' "$_soft" | wc -l | tr -d ' ') (lihat \`$_v.laporan.txt\`)"; fi
    echo ""
    echo '```'
    printf '%s\n' "$_stat"
    echo '```'
  } > "$AK_TMP/changelog.entry"
  if [ -f "$_dist/CHANGELOG.md" ]; then cat "$_dist/CHANGELOG.md" "$AK_TMP/changelog.entry" > "$AK_TMP/changelog.new"
  else cp "$AK_TMP/changelog.entry" "$AK_TMP/changelog.new"; fi
  cp "$AK_TMP/changelog.new" "$_dist/CHANGELOG.md"
  echo "$_new" > "$_dist/LATEST"
  ak_write_state "$_new" "build"

  ak_say "Versi baru: $AK_PROJECT $_v"
  printf '%s\n' "$_stat" | grep -E "changed" | sed 's/^/  /'
  ak_say "  $_dist/$_v.patch ($(wc -c < "$_dist/$_v.patch" | tr -d ' ') byte)"
  [ -s "$AK_TMP/secret.lst" ] && ak_say "  dikecualikan: $(tr '\n' ' ' < "$AK_TMP/secret.lst")"
  [ -s "$AK_TMP/links.lst" ] && ak_say "  symlink tidak dipaketkan (dibuat ulang saat apply): $(wc -l < "$AK_TMP/links.lst" | tr -d ' ')"
  [ -n "$_soft" ] && ak_say "  PERHATIAN: $(printf '%s\n' "$_soft" | wc -l | tr -d ' ') baris berpola kredensial ikut terpaket, lihat $_v.laporan.txt"
  ak_say ""
  ak_say "Langkah berikutnya (tidak dijalankan otomatis):"
  ak_say "  cd \"$AK_DIR\" && git add .agent-kit/dist/$AK_PROJECT && git commit -m \"$AK_PROJECT $_v: ${AK_NOTE:-update}\" && git push"
}

# ----------------------------------------------------------------- apply
ak_patch_files() {   # $1=patch -> daftar path (satu per baris)
  (cd "$AK_TMP" && ak_git apply --numstat -p1 "$1" 2>/dev/null) | cut -f3-
}

ak_cmd_apply() {
  ak_load_conf
  ak_check_target
  _inst="$(ak_installed_version)"
  _latest="$(ak_latest)"
  _dry="$AK_DRY"
  [ "$_latest" -gt 0 ] || ak_die "belum ada versi untuk $AK_PROJECT di sumber ($( [ "$AK_SOURCE" = local ] && echo "$AK_DIR" || echo "$AK_BASE"))"
  ak_say "Apply $AK_PROJECT ke $AK_TARGET: terpasang $(ak_vname "$_inst"), terbaru $(ak_vname "$_latest")$( [ "$_dry" = 1 ] && echo ' [SIMULASI]')"
  [ "$_inst" -le "$_latest" ] || ak_die "versi terpasang lebih baru dari sumber"
  ak_write_exclude_block "$_dry"

  if [ "$AK_OVERWRITE" = 1 ]; then
    ak_apply_overwrite "$_inst" "$_latest" "$_dry" || exit 1
  elif [ "$_inst" -lt "$_latest" ]; then
    ak_apply_chain "$_inst" "$_latest" "$_dry" || exit 1
  else
    ak_say "  sudah versi terbaru."
  fi
  ak_install_seeds "$_dry"
  if [ "$_dry" = 1 ]; then ak_say "Simulasi selesai; tidak ada berkas yang diubah."; return 0; fi
  ak_post_install
  ak_cmd_verify
}

ak_apply_chain() {   # $1=terpasang, $2=terbaru, $3=dry
  _scr="$AK_TMP/scratch"; mkdir -p "$_scr"; : > "$AK_TMP/seen.lst"
  _i=$(($1 + 1))
  while [ "$_i" -le "$2" ]; do
    _v="$(ak_vname "$_i")"
    _pf="$AK_TMP/$_v.patch"
    ak_fetch ".agent-kit/dist/$AK_PROJECT/$_v.patch" "$_pf" || ak_die "patch $_v tidak bisa diambil"
    ak_patch_files "$_v.patch" > "$AK_TMP/$_v.files"
    # Salin keadaan berkas target yang disentuh patch ini ke folder kerja (sekali per berkas).
    while IFS= read -r _f; do
      [ -z "$_f" ] && continue
      grep -Fxq -- "$_f" "$AK_TMP/seen.lst" && continue
      echo "$_f" >> "$AK_TMP/seen.lst"
      if [ -f "$AK_TARGET/$_f" ]; then mkdir -p "$_scr/$(dirname "$_f")"; cp -p "$AK_TARGET/$_f" "$_scr/$_f"; fi
    done < "$AK_TMP/$_v.files"
    if ! _err="$(cd "$_scr" && ak_git apply -p1 --whitespace=nowarn "$_pf" 2>&1)"; then
      ak_say "  $_v TIDAK bisa diterapkan; tidak ada berkas yang diubah untuk versi ini:"
      printf '%s\n' "$_err" | sed 's/^/      /' | head -20
      ak_say "  Penyebab umum: berkas diubah lokal atau sudah ada sebelum pemasangan pertama."
      ak_say "  Tinjau, lalu ulangi dengan --overwrite (berkas lokal dicadangkan di $AK_GITDIR/agent-kit/backups/)."
      [ "$3" = 1 ] || [ "$_i" -eq $(($1 + 1)) ] || ak_say "  Versi terpasang sekarang $(ak_vname $((_i - 1)))."
      return 1
    fi
    _stat="$(cd "$AK_TMP" && ak_git apply --stat "$_v.patch" 2>/dev/null | tail -1)"
    if [ "$3" = 1 ]; then
      ak_say "  [simulasi] $_v:$_stat"
    else
      while IFS= read -r _f; do
        [ -z "$_f" ] && continue
        if [ -f "$_scr/$_f" ]; then
          if [ -f "$AK_TARGET/$_f" ]; then
            cmp -s "$_scr/$_f" "$AK_TARGET/$_f" || ak_backup "$_f"
          fi
          mkdir -p "$AK_TARGET/$(dirname "$_f")"
          cp -p "$_scr/$_f" "$AK_TARGET/$_f"
        elif [ -e "$AK_TARGET/$_f" ]; then
          ak_backup "$_f"; rm -f "$AK_TARGET/$_f"
        fi
      done < "$AK_TMP/$_v.files"
      ak_write_state "$_i" "apply"
      ak_say "  $_v diterapkan:$_stat"
    fi
    _i=$((_i + 1))
  done
  return 0
}

ak_apply_overwrite() {   # $1=terpasang, $2=terbaru, $3=dry
  ak_reconstruct "$AK_TMP/latest" "$2"
  ak_manifest "$AK_TMP/latest" > "$AK_TMP/latest.manifest"
  cut -d' ' -f3- "$AK_TMP/latest.manifest" > "$AK_TMP/latest.paths"
  _c=0; _u=0; _s=0; _d=0
  while read -r _sha _x _f; do
    if [ ! -f "$AK_TARGET/$_f" ]; then _c=$((_c + 1))
    elif cmp -s "$AK_TMP/latest/$_f" "$AK_TARGET/$_f" && { ak_is_windows || [ "$_x" = "$( [ -x "$AK_TARGET/$_f" ] && echo x || echo -)" ]; }; then
      _s=$((_s + 1)); continue
    else _u=$((_u + 1)); [ "$3" = 1 ] || ak_backup "$_f"; fi
    if [ "$3" != 1 ]; then
      mkdir -p "$AK_TARGET/$(dirname "$_f")"
      cp -p "$AK_TMP/latest/$_f" "$AK_TARGET/$_f"
    fi
  done < "$AK_TMP/latest.manifest"
  if [ "$1" -gt 0 ] && ak_fetch ".agent-kit/dist/$AK_PROJECT/$(ak_vname "$1").manifest" "$AK_TMP/inst.manifest"; then
    while read -r _sha _x _f; do
      grep -Fxq -- "$_f" "$AK_TMP/latest.paths" && continue
      if [ -e "$AK_TARGET/$_f" ]; then
        _d=$((_d + 1))
        if [ "$3" != 1 ]; then ak_backup "$_f"; rm -f "$AK_TARGET/$_f"; fi
      fi
    done < "$AK_TMP/inst.manifest"
  fi
  ak_say "  $( [ "$3" = 1 ] && echo '[simulasi] ')disamakan dengan $(ak_vname "$2"): dibuat=$_c, ditimpa=$_u (dicadangkan), sama=$_s, dihapus=$_d"
  [ "$3" = 1 ] || ak_write_state "$2" "apply --overwrite"
  return 0
}

# ----------------------------------------------------------------- verify & status
ak_cmd_verify() {
  [ -n "$AK_CONF" ] || ak_load_conf
  [ -n "$AK_GITDIR" ] || ak_check_target
  _inst="$(ak_installed_version)"
  [ "$_inst" -gt 0 ] || ak_die "belum ada agent-kit terpasang di $AK_TARGET"
  _v="$(ak_vname "$_inst")"
  ak_fetch ".agent-kit/dist/$AK_PROJECT/$_v.manifest" "$AK_TMP/verify.manifest" || ak_die "manifest $_v tidak bisa diambil"
  _ok=1; _bad=""; _n=0
  while read -r _sha _x _f; do
    _n=$((_n + 1))
    if [ ! -f "$AK_TARGET/$_f" ]; then _bad="$_bad
        - $_f hilang"
    elif [ "$(ak_sha "$AK_TARGET/$_f")" != "$_sha" ]; then _bad="$_bad
        - $_f berbeda"
    elif ! ak_is_windows && [ "$_x" = x ] && [ ! -x "$AK_TARGET/$_f" ]; then _bad="$_bad
        - $_f tidak executable"
    fi
  done < "$AK_TMP/verify.manifest"
  if [ -z "$_bad" ]; then ak_say "  [OK] $_n berkas sesuai manifest $_v"; else _ok=0; ak_say "  [GAGAL] berkas tidak sesuai manifest $_v:$_bad"; fi

  _hbad=""
  for _h in "$AK_TARGET"/.agents/git-hooks/*; do
    [ -f "$_h" ] || continue
    _n2="$(basename "$_h")"
    if [ ! -f "$AK_COMMON/hooks/$_n2" ] || ! cmp -s "$_h" "$AK_COMMON/hooks/$_n2"; then _hbad="$_hbad $_n2"; fi
  done
  if [ -z "$_hbad" ]; then ak_say "  [OK] hook git terpasang dan sama dengan .agents/git-hooks"; else _ok=0; ak_say "  [GAGAL] hook belum terpasang/berbeda:$_hbad"; fi

  if grep -q "^$AK_BLOCK_BEGIN" "$AK_COMMON/info/exclude" 2>/dev/null; then ak_say "  [OK] blok exclude agent-kit ada"
  else _ok=0; ak_say "  [GAGAL] blok exclude agent-kit tidak ada"; fi

  _tops="$(cut -d' ' -f3- "$AK_TMP/verify.manifest" | cut -d/ -f1 | LC_ALL=C sort -u)"
  _leak="$(git -C "$AK_TARGET" status --porcelain --untracked-files=all 2>/dev/null | cut -c4- | while IFS= read -r _p; do
      _t="${_p%%/*}"; _t="${_t#\"}"
      printf '%s\n' "$_tops" | grep -Fxq -- "$_t" && echo "$_p"
    done)"
  if [ -z "$_leak" ]; then ak_say "  [OK] berkas agent tidak muncul di git status"
  else _ok=0; ak_say "  [GAGAL] berkas agent terlihat di git status:"; printf '%s\n' "$_leak" | head -10 | sed 's/^/        - /'; fi

  _sbad=""
  for _s in "$AK_TARGET"/.agents/skills/*/SKILL.md; do
    [ -f "$_s" ] || continue
    _sn="$(basename "$(dirname "$_s")")"
    [ -f "$AK_TARGET/.claude/skills/$_sn/SKILL.md" ] || _sbad="$_sbad $_sn"
  done
  if [ -z "$_sbad" ]; then ak_say "  [OK] skill tersedia di .claude/skills"; else _ok=0; ak_say "  [GAGAL] skill belum tertaut:$_sbad"; fi

  if [ "$_ok" = 1 ]; then ak_say "Verifikasi $AK_PROJECT $_v: LULUS"; return 0; fi
  ak_say "Verifikasi $AK_PROJECT $_v: GAGAL"; return 2
}

ak_cmd_status() {
  ak_load_conf
  ak_check_target
  _inst="$(ak_installed_version)"
  _latest="$(ak_latest)"
  ak_say "Proyek  : $AK_PROJECT ($AK_TARGET)"
  ak_say "Terpasang: $(ak_vname "$_inst")$( [ -f "$AK_STATE" ] && echo " — $(sed -n 's/^updated_at=//p' "$AK_STATE") via $(sed -n 's/^source=//p' "$AK_STATE")")"
  ak_say "Terbaru  : $(ak_vname "$_latest") ($( [ "$AK_SOURCE" = local ] && echo "lokal $AK_DIR" || echo "$AK_BASE"))"
  [ "$AK_SOURCE" = local ] || ak_say "Akses    : $( [ -n "$AK_TOKEN" ] && echo "token dari $AK_TOKEN_SRC" || echo "tanpa token")"
  if [ "$_inst" -lt "$_latest" ]; then
    ak_say "Tertunda : $((_latest - _inst)) versi. Jalankan perintah apply untuk memperbarui."
    if ak_fetch ".agent-kit/dist/$AK_PROJECT/CHANGELOG.md" "$AK_TMP/CHANGELOG.md"; then
      awk -v from="$(ak_vname $((_inst + 1)))" '/^## v[0-9]+/ { v = $2; show = (v >= from) } show && /^(## |- Catatan)/' "$AK_TMP/CHANGELOG.md" | sed 's/^/  /'
    fi
  else
    ak_say "Status   : sudah terbaru"
  fi
}

ak_usage() {
  cat <<'EOF'
AgentKit Runner — distribusi berkas agent tanpa Git repo proyek

  curl -fsSL https://raw.githubusercontent.com/semanggilab/AgentKit-Run/refs/heads/main/run.sh \
    | bash -s -- <GROUP> <PROJECT> <COMMAND> [opsi]

  GROUP   : nama konfigurasi config/<GROUP>.txt dari repo AgentKit-Run
  PROJECT : nilai PROJECT yang terdaftar pada grup
  COMMAND :
    build   bangun versi patch baru dari folder proyek ke data agentkit/.agent-kit/dist/<PROJECT>/ (otomatis vNNNN berikutnya)
    apply   terapkan patch dari versi terpasang (atau v0001) sampai versi terbaru
    verify  periksa berkas, hook git, blok exclude, git status, dan skill
    status  tampilkan versi terpasang dan versi terbaru
    help    bantuan ini

  Opsi: --root DIR --target DIR --agentkit DIR --local --base-url URL --branch NAME --dry-run --overwrite --note TEKS --force
  Konfigurasi grup dimuat dari AgentKit-Run/config/<GROUP>.txt. Data patch memakai BASE + BRANCH;
  token dicari otomatis sesuai host sumber. Lokal (pemelihara): bash agentkit-run/run.sh <GROUP> <PROJECT> <COMMAND> --local
EOF
}

# ----------------------------------------------------------------- main
main() {
  AK_GROUP="${1:-}"; AK_PROJECT="${2:-}"; AK_COMMAND="${3:-}"
  case "$AK_GROUP" in ''|help|-h|--help) ak_usage; return 0 ;; esac
  [ $# -ge 3 ] && shift 3 || shift $#
  AK_ROOT=""; AK_TARGET=""; AK_DIR=""; AK_DRY=0; AK_OVERWRITE=0; AK_NOTE=""; AK_FORCE=0
  AK_SOURCE="${AGENTKIT_SOURCE:-remote}"; AK_BASE="${AGENTKIT_BASE_URL:-}"; AK_BRANCH="${AGENTKIT_BRANCH:-}"; AK_RUN_BASE="${AGENTKIT_RUN_URL:-$AK_DEFAULT_RUN_BASE}"
  AK_CONF=""; AK_GITDIR=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) AK_ROOT="$2"; shift 2 ;;
      --target) AK_TARGET="$2"; shift 2 ;;
      --agentkit) AK_DIR="$2"; shift 2 ;;
      --local) AK_SOURCE=local; shift ;;
      --base-url) AK_BASE="$2"; shift 2 ;;
      --branch) AK_BRANCH="$2"; shift 2 ;;
      --dry-run) AK_DRY=1; shift ;;
      --overwrite) AK_OVERWRITE=1; shift ;;
      --note) AK_NOTE="$2"; shift 2 ;;
      --force) AK_FORCE=1; shift ;;
      *) ak_die "opsi tidak dikenal: $1" ;;
    esac
  done
  [ -n "$AK_PROJECT" ] || ak_die "PROJECT wajib diisi setelah GROUP"
  command -v git >/dev/null 2>&1 || ak_die "git tidak ditemukan (dibutuhkan sebagai mesin patch)"
  AK_STAMP="$(date '+%Y%m%d-%H%M%S')"
  ak_mktemp
  AK_RUN_BASE="${AK_RUN_BASE%/}"
  ak_load_group
  ak_resolve_project
  [ "$AK_SOURCE" = local ] || command -v curl >/dev/null 2>&1 || ak_die "curl tidak ditemukan"
  ak_resolve_data_source
  ak_resolve_paths
  case "$AK_COMMAND" in
    build) ak_cmd_build ;;
    apply) ak_cmd_apply ;;
    verify) ak_load_conf; ak_check_target; ak_cmd_verify ;;
    status) ak_cmd_status ;;
    help|'') ak_usage ;;
    *) ak_die "COMMAND tidak dikenal: $AK_COMMAND (build|apply|verify|status|help)" ;;
  esac
}

main "$@"
