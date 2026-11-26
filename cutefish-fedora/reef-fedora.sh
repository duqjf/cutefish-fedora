#!/usr/bin/env bash
# Leva o Reef (camada de apps do Mac do Cutefish) para o Fedora reempacotando
# os .deb oficiais como RPM. O Reef não tem código-fonte publicado; a licença
# do binário (BSD-3-Clause) permite redistribuí-lo.
#
# Uso (como usuário normal; chama o sudo quando precisa):
#   ./reef-fedora.sh pin       # fixa o cutefish-toolkit no commit do nightly do Debian
#                              (PIN_REPOS="a b" ou PIN_REPOS=all para fixar outros)
#   ./reef-fedora.sh package   # baixa, verifica, compila ICU 76 e gera os RPMs
#   ./reef-fedora.sh install   # repositório local + dnf install cutefish-reef
#   ./reef-fedora.sh check     # lista bibliotecas que o Reef pede e o Fedora não tem
#   ./reef-fedora.sh ghostty-vt  # libghostty-vt do nightly como RPM (para o terminal)
#
# O que a engenharia reversa mostrou (reef-fedora-porte.md, seção 7):
# - a raiz é dirname(/proc/self/exe)/../lib/cutefish-reef: basta /usr/bin + /usr/lib
# - libicucore liga ~1000 símbolos *_76: precisa de um ICU 76 privado
# - LLVM/Clang 19 para os shaders Metal: llvm19-libs/clang19-libs do Fedora
# - o Files instala o Reef via PackageKit pelo nome "cutefish-reef": um repositório
#   local com esse nome faz o fluxo "abrir app do Mac" funcionar sem mudar código
set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SRC=${SRC:-$HOME/cutefish}
WORK=${WORK:-$SRC/reef-rpm}
REPO_DIR=/var/lib/cutefish-local-repo
ICU_VER=76.1
ICU_TGZ=icu4c-76_1-src.tgz
ICU_URL=https://github.com/unicode-org/icu/releases/download/release-76-1/$ICU_TGZ
# SHASUM512.txt oficial da release 76-1 (conferido em 2026-11-24)
ICU_SHA512=b702ab62fb37a1574d5f4a768326d0f8fa30d9db5b015605b5f8215b5d8547f83d84880c586d3dcc7b6c76f8d47ef34e04b0f51baa55908f737024dd79a42a6c
ICU_PREFIX=/usr/lib64/cutefish-reef-icu76
DEBIAN_REPO=https://download.cutefish.org/debian
REEF_REPO=https://download.cutefish.org/reef
SUITE=trixie-nightly
# Chaves copiadas do Cutefish instalado em Debian: Cutefish Archive (5F527F0C…9E1091A7)
# e Cutefish Reef Archive Signing Key (2C1130F7…227AD01E).
KEY_DEBIAN=$HERE/keys/cutefish-archive.asc
KEY_REEF=$HERE/keys/cutefish-reef.asc

case $(uname -m) in
  x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;;
  *) echo "Arquitetura $(uname -m) não suportada pelo Reef"; exit 1 ;;
esac

log() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }

# O Reef só liga no libcutefish-toolkit (e no WebKit, que vem do .deb): só ele
# precisa do mesmo commit do nightly. O resto segue o upstream.
PIN_REPOS=${PIN_REPOS:-cutefish-toolkit}

# checkout_keep DIR REF: faz checkout sem perder edições locais não commitadas.
# Guarda no stash, troca de commit e reaplica; se der conflito, o repositório
# fica limpo no REF e as edições continuam no 'git stash list'.
checkout_keep() {
  local d=$1 ref=$2 name; name=$(basename "$d")
  if [[ -z $(git -C "$d" status --porcelain --untracked-files=no) ]]; then
    git -C "$d" checkout -q --detach "$ref"; return
  fi
  git -C "$d" stash push -q -m "cutefish-fedora: edições locais antes de $ref"
  git -C "$d" checkout -q --detach "$ref"
  if git -C "$d" stash pop -q >/dev/null 2>&1; then
    echo "  $name: edições locais reaplicadas"
  else
    git -C "$d" reset -q --hard
    echo "  AVISO $name: edições locais conflitam com $ref; ficaram em 'git -C $d stash list'" >&2
  fi
}

