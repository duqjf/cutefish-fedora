#!/usr/bin/env bash
set -euo pipefail

# Instala ou atualiza o Obsidian como RPM nativo no Fedora, a partir do tarball
# oficial do GitHub (spec em configs/obsidian/obsidian.spec).
# Uso: bash instalar-obsidian.sh [--forcar] [--instalar-atualizador] [--apenas-rpm DIR]
#   --forcar               reconstroi e reinstala mesmo se a versao ja estiver instalada.
#   --instalar-atualizador instala o timer obsidian-rpm-update (verifica a cada 12 h).
#   --apenas-rpm DIR       so gera o RPM em DIR, sem instalar.
#   --automatico           modo do timer: adia a atualizacao com o Obsidian aberto.
# OBSIDIAN_VERSION=1.15.0 fixa uma release em vez da ultima.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UPDATER_DIR=/usr/local/libexec/obsidian-rpm
REPO=obsidianmd/obsidian-releases

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
as_root() { if [[ "$EUID" -eq 0 ]]; then "$@"; else sudo "$@"; fi; }

force=0 install_updater=0 automatic=0 rpm_only=''
while (( $# )); do
  case "$1" in
    --forcar) force=1 ;;
    --instalar-atualizador) install_updater=1 ;;
    --automatico) automatic=1 ;;
    --apenas-rpm) [[ $# -ge 2 ]] || die '--apenas-rpm precisa de um diretorio.'; rpm_only="$2"; shift ;;
    *) die "Opcao desconhecida: $1" ;;
  esac
  shift
done

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == fedora ]] || die 'Este instalador gera um RPM e foi feito para o Fedora.'
[[ "$(uname -m)" == x86_64 ]] || die 'O spec suporta apenas x86_64.'
# No repositorio o spec fica em configs/; instalado, fica ao lado do script.
spec="$SCRIPT_DIR/obsidian.spec"
[[ -r "$spec" ]] || spec="$SCRIPT_DIR/configs/obsidian/obsidian.spec"
[[ -r "$spec" ]] || die 'obsidian.spec nao encontrado.'

install_updater_files() {
  local unit units="$SCRIPT_DIR/configs/obsidian"
  for unit in obsidian-rpm-update.service obsidian-rpm-update.timer; do
    [[ -r "$units/$unit" ]] || die "Arquivo ausente: configs/obsidian/$unit"
  done
  log "Instalando o atualizador automatico em $UPDATER_DIR"
  # Copias proprias: o timer nao depende desta pasta continuar existindo.
  as_root install -D -m 0755 "$SCRIPT_DIR/instalar-obsidian.sh" "$UPDATER_DIR/instalar-obsidian.sh"
  as_root install -D -m 0644 "$spec" "$UPDATER_DIR/obsidian.spec"
  as_root install -m 0644 "$units/obsidian-rpm-update.service" "$units/obsidian-rpm-update.timer" \
    /etc/systemd/system/
  as_root systemctl daemon-reload
  as_root systemctl enable --now obsidian-rpm-update.timer
}

missing=()
for package in rpm-build curl python3; do
  rpm -q --quiet "$package" || missing+=("$package")
done
if (( ${#missing[@]} )); then
  log "Instalando dependencias: ${missing[*]}"
  as_root dnf install -y "${missing[@]}"
fi

if [[ -n "${OBSIDIAN_VERSION:-}" ]]; then
  api="https://api.github.com/repos/$REPO/releases/tags/v$OBSIDIAN_VERSION"
else
  api="https://api.github.com/repos/$REPO/releases/latest"
fi
# Imprime versao, URL e SHA-256 do tarball x86_64; o digest vem da API do GitHub.
release="$(curl --proto '=https' -fsSL --retry 3 --connect-timeout 20 "$api" | python3 -Ic '
import json, sys
data = json.load(sys.stdin)
version = data["tag_name"].removeprefix("v")
name = f"obsidian-{version}.tar.gz"
for asset in data["assets"]:
    if asset["name"] == name:
        digest = asset.get("digest") or ""
        print(version, asset["browser_download_url"], digest.removeprefix("sha256:"))
        break
')" || die 'Nao foi possivel consultar as releases do Obsidian.'
read -r version url sha256 <<< "$release"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Release do Obsidian nao identificada.'
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || die "A release $version nao publica o SHA-256 do tarball."

installed="$(rpm -q --qf '%{VERSION}' obsidian 2>/dev/null)" || installed=''
if [[ -z "$rpm_only" && "$installed" == "$version" && "$force" -eq 0 ]]; then
  printf 'Obsidian %s ja esta instalado.\n' "$version"
  (( install_updater )) && install_updater_files
  exit 0
fi
if (( automatic )) && pgrep -x obsidian >/dev/null; then
  printf 'Obsidian %s disponivel (instalado: %s); adiado porque o aplicativo esta aberto.\n' \
    "$version" "${installed:-nenhum}"
  exit 0
fi

# O tarball tem ~130 MB e o build dobra isso; /tmp costuma ser tmpfs.
work="$(mktemp -d "${TMPDIR:-/var/tmp}/obsidian-rpm.XXXXXXXX")"
trap 'rm -rf -- "$work"' EXIT
mkdir -p "$work"/{SOURCES,SPECS,BUILD,BUILDROOT,RPMS,SRPMS}
log "Baixando o Obsidian $version (instalado: ${installed:-nenhum})"
curl --proto '=https' --tlsv1.2 -fL --retry 3 --connect-timeout 20 \
  -o "$work/SOURCES/obsidian-$version.tar.gz" "$url"
printf '%s  %s\n' "$sha256" "$work/SOURCES/obsidian-$version.tar.gz" | sha256sum --check --status ||
  die 'SHA-256 do tarball nao confere com a release do GitHub.'

log "Gerando o RPM do Obsidian $version"
cp -- "$spec" "$work/SPECS/obsidian.spec"
rpmbuild --quiet --define "_topdir $work" --define "obsidian_version $version" \
  -bb "$work/SPECS/obsidian.spec"
rpm_file="$(find "$work/RPMS" -type f -name "obsidian-$version-*.rpm" -print -quit)"
[[ -n "$rpm_file" ]] || die 'O rpmbuild nao gerou o RPM.'

if [[ -n "$rpm_only" ]]; then
  install -d "$rpm_only"
  cp -- "$rpm_file" "$rpm_only/"
  printf 'RPM gerado: %s\n' "$rpm_only/${rpm_file##*/}"
  exit 0
fi

log "Instalando ${rpm_file##*/}"
if [[ "$installed" == "$version" ]]; then
  as_root dnf reinstall -y "$rpm_file"
else
  as_root dnf install -y "$rpm_file"
fi
[[ "$(rpm -q --qf '%{VERSION}' obsidian)" == "$version" ]] || die "Obsidian $version nao ficou instalado."
printf 'Obsidian %s instalado.\n' "$version"
(( install_updater )) && install_updater_files
exit 0
