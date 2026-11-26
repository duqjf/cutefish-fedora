#!/usr/bin/env bash
set -euo pipefail

# Instala os programas e configuracoes desta maquina no pearOS/Arch com KDE Plasma 6.
# Execute como usuario normal, depois de instalar o sistema.
# Uso: bash reinstalar-arch.sh [--hibernacao | --sem-hibernacao] [--ardia | --sem-ardia]

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
# shellcheck source=comum.sh
. "$SCRIPT_DIR/comum.sh"

# shellcheck disable=SC1091
. /etc/os-release
os_ids="${ID:-} ${ID_LIKE:-}"
case "${os_ids,,}" in
  *arch*|*pearos*) ;;
  *) die "Este script foi feito para Arch/pearOS, nao para ${ID:-desconhecido}." ;;
esac
# Nenhum arquivo de configuracao adicional e exigido no Arch.
# shellcheck disable=SC2119
check_common
parse_options "$@"
sudo -v

log 'Removendo aplicativos padrao dispensados'
# Antes da atualizacao, para nao baixar updates de pacotes que serao removidos.
# Sem remocao forcada: se o pearOS depender de um deles, o pacote fica.
for package in firefox kate okular kwrite; do
  if pacman -Q "$package" >/dev/null 2>&1; then
    sudo pacman -R "$package" || warn "$package mantido: remocao impedida por dependencias."
  fi
done

log 'Atualizando o sistema completo'
# Arch nao suporta atualizacao parcial.
sudo pacman -Syu

log 'Instalando codecs, aceleracao de video Intel e pacotes do sistema'
# O base-devel tambem traz o objcopy que monta a UKI na troca para o systemd-boot.
sudo pacman -S --needed \
  7zip cpio curl gzip tar xz git base-devel fontconfig noto-fonts-cjk fuse2 gtk3 nss alsa-lib kconfig \
  flatpak desktop-file-utils xdg-utils xorg-xwayland xdg-desktop-portal xdg-desktop-portal-kde \
  ffmpeg libva libva-utils mesa intel-media-driver libva-intel-driver \
  gstreamer gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav gst-plugin-va

log 'Disponibilizando portugues brasileiro'
if ! grep -Eq '^[[:space:]]*pt_BR\.UTF-8[[:space:]]+UTF-8' /etc/locale.gen; then
  printf '\npt_BR.UTF-8 UTF-8\n' | sudo tee -a /etc/locale.gen >/dev/null
fi
sudo locale-gen

log 'Instalando aplicativos'
sudo pacman -S --needed \
  gnome-calculator gnome-text-editor gwenview haruna mpv dolphin papers qbittorrent \
  kimageformats qt6-imageformats libheif libavif keyd ttf-jetbrains-mono-nerd obsidian ghostty

log 'Instalando Helium e Microsoft Edge pelo AUR'
if command_exists paru; then
  aur_helper=paru
else
  aur_helper=yay
  if ! command_exists yay; then
    yay_tmp="$(mktemp -d -t yay.XXXXXXXX)"
    git clone --depth 1 https://aur.archlinux.org/yay.git "$yay_tmp"
    (cd "$yay_tmp" && makepkg -si)
    rm -rf -- "$yay_tmp"
  fi
fi
"$aur_helper" -S --needed helium-browser-bin microsoft-edge-stable-bin

log 'Aplicando a correcao do Caps Lock com o keyd'
configure_keyd

log 'Configurando o Fn Lock ASUS'
configure_asus_fnlock

install_user_apps_and_configs

if (( ENABLE_HIBERNATION )); then
  log 'Ativando a hibernacao'
  # Antes da troca de bootloader, que leva o resume= para o systemd-boot.
  if [[ "$(findmnt -no FSTYPE /)" == btrfs ]]; then sudo pacman -S --needed btrfs-progs; fi
  configure_hibernation
fi

if grub_installed && esp="$(systemd_boot_preflight)"; then
  log 'Trocando o GRUB pelo systemd-boot'
  # Por ultimo: se falhar, todo o resto ja esta instalado.
  write_kernel_cmdline
  # O GRUB carregava o microcode a parte; na UKI ele entra pelo hook microcode.
  if ! grep -Eq '^HOOKS=.*\bmicrocode\b' /etc/mkinitcpio.conf; then
    sudo sed -i -E '/^HOOKS=/ s/\bautodetect\b/autodetect microcode/' /etc/mkinitcpio.conf
  fi
  # Cada kernel vira uma UKI em EFI/Linux, que o systemd-boot encontra sozinho e o
  # mkinitcpio atualiza a cada kernel novo. So o preset default, para caber na ESP.
  sudo install -d "$esp/EFI/Linux"
  for preset in /etc/mkinitcpio.d/*.preset; do
    sudo sed -i -E \
      -e 's/^([[:space:]]*(default|fallback)_image=)/#\1/' \
      -e '/^[[:space:]]*#?[[:space:]]*(default|fallback)_uki=/d' \
      -e "s/^PRESETS=.*/PRESETS=('default')/" "$preset"
    printf 'default_uki="%s/EFI/Linux/arch-%s.efi"\n' "$esp" "$(basename "$preset" .preset)" |
      sudo tee -a "$preset" >/dev/null
  done
  # Sem mexer na ordem de boot ate as UKIs existirem: se algo falhar, o GRUB continua.
  sudo bootctl install --no-variables
  sudo mkinitcpio -P
  sudo find "$esp/EFI/Linux" -name 'arch-*.efi' -print -quit | grep -q . ||
    die 'Nenhuma UKI gerada em EFI/Linux; o GRUB continua como bootloader.'
  sudo bootctl install

  # Sem -s: dependencias que o GRUB puxou continuam instaladas.
  mapfile -t grub_packages < <(pacman -Qq | grep -E 'grub|^os-prober$' || true)
  if (( ${#grub_packages[@]} )); then
    sudo pacman -Rn "${grub_packages[@]}" ||
      warn "pacotes do GRUB mantidos, outros pacotes dependem deles: ${grub_packages[*]}"
  fi
  finish_systemd_boot_migration "$esp"
fi

finish_message
