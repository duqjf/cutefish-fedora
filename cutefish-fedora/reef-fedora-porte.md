# Reef no Fedora — análise do pacote e plano de porte

Analisado em 2026-11-24, sem instalar, a partir de:
- `cutefish-reef 0.1~git20261124000526.11bd348+ci20261124000852` (amd64, 15 MB, 69 MB instalado)
- `cutefish-webkit 2.54.2~git20261120163706.157ef16` (dependência obrigatória, 36 MB)

## 1. Licença: dá para redistribuir

- O `copyright` do pacote coloca **todo o código do Reef sob BSD-3-Clause** (`licenses/reef/LICENSE`, © Reion Wong). O código-fonte não é publicado, mas a licença do binário **permite redistribuir**, desde que o aviso de copyright vá junto. A cláusula 3 proíbe usar o nome do autor para promover derivados.
- As partes de terceiros (Swift runtime, CoreFoundation, libdispatch, libc++, lzfse, Tcl, ICU data, Lucide) usam Apache-2.0, BSD, MIT ou TCL. Só 1 arquivo é APSL-2.0, e o fonte dele já vem no pacote.
- O `cutefish-webkit` é **aberto**: https://github.com/cutefishos/cutefish-webkit (BSD-2 + LGPL-2+). Dá para recompilar no Fedora.

Mesmo assim, vale avisar o autor: ele publica *nightlies* e o ABI muda com frequência.

## 2. O que o pacote instala

| Caminho | O quê |
|---|---|
| `/usr/bin/reef` | Loader de Mach-O (ELF, só depende de libc/libstdc++). Faz `dlopen` do resto. |
| `/usr/bin/reef-diagnose`, `reef-authhelper` | Diagnóstico e helper de autenticação |
| `/usr/libexec/cutefish-reef/reef-open`, `reef-install-package`, `reef-unsupported` | Abrir `.app`, instalar `.pkg` (xar), tela de "não suportado" |
| `/usr/lib/cutefish-reef/host/libreef-appkit-host.so` | Ponte AppKit → `cutefish-toolkit` (Skia/EGL/HarfBuzz) |
| `/usr/lib/cutefish-reef/host/libreef-webkit-host.so` | Ponte WebKit → `libcutefish-webkit.so.2` |
| `/usr/lib/cutefish-reef/lib/libreef-metal-{translator,msl}.so` | Metal → GL; compila shaders com **LLVM/Clang 19** |
| `/usr/lib/cutefish-reef/System/Library/{Frameworks,PrivateFrameworks,CoreServices}` | ~120 frameworks reimplementados (Mach-O x86_64) |
| `/usr/lib/cutefish-reef/usr/lib/*.dylib` | libSystem, libobjc, libc++, Swift… (Mach-O) |
| `/usr/share/applications/cutefish-reef*.desktop` | Associa `application/x-apple-app` e `application/x-xar` |
| `/usr/share/thumbnailers/cutefish-reef.thumbnailer` | Ícone de `.app` no Files |

- **Não há scripts de manutenção** (sem postinst/prerm). Isso facilita converter para RPM.
- No usuário, ele usa `~/.local/share/cutefish-reef/bin` e `~/.local/share/fonts`.

## 3. Como funciona o "instalar com um clique"

1. O Files reconhece `application/x-apple-app`.
2. O `cutefish-services` mostra "To open “{name}”, Reef has to be downloaded and installed".
3. Ele instala o pacote **`cutefish-reef` pelo PackageKit** (D-Bus `org.freedesktop.PackageKit`), via `libcutefish-packagekit-client`.

Não depende de apt. **No Fedora isso funciona sem alterar o código**, basta haver um RPM chamado `cutefish-reef` num repositório dnf habilitado (COPR, por exemplo). O PackageKit do Fedora resolve o resto.

## 4. Dependências binárias e a situação no Fedora

ELF NEEDED e `dlopen` encontrados nos binários. Versão mais alta de símbolo: GLIBC_2.38, GLIBCXX_3.4.31 (o Fedora 43+ atende).

