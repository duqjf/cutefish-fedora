# shellcheck shell=bash
# Etapas compartilhadas por reinstalar-fedora.sh e reinstalar-arch.sh.
# Carregado com source depois de definir SCRIPT_DIR.

CONFIG_DIR="$SCRIPT_DIR/configs"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
# Preenchido por configure_hibernation; a troca para o systemd-boot o reaproveita.
RESUME_ARGS=''
EDGE_FLAGS='--enable-gpu-rasterization --use-gl=angle --use-angle=gl --enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder'

log() { printf '\n==> %s\n' "$*"; }
warn() { printf 'AVISO: %s\n' "$*" >&2; }
die() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Recebe os arquivos de configs/ especificos da distro, alem dos comuns.
check_common() {
  local config
  [[ "$EUID" -ne 0 ]] || die 'Execute como usuario normal, sem sudo; o script usa sudo quando necessario.'
  command_exists sudo || die 'sudo nao foi encontrado.'
  for config in system/asus-fnlock.conf system/capslock.conf \
                system/hibernate.conf system/dracut-resume.conf \
                ghostty/config fonts/kdeglobals fonts/99-apple-rendering.conf "$@"; do
    [[ -r "$CONFIG_DIR/$config" ]] || die "Arquivo ausente: configs/$config"
  done
}

# Le as opcoes e pergunta no inicio o que nao foi passado, para o resto da
# instalacao rodar sem esperar respostas.
#   --hibernacao | --sem-hibernacao  ativa ou nao a hibernacao
#   --ardia | --sem-ardia            instala ou nao a nightly do navegador Ardia
#   --kde | --cutefish               desktop em uso (so o Fedora usa; sem a opcao,
#                                    vem de XDG_CURRENT_DESKTOP)
ENABLE_HIBERNATION=''
INSTALL_ARDIA=''
DESKTOP_ENV=''
parse_options() {
  local answer desktop="${XDG_CURRENT_DESKTOP:-}"
  while (( $# )); do
    case "$1" in
      --hibernacao) ENABLE_HIBERNATION=1 ;;
      --sem-hibernacao) ENABLE_HIBERNATION=0 ;;
      --ardia) INSTALL_ARDIA=1 ;;
      --sem-ardia) INSTALL_ARDIA=0 ;;
      --kde) DESKTOP_ENV=kde ;;
      --cutefish) DESKTOP_ENV=cutefish ;;
      *) die "Opcao desconhecida: $1 (use --hibernacao, --sem-hibernacao, --ardia, --sem-ardia, --kde ou --cutefish)" ;;
    esac
    shift
  done
  if [[ -z "$DESKTOP_ENV" ]]; then
    if [[ "${desktop,,}" == *cutefish* ]]; then DESKTOP_ENV=cutefish; else DESKTOP_ENV=kde; fi
  fi
  if [[ -z "$ENABLE_HIBERNATION" ]]; then
    answer=''
    read -rp 'Ativar a hibernacao (swapfile e suspender, depois hibernar)? [s/N] ' answer || true
    if [[ "${answer,,}" == s* ]]; then ENABLE_HIBERNATION=1; else ENABLE_HIBERNATION=0; fi
  fi
  if [[ -z "$INSTALL_ARDIA" ]]; then
    answer=''
    read -rp 'Instalar a nightly mais recente do navegador Ardia? [s/N] ' answer || true
    if [[ "${answer,,}" == s* ]]; then INSTALL_ARDIA=1; else INSTALL_ARDIA=0; fi
  fi
}

configure_asus_fnlock() {
  local vendor
  vendor="$(cat /sys/devices/virtual/dmi/id/sys_vendor 2>/dev/null || true)"
  if [[ "${vendor,,}" == *asus* ]]; then
    sudo install -D -m 0644 "$CONFIG_DIR/system/asus-fnlock.conf" /etc/modprobe.d/asus-fnlock.conf
    printf '%s\n' 'Fn Lock ASUS configurado; a opcao sera aplicada no proximo boot.'
  else
    warn "hardware nao identificado como ASUS (${vendor:-desconhecido}); Fn Lock ignorado."
  fi
}

