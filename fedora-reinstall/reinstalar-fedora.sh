#!/usr/bin/env bash
set -euo pipefail

# Instala os programas e configuracoes desta maquina no Fedora KDE.
# Inventario capturado em 2026-08-27 no Fedora 44. Execute como usuario normal.
# Uso: bash reinstalar-fedora.sh [--hibernacao | --sem-hibernacao]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=comum.sh
. "$SCRIPT_DIR/comum.sh"

# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == fedora ]] || die "Este script foi feito para Fedora, nao para ${ID:-desconhecido}."
[[ -r "$SCRIPT_DIR/instalar-obsidian.sh" ]] || die 'Leve tambem instalar-obsidian.sh junto com os scripts.'
check_common system/dnf.conf system/microsoft-edge.repo obsidian/obsidian.spec \
  obsidian/obsidian-rpm-update.service obsidian/obsidian-rpm-update.timer \
  claude-desktop/update-retry.conf "$CLAUDE_BUILDER_SOURCE"
ask_hibernation "${1:-}"
sudo -v

log 'Aplicando a configuracao personalizada do DNF'
sudo install -m 0644 "$CONFIG_DIR/system/dnf.conf" /etc/dnf/dnf.conf
sudo dnf install -y dnf5-plugins curl flatpak

log 'Ativando RPM Fusion, COPR do Helium e o repositorio oficial do Microsoft Edge'
fedora_release="$(rpm -E %fedora)"
sudo dnf install -y \
  "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_release}.noarch.rpm" \
  "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_release}.noarch.rpm"
sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1
sudo dnf copr enable -y imput/helium
sudo install -m 0644 "$CONFIG_DIR/system/microsoft-edge.repo" /etc/yum.repos.d/microsoft-edge.repo

log 'Removendo aplicativos padrao dispensados'
# Antes da atualizacao, para nao baixar updates de pacotes que serao removidos.
to_remove=()
for package in firefox kate okular kwrite nautilus xdg-desktop-portal-gnome; do
  if rpm -q "$package" >/dev/null 2>&1; then to_remove+=("$package"); fi
done
if (( ${#to_remove[@]} )); then sudo dnf remove -y "${to_remove[@]}"; fi

log 'Atualizando o sistema antes das instalacoes'
sudo dnf upgrade --refresh -y
sudo dnf update -y @core
sudo dnf install -y 'rpmfusion-*-appstream-data'

log 'Instalando codecs, aceleracao de video Intel e pacotes do sistema'
# Antes dos aplicativos, para que eles ja usem o FFmpeg completo do RPM Fusion.
sudo dnf swap -y ffmpeg-free ffmpeg --allowerasing
sudo dnf group install -y sound-and-video
sudo dnf install -y ffmpeg-libs libva libva-utils
sudo dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing
sudo dnf install -y libva-intel-driver
sudo dnf install -y \
  7zip cpio gzip tar xz fontconfig fuse-libs gtk3 nss alsa-lib kf6-kconfig gcc make git \
  langpacks-pt_BR xdg-desktop-portal-kde

log 'Instalando aplicativos RPM'
sudo dnf install -y \
  gnome-calculator gnome-text-editor gwenview haruna dolphin papers qbittorrent \
  helium-bin microsoft-edge-stable

log 'Gerando o RPM do Obsidian e instalando o atualizador automatico'
install_obsidian_rpm

log 'Compilando o Claude Desktop a partir do build oficial para Linux'
install_claude_desktop

log 'Compilando o keyd e aplicando a correcao do Caps Lock'
# Versao testada nesta maquina: keyd v2.6.0 (7c0aecb). https://github.com/rvaiya/keyd
keyd_tmp="$(mktemp -d -t keyd.XXXXXXXX)"
git clone --depth 1 --branch v2.6.0 https://github.com/rvaiya/keyd.git "$keyd_tmp"
make -C "$keyd_tmp"
sudo make -C "$keyd_tmp" install
rm -rf -- "$keyd_tmp"
sudo systemctl daemon-reload
configure_keyd

log 'Configurando o Fn Lock ASUS'
configure_asus_fnlock

log 'Instalando a JetBrainsMono Nerd Font'
install -d "$DATA_HOME/fonts/JetBrainsMono"
curl -fsSL https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz |
  tar -xJ -C "$DATA_HOME/fonts/JetBrainsMono"
fc-cache -f "$DATA_HOME/fonts/JetBrainsMono"

install_user_apps_and_configs

if (( ENABLE_HIBERNATION )); then
  log 'Ativando a hibernacao'
  # Antes da troca de bootloader, que leva o resume= para o systemd-boot.
  sudo dnf install -y btrfs-progs policycoreutils-python-utils
  configure_hibernation
fi

if grub_installed && esp="$(systemd_boot_preflight)"; then
  log 'Trocando o GRUB pelo systemd-boot'
  # Por ultimo: se falhar, todo o resto ja esta instalado.
  sudo dnf install -y systemd-boot-unsigned
  write_kernel_cmdline
  printf 'layout=bls\nBOOT_ROOT=%s\n' "$esp" | sudo tee /etc/kernel/install.conf >/dev/null
  # Sem mexer na ordem de boot ate as entradas existirem: se algo falhar, o GRUB continua.
  sudo bootctl install --no-variables
  for kernel_dir in /lib/modules/*/; do
    if [[ -f "$kernel_dir/vmlinuz" ]]; then
      sudo kernel-install add "$(basename "$kernel_dir")" "$kernel_dir/vmlinuz"
    fi
  done
  sudo find "$esp/loader/entries" -name "*$(uname -r).conf" -print -quit | grep -q . ||
    die 'Entrada do systemd-boot nao criada; o GRUB continua como bootloader.'
  sudo bootctl install

  # rpm -e --test garante que nenhum outro pacote depende dos removidos, e
  # clean_requirements_on_remove=False impede que o dnf leve dependencias junto.
  mapfile -t grub_packages < <(rpm -qa --qf '%{NAME}\n' 'grub2*' 'shim*' os-prober grub-customizer | sort -u)
  if (( ${#grub_packages[@]} )); then
    if sudo rpm -e --test "${grub_packages[@]}"; then
      sudo dnf remove -y --setopt=clean_requirements_on_remove=False "${grub_packages[@]}"
    else
      warn "pacotes do GRUB mantidos, outros pacotes dependem deles: ${grub_packages[*]}"
    fi
  fi
  if rpm -q grubby >/dev/null 2>&1; then
    if sudo rpm -e --test grubby 2>/dev/null; then
      sudo dnf remove -y --setopt=clean_requirements_on_remove=False grubby
    else
      warn 'grubby mantido: outro pacote depende dele (por exemplo, akmods do driver NVIDIA).'
    fi
  fi
  finish_systemd_boot_migration "$esp"
fi

log 'Limpando o cache do DNF'
sudo dnf clean all

finish_message