| Dependência | Fedora 45 | Ação |
|---|---|---|
| `libcutefish-toolkit.so.1`, `-base.so.1` | não existe | Compilar o toolkit **no mesmo commit** (`>= …111537f`). O ABI C++ é interno; uma versão diferente pode quebrar. |
| `libcutefish-webkit.so.2` | não existe | Compilar a partir do GitHub (é aberto) |
| `libLLVM.so.19.1`, `libclang-cpp.so.19.1` | `llvm19-libs` existe, mas fica em `/usr/lib64/llvm19/lib/` (fora do caminho padrão). Falta confirmar `clang19-libs`. | `Requires: llvm19-libs clang19-libs` + arquivo em `/etc/ld.so.conf.d/` ou `patchelf --set-rpath` |
| `libicuuc.so.76`, `libicui18n.so.76` (hardcoded em `libicucore.A.dylib` e `reef-hdiutil`) | o F43/44 têm ICU 77, o F45 tem ICU 78 | **Embutir o ICU 76** como cópia privada em `/usr/lib/cutefish-reef/lib`, ou pedir ao autor que use dlopen sem versão. Os símbolos do ICU levam sufixo de versão, então não dá para simplesmente criar um symlink. |
| `libbz2.so.1.0`, `libcurl-gnutls.so.4`, `libxml2.so.16` | nomes do Debian | Já existe fallback no binário (`libbz2.so.1`, `libcurl.so.4`, `libxml2.so.2`). Testar. |
| GL/EGL/GBM, fontconfig, freetype, harfbuzz(-subset), libva, pulse, sndfile, cups, openjp2, xslt, hyphen, enchant, krb5, dbus, systemd, brotli, lz4, ffi.so.8 | existem com o mesmo soname | `Requires` normais (o `rpmbuild` gera automaticamente) |
| WebKit: `libjpeg.so.62`, `libjxl.so.0.11`, `libavif.so.16`, gstreamer, seccomp, bubblewrap, xdg-dbus-proxy | recompilar resolve | — |

O `reef-diagnose` consulta `dpkg-query` e `/etc/debian_version`, mas já trata a ausência deles ("dpkg-query is not available"). É só cosmético.

## 5. Plano de porte

**Fase A: desktop + WebKit em RPM (é o pré-requisito)**
1. Fazer um `.spec` por repositório do `docs/building.md`, mais o `cutefish-webkit`. Fixar os mesmos commits que o Debian nightly usa: a versão do pacote `.deb` já contém o hash (`git…<hash>`).
2. Fazer o build no COPR, com acesso à rede habilitado por causa do `fetch-skia.sh`/`fetch-pdfium.sh`.
3. Prestar atenção em `-DCMAKE_INSTALL_PREFIX=/usr`. No Fedora, libdir é `/usr/lib64`, e o `.deb` usa `/usr/lib/x86_64-linux-gnu`. O Reef procura o toolkit pelo soname, então isso não deve importar, mas testar.

**Fase B: `cutefish-reef` como RPM "repack"**
1. Um `.spec` com `Source0: cutefish-reef_<ver>_amd64.deb`. No `%install`, extrair (`ar`/`bsdtar`) para `%{buildroot}`.
2. Incluir uma cópia privada do ICU 76 (compilada de `icu4c-76` no mesmo COPR) em `/usr/lib/cutefish-reef/lib`.
3. Resolver o caminho do LLVM 19 com `ld.so.conf.d` ou `patchelf --set-rpath` nos dois `libreef-metal-*.so` e no `libicucore` (Mach-O, que faz `dlopen` de sonames, então o caminho vale pelo `ld.so`).
4. Colocar `%global __requires_exclude` para os sonames embutidos e `AutoReqProv` normal para o resto. Definir `%global debug_package %{nil}`, já que não há fonte.
5. Colocar `Requires: cutefish-toolkit = <versão exata>`, `cutefish-webkit = <versão exata>`.
6. Automatizar: um GitHub Action que lê `https://download.cutefish.org/reef/dists/trixie-nightly/…/Packages`, baixa o `.deb` novo e dispara o COPR **junto** com o toolkit do mesmo commit.

**Fase C: ISO**
- Kickstart ou Kiwi com o COPR habilitado, `PackageKit` instalado, `generic-logos` no lugar de `fedora-logos` e o nome "X, a Fedora Remix".
- Instalar o Reef de fábrica ou deixar sob demanda (o fluxo do Files já funciona com o PackageKit).

## 6. Riscos

- **Amarração ao ABI do toolkit:** cada nightly do Reef exige o toolkit daquele dia. Você precisa reconstruir os dois em sincronia.
- **ICU 76 embutido:** você passa a manter uma cópia de biblioteca, incluindo os CVEs dela.
- **arm64:** o repositório do Reef só tem amd64 por enquanto. O site cita arm64, mas o `Packages` atual só lista amd64.
- **Sem código-fonte:** nada pode ser corrigido no Reef em si. Se algo quebrar no Fedora (seccomp, SELinux, caminhos), só o autor conserta.
- **SELinux:** o Fedora vem com enforcing. O loader faz mmap de Mach-O executável e lê `/proc/self/maps`, então pode exigir `execmem`/`execmod`. Precisa testar no Fedora.

