#!/usr/bin/env bash
# Compila e instala o desktop Cutefish inteiro (compositor, sessão, apps) num
# Fedora "Minimal Install". Baseado em cutefish/docs/building.md (escrito para
# Debian 13), com as dependências traduzidas para o dnf via pkgconfig().
#
# Uso:
#   ./cutefish-fedora-build.sh prep        # configs da pasta fedora-reinstall (sudo)
#   ./cutefish-fedora-build.sh deps        # instala dependências (sudo)
#   ./cutefish-fedora-build.sh clone       # clona/atualiza os repositórios (forks de repos.conf)
#   ./cutefish-fedora-build.sh sync        # atualiza tudo e faz rebase dos forks no main do upstream
#                                          # (PUSH=1 também envia as branches dos forks)
#   ./cutefish-fedora-build.sh build       # compila e instala em /usr (sudo)
#   ./cutefish-fedora-build.sh session     # serviços de runtime + login
#   ./cutefish-fedora-build.sh reef        # RPM do Reef a partir do .deb oficial (reef-fedora.sh)
#   ./cutefish-fedora-build.sh all         # tudo acima, em ordem
#
# Variáveis:
#   SRC=~/cutefish        onde clonar
#   WITH_DM=1             usa cutefish-dm (0 = SDDM)
#   WITH_QT=1             compila qt-plugins (tema para apps Qt)
#   WITH_TERMINAL=1       compila o terminal (padrão). A libghostty-vt vem do nightly
#                         do Debian como RPM (reef-fedora.sh ghostty-vt), sem Zig
#   JOBS=$(nproc)
#   FORK_BASE=https://github.com/USUARIO   sobrepõe o FORK_BASE do repos.conf
#   REINSTALL_DIR=../fedora-reinstall           pasta com comum.sh e configs/
#   HIBERNATE=0|1         prep: ativa a hibernação com o configure_hibernation do comum.sh
#   WITH_REEF=1           fixa o cutefish-toolkit no commit do nightly e instala o Reef
#                         (os outros repositórios seguem o upstream; PIN_REPOS=all fixa todos)
#                         (precisa de reef-fedora.sh e keys/ ao lado deste script)
set -euo pipefail

SRC=${SRC:-$HOME/cutefish}
JOBS=${JOBS:-$(nproc)}
WITH_DM=${WITH_DM:-1}
WITH_QT=${WITH_QT:-0}
WITH_TERMINAL=${WITH_TERMINAL:-1}
WITH_REEF=${WITH_REEF:-1}
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
GH=https://github.com/cutefishos

# Ordem de build de docs/building.md. Cada projeto é instalado antes do próximo.
REQUIRED=(cutefish-toolkit cutefish-framework icons cutefish-core filemanager cutefish-compositor wallpapers)
ORDER=(cutefish-toolkit cutefish-framework qt-plugins icons cutefish-core cutefish-dm
       filemanager terminal xdg-desktop-portal-cutefish settings system-monitor
       text-editor video-player calendar calculator preview cutefish-compositor wallpapers)
# Repositórios que existem na org mas não estão na lista do guia; compilados no fim se existirem.
EXTRA=(clock disk-utility)

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

# Edições locais não commitadas nunca são descartadas: ficam no stash durante a
# troca de commit e são reaplicadas. Se conflitarem, o repositório fica limpo e
# elas continuam em 'git stash list'.
stash_local() {
  [[ -n $(git -C "$1" status --porcelain --untracked-files=no) ]] || return 1
  git -C "$1" stash push -q -m "cutefish-fedora: edições locais $(date +%F_%T)"
}
unstash_local() {
  if git -C "$1" stash pop -q >/dev/null 2>&1; then
    echo "  $(basename "$1"): edições locais reaplicadas"
  else
    git -C "$1" reset -q --hard
    echo "  AVISO $(basename "$1"): edições locais conflitam; ficaram em 'git -C $1 stash list'" >&2
  fi
}
checkout_keep() {  # DIR REF: checkout destacado sem perder edições
  local s=0; stash_local "$1" && s=1
  git -C "$1" checkout -q --detach "$2"
  ((s)) && unstash_local "$1"; return 0
}