mkdir -p "$WORK"
REPOPY=$WORK/repo.py
cat > "$REPOPY" <<'PY'
"""Lê Release (já verificado pelo gpgv) e Packages de um repositório apt."""
import hashlib, re, sys

def stanzas(text):
    for block in text.strip().split("\n\n"):
        d, key = {}, None
        for line in block.splitlines():
            if line[:1] in " \t" and key:
                d[key] += "\n" + line.strip()
            elif ":" in line:
                key, _, v = line.partition(":"); d[key] = v.strip()
        yield d

cmd = sys.argv[1]
if cmd == "packages-sha256":          # Release, caminho -> sha256 esperado
    rel = open(sys.argv[2]).read()
    sect = rel.split("SHA256:", 1)[1]
    for line in sect.splitlines()[1:]:
        if not line.startswith(" "): break
        h, size, path = line.split()
        if path == sys.argv[3]: print(h); break
elif cmd == "pick":                    # Packages, nome -> versão, arquivo, sha256, depends
    best = None
    for s in stanzas(open(sys.argv[2]).read()):
        if s.get("Package") == sys.argv[3] and (best is None or s["Version"] > best["Version"]):
            best = s
    if not best: sys.exit(f"pacote {sys.argv[3]} não encontrado")
    print(best["Version"]); print(best["Filename"]); print(best["SHA256"]); print(best.get("Depends", ""))
elif cmd == "hash":                    # versão Debian -> hash git
    m = re.search(r"git\d{14}\.([0-9a-f]{7,40})", sys.argv[2]); print(m.group(1) if m else "")
elif cmd == "sha256":
    print(hashlib.sha256(open(sys.argv[2], "rb").read()).hexdigest())
PY
py() { python3 -I "$REPOPY" "$@"; }

# Baixa InRelease, verifica a assinatura e o Packages da arquitetura.
fetch_index() {  # base keyfile nome
  local base=$1 key=$2 name=$3 d=$WORK/index/$3
  mkdir -p "$d"
  [[ -s $d/keyring.gpg ]] || gpg --dearmor < "$key" > "$d/keyring.gpg"
  curl -fsSL -o "$d/InRelease" "$base/dists/$SUITE/InRelease"
  rm -f "$d/Release"
  if command -v gpgv >/dev/null; then
    gpgv --keyring "$d/keyring.gpg" --output "$d/Release" "$d/InRelease" 2>"$d/gpgv.log" ||
      { cat "$d/gpgv.log"; die "assinatura inválida em $base"; }
  else
    local gh; gh=$(mktemp -d)
    gpg --homedir "$gh" --batch --no-default-keyring --keyring "$d/keyring.gpg" \
      --status-fd 3 --output "$d/Release" --decrypt "$d/InRelease" 3>"$d/gpg.status" 2>"$d/gpgv.log" || true
    rm -rf "$gh"
    grep -q '^\[GNUPG:\] VALIDSIG' "$d/gpg.status" ||
      { cat "$d/gpgv.log"; rm -f "$d/Release"; die "assinatura inválida em $base"; }
  fi
  curl -fsSL -o "$d/Packages" "$base/dists/$SUITE/main/binary-$ARCH/Packages"
  local want; want=$(py packages-sha256 "$d/Release" "main/binary-$ARCH/Packages")
  [[ -n $want && $(py sha256 "$d/Packages") == "$want" ]] || die "Packages de $base não confere com o Release"
}

fetch_deb() {  # base nome pacote -> caminho do .deb
  local base=$1 name=$2 pkg=$3 info ver file sha out
  mapfile -t info < <(py pick "$WORK/index/$name/Packages" "$pkg")
  ver=${info[0]} file=${info[1]} sha=${info[2]}
  out=$WORK/debs/${file##*/}; mkdir -p "$WORK/debs"
  [[ -s $out ]] || curl -fsSL -o "$out" "$base/$file"
  [[ $(py sha256 "$out") == "$sha" ]] || { rm -f "$out"; die "SHA-256 errado em $out"; }
  printf '%s\n' "$out"
}

deps() {
  sudo dnf install -y --skip-unavailable gnupg2 curl python3 bsdtar binutils patchelf \
    rpm-build createrepo_c gcc-c++ make llvm19-libs clang19-libs
  rpm -q llvm19-libs >/dev/null || die "llvm19-libs não existe nesta versão do Fedora"
  rpm -q clang19-libs >/dev/null ||
    echo "AVISO: clang19-libs indisponível; libreef-metal-msl (compilação de shaders) não vai carregar."
}

# Repositório -> pacote Debian que o nightly gera a partir dele.
deb_name() {
  case $1 in
    cutefish-*|xdg-desktop-portal-cutefish) echo "$1" ;;
    icons) echo cutefish-icon-theme ;;
    *) echo "cutefish-$1" ;;
  esac
}