## 7. Instalação real observada (2026-11-24, 21:15–21:27)

Monitores usados: tcpdump como root (pcap completo), `ss` com nome de processo, fotos do sistema de arquivos antes e depois, journal do sistema e do usuário, `/proc/<pid>/maps` e strace. Para a análise estática: REA 6.10.1 + Ghidra 12.2 (JDK 25).

### 7.1 Sequência
| Hora | O quê | Quem |
|---|---|---|
| 21:16:41 | `Ghostty.dmg` montado/extraído e `Ghostty.app` copiado para `/Applications` | **cutefish-filemanager / `cutefish-mountd`**, antes de o Reef existir. Leitor de DMG próprio do Cutefish (os binários contêm referências a UDIF/`koly`), **não é o `reef-hdiutil`** |
| 21:17:39 | `resolve cutefish-reef` → pedido polkit `org.freedesktop.packagekit.package-install` → senha | `cutefish-services` → PackageKit |
| 21:17:41–21:18:30 | Download e instalação de 82 pacotes | PackageKit (backend apt) |
| 21:18:58 | Ghostty aberto: `cutefish-appruntime` → `/usr/bin/reef` | — |
| 21:18:58 | HTTPS para `release.files.ghostty.org` | o próprio Ghostty (Sparkle, verificação de atualização). O Reef não fez nenhuma conexão própria. |

### 7.2 Rede (pcap, por SNI/DNS)
| Servidor | MB | Conteúdo |
|---|---|---|
| `download.cutefish.org` (Cloudflare, HTTPS) | 53,0 | `cutefish-reef` (15,1) + `cutefish-webkit` (35,8) |
| `deb.debian.org` (Fastly, HTTP) | 67,7 | 80 dependências do Debian |
| `release.files.ghostty.org` | 0,01 | appcast do Sparkle (Ghostty) |

**Por que 80 dependências:** `APT::Install-Recommends "1"` + `cutefish-webkit` **Recommends** `gstreamer1.0-plugins-bad, gstreamer1.0-libav, gstreamer1.0-gl`. O plugins-bad puxa onnxruntime, ImageMagick, ghostscript, fluidsynth etc. Dependências reais do Reef: só `libclang-cpp19`, `libhyphen0`, `hyphen-en-us`, `libexttextcat-data`, `libxslt1.1`.
→ No Fedora: `Recommends: gstreamer1-plugins-bad-free gstreamer1-plugin-libav` (ou `-freeworld` do RPM Fusion), nunca `Requires`.

### 7.3 Arquivos criados fora dos pacotes
| Caminho | Função |
|---|---|
| `/Applications/<App>.app` | instalado pelo Files (pasta `root:sudo`, setgid, mode 2775; o app fica com dono `joao:sudo`) |
| `~/.local/share/cutefish-reef/bin/<executável>` | **symlink → `/usr/bin/reef`**. O Reef faz `execve` desse link com `argv[0]` = caminho do Mach-O, para o processo se chamar `ghostty` |
| `~/.cache/cutefish-reef/binds/<hash>{,.paths,.objc-selectors}` | cache de binding do loader (formato `REEFSTA1`/`REEFBND1`): resolução de dylibs e seletores Obj-C |
| `~/.cache/cutefish-reef/metal/<hash>/…` | shaders Metal já traduzidos |
| `~/.cache/cutefish-reef/terminfo`, `font-answers` | caches auxiliares |
| `~/Library/{Caches,Preferences,Application Support,Saved Application State}` | **o `~/Library` do macOS é mapeado literalmente para `$HOME/Library`**. Preferências em `.plist` (`com.mitchellh.ghostty.plist`) |
| `~/.config/cutefish/reef.conf` | configuração do loader (string no binário, não foi criada nesta execução) |