# repos.conf: repositórios que vêm de um fork seu, numa branch com os patches
# para o Fedora. Os outros vêm de $GH, na branch padrão.
declare -A FORK_BRANCH=()
load_manifest() {
  local f=$HERE/repos.conf name branch base=
  [[ -f $f ]] || return 0
  while read -r name branch _; do
    [[ -z $name || $name == \#* ]] && continue
    if [[ $name == FORK_BASE=* ]]; then base=${name#FORK_BASE=}; continue; fi
    FORK_BRANCH[$name]=${branch:-fedora}
  done < "$f"
  FORK_BASE=${FORK_BASE:-$base}
  [[ $FORK_BASE == *SEU_USUARIO* ]] && FORK_BASE=
  return 0
}
fork_url() { [[ -z ${FORK_BASE:-} ]] || echo "$FORK_BASE/$1"; }
reachable() { [[ -n $1 ]] && git ls-remote --exit-code "$1" HEAD >/dev/null 2>&1; }

# Repositório com fork: origin = seu fork, upstream = cutefishos, e o checkout fica
# na branch local (não destacado), para você commitar nela.
update_fork() {
  local r=$1 b=$2 d=$SRC/$1 url up=$GH/$1 s=0
  url=$(fork_url "$r")
  git -C "$d" remote get-url upstream >/dev/null 2>&1 || git -C "$d" remote add upstream "$up"
  git -C "$d" remote set-url upstream "$up"
  if reachable "$url"; then
    git -C "$d" remote set-url origin "$url"
    git -C "$d" fetch -q origin
  else
    echo "  $r: fork não acessível (${url:-FORK_BASE não definido em repos.conf}); uso a branch local $b"
  fi
  git -C "$d" fetch -q upstream
  git -C "$d" remote set-head upstream -a >/dev/null
  stash_local "$d" && s=1
  if git -C "$d" show-ref -q --verify "refs/heads/$b"; then
    git -C "$d" checkout -q "$b"
    if [[ $(git -C "$d" remote get-url origin) != "$up" ]] &&
       git -C "$d" show-ref -q --verify "refs/remotes/origin/$b"; then
      git -C "$d" merge -q --ff-only "origin/$b" 2>/dev/null ||
        echo "  AVISO $r: a branch $b local e a do fork divergiram; mantive a local (veja 'git -C $d status')" >&2
    fi
  elif git -C "$d" show-ref -q --verify "refs/remotes/origin/$b"; then
    git -C "$d" checkout -q -b "$b" --track "origin/$b"
  else
    git -C "$d" checkout -q -b "$b" upstream/HEAD
    echo "  AVISO $r: não achei a branch $b; criei a partir do upstream, sem seus patches" >&2
  fi
  ((s)) && unstash_local "$d"; return 0
}


REINSTALL_DIR=${REINSTALL_DIR:-$(dirname -- "$HERE")/fedora-reinstall}
HIBERNATE=${HIBERNATE:-0}

# Partes da sua pasta fedora-reinstall que independem do KDE e devem vir antes do
# build: o dnf.conf e o RPM Fusion fazem o Cutefish ser compilado já contra o
# FFmpeg completo. As funções vêm do próprio comum.sh (sem copiar código); as
# partes do KDE (kdeglobals, plasmakeyboardrc, portal KDE, PowerDevil, apps KDE)
# ficam de fora porque o Cutefish tem compositor, portal e configurações próprios.
prep() {
  [[ -r $REINSTALL_DIR/comum.sh && -d $REINSTALL_DIR/configs ]] ||
    { echo "Não achei $REINSTALL_DIR/comum.sh e configs/. Ajuste REINSTALL_DIR."; exit 1; }
  local ourlog; ourlog=$(declare -f log)
  SCRIPT_DIR=$REINSTALL_DIR
  # shellcheck source=/dev/null
  . "$REINSTALL_DIR/comum.sh"
  eval "$ourlog"
  # A hibernação do comum.sh termina configurando o PowerDevil (KDE). No Cutefish não existe.
  configure_kde_hibernation() { echo "  (PowerDevil/KDE ignorado no Cutefish)"; }
  [[ $EUID -ne 0 ]] || { echo "Rode como usuário normal; o script chama o sudo."; exit 1; }
  sudo -v

  log "dnf.conf (downloads paralelos, defaultyes)"
  sudo install -m 0644 "$CONFIG_DIR/system/dnf.conf" /etc/dnf/dnf.conf
  sudo dnf install -y dnf5-plugins curl

  log "RPM Fusion + OpenH264, antes do build"
  local rel; rel=$(rpm -E %fedora)
  sudo dnf install -y \
    "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${rel}.noarch.rpm" \
    "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${rel}.noarch.rpm"
  sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1
  sudo dnf upgrade --refresh -y

  log "FFmpeg completo e VA-API (o Cutefish vai linkar contra ele)"
  sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing || sudo dnf install -y ffmpeg
  sudo dnf install -y ffmpeg-libs ffmpeg-devel libva libva-utils
  if grep -qs 0x8086 /sys/class/drm/card*/device/vendor; then
    sudo dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing ||
      sudo dnf install -y intel-media-driver
    sudo dnf install -y libva-intel-driver
  fi

  log "keyd v2.6.0 + Caps Lock (configs/system/capslock.conf)"
  sudo dnf install -y gcc make git
  local kt; kt=$(mktemp -d -t keyd.XXXXXXXX)
  git clone --depth 1 --branch v2.6.0 https://github.com/rvaiya/keyd.git "$kt"
  make -C "$kt"; sudo make -C "$kt" install; rm -rf -- "$kt"
  sudo systemctl daemon-reload
  configure_keyd

  log "Fn Lock ASUS (só em hardware ASUS)"
  configure_asus_fnlock

  log "Fontes: SF Pro / SF Mono da Apple + JetBrainsMono Nerd Font"
  sudo dnf install -y 7zip cpio gzip tar xz fontconfig
  install_apple_font SF-Pro
  install_apple_font SF-Mono
  install -d "$DATA_HOME/fonts/JetBrainsMono"
  curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz |
    tar -xJ -C "$DATA_HOME/fonts/JetBrainsMono"
  fc-cache -f "$DATA_HOME/fonts/JetBrainsMono"
  verify_fonts
  # O Cutefish grava ~/.config/fontconfig/conf.d/99-cutefish.conf (rgb + hintfull).
  # Arquivos são lidos em ordem alfabética e o último vence: com o nome original,
  # 99-apple-rendering.conf perderia para 99-cutefish.conf.
  install -d "$CONFIG_HOME/fontconfig/conf.d"
  install -m 0644 "$CONFIG_DIR/fonts/99-apple-rendering.conf" \
    "$CONFIG_HOME/fontconfig/conf.d/99-zz-apple-rendering.conf"

  log "Config do Ghostty e PATH"
  install -d "$CONFIG_HOME/ghostty"
  install -m 0644 "$CONFIG_DIR/ghostty/config" "$CONFIG_HOME/ghostty/config"
  ensure_local_bin_in_path

  if [[ $HIBERNATE == 1 ]]; then
    log "Hibernação (swapfile, resume=, dracut, SELinux swapfile_t)"
    sudo dnf install -y btrfs-progs policycoreutils-python-utils
    configure_hibernation
  fi
}

deps() {
  log "Ferramentas de build"
  sudo dnf install -y git cmake ninja-build pkgconf-pkg-config clang gcc-c++ \
    python3 gettext curl minisign gtk-update-icon-cache

  log "Bibliotecas (por módulo pkg-config, como o guia sugere para Fedora)"
  local pcs=(
    # Wayland e gráficos
    wayland-client wayland-server wayland-egl wayland-scanner wayland-protocols
    egl glesv2 gbm libdrm
    # Entrada, seat, sistema
    xkbcommon libinput libseat libudev libsystemd pam
    # Fontes e texto
    fontconfig freetype2 harfbuzz icu-uc icu-i18n expat
    # Imagens
    libpng libjpeg zlib libwebp libtiff-4 libheif libjxl lcms2 libopenjp2 libhwy absl_base
    # Áudio e mídia (ffmpeg-free do Fedora; codecs completos vêm do RPM Fusion)
    libpipewire-0.3 libspa-0.2 libavcodec libavformat libavutil libswscale libva
    # XWayland
    xcb xcb-composite xcb-xfixes xcb-shape xcb-sync xcursor
    # Outros
    libarchive fuse3 libmtp smbclient libssh libzip libxcrypt libpcre2-8
    # Apps opcionais
    mpv libcurl libical
  )
  local args=(); for p in "${pcs[@]}"; do args+=("pkgconfig($p)"); done
  sudo dnf install -y --skip-unavailable "${args[@]}"
  # Alguns são encontrados pelo nome e não por pkg-config
  sudo dnf install -y --skip-unavailable libxcrypt-devel gtest-devel
  # filemanager (imagens de disco, commit 3887a85 de 2026-11-23): zlib, bzip2, LZMA e LZFSE.
  # O docs/building.md ainda não lista bzip2, LZMA e LZFSE. Sem --skip-unavailable: se faltar, falha já aqui.
  sudo dnf install -y bzip2-devel xz-devel lzfse-devel

  # --skip-unavailable esconde o que faltou; mostra agora em vez de no meio do build.
  local miss=()
  for p in "${pcs[@]}" bzip2 liblzma libwebpdemux harfbuzz-subset libjxl_threads \
           absl_flat_hash_set absl_inlined_vector absl_cleanup; do
    pkg-config --exists "$p" || miss+=("$p")
  done
  [[ -f /usr/include/lzfse.h ]] || miss+=(lzfse.h)
  if ((${#miss[@]})); then
    echo "AVISO: módulos ainda ausentes: ${miss[*]}"
    echo "  (mpv e ffmpeg completos vêm do RPM Fusion: rode '$0 prep' antes)"
  fi

  if [[ $WITH_QT == 1 ]]; then
    sudo dnf install -y qt6-qtbase-devel qt6-qtbase-private-devel \
      qt6-qtdeclarative-devel 'pkgconfig(librsvg-2.0)'
  fi

  log "Serviços de runtime (equivalentes Fedora da lista do guia)"
  sudo dnf install -y accountsservice polkit gsettings-desktop-schemas xdg-user-dirs \
    glibc-langpack-pt glibc-langpack-en NetworkManager NetworkManager-wifi bluez upower \
    power-profiles-daemon udisks2 fuse3 pipewire pipewire-pulseaudio wireplumber \
    gnome-keyring gnome-keyring-pam xdg-desktop-portal xorg-x11-server-Xwayland \
    adwaita-icon-theme policycoreutils-python-utils mesa-dri-drivers mesa-vulkan-drivers PackageKit \
    google-noto-sans-fonts google-noto-emoji-fonts liberation-fonts \
    glibc-locale-source libxcrypt dbus-tools
  # glibc-locale-source = "locales" do Debian: o serviço cutefish-locales gera com
  # localedef os idiomas escolhidos em Ajustes (lê /usr/share/i18n/locales).
  # dbus-tools = dbus-send (o "dbus-bin" do Debian): o AppRuntime chama para o atalho de captura de tela.
}

update_repos() {
  load_manifest
  mkdir -p "$SRC"; cd "$SRC"
  local r url
  for r in "${ORDER[@]}" "${EXTRA[@]}"; do
    if [[ -n ${FORK_BRANCH[$r]:-} ]]; then
      if [[ ! -d $r/.git ]]; then
        url=$(fork_url "$r")
        if reachable "$url"; then log "Clonando $r do seu fork"; git clone -q "$url" "$r"
        else log "Clonando $r do upstream (fork não acessível)"; git clone -q "$GH/$r" "$r"; fi
      else
        log "Atualizando $r (fork, branch ${FORK_BRANCH[$r]})"
      fi
      update_fork "$r" "${FORK_BRANCH[$r]}"
    elif [[ -d $r/.git ]]; then
      # Pode estar fixado num commit (pin do Reef): volta para a ponta e o pin refaz.
      log "Atualizando $r"; git -C "$r" fetch -q origin && checkout_keep "$SRC/$r" origin/HEAD
    elif git ls-remote --exit-code "$GH/$r" HEAD >/dev/null 2>&1; then
      log "Clonando $r"; git clone -q "$GH/$r"
    else
      echo "  (pulando $r: repositório não encontrado)"
    fi
  done
}

# Rebase da branch de cada fork sobre o main do upstream. Com PUSH=1, envia
# para o fork (--force-with-lease, porque o rebase reescreve a branch).
sync_forks() {
  local r b d n s
  for r in "${!FORK_BRANCH[@]}"; do
    b=${FORK_BRANCH[$r]}; d=$SRC/$r; s=0
    [[ -d $d/.git ]] || continue
    [[ $(git -C "$d" symbolic-ref -q --short HEAD) == "$b" ]] ||
      { echo "  AVISO $r: não está na branch $b; pulei" >&2; continue; }
    stash_local "$d" && s=1
    if git -C "$d" rebase -q upstream/HEAD >/dev/null 2>&1; then
      n=$(git -C "$d" rev-list --count upstream/HEAD..HEAD)
      echo "  $r: $b com $n patch(es) sobre o upstream $(git -C "$d" rev-parse --short upstream/HEAD)"
      if [[ ${PUSH:-0} == 1 ]]; then
        if [[ $(git -C "$d" remote get-url origin) == "$GH/$r" ]]; then
          echo "  $r: origin ainda é o upstream; defina FORK_BASE em repos.conf para enviar" >&2
        else
          git -C "$d" push -q -u --force-with-lease origin "$b" && echo "  $r: enviado para o fork"
        fi
      fi
    else
      git -C "$d" rebase --abort
      echo "  AVISO $r: conflito no rebase; nada mudou. Resolva com: git -C $d rebase upstream/HEAD" >&2
    fi
    ((s)) && unstash_local "$d"
  done
  return 0
}

sync() {
  update_repos
  log "Rebase dos forks sobre o upstream"
  sync_forks
}

clone() {
  update_repos
  if [[ $WITH_REEF == 1 ]]; then
    # O Reef é binário e liga no libcutefish-toolkit do nightly do Debian (ABI C++
    # interno): o toolkit fica no mesmo commit. Os outros repositórios seguem o upstream.
    SRC=$SRC "$HERE/reef-fedora.sh" pin
  fi
  log "Baixando Skia e PDFium nas revisões fixadas"
  (cd cutefish-toolkit && ./scripts/fetch-skia.sh)
  (cd cutefish-framework && ./scripts/fetch-pdfium.sh)
}

skip() {
  local r=$1
  [[ ! -d $SRC/$r ]] && return 0
  [[ $r == qt-plugins && $WITH_QT != 1 ]] && return 0
  [[ $r == cutefish-dm && $WITH_DM != 1 ]] && return 0
  if [[ $r == terminal ]]; then
    [[ $WITH_TERMINAL != 1 ]] && return 0
    pkg-config --exists cutefish-ghostty-vt || SRC=$SRC "$HERE/reef-fedora.sh" ghostty-vt ||
      { echo "  terminal: não consegui a libghostty-vt (rode '$HERE/reef-fedora.sh ghostty-vt')"; return 0; }
  fi
  # Opcionais com dependências fora do repositório base: pula em vez de derrubar o build.
  if [[ $r == video-player ]] && ! pkg-config --exists 'mpv >= 2.0'; then
    echo "  video-player: falta mpv-devel (RPM Fusion; rode '$0 prep')"; return 0
  fi
  if [[ $r == calendar ]] && ! pkg-config --exists libcurl libical; then
    echo "  calendar: falta libcurl-devel/libical-devel"; return 0
  fi
  return 1
}

build_one() {
  local r=$1
  log "Compilando $r"
  if [[ $r == cutefish-core ]]; then
    # A pasta /Applications pertence ao grupo de administradores, que no código é o
    # "sudo" do Debian. No Fedora é "wheel" (sem isso: "No group sudo" ao instalar apps).
    sed -i 's/std::string group = "sudo";/std::string group = "wheel";/' \
      "$SRC/$r/applicationsfolder/applicationsfolderservice.h"
    grep -q 'group = "wheel"' "$SRC/$r/applicationsfolder/applicationsfolderservice.h" ||
      echo "AVISO: não consegui trocar o grupo sudo -> wheel no cutefish-core (código mudou?)"
  fi
  cmake -S "$SRC/$r" -B "$SRC/build/$r" -G Ninja \
    -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF
  cmake --build "$SRC/build/$r" --parallel "$JOBS"
  sudo cmake --install "$SRC/build/$r"
  sudo ldconfig
}

build() {
  for r in "${REQUIRED[@]}"; do
    [[ -d $SRC/$r ]] || { echo "Falta o repositório obrigatório $r. Rode: $0 clone"; exit 1; }
  done
  for r in "${ORDER[@]}" "${EXTRA[@]}"; do
    skip "$r" || build_one "$r"
  done
  [[ -f /etc/pam.d/cutefish-dm ]] && fedora_dm_pam
  # SELinux: arquivos instalados pelo cmake não recebem rótulo automaticamente.
  log "Restaurando rótulos SELinux"
  sudo restorecon -R /usr/bin /usr/lib /usr/lib64 /usr/libexec /usr/share /etc 2>/dev/null || true
}

# O cutefish-dm instala PAM com "@include common-*", que só existe no Debian: no Fedora
# o login falharia. O compositor já troca por system-auth sozinho; aqui fazemos o mesmo
# para o login e o greeter, no modelo do gdm-password / gdm-launch-environment.
fedora_dm_pam() {
  [[ -f /etc/pam.d/system-auth && ! -f /etc/pam.d/common-auth ]] || return 0
  log "PAM do cutefish-dm no formato do Fedora (system-auth/password-auth)"
  sudo tee /etc/pam.d/cutefish-dm >/dev/null <<'PAM'
#%PAM-1.0
# Fedora: gerado por cutefish-fedora-build.sh (o original usa common-* do Debian).
auth     requisite   pam_nologin.so
auth     required    pam_succeed_if.so user != root quiet_success
auth     substack    password-auth
-auth    optional    pam_gnome_keyring.so
auth     include     postlogin

account  required    pam_nologin.so
account  include     password-auth

password substack    password-auth
-password optional   pam_gnome_keyring.so use_authtok

session  required    pam_selinux.so close
session  required    pam_loginuid.so
session  required    pam_selinux.so open
session  optional    pam_keyinit.so force revoke
session  required    pam_namespace.so
session  include     password-auth
-session optional    pam_gnome_keyring.so auto_start
session  include     postlogin
session  required    pam_env.so
PAM
  sudo tee /etc/pam.d/cutefish-dm-greeter >/dev/null <<'PAM'
#%PAM-1.0
# Fedora: o greeter roda sem senha, como o usuário de sistema cutefish-greeter.
auth     required    pam_succeed_if.so audit quiet_success user = cutefish-greeter
auth     required    pam_permit.so
account  required    pam_succeed_if.so audit quiet_success user = cutefish-greeter
account  required    pam_permit.so
password required    pam_deny.so
session  required    pam_selinux.so close
session  required    pam_loginuid.so
session  required    pam_selinux.so open
session  optional    pam_keyinit.so force revoke
session  include     system-auth
session  required    pam_env.so
PAM
}

session() {
  log "Serviços"
  sudo systemctl enable --now NetworkManager bluetooth accounts-daemon upower udisks2 power-profiles-daemon || true
  # /Applications para apps Mac (Reef). No Fedora o grupo administrativo é wheel.
  sudo install -d -m 2775 -o root -g wheel /Applications
  sudo semanage fcontext -a -t usr_t '/Applications(/.*)?' 2>/dev/null || true
  sudo restorecon -R /Applications || true

  # O xdg-desktop-portal do Fedora tem Requisite=graphical-session.target, e o
  # cutefish-session não ativa esse target. Sem ele o portal não sobe, e os apps
  # (Helium, Edge, Electron) caem no seletor de arquivos do GTK em vez do Files.
  # Um target da sessão que se prende a graphical-session.target, iniciado pelo autostart.
  log "graphical-session.target para os portais (seletor de arquivos do Files)"
  sudo tee /usr/lib/systemd/user/cutefish-session.target >/dev/null <<'UNIT'
[Unit]
Description=Cutefish session
BindsTo=graphical-session.target
Wants=graphical-session-pre.target
After=graphical-session-pre.target
UNIT
  sudo tee /usr/libexec/cutefish-fedora-session-target >/dev/null <<'SH'
#!/bin/sh
# Leva o ambiente da sessão ao systemd (redundante com dbus-update-activation-environment,
# mas não depende do dbus-tools) e ativa graphical-session.target.
systemctl --user import-environment WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP \
  XDG_SESSION_TYPE XDG_SESSION_DESKTOP DESKTOP_SESSION
exec systemctl --user start cutefish-session.target
SH
  sudo chmod 0755 /usr/libexec/cutefish-fedora-session-target
  sudo tee /etc/xdg/autostart/cutefish-fedora-session-target.desktop >/dev/null <<'DESK'
[Desktop Entry]
Type=Application
Name=Cutefish systemd session target
Exec=/usr/libexec/cutefish-fedora-session-target
OnlyShowIn=Cutefish;
NoDisplay=true
DESK
  sudo restorecon /usr/libexec/cutefish-fedora-session-target /usr/lib/systemd/user/cutefish-session.target || true

  if [[ $WITH_DM == 1 && -d $SRC/cutefish-dm ]]; then
    log "Login: cutefish-dm"
    # Como no docs/building.md: o greeter precisa da home (config e cache do toolkit).
    id cutefish-greeter >/dev/null 2>&1 || sudo useradd --system --user-group --create-home \
      --home-dir /var/lib/cutefish-greeter --shell /usr/sbin/nologin cutefish-greeter
    # A unit lê /etc/default/locale (Debian); no Fedora o idioma está em /etc/locale.conf.
    sudo install -d /etc/systemd/system/cutefish-dm.service.d
    printf '[Service]\nEnvironmentFile=-/etc/locale.conf\n' |
      sudo tee /etc/systemd/system/cutefish-dm.service.d/fedora-locale.conf >/dev/null
    # O Fedora usa o kmscon no tty1 (o Debian usa getty). Em segundo plano ele ainda lê o
    # teclado e trava no zoom (Ctrl+- / Ctrl+=); o OnFailure sobe getty@tty1, que conflita
    # com o DM e derruba a sessão. O DM assume o tty1, como faz com o getty.
    printf '[Unit]\nConflicts=kmsconvt@tty1.service\nAfter=kmsconvt@tty1.service\n' |
      sudo tee /etc/systemd/system/cutefish-dm.service.d/fedora-kmscon.conf >/dev/null
    sudo systemctl daemon-reload
    sudo systemctl disable gdm sddm lightdm 2>/dev/null || true
    sudo systemctl enable cutefish-dm
  else
    log "Login: SDDM (sessão 'Cutefish (Wayland)')"
    sudo dnf install -y sddm
    sudo systemctl enable sddm
  fi
  sudo systemctl set-default graphical.target
  echo "Pronto. Reinicie para entrar no Cutefish."
}

case ${1:-} in
  prep) prep ;; deps) deps ;; clone) clone ;; sync) sync ;; build) build ;; session) session ;;
  reef) SRC=$SRC "$HERE/reef-fedora.sh" package && SRC=$SRC "$HERE/reef-fedora.sh" install ;;
  all) prep; deps; clone; build; session
       if [[ $WITH_REEF == 1 ]]; then
         SRC=$SRC "$HERE/reef-fedora.sh" package && SRC=$SRC "$HERE/reef-fedora.sh" install
       fi ;;
  *) sed -n '2,30p' "$0"; exit 1 ;;
esac