pin() {
  log "Fixando no commit do nightly do Debian: $PIN_REPOS (o ABI que o Reef espera)"
  fetch_index "$DEBIAN_REPO" "$KEY_DEBIAN" debian
  fetch_index "$REEF_REPO" "$KEY_REEF" reef
  local d r info hash b
  for d in "$SRC"/*/.git; do
    r=$(basename "$(dirname "$d")")
    [[ $PIN_REPOS == all || " $PIN_REPOS " == *" $r "* ]] || continue
    if b=$(git -C "$SRC/$r" symbolic-ref -q --short HEAD); then
      echo "  AVISO $r: está na branch $b (fork), não fixo. Se o ABI mudar, o Reef pode quebrar" >&2
      continue
    fi
    mapfile -t info < <(py pick "$WORK/index/debian/Packages" "$(deb_name "$r")" 2>/dev/null) || true
    [[ ${#info[@]} -ge 1 ]] || { echo "  $r: sem pacote no nightly, fica no main"; continue; }
    hash=$(py hash "${info[0]}")
    [[ -n $hash ]] || { echo "  $r: versão ${info[0]} sem hash"; continue; }
    git -C "$SRC/$r" fetch -q --unshallow 2>/dev/null || git -C "$SRC/$r" fetch -q
    checkout_keep "$SRC/$r" "$hash" && echo "  $r -> $hash"
  done
  # O Reef declara "cutefish-toolkit (>= versão)"; avisa se o toolkit fixado for outro.
  mapfile -t info < <(py pick "$WORK/index/reef/Packages" cutefish-reef)
  local need; need=$(grep -oE 'cutefish-toolkit \(>= [^)]+\)' <<<"${info[3]}" || true)
  echo "  Reef ${info[0]} pede: $need"
}

build_icu() {
  local b=$WORK/icu
  [[ -s $WORK/stage-icu$ICU_PREFIX/libicuuc.so.76 ]] && return
  log "Compilando ICU $ICU_VER privado (libicucore do Reef liga símbolos *_76)"
  mkdir -p "$b"; cd "$b"
  [[ -s $ICU_TGZ ]] || curl -fsSLO "$ICU_URL"
  echo "$ICU_SHA512  $ICU_TGZ" | sha512sum -c --quiet || die "SHA-512 do ICU não confere"
  rm -rf icu; tar -xzf "$ICU_TGZ"
  cd icu/source
  ./runConfigureICU Linux --prefix="$ICU_PREFIX" --libdir="$ICU_PREFIX" \
    --disable-samples --disable-tests --disable-extras
  make -j"$(nproc)"
  make DESTDIR="$b/dest" install
  install -d "$WORK/stage-icu$ICU_PREFIX"
  cp -a "$b/dest$ICU_PREFIX"/libicu{data,uc,i18n,io}.so.76* "$WORK/stage-icu$ICU_PREFIX/"
}

extract() {  # deb destino
  rm -rf "$2"; mkdir -p "$2"
  bsdtar -xOf "$1" 'data.tar.*' | bsdtar -xf - -C "$2"
}

# Bibliotecas pedidas (NEEDED) pelos ELF de um diretório que nem o Fedora nem o
# próprio pacote fornecem.
missing_libs() {
  local root=$1 f n
  local have; have=$( { /usr/sbin/ldconfig -p | awk '{print $1}';
    ls /usr/lib64/llvm19/lib 2>/dev/null; ls "$WORK"/stage-*/"$ICU_PREFIX" 2>/dev/null;
    find "$WORK"/stage-* -name '*.so*' -printf '%f\n' 2>/dev/null; } | sort -u)
  while IFS= read -r f; do
    for n in $(objdump -p "$f" 2>/dev/null | awk '/NEEDED/{print $2}'); do
      grep -qxF "$n" <<<"$have" || echo "$n ${f#"$root"}"
    done
  done < <(find "$root" -type f \( -name '*.so*' -o -perm -u+x \) -exec sh -c 'head -c4 "$1" | grep -q ELF' _ {} \; -print)
}