### 7.4 Achados da análise com REA/Ghidra
- **A raiz é relocável:** `FUN_00179010` faz `readlink("/proc/self/exe")`, pega o `dirname` e concatena `"/../lib/cutefish-reef"`. Não há caminho Debian fixo. No Fedora, instalar em `/usr/bin/reef` + `/usr/lib/cutefish-reef/` (literalmente `lib`, **não** `lib64`) funciona sem patch.
- **ICU 76 é obrigatório:** `libicucore.A.dylib` faz `dlopen("libicuuc.so.76:libicui18n.so.76")` e liga **~1000 símbolos com sufixo `_76`** (`u_charType_76`, `UCNV_*_76`…). Não dá para usar o ICU 77/78 do Fedora; o pacote precisa levar uma cópia privada do ICU 76.
- **Bibliotecas do host realmente carregadas** (`/proc/<pid>/maps` do Ghostty): toolkit, EGL/GLES/gbm/mesa, wayland, fontconfig/freetype/harfbuzz, ICU 76, **libLLVM.so.19.1** (via `libreef-metal-translator`), curl/gnutls/krb5/ldap, libxml2/xslt, cups, systemd (para o journal), avahi, heif/tiff/webp/jpeg. O `libreef-webkit-host`/`libcutefish-webkit` não foi carregado pelo Ghostty (só carrega sob demanda).
- **Instância única:** um segundo `reef /Applications/Ghostty.app` só fala no D-Bus da sessão e sai em ~60 ms, entregando o pedido à instância que já está aberta.
- **SELinux:** **nenhuma região RWX** (o strace não mostrou nenhum `mmap` RWX, e o processo vivo não tem nenhuma). O loader mapeia os Mach-O com `PROT_EXEC` a partir de arquivos (96 mapeamentos), inclusive de `/Applications`. No Fedora, provavelmente basta rotular `/Applications(/.*)?` como `bin_t` (ou `usr_t`) via `semanage fcontext` no `%post`. Isso ainda precisa ser testado com enforcing.

### 7.5 Impacto no plano de porte
1. **O RPM `cutefish-reef` fica mais simples:** sem scripts, sem caminhos Debian e com raiz relocável. Basta reempacotar o `.deb` + ICU 76 privado + `Requires: llvm19-libs clang19-libs` + ajuste de `ld.so.conf.d` para `/usr/lib64/llvm19/lib`.
2. **O leitor de DMG está no `cutefish-filemanager`/`cutefish-mountd`** (código aberto), não no Reef. Ele vem junto no porte do desktop.
3. **O `/Applications` precisa ser criado por algum pacote do desktop** (`root:wheel 2775` no Fedora, já que lá não existe o grupo `sudo`), com regra SELinux.
4. **A cadeia de Recommends do WebKit** precisa ser revista no `.spec`, senão uma instalação "mínima" puxa ~70 MB de GStreamer/ImageMagick.

## 8. O que ainda precisa ser verificado em execução

- ~~Instalar o Reef pelo fluxo do Files e registrar o que ele cria~~ (feito, seção 7).
- Strace completo de uma inicialização a frio do Ghostty (com a instância atual fechada), para ver os `dlopen` feitos depois da janela abrir, como WebKit e áudio.
- Descobrir qual nome D-Bus o Reef usa para o modo instância única (o `cutefish-appruntime` precisa existir no Fedora).
- Testar numa VM Fedora 45 com o toolkit compilado e o RPM repack, com SELinux enforcing e rótulo em `/Applications`.

## 9. Fedora Minimal + Cutefish compilado do código-fonte

Script: [`cutefish-fedora-build.sh`](cutefish-fedora-build.sh). Ele segue a ordem do `docs/building.md` e traduz as dependências para o `dnf` via `pkgconfig()`. A sintaxe foi conferida e os 20 repositórios que ele clona foram confirmados no GitHub. **Ainda não foi executado num Fedora.**

### 9.1 Instalar o Fedora mínimo
1. Baixe o **Fedora Everything netinstall** (x86_64) da versão atual, em fedoraproject.org/misc → "Everything".
2. No Anaconda, vá em *Seleção de software* → **Minimal Install**, sem ambiente gráfico. Opcionalmente, marque "Standard".
3. Crie o seu usuário como **administrador** (grupo `wheel`).
4. **Se for VM:** o compositor exige EGL/GLES2 + KMS. No virt-manager, use vídeo `virtio` com "3D acceleration" e display Spice com OpenGL. No GNOME Boxes, ligue a aceleração 3D. Sem isso o `cutefish-compositor` não sobe.

### 9.2 Compilar
```bash
sudo dnf install -y git
git clone <onde você guardar o script>   # ou copie o cutefish-fedora-build.sh
./cutefish-fedora-build.sh all
```
Ou por etapas: `deps` → `clone` → `build` → `session`. O `cutefish-toolkit` é o mais demorado porque compila o Skia; reserve uns 30 a 60 min e ~15 GB de disco.