# Para desativar a correcao: sudo systemctl disable --now keyd.service
configure_keyd() {
  sudo install -D -m 0644 "$CONFIG_DIR/system/capslock.conf" /etc/keyd/capslock.conf
  sudo systemctl enable keyd.service
  sudo systemctl restart keyd.service
  sudo systemctl is-active --quiet keyd.service
}

# Acrescenta resume= e resume_offset= ao kernel atual e aos futuros, em
# systemd-boot (entradas BLS e /etc/kernel/cmdline) e GRUB.
set_resume_kernel_args() {
  local args="$1" entry updated=0
  local strip='s/(^|[[:space:]"'\''])resume(_offset)?=[^[:space:]"'\'']*/\1/g'
  local -a entries
  if [[ -f /etc/kernel/cmdline ]]; then
    sudo sed -i -E "$strip; s|[[:space:]]*\$| $args|" /etc/kernel/cmdline
    updated=1
  fi
  # A ESP so e legivel pelo root, por isso o find roda com sudo.
  mapfile -d '' entries < <(sudo find /boot /efi -maxdepth 4 -path '*/loader/entries/*.conf' -type f -print0 2>/dev/null)
  for entry in "${entries[@]}"; do
    sudo sed -i -E "/^options[[:space:]]/ { $strip; s|[[:space:]]*\$| $args| }" "$entry"
    updated=1
  done
  if [[ -f /etc/default/grub ]] && ! sudo bootctl is-installed >/dev/null 2>&1; then
    if command_exists grubby; then
      sudo grubby --update-kernel=ALL --remove-args='resume resume_offset' --args="$args"
    else
      sudo sed -i -E "/^GRUB_CMDLINE_LINUX_DEFAULT=/ { $strip; s|[[:space:]]*([\"'])\$| $args\\1| }" /etc/default/grub
      sudo grub-mkconfig -o /boot/grub/grub.cfg
    fi
    updated=1
  fi
  (( updated )) || warn "bootloader nao reconhecido; acrescente ao kernel: $args"
}

enable_resume_in_initramfs() {
  if [[ -f /etc/mkinitcpio.conf ]]; then
    # O hook systemd ja retoma da hibernacao; o hook udev precisa do resume.
    if ! grep -Eq '^HOOKS=.*\b(systemd|resume)\b' /etc/mkinitcpio.conf; then
      sudo sed -i -E '/^HOOKS=/ s/\bfilesystems\b/filesystems resume/' /etc/mkinitcpio.conf
    fi
    grep -Eq '^HOOKS=.*\b(systemd|resume)\b' /etc/mkinitcpio.conf ||
      warn 'hook resume nao adicionado em /etc/mkinitcpio.conf; acrescente-o depois de filesystems.'
    sudo mkinitcpio -P
  elif command_exists dracut; then
    sudo install -D -m 0644 "$CONFIG_DIR/system/dracut-resume.conf" /etc/dracut.conf.d/resume.conf
    sudo dracut --regenerate-all --force
  else
    warn 'nem mkinitcpio nem dracut encontrados; o initramfs nao foi regenerado.'
  fi
}

# Valores do PowerDevil: SleepMode 3 = suspender, depois hibernar; acao 2 = hibernar.
configure_kde_hibernation() {
  local profile
  for profile in AC Battery LowBattery; do
    kwriteconfig6 --file powerdevilrc --group "$profile" --group SuspendAndShutdown --key SleepMode 3
  done
  kwriteconfig6 --file powerdevilrc --group LowBattery --group SuspendAndShutdown --key LidAction 2
  kwriteconfig6 --file powerdevilrc --group LowBattery --group SuspendAndShutdown --key AutoSuspendAction 2
  kwriteconfig6 --file powerdevilrc --group BatteryManagement --key BatteryCriticalAction 2
}