# Debian 13 tem libxml2.so.2; o libxml2 2.14+ (Fedora novo) virou libxml2.so.16.
# O próprio Reef já tenta .16 no dlopen; aqui fazemos o mesmo nos NEEDED.
fix_sonames() {
  local root=$1 line lib file
  while read -r lib file; do
    case $lib in
      libxml2.so.2)
        if /usr/sbin/ldconfig -p | grep -q 'libxml2.so.16 '; then
          patchelf --replace-needed libxml2.so.2 libxml2.so.16 "$root$file"
          echo "  $file: libxml2.so.2 -> libxml2.so.16"
        fi ;;
    esac
  done < <(missing_libs "$root")
}

package() {
  deps
  fetch_index "$DEBIAN_REPO" "$KEY_DEBIAN" debian
  fetch_index "$REEF_REPO" "$KEY_REEF" reef
  local reef_deb webkit_deb
  reef_deb=$(fetch_deb "$REEF_REPO" reef cutefish-reef)
  webkit_deb=$(fetch_deb "$DEBIAN_REPO" debian cutefish-webkit)
  log "Baixados e verificados: ${reef_deb##*/}, ${webkit_deb##*/}"

  build_icu

  log "Extraindo e adaptando ao layout do Fedora"
  extract "$reef_deb" "$WORK/stage-reef"
  extract "$webkit_deb" "$WORK/stage-webkit"
  local W=$WORK/stage-webkit
  if [[ -d $W/usr/lib/x86_64-linux-gnu || -d $W/usr/lib/aarch64-linux-gnu ]]; then
    mkdir -p "$W/usr/lib64"; mv "$W"/usr/lib/*-linux-gnu/* "$W/usr/lib64/"; rm -rf "$W"/usr/lib/*-linux-gnu
    rmdir "$W/usr/lib" 2>/dev/null || true
    sed -i -E 's#/usr/lib/[a-z0-9_]+-linux-gnu#/usr/lib64#g' "$W"/usr/lib64/pkgconfig/*.pc
  fi
  rm -rf "$WORK"/stage-*/usr/share/doc/*/changelog.Debian.gz
  install -d "$WORK/stage-icu/etc/ld.so.conf.d"
  printf '%s\n/usr/lib64/llvm19/lib\n' "$ICU_PREFIX" > "$WORK/stage-icu/etc/ld.so.conf.d/cutefish-reef.conf"

  fix_sonames "$WORK/stage-reef"; fix_sonames "$WORK/stage-webkit"
  check_report

  log "Gerando os RPMs"
  local rv wv wr
  rv=$(py pick "$WORK/index/reef/Packages" cutefish-reef | head -1)
  wv=$(py pick "$WORK/index/debian/Packages" cutefish-webkit | head -1)
  wr=${wv##*-}; wv=${wv%-*}
  write_spec "$rv" "$wv" "$wr" > "$WORK/cutefish-reef.spec"
  rpmbuild -bb "$WORK/cutefish-reef.spec" \
    --define "_topdir $WORK/rpmbuild" --define "stage $WORK"
  find "$WORK/rpmbuild/RPMS" -name '*.rpm' -printf '  %f\n'
}

check_report() {
  local m
  m=$( { missing_libs "$WORK/stage-reef"; missing_libs "$WORK/stage-webkit"; } |
       grep -vE '^libcutefish-(toolkit|toolkit-base|webkit)\.so' | sort -u || true)
  if [[ -n $m ]]; then
    echo "AVISO: bibliotecas pedidas que o Fedora não fornece (instale o pacote ou o Reef pode falhar):"
    sed 's/^/    /' <<<"$m"
  else
    echo "  Todas as bibliotecas pedidas existem no sistema ou nos pacotes."
  fi
}

write_spec() {  # reef_ver webkit_ver webkit_rel
  cat <<SPEC
%global debug_package %{nil}
# Binários de terceiros: sem strip, sem mexer em shebangs, sem build-id.
%global __os_install_post %{nil}
%global _build_id_links none
# O toolkit vem do build via cmake (fora do rpm) e o LLVM 19 do Fedora fica em /usr/lib64/llvm19/lib.
# O WebKit do Debian pede símbolos libcurl versionados (CURL_OPENSSL_4); o libcurl do Fedora
# tem o mesmo soname, mas sem versões de símbolo (o ld.so aceita, só avisa). Fica o libcurl.so.4() normal.
# Parênteses como [(] [)]: o rpm come o "\" ao expandir a macro e "\(" viraria um grupo da regex.
%global __requires_exclude ^(libcutefish-toolkit|libcutefish-toolkit-base|libLLVM\\.so\\.19|libclang-cpp\\.so\\.19|libcurl\\.so\\.4[(]CURL_OPENSSL_4[)])
%global __requires_exclude_from ^/usr/lib/cutefish-reef/System/.*\$
%global __provides_exclude_from ^/usr/lib/cutefish-reef/.*\$

Name:           cutefish-reef
Version:        $1
Release:        1.fedora%{?dist}
Summary:        Cutefish Reef: roda apps do Mac no desktop Cutefish
License:        BSD-3-Clause AND Apache-2.0 AND APSL-2.0 AND MIT AND ISC AND TCL AND Unicode-3.0
URL:            https://cutefish.org/reef
Requires:       cutefish-webkit = $2-$3.fedora%{?dist}
Requires:       cutefish-reef-icu76 = $ICU_VER-1%{?dist}
Requires:       llvm19-libs
# Depends do .deb que o Reef abre com dlopen (não aparecem como NEEDED, então o rpm não os acha).
Requires:       pulseaudio-libs libsndfile cups-libs libxslt hyphen libexttextcat libva
Recommends:     clang19-libs
Recommends:     hyphen-en

%description
Pacote do Reef (binário oficial do Cutefish para Debian 13) adaptado ao Fedora.

%package -n cutefish-webkit
Version:        $2
Release:        $3.fedora%{?dist}
Summary:        Motor web do Cutefish (WPE WebKit), binário do nightly do Debian
License:        BSD-2-Clause AND LGPL-2.0-or-later
Requires:       cutefish-reef-icu76 = $ICU_VER-1%{?dist}
Requires:       bubblewrap xdg-dbus-proxy
Recommends:     gstreamer1-plugins-good gstreamer1-plugins-bad-free gstreamer1-plugin-libav

%description -n cutefish-webkit
Motor web usado pelo Reef (WebKit.framework).

%package -n cutefish-reef-icu76
Version:        $ICU_VER
Release:        1%{?dist}
Summary:        ICU 76 privado do Reef (não substitui o ICU do sistema)
License:        Unicode-3.0

%description -n cutefish-reef-icu76
ICU $ICU_VER compilado do código-fonte oficial, instalado em $ICU_PREFIX.

%install
cp -a %{stage}/stage-reef/.   %{buildroot}/
cp -a %{stage}/stage-webkit/. %{buildroot}/
cp -a %{stage}/stage-icu/.    %{buildroot}/

%post -p /sbin/ldconfig
%postun -p /sbin/ldconfig
%post -n cutefish-webkit -p /sbin/ldconfig
%postun -n cutefish-webkit -p /sbin/ldconfig
%post -n cutefish-reef-icu76 -p /sbin/ldconfig
%postun -n cutefish-reef-icu76 -p /sbin/ldconfig

%files
$(cd "$WORK/stage-reef" && find . -mindepth 1 \( -type f -o -type l \) | sed 's#^\.##; s#.*#"&"#')
%dir /usr/lib/cutefish-reef

%files -n cutefish-webkit
$(cd "$WORK/stage-webkit" && find . -mindepth 1 \( -type f -o -type l \) | sed 's#^\.##; s#.*#"&"#')

%files -n cutefish-reef-icu76
%config(noreplace) /etc/ld.so.conf.d/cutefish-reef.conf
$ICU_PREFIX
SPEC
}

local_repo() {  # rpm... -> copia para o repositório local e atualiza o metadado
  log "Repositório local $REPO_DIR (o PackageKit acha 'cutefish-reef' por ele)"
  sudo install -d "$REPO_DIR"
  sudo cp "$@" "$REPO_DIR/"
  sudo createrepo_c --update "$REPO_DIR"
  sudo tee /etc/yum.repos.d/cutefish-local.repo >/dev/null <<REPO
[cutefish-local]
name=Cutefish (RPMs gerados localmente)
baseurl=file://$REPO_DIR
enabled=1
# Pacotes gerados nesta máquina a partir de .deb verificados com as chaves do Cutefish.
gpgcheck=0
REPO
  # --refresh: um rebuild gera RPMs com o mesmo nome; sem isso o dnf pode usar o metadado antigo.
  sudo dnf makecache --refresh --repo cutefish-local
}

install_rpms() {
  local_repo "$WORK"/rpmbuild/RPMS/x86_64/cutefish-{reef,webkit}*.rpm
  sudo dnf install -y cutefish-reef
  sudo install -d -m 2775 -o root -g wheel /Applications
  sudo semanage fcontext -a -t usr_t '/Applications(/.*)?' 2>/dev/null || true
  sudo restorecon -R /Applications /usr/lib/cutefish-reef "$ICU_PREFIX" || true
  log "Teste rápido"
  /usr/bin/reef-diagnose 2>&1 | head -40 || true
  echo "Abra um .dmg ou .app no Files. Se algo falhar: journalctl --user -b | grep -i reef"
}

# libghostty-vt (estática, só para compilar o terminal). O upstream compila com Zig;
# o nightly do Debian já traz o resultado como cutefish-ghostty-vt-dev, assinado no
# mesmo repositório. Reempacotar evita instalar o Zig e usa a mesma versão do Debian.
ghostty_vt() {
  sudo dnf install -y --skip-unavailable gnupg2 curl python3 bsdtar rpm-build createrepo_c
  fetch_index "$DEBIAN_REPO" "$KEY_DEBIAN" debian
  local deb ver S=$WORK/stage-gvt
  deb=$(fetch_deb "$DEBIAN_REPO" debian cutefish-ghostty-vt-dev)
  ver=$(py pick "$WORK/index/debian/Packages" cutefish-ghostty-vt-dev | head -1)
  log "Reempacotando ${deb##*/} (layout /usr/lib64)"
  extract "$deb" "$S"
  mkdir -p "$S/usr/lib64"; mv "$S"/usr/lib/*-linux-gnu/* "$S/usr/lib64/"
  rm -rf "$S/usr/lib"
  sed -i -E 's#/usr/lib/[a-z0-9_]+-linux-gnu#/usr/lib64#g' "$S"/usr/lib64/pkgconfig/cutefish-ghostty-vt.pc
  rm -f "$S"/usr/share/doc/*/changelog.Debian.gz
  cat > "$WORK/cutefish-ghostty-vt.spec" <<SPEC