### 9.3 O que muda em relação ao Debian
| Ponto | Debian (guia) | Fedora (script) |
|---|---|---|
| Libdir | `/usr/lib/x86_64-linux-gnu` | `/usr/lib64` (GNUInstallDirs resolve sozinho) |
| Codecs | `libavcodec-dev` completo | `ffmpeg-free`. Para H.264/HEVC no video-player: RPM Fusion + `dnf swap ffmpeg-free ffmpeg --allowerasing` |
| PAM keyring | `libpam-gnome-keyring` | `gnome-keyring-pam` |
| Grupo admin / `/Applications` | `sudo` | `wheel`, mais o rótulo SELinux `usr_t` em `/Applications` |
| SELinux | — | `restorecon` depois do `cmake --install`. O `cutefish-dm` roda como serviço systemd (`unconfined_service_t`). Se o login falhar, veja `ausearch -m avc -ts recent` |
| Terminal | Zig 0.17.1 + libghostty-vt 1.0.1 | Sem Zig: `reef-fedora.sh ghostty-vt` reempacota o `cutefish-ghostty-vt-dev` do nightly (estático, assinado) como `cutefish-ghostty-vt-devel`. Ligado por padrão (`WITH_TERMINAL=1`); o build chama isso sozinho se a lib faltar |
| Login | cutefish-dm ou o DM existente | `WITH_DM=1` (padrão) usa o cutefish-dm. `WITH_DM=0` instala o SDDM |
| Portais / seletor de arquivos | o portal sobe sozinho | O `xdg-desktop-portal` do Fedora exige `graphical-session.target`, que o `cutefish-session` não ativa. Sem isso, Helium, Edge e Electron usam o seletor do GTK. O `session` instala `cutefish-session.target` + autostart. O `dbus-tools` (o `dbus-update-activation-environment`) também é necessário |
| Console (kmscon) | `getty` no tty1 | O Fedora usa o `kmscon` no tty1. Em segundo plano ele ainda lê o teclado e trava com Ctrl+-/Ctrl+= (`zoom_out`). O `OnFailure` sobe o `getty@tty1`, que conflita com o `cutefish-dm` e derruba a sessão. O drop-in `fedora-kmscon.conf` faz o DM conflitar também com o `kmsconvt@tty1` |

### 9.4 Depois de funcionar
- O Reef no Fedora ainda não existe como RPM (seção 5, fase B). Até lá, o fluxo "abrir app do Mac" do Files vai mostrar "Reef is not available for this computer", porque o PackageKit não acha o pacote `cutefish-reef`.
- Próximo passo natural: transformar cada `build_one` num `.spec` e publicar no COPR (seção 5, fase A).

## 10. Reef no Fedora: `reef-fedora.sh`

Leve juntos: `cutefish-fedora-build.sh`, `reef-fedora.sh` e a pasta `keys/`. Com `WITH_REEF=1` (o padrão), o `all` já inclui o Reef. Também dá para rodar só `./cutefish-fedora-build.sh reef` depois do desktop pronto.