# Como nesta maquina: swapfile do tamanho da RAM + 2 GiB (no Btrfs, em um
# subvolume proprio /swap), prioridade abaixo do zram, resume= no kernel e
# suspensao que vira hibernacao apos 60 min (configs/system/hibernate.conf).
configure_hibernation() {
  local fstype swapfile size_gib uuid offset
  if grep -q '\[\(integrity\|confidentiality\)\]' /sys/kernel/security/lockdown 2>/dev/null; then
    warn 'kernel lockdown ativo (Secure Boot): o kernel bloqueia a hibernacao ate desativar o Secure Boot.'
  fi
  fstype="$(findmnt -no FSTYPE /)"
  size_gib=$(( ($(awk '/^MemTotal:/ { print $2 }' /proc/meminfo) + 1048575) / 1048576 + 2 ))
  case "$fstype" in
    btrfs) swapfile=/swap/swapfile ;;
    ext4|xfs) swapfile=/swapfile ;;
    *) warn "sistema de arquivos $fstype nao suportado para o swapfile; hibernacao ignorada."; return ;;
  esac

  if sudo test -e "$swapfile"; then
    printf 'Swapfile existente reaproveitado: %s\n' "$swapfile"
  elif [[ "$fstype" == btrfs ]]; then
    # O subvolume fica fora dos snapshots do /, e o mkswapfile cria o arquivo sem CoW.
    [[ -d /swap ]] || sudo btrfs subvolume create /swap
    sudo btrfs filesystem mkswapfile --size "${size_gib}g" "$swapfile"
  else
    sudo fallocate -l "${size_gib}G" "$swapfile"
    sudo chmod 0600 "$swapfile"
    sudo mkswap "$swapfile"
  fi

  # Sem o rotulo swapfile_t, o SELinux do Fedora impede o systemd de hibernar.
  if command_exists semanage && command_exists selinuxenabled && selinuxenabled; then
    sudo semanage fcontext -a -t swapfile_t "$swapfile" 2>/dev/null ||
      sudo semanage fcontext -m -t swapfile_t "$swapfile"
    sudo restorecon "$swapfile"
  fi

  if ! grep -Eq "^[[:space:]]*${swapfile}[[:space:]]" /etc/fstab; then
    printf '%s none swap defaults,pri=0 0 0\n' "$swapfile" | sudo tee -a /etc/fstab >/dev/null
    sudo systemctl daemon-reload
  fi
  swapon --show=NAME --noheadings | grep -Fxq "$swapfile" || sudo swapon --priority 0 "$swapfile"

  if [[ "$fstype" == btrfs ]]; then
    offset="$(sudo btrfs inspect-internal map-swapfile -r "$swapfile")"
  else
    offset="$(sudo filefrag -v "$swapfile" | awk '$1 == "0:" { sub(/\.\.$/, "", $4); print $4; exit }')"
  fi
  uuid="$(findmnt -no UUID -T "$swapfile")"
  [[ "$offset" =~ ^[0-9]+$ && -n "$uuid" ]] || die "Nao foi possivel calcular o resume do swapfile $swapfile."
  printf 'Swapfile: %s (%s GiB alvo), resume=UUID=%s resume_offset=%s\n' "$swapfile" "$size_gib" "$uuid" "$offset"

  sudo install -D -m 0644 "$CONFIG_DIR/system/hibernate.conf" /etc/systemd/sleep.conf.d/hibernate.conf
  RESUME_ARGS="resume=UUID=$uuid resume_offset=$offset"
  set_resume_kernel_args "$RESUME_ARGS"
  enable_resume_in_initramfs
  configure_kde_hibernation
}

grub_installed() {
  command_exists grub2-install || command_exists grub-install ||
    sudo test -d /boot/grub2 || sudo test -d /boot/grub
}

