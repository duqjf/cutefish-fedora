# Reinstalação dos programas no Fedora ou no pearOS/Arch

Instaladores para um sistema recém-instalado com KDE Plasma 6 (no Fedora, também com o Cutefish). Instalam os aplicativos e aplicam as configurações pessoais desta máquina. Não fazem backup das configurações existentes, porque partem de uma instalação limpa.

Leve a pasta inteira (`comum.sh`, os scripts e `configs/`, incluindo `instalar-obsidian.sh`) e execute como usuário normal, sem sudo, dentro da sessão gráfica:

```bash
bash reinstalar-fedora.sh   # Fedora KDE ou Cutefish
bash reinstalar-arch.sh     # pearOS / Arch
```

No início, o script pergunta se deve ativar a hibernação e se deve instalar a nightly do navegador Ardia. Para pular as perguntas, use `--hibernacao` ou `--sem-hibernacao` e `--ardia` ou `--sem-ardia`.

No Fedora, o desktop vem de `XDG_CURRENT_DESKTOP` (Cutefish ou, por padrão, KDE); `--kde` ou `--cutefish` forçam um deles. No Cutefish, os aplicativos de desktop (Editor de Texto e Calculadora do GNOME, Gwenview, Haruna, Dolphin, Papers e qBittorrent) não são instalados, porque o Cutefish traz os próprios, e o Ghostty.app do Mac é baixado para `/Applications`. O resto é igual.

## Ordem das etapas

1. Pergunta sobre a hibernação e o Ardia e pede a senha do sudo. O sudo pode pedi-la novamente após uma compilação demorada; no Arch continuam as confirmações do pacman.
2. No Fedora, ativa o RPM Fusion, o COPR do Helium e o repositório do Edge.
3. Remove os aplicativos dispensados antes da atualização, para não baixar updates deles.
4. Atualiza o sistema inteiro.
5. Instala os codecs e os pacotes do sistema, antes dos aplicativos, para que eles já usem o FFmpeg completo.
6. No Fedora, gera e instala os RPMs do Obsidian e do Claude Desktop com seus atualizadores; depois instala o keyd, o Fn Lock, as fontes e as configurações do KDE.
7. Ativa a hibernação, se escolhida.
8. Se houver GRUB, troca pelo systemd-boot. Fica por último para que uma falha não impeça o resto; o `resume=` da etapa anterior é levado para o systemd-boot.

## Estrutura