### 10.1 O que o script faz, e o que veio da engenharia reversa
| Passo | Por quê |
|---|---|
| **`pin`**: fixa só o `cutefish-toolkit` no commit que o nightly do Debian empacotou (o hash vem da versão do `.deb`, p.ex. `111537f`). Os outros repositórios seguem o upstream. `PIN_REPOS=all` volta a fixar todos. Edições locais não commitadas são guardadas no stash e reaplicadas; se conflitarem, ficam no `git stash list` | O Reef é binário e só liga no `libcutefish-toolkit.so.1`/`-base.so.1` (o WebKit vem do `.deb`). O ABI C++ do toolkit é interno, então ele precisa ser o mesmo do Debian. Roda antes do `fetch-skia.sh`, para o Skia também ser o da revisão certa |
| Baixa `InRelease` dos dois repositórios e verifica com as chaves em `keys/` (Cutefish Archive `5F527F0C…9E1091A7`, Cutefish Reef `2C1130F7…227AD01E`). Depois confere o SHA-256 do `Packages` e de cada `.deb` | O mesmo nível de verificação do apt. Testado aqui: uma alteração no `InRelease` dá `BADSIG` e o script para |
| Compila o **ICU 76.1** do código-fonte oficial (SHA-512 conferido com o `SHASUM512.txt` da release) em `/usr/lib64/cutefish-reef-icu76` | O `libicucore.A.dylib` liga cerca de 1000 símbolos `*_76`, e o Fedora 45 tem ICU 78. Como os sonames são diferentes (`.so.76`), não há conflito com o ICU do sistema |
| `/etc/ld.so.conf.d/cutefish-reef.conf` com o ICU 76 e `/usr/lib64/llvm19/lib` | O `libreef-metal-*` pede `libLLVM.so.19.1` e `libclang-cpp.so.19.1`. O `llvm19-libs` do Fedora fica fora do caminho padrão |
| Move o WebKit de `/usr/lib/x86_64-linux-gnu` para `/usr/lib64` e corrige o `.pc` | O layout do Fedora. O Reef acha `libcutefish-webkit.so.2` pelo soname |
| Mantém `/usr/bin/reef` e `/usr/lib/cutefish-reef/` **exatamente** como estão | A raiz é `dirname(/proc/self/exe)/../lib/cutefish-reef` (decompilado). Literalmente `lib`, não `lib64` |
| Verifica os `NEEDED` de cada ELF contra o `ldconfig` e os pacotes gerados, e lista o que faltar | Mostra antes de instalar o que pode quebrar |
| Troca `libxml2.so.2` → `libxml2.so.16` com `patchelf`, **só se** o Fedora tiver apenas o `.16` | O libxml2 2.14+ mudou o soname. O próprio Reef já tenta `.16` no `dlopen`; aqui o script faz o mesmo nos `NEEDED` |
| Gera três RPMs (`cutefish-reef`, `cutefish-webkit`, `cutefish-reef-icu76`) sem strip e sem os scripts `brp-*` | São binários de terceiros e Mach-O, que não podem ser alterados |
| Publica os RPMs num repositório local em `/var/lib/cutefish-local-repo`, mais `/etc/yum.repos.d/cutefish-local.repo`, e instala | O Files pede ao **PackageKit** o pacote `cutefish-reef` pelo nome. Com o repositório local, o fluxo "abrir app do Mac" funciona sem mudar código |
| `/Applications` com dono `root:wheel 2775`, rótulo SELinux `usr_t` e `restorecon` | O Ghostty rodou sem nenhuma região RWX, então não é preciso `execmem` |

### 10.2 Testado aqui (Debian) × só no Fedora
- **Testado:** download e verificação de assinatura (inclusive a rejeição de um `InRelease` adulterado); escolha das versões; mapeamento repositório → commit (14 repositórios, incluindo o toolkit em `111537f`, igual ao que o Reef exige); mudança do layout do WebKit; relatório de bibliotecas; geração do `.spec` (3507 arquivos, nenhum com caractere que o rpm interprete).
- **Só no Fedora:** `dnf`, `rpmbuild`, `createrepo_c`, SELinux, se o `llvm19-libs` e o `clang19-libs` existem na versão instalada, as versões de libjxl/libavif/libxml2, e a execução do Reef em si.

- **Testado no Fedora 45 (2026-11-25):** Intel ADL GT2, Mesa 26.2.7, kernel 7.3.4, SELinux enforcing. O `install` funcionou depois da correção do libcurl, e o **Ghostty.app abriu e funciona** pelo fluxo do Files. O `reef-diagnose` ainda acusa 14 falhas no código do próprio Reef (SIMD groups com largura 16 na Intel, sincronização do `surfaces.export` e das janelas no compositor), mas elas não impediram o Ghostty de rodar.

### 10.3 Se der errado
- `./reef-fedora.sh check` lista as bibliotecas que faltam.
- `reef-diagnose` (instalado pelo pacote) mostra GPU, drivers e o ambiente.
- Logs: `journalctl --user -b | grep -i reef` e `ausearch -m avc -ts recent` (SELinux).
- Para desinstalar: `sudo dnf remove cutefish-reef cutefish-webkit cutefish-reef-icu76`.
- **`nada fornece libcurl.so.4(CURL_OPENSSL_4)`** (visto em 2026-11-25): o WebKit do Debian liga símbolos versionados do libcurl, e o libcurl do Fedora não tem versões de símbolo. O `ld.so` aceita isso (só avisa), então o `.spec` exclui essa exigência e mantém o `libcurl.so.4()` normal. Na regex, os parênteses vão como `[(]`/`[)]`, porque o rpm consome o `\` ao expandir a macro.