%global debug_package %{nil}
%global __os_install_post %{nil}
Name:           cutefish-ghostty-vt-devel
Version:        ${ver%-*}
Release:        ${ver##*-}.fedora%{?dist}
Summary:        libghostty-vt estática para compilar o cutefish-terminal
License:        MIT
URL:            https://github.com/ghostty-org/ghostty

%description
Binário do nightly do Debian (cutefish-ghostty-vt-dev). Só é usado na compilação.

%install
cp -a $S/. %{buildroot}/

%files
$(cd "$S" && find . -mindepth 1 \( -type f -o -type l \) | sed 's#^\.##; s#.*#"&"#')
SPEC
  rpmbuild -bb "$WORK/cutefish-ghostty-vt.spec" --define "_topdir $WORK/rpmbuild"
  local_repo "$WORK"/rpmbuild/RPMS/x86_64/cutefish-ghostty-vt-devel-*.rpm
  sudo dnf install -y cutefish-ghostty-vt-devel
  pkg-config --modversion cutefish-ghostty-vt
}

case ${1:-} in
  pin) pin ;; package) package ;; install) install_rpms ;;
  ghostty-vt) ghostty_vt ;;
  check) check_report ;;
  fetch)  # só baixa e verifica (não precisa de dnf); útil para testar fora do Fedora
    fetch_index "$DEBIAN_REPO" "$KEY_DEBIAN" debian
    fetch_index "$REEF_REPO" "$KEY_REEF" reef
    fetch_deb "$REEF_REPO" reef cutefish-reef
    fetch_deb "$DEBIAN_REPO" debian cutefish-webkit ;;
  spec)   # gera o .spec a partir de stage-* já extraídos (teste)
    rv=$(py pick "$WORK/index/reef/Packages" cutefish-reef | head -1)
    wv=$(py pick "$WORK/index/debian/Packages" cutefish-webkit | head -1)
    write_spec "$rv" "${wv%-*}" "${wv##*-}" ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