- `comum.sh`: etapas iguais nas duas distros (fontes Apple, KDE, portal, Ghostty, Edge, Stremio, T3 Code, Ardia, Claude Code, keyd, Fn Lock, hibernação e troca do GRUB pelo systemd-boot).
- `reinstalar-fedora.sh`: DNF, RPM Fusion, COPR do Helium, repositório do Edge, codecs, compilação do keyd v2.6.0 e Nerd Font baixada do GitHub.
- `instalar-obsidian.sh`: no Fedora, gera um RPM do Obsidian a partir do tarball oficial (spec em `configs/obsidian/`, baseada em [idhirandar/obsidian-rpm-fedora](https://github.com/idhirandar/obsidian-rpm-fedora)) e instala o atualizador automático.
- `reinstalar-arch.sh`: `pacman -Syu`, pacotes nativos (incluindo `keyd`, `ghostty` e `ttf-jetbrains-mono-nerd`), Helium/Edge pelo AUR (usa paru ou yay; instala yay se não houver nenhum) e locale `pt_BR.UTF-8`. Mantém os prompts do pacman.

## O que é instalado

Helium, Microsoft Edge, Ardia Nightly (opcional), Ghostty (no Arch, o pacote; no Fedora com Cutefish, o app do Mac), Obsidian, Claude Desktop (só no Fedora), Claude Code, T3 Code Nightly, Stremio (Flathub, stable, escopo do usuário), qBittorrent, Haruna/mpv, Papers, Dolphin, Editor de Texto e Calculadora do GNOME e Gwenview (esses sete só no KDE), codecs FFmpeg/GStreamer e drivers VA-API Intel.

Remove Firefox, Kate, Okular e KWrite; no Fedora, também Nautilus e `xdg-desktop-portal-gnome`. No Arch, um pacote do qual o pearOS dependa é mantido, com aviso.

- **Claude Code:** instalador nativo geral para Linux (`curl -fsSL https://claude.ai/install.sh | bash`), em `~/.local/bin/claude`, com atualização automática. Para entrar na conta, execute `claude` depois da instalação. [Documentação](https://code.claude.com/docs/en/setup). Se o computer-use do Cutefish já estiver em `/usr/bin/cutefish-computer-use` (compilado pelo `cutefish-fedora-build.sh`), registra-o como servidor MCP `cutefish` no escopo do usuário.
- **Ardia Nightly (opcional):** procura nas releases de [ardia-browser/ardia](https://github.com/ardia-browser/ardia) a nightly mais recente (`vX.Y.Z-nightly.N`), baixa `Ardia-…-linux-x64.tar.xz`, confere o `.sha256` publicado junto e roda o `install.sh` que vem dentro dele, com sudo. Fica em `/usr/lib/ardia`, com `/usr/bin/ardia`, lançador e ícone; o próprio Ardia se atualiza pelo polkit.
- **T3 Code Nightly:** baixa o AppImage x86_64 da nightly mais recente no GitHub e o mantém intacto em `~/.local/share/t3code-nightly/`, para que o updater da interface funcione. Cria o atalho no menu e registra o link `t3code://`.
- **Ghostty:** no Arch, pacote `ghostty` do repositório oficial. No Fedora com Cutefish, baixa o `Ghostty.dmg` da versão estável mais nova do appcast oficial, extrai o `Ghostty.app` com o 7z (sem montar a imagem) e o coloca em `/Applications`, onde o Reef o roda. No Fedora com KDE não é instalado. A configuração `configs/ghostty/config` é copiada nas duas distros, porque o Ghostty do Mac também lê `~/.config/ghostty/config`.
- **Obsidian:** no Fedora, `instalar-obsidian.sh` consulta a última release de `obsidianmd/obsidian-releases`, baixa `obsidian-X.Y.Z.tar.gz`, confere o SHA-256 publicado pelo GitHub e gera o RPM em `/usr/lib64/obsidian`, com lançador e ícone. O timer de sistema `obsidian-rpm-update.timer` roda 10 min após o boot e a cada 12 h, e só reconstrói quando há versão nova; se o Obsidian estiver aberto, adia para a próxima verificação. Opções: `--forcar`, `--apenas-rpm DIR` e `OBSIDIAN_VERSION=1.15.0`. No Arch, usa o pacote `obsidian` do repositório oficial, atualizado pelo pacman.
- **Claude Desktop:** só no Fedora. Usa o builder de [dewzor/claude-desktop-fedora](https://github.com/dewzor/claude-desktop-fedora) na revisão `f9f3faa5`, a mesma revisada e compilada nesta máquina, guardada em `configs/claude-desktop/` e conferida por SHA-256. O builder confere o repositório apt assinado da Anthropic, reempacota o `.deb` oficial como RPM e instala `claude-desktop-update.timer` (verificação diária). O reinstalador acrescenta um drop-in que repete a verificação em 15 min quando ela falha, porque o timer dispara logo após o boot ou o resume, antes do DNS. Também instala `qemu-system-x86-core`, `edk2-ovmf` e `virtiofsd` para o Cowork. Comandos: `sudo claude-desktop-update --check` e `journalctl -u claude-desktop-update.service`.

O script adiciona `~/.local/bin` ao `PATH` no `~/.bashrc` se ainda não estiver lá.

## Configurações aplicadas

- **Fontes:** SF Pro, SF Pro Text e SF Mono baixadas da [Apple](https://developer.apple.com/fonts/), mais a JetBrainsMono Nerd Font. Os valores do KDE e da suavização vêm de `configs/fonts/`.
- **Ghostty:** `configs/ghostty/config`.
- **Acentos:** desativa o popup de diacríticos do Plasma, que atrapalhava a digitação rápida.
- **Seletor de arquivos:** usa o seletor do KDE nas janelas de abrir e salvar, por meio de `~/.config/xdg-desktop-portal/kde-portals.conf`.
- **Caps Lock:** a regra do keyd está em `configs/system/capslock.conf`. Para desativar: `sudo systemctl disable --now keyd.service`.
- **Fn Lock ASUS:** `options asus_wmi fnlock_default=N`, aplicado só em hardware ASUS.
- **Edge:** copia o lançador para `~/.local/share/applications/` e acrescenta `--enable-gpu-rasterization --use-gl=angle --use-angle=gl --enable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL,AcceleratedVideoEncoder` a todas as ações. Confira em `edge://gpu` e `edge://media-internals`.
- **systemd-boot no lugar do GRUB:** automático quando o GRUB está instalado, como nesta máquina. Só acontece em UEFI, com Secure Boot desativado (o systemd-boot das distros não é assinado) e ESP de pelo menos 500 MiB; caso contrário, o GRUB fica e o script avisa. A linha de comando atual vai para `/etc/kernel/cmdline`.
  - Fedora: instala `systemd-boot-unsigned`, grava `/etc/kernel/install.conf` (`layout=bls`, `BOOT_ROOT` = ESP) e roda `kernel-install` em cada kernel, que copia kernel e initramfs para a ESP.
  - Arch: os presets do mkinitcpio passam a gerar uma UKI por kernel em `EFI/Linux` (só o preset `default`, para caber na ESP), com o hook `microcode`.
  - A ordem de boot só muda depois que as entradas existem; se algo falhar antes, o GRUB continua funcionando.
  - Remove os pacotes do GRUB, do shim, o `os-prober` e o `grubby` só se nenhum outro pacote depender deles (`rpm -e --test`; no Arch, `pacman -Rn`), sem levar dependências junto. O `grubby` fica se o `akmods` (NVIDIA) estiver instalado.
  - Apaga os restos: binários do GRUB e do shim na ESP, `/boot/grub*`, `/boot/loader` e initramfs antigos da `/boot`, `/etc/default/grub` e as entradas da firmware que apontam para o GRUB ou o shim. Kernels da `/boot`, `EFI/Microsoft` e `EFI/systemd` ficam intactos. Ativa `systemd-boot-update.service`.
  - O systemd-boot detecta sozinho um Windows na mesma ESP. Se o Windows estiver em outra ESP, o script avisa; inicie-o pelo menu de boot da firmware.
- **Hibernação (opcional):** igual a esta máquina. Cria um swapfile com o tamanho da RAM + 2 GiB (no Btrfs, `/swap/swapfile` em um subvolume próprio, criado com `btrfs filesystem mkswapfile`; em ext4/XFS, `/swapfile`) e o adiciona ao `fstab` com prioridade 0, abaixo do zram. Acrescenta `resume=UUID=… resume_offset=…` ao kernel (`/etc/kernel/cmdline` e entradas do systemd-boot; com GRUB, no GRUB, e a troca para o systemd-boot leva os parâmetros junto), ativa o resume no initramfs (módulo `resume` do dracut ou hook `resume` do mkinitcpio, desnecessário com o hook `systemd`) e regenera o initramfs. Instala `configs/system/hibernate.conf` (`HibernateDelaySec=60min`) e configura o PowerDevil para suspender e depois hibernar, além de hibernar com bateria crítica ou fraca. No Fedora, aplica o rótulo SELinux `swapfile_t`. Com Secure Boot ativo, o kernel bloqueia a hibernação, e o script avisa.
- **Só no Fedora:** `dnf.conf` com `max_parallel_downloads=10` e `defaultyes=True`, e `dnf clean all` no final.

Ao terminar, reinicie o computador.

## Fontes

- RPM Fusion: https://rpmfusion.org/Configuration
- Ghostty: https://ghostty.org/docs/install/binary
- Ardia: https://github.com/ardia-browser/ardia/releases
- Helium: https://github.com/imputnet/helium-linux
- AUR: [helium-browser-bin](https://aur.archlinux.org/packages/helium-browser-bin) e [microsoft-edge-stable-bin](https://aur.archlinux.org/packages/microsoft-edge-stable-bin)
- Claude Code: https://code.claude.com/docs/en/setup
- Obsidian: https://github.com/obsidianmd/obsidian-releases
- Claude Desktop no Fedora: https://github.com/dewzor/claude-desktop-fedora
- keyd: https://github.com/rvaiya/keyd
- Aceleração de vídeo no Arch: https://wiki.archlinux.org/title/Hardware_video_acceleration

## Validação dos scripts

```bash
bash -n *.sh
shellcheck -x *.sh
```