# Imprime o caminho da ESP se for seguro trocar o GRUB pelo systemd-boot. O
# systemd-boot exige UEFI, e o das distros nao e assinado (nao roda com Secure Boot).
systemd_boot_preflight() {
  local esp size_mib sb_var=/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d0-aa0d-00e098032b8c
  if [[ ! -d /sys/firmware/efi ]]; then
    warn 'boot em modo BIOS: o systemd-boot exige UEFI; GRUB mantido.'
    return 1
  fi
  if [[ -r "$sb_var" && "$(tail -c 1 "$sb_var" | od -An -tu1 | tr -d ' ')" == 1 ]]; then
    warn 'Secure Boot ativo: o systemd-boot da distro nao e assinado; GRUB mantido.'
    return 1
  fi
  if ! esp="$(sudo bootctl --print-esp-path 2>/dev/null)"; then
    warn 'ESP nao encontrada; GRUB mantido.'
    return 1
  fi
  # Os kernels e initramfs passam a ficar na ESP.
  size_mib="$(sudo df -BM --output=size "$esp" | tail -n 1 | tr -dc '0-9')"
  if (( size_mib < 500 )); then
    warn "ESP com ${size_mib} MiB (minimo 500 MiB para os kernels); GRUB mantido."
    return 1
  fi
  printf '%s\n' "$esp"
}

# Linha de comando atual sem os parametros que so o GRUB acrescenta. A hibernacao
# roda antes da troca, e o resume= dela ainda nao esta no kernel em execucao.
write_kernel_cmdline() {
  local cmdline
  [[ -f /etc/kernel/cmdline ]] && return
  cmdline="$(sed -E 's/(^|[[:space:]])(BOOT_IMAGE|initrd)=[^[:space:]]*//g; s/^[[:space:]]+//' /proc/cmdline)"
  if [[ -n "$RESUME_ARGS" ]]; then
    cmdline="$(sed -E 's/(^|[[:space:]])resume(_offset)?=[^[:space:]]*//g; s/[[:space:]]+$//' <<<"$cmdline") $RESUME_ARGS"
  fi
  sudo install -d /etc/kernel
  printf '%s\n' "$cmdline" | sudo tee /etc/kernel/cmdline >/dev/null
}

# Depois de remover os pacotes do GRUB: apaga os restos dele e do shim e reinstala
# o systemd-boot (a remocao do shim leva junto o EFI/BOOT/BOOTX64.EFI).
# Nao toca em EFI/Microsoft, EFI/systemd, EFI/Linux nem nos kernels da /boot.
finish_systemd_boot_migration() {
  local esp="$1" entry
  if sudo grep -qsi windows /boot/grub2/grub.cfg /boot/grub/grub.cfg "$esp"/EFI/*/grub.cfg &&
     ! sudo test -d "$esp/EFI/Microsoft"; then
    warn 'o GRUB listava um Windows fora desta ESP; o systemd-boot nao o detecta. Use o menu de boot da firmware.'
  fi
  sudo find "$esp/EFI" -mindepth 2 -maxdepth 3 -type f -not -ipath "$esp/EFI/Microsoft/*" \
    \( -iname 'grub*' -o -iname 'shim*.efi' -o -iname 'mm*.efi' -o -iname 'fb*.efi' \
       -o -iname 'BOOT*.CSV' -o -iname '*.pf2' \) -delete
  sudo find "$esp/EFI" -mindepth 1 -depth -type d -empty -delete
  sudo rm -rf /boot/grub /boot/grub2
  # initramfs no formato do GRUB; o systemd-boot usa os da ESP.
  sudo find /boot -maxdepth 1 -type f -name 'initramfs-*.img' -delete
  if [[ "$esp" != /boot ]]; then sudo rm -rf /boot/loader; fi
  if ! command_exists grub2-mkconfig && ! command_exists grub-mkconfig; then
    sudo rm -f /etc/default/grub /etc/default/grub.rpmsave /etc/default/grub.pacsave
  fi
  # Entradas da firmware que apontam para o GRUB ou o shim.
  while read -r entry; do
    sudo efibootmgr -q -b "$entry" -B
  done < <(efibootmgr | sed -nE 's/^Boot([0-9A-Fa-f]{4})\*?[[:space:]].*\\(grub|shim)[^\\]*\.efi.*/\1/Ip')
  sudo bootctl install
  sudo systemctl enable systemd-boot-update.service
  printf 'systemd-boot instalado em %s; GRUB removido.\n' "$esp"
}

# So no Fedora: RPM gerado do tarball oficial, mais o timer obsidian-rpm-update.
install_obsidian_rpm() {
  bash "$SCRIPT_DIR/instalar-obsidian.sh" --instalar-atualizador
}

# So no Fedora: builder de https://github.com/dewzor/claude-desktop-fedora na
# revisao f9f3faa5, a mesma revisada e compilada nesta maquina em 30/10/2026.
# O builder verifica o apt assinado da Anthropic, reempacota o .deb oficial e
# instala claude-desktop-update.timer, que repete isso uma vez por dia.
CLAUDE_BUILDER_SOURCE=claude-desktop/claude-desktop-fedora-22404142.tar.gz
CLAUDE_BUILDER_SHA256=72d0abc21474bddac66e4d1738b93939b15fd56ce6f238aaa1f20b6445df31b4
install_claude_desktop() (
  local tmp builder
  printf '%s  %s\n' "$CLAUDE_BUILDER_SHA256" "$CONFIG_DIR/$CLAUDE_BUILDER_SOURCE" | sha256sum --check --status ||
    die "SHA-256 inesperado em configs/$CLAUDE_BUILDER_SOURCE"
  tmp="$(mktemp -d -t claude-desktop.XXXXXXXX)"
  trap 'rm -rf -- "$tmp"' EXIT
  sudo dnf install -y rpm-build systemd-rpm-macros
  tar -xzf "$CONFIG_DIR/$CLAUDE_BUILDER_SOURCE" -C "$tmp"
  bash "$tmp/copr/make-srpm.sh"
  rpmbuild --define "_topdir $tmp/rpmbuild" --rebuild "$tmp"/copr/build/SRPMS/claude-desktop-builder-*.src.rpm
  builder="$(find "$tmp/rpmbuild/RPMS" -type f -name 'claude-desktop-builder-*.noarch.rpm' -print -quit)"
  [[ -n "$builder" ]] || die 'O RPM claude-desktop-builder nao foi gerado.'
  sudo dnf install -y "$builder"
  # O timer dispara logo apos o boot ou o resume, quando o DNS pode falhar.
  sudo install -D -m 0644 "$CONFIG_DIR/claude-desktop/update-retry.conf" \
    /etc/systemd/system/claude-desktop-update.service.d/retry.conf
  sudo systemctl daemon-reload
  sudo systemctl enable --now claude-desktop-update.timer
  # Ferramentas de virtualizacao usadas pelo Cowork.
  sudo dnf install -y qemu-system-x86-core edk2-ovmf virtiofsd
  # Primeiro ciclo: baixa, verifica, reempacota e instala o aplicativo.
  sudo env TMPDIR=/var/tmp claude-desktop-update
  rpm -q claude-desktop
)

# So no Fedora com Cutefish: o Ghostty do Mac, que roda pelo Reef. Pega o DMG da
# versao estavel mais nova no appcast oficial e extrai o Ghostty.app com o 7z,
# sem montar a imagem. /Applications e criada pelo build do Cutefish; se faltar,
# e criada aqui do mesmo jeito (root:wheel 2775, rotulo SELinux usr_t).
install_ghostty_app() (
  local tmp url
  url="$(curl -fsSL --retry 3 https://release.files.ghostty.org/appcast.xml |
    grep -oE 'https://release\.files\.ghostty\.org/[0-9]+\.[0-9]+\.[0-9]+/Ghostty\.dmg' |
    sort -uV | tail -n 1)" || true
  [[ -n "$url" ]] || die 'Nenhum Ghostty.dmg encontrado no appcast do Ghostty.'
  printf 'Ghostty: %s\n' "$url"
  tmp="$(mktemp -d -t ghostty.XXXXXXXX)"
  trap 'rm -rf -- "$tmp"' EXIT
  curl -fL --retry 3 -o "$tmp/Ghostty.dmg" "$url"
  7z x -y "-o$tmp/dmg" "$tmp/Ghostty.dmg" >/dev/null
  [[ -x "$tmp/dmg/Ghostty.app/Contents/MacOS/ghostty" ]] || die 'Ghostty.app nao encontrado no DMG.'
  if [[ ! -d /Applications ]]; then
    sudo install -d -m 2775 -o root -g wheel /Applications
    sudo semanage fcontext -a -t usr_t '/Applications(/.*)?' 2>/dev/null || true
  fi
  # O usuario esta no grupo wheel, dono da pasta, como quando o Files instala um app.
  sudo rm -rf /Applications/Ghostty.app
  sudo install -d -m 2775 -o "$USER" -g wheel /Applications/Ghostty.app
  cp -a "$tmp/dmg/Ghostty.app/." /Applications/Ghostty.app/
  sudo restorecon -R /Applications 2>/dev/null || true
)

# Nightly mais recente de https://github.com/ardia-browser/ardia. O tar.xz para Linux
# traz o install.sh oficial, que instala em /usr/lib/ardia com lancador e icone e
# registra a acao do polkit usada pelo atualizador do proprio Ardia.
install_ardia_nightly() (
  local releases url tmp name
  # /releases/latest ignora prereleases, e as releases "Engine" ocupam boa parte da lista.
  releases="$(curl -fsSL --retry 3 'https://api.github.com/repos/ardia-browser/ardia/releases?per_page=100')"
  url="$(grep -oE 'https://github\.com/ardia-browser/ardia/releases/download/v[^"/]*-nightly[^"/]*/Ardia-[^"/]*-linux-x64\.tar\.xz' <<< "$releases" |
    head -n 1)" || true
  [[ -n "$url" ]] || die 'Nenhuma nightly do Ardia para Linux encontrada.'
  name="${url##*/}"
  printf 'Ardia Nightly: %s\n' "$name"
  tmp="$(mktemp -d -t ardia.XXXXXXXX)"
  trap 'rm -rf -- "$tmp"' EXIT
  curl -fL --retry 3 -o "$tmp/$name" "$url"
  curl -fsSL --retry 3 -o "$tmp/$name.sha256" "$url.sha256"
  (cd "$tmp" && sha256sum --check --status "$name.sha256") || die "SHA-256 inesperado em $name"
  tar -xJf "$tmp/$name" -C "$tmp"
  [[ -f "$tmp/ardia/install.sh" ]] || die "install.sh nao encontrado em $name"
  sudo bash "$tmp/ardia/install.sh"
  [[ -x /usr/lib/ardia/ardia-launch ]] || die "Ardia nao foi instalado em /usr/lib/ardia."
)

refresh_desktop_database() {
  if command_exists update-desktop-database; then
    update-desktop-database "$DATA_HOME/applications"
  fi
}

# Extrai DMG -> PKG (XAR) -> Payload (gzip/cpio), sem executar o instalador macOS.
install_apple_font() (
  local family="$1" tmp package payload index=0
  local -a packages payloads font_files
  tmp="$(mktemp -d -t apple-fonts.XXXXXXXX)"
  trap 'rm -rf -- "$tmp"' EXIT
  curl -fL --retry 3 -o "$tmp/$family.dmg" \
    "https://devimages-cdn.apple.com/design/resources/download/$family.dmg"
  7z x -y "-o$tmp/dmg" "$tmp/$family.dmg" >/dev/null
  mapfile -d '' packages < <(find "$tmp/dmg" -type f -name '*.pkg' -print0)
  (( ${#packages[@]} )) || die "Pacote Apple nao encontrado: $family"
  for package in "${packages[@]}"; do
    index=$((index + 1))
    7z x -y "-o$tmp/pkg/$index" "$package" >/dev/null
  done
  mapfile -d '' payloads < <(find "$tmp/pkg" -type f -name Payload -print0)
  (( ${#payloads[@]} )) || die "Payload Apple nao encontrado: $family"
  install -d "$tmp/fonts"
  for payload in "${payloads[@]}"; do
    (cd "$tmp/fonts" && gzip -dc "$payload" | cpio -id --quiet --no-absolute-filenames)
  done
  mapfile -d '' font_files < <(find "$tmp/fonts" -type f \( -iname '*.otf' -o -iname '*.ttf' \) -print0)
  (( ${#font_files[@]} )) || die "Nenhuma fonte extraida: $family"
  install -d "$DATA_HOME/fonts/Apple/$family"
  install -m 0644 "${font_files[@]}" "$DATA_HOME/fonts/Apple/$family/"
  fc-cache -f "$DATA_HOME/fonts/Apple/$family"
)

verify_fonts() {
  local family families
  families="$(fc-list -f '%{family}\n' | tr ',' '\n')"
  for family in 'SF Pro' 'SF Pro Text' 'SF Mono' 'JetBrainsMono Nerd Font Mono'; do
    grep -Fxq -- "$family" <<< "$families" || die "Fonte necessaria nao encontrada: $family"
  done
}

apply_kde_fonts() {
  local line group=''
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    case "$line" in
      \[*\]) group="${line:1:-1}" ;;
      *=*) kwriteconfig6 --file kdeglobals --group "$group" --key "${line%%=*}" "${line#*=}" ;;
    esac
  done < "$CONFIG_DIR/fonts/kdeglobals"
  install -d "$CONFIG_HOME/fontconfig/conf.d"
  install -m 0644 "$CONFIG_DIR/fonts/99-apple-rendering.conf" "$CONFIG_HOME/fontconfig/conf.d/"
}

configure_kde() {
  # Desativa o popup de diacriticos do Plasma: corrige os acentos na digitacao rapida.
  kwriteconfig6 --file plasmakeyboardrc --group General \
    --key diacriticsPopupEnabled --type bool --notify false

  # Seletor de arquivos do KDE nas janelas de abrir/salvar de todos os aplicativos.
  # kde-portals.conf do usuario tem precedencia sobre o do sistema.
  install -d "$CONFIG_HOME/xdg-desktop-portal"
  cat > "$CONFIG_HOME/xdg-desktop-portal/kde-portals.conf" <<'PORTAL_CONFIG'
[preferred]
default=kde
org.freedesktop.impl.portal.Settings=kde;gtk;
org.freedesktop.impl.portal.Secret=kwallet
org.freedesktop.impl.portal.Notification=plasmanotify
org.freedesktop.impl.portal.FileChooser=kde;
PORTAL_CONFIG
  if systemctl --user is-active --quiet xdg-desktop-portal.service; then
    systemctl --user restart xdg-desktop-portal.service
  fi

  install -d "$CONFIG_HOME/ghostty"
  install -m 0644 "$CONFIG_DIR/ghostty/config" "$CONFIG_HOME/ghostty/config"
}

# Copia o lancador do pacote para o escopo do usuario (mesmo desktop ID, que
# prevalece apos updates) e acrescenta as flags de GPU em todas as acoes.
configure_edge_launcher() {
  local system_desktop=/usr/share/applications/microsoft-edge.desktop
  if [[ ! -r "$system_desktop" ]]; then
    warn "$system_desktop nao foi encontrado; flags de GPU do Edge ignoradas."
    return
  fi
  install -d "$DATA_HOME/applications"
  awk -v flags="$EDGE_FLAGS" '
    /^Exec=/ {
      separator = index($0, " ")
      if (separator > 0) print substr($0, 1, separator - 1) " " flags substr($0, separator)
      else print $0 " " flags
      next
    }
    { print }
  ' "$system_desktop" > "$DATA_HOME/applications/microsoft-edge.desktop"
  refresh_desktop_database
}

# Usa o AppImage intacto e gravavel pelo usuario: o updater do T3 Code so funciona
# com AppImage/DEB (o pacote AUR extrai o AppImage e perde as atualizacoes pela interface).
# Fonte: https://github.com/pingdotgg/t3code/blob/main/apps/desktop/src/updates/DesktopUpdates.ts
install_t3code_nightly() {
  local releases url install_dir="$DATA_HOME/t3code-nightly"
  # /releases/latest ignora prereleases; a API lista da release mais nova para a mais antiga.
  releases="$(curl -fsSL --retry 3 'https://api.github.com/repos/pingdotgg/t3code/releases?per_page=30')"
  url="$(grep -o 'https://[^"]*/download/v[^"/]*-nightly[^"/]*/T3-Code-[^"/]*x86_64\.AppImage' <<< "$releases")" ||
    die 'Nenhuma nightly do T3 Code encontrada.'
  url="${url%%$'\n'*}"
  printf 'T3 Code Nightly: %s\n' "${url##*/}"

  install -d "$install_dir" "$DATA_HOME/applications"
  curl -fL --retry 3 -o "$install_dir/T3-Code-Nightly.AppImage" "$url"
  chmod 0755 "$install_dir/T3-Code-Nightly.AppImage"
  curl -fsSL --retry 3 -o "$install_dir/icon.png" \
    https://raw.githubusercontent.com/pingdotgg/t3code/main/assets/nightly/nightly-universal-1024.png
  # MimeType registra o t3code:// usado pelo aplicativo.
  cat > "$DATA_HOME/applications/t3code-nightly.desktop" <<T3CODE_DESKTOP
[Desktop Entry]
Name=T3 Code Nightly
Comment=Interface para agentes de programacao
Exec="$install_dir/T3-Code-Nightly.AppImage" %U
Terminal=false
Type=Application
Icon=$install_dir/icon.png
StartupWMClass=t3code
Categories=Development;
MimeType=x-scheme-handler/t3code;
T3CODE_DESKTOP
  refresh_desktop_database
  printf '%s\n' 'T3 Code Nightly instalado. Atualize pela interface do aplicativo; mantenha o canal nightly.'
}

# O Claude Code fica em ~/.local/bin.
ensure_local_bin_in_path() {
  # shellcheck disable=SC2016
  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  export PATH="$HOME/.local/bin:$PATH"
  if ! grep -Fqx "$path_line" "$HOME/.bashrc" 2>/dev/null; then
    printf '\n%s\n' "$path_line" >> "$HOME/.bashrc"
  fi
}

# Etapas iguais nas duas distros, depois dos pacotes do sistema instalados.
install_user_apps_and_configs() {
  ensure_local_bin_in_path

  log 'Instalando SF Pro e SF Mono da Apple'
  install_apple_font SF-Pro
  install_apple_font SF-Mono
  verify_fonts

  log 'Aplicando fontes e suavizacao do KDE'
  apply_kde_fonts

  log 'Aplicando acentos, seletor de arquivos e Ghostty'
  configure_kde

  log 'Configurando o lancador do Microsoft Edge com aceleracao por GPU'
  configure_edge_launcher

  log 'Instalando o Stremio pelo Flathub'
  flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
  flatpak install --user -y flathub com.stremio.Stremio//stable

  log 'Instalando a nightly mais recente do T3 Code'
  install_t3code_nightly

  if (( INSTALL_ARDIA )); then
    log 'Instalando a nightly mais recente do Ardia'
    install_ardia_nightly
  fi

  log 'Instalando o Claude Code pelo instalador nativo'
  # Instalador geral para Linux: https://code.claude.com/docs/en/setup
  curl -fsSL https://claude.ai/install.sh | bash
  hash -r
  claude --version
  # Computer-use do Cutefish (compilado por cutefish-fedora-build.sh), se presente.
  if [[ -x /usr/bin/cutefish-computer-use ]] && ! claude mcp get cutefish >/dev/null 2>&1; then
    claude mcp add -s user cutefish -- /usr/bin/cutefish-computer-use
  fi
}

finish_message() {
  log 'Concluido'
  printf '%s\n' 'Para entrar na conta, execute: claude'
  printf '%s\n' 'Reinicie para aplicar o Fn Lock, as fontes, os acentos e o seletor de arquivos do KDE.'
  if (( ENABLE_HIBERNATION )); then
    printf '%s\n' 'Depois de reiniciar, teste a hibernacao com: systemctl hibernate'
  fi
  printf '%s\n' 'Confira vainfo e edge://gpu para validar a aceleracao de video.'
}
