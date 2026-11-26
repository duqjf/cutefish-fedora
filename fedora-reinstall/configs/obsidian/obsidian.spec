# Baseado em https://github.com/idhirandar/obsidian-rpm-fedora (1.12.7).
# A versao vem de instalar-obsidian.sh: rpmbuild --define "obsidian_version X.Y.Z".
%{!?obsidian_version: %global obsidian_version 1.15.0}
# Binarios do Electron ja vem sem simbolos; nao ha debuginfo para extrair.
%global debug_package %{nil}
%global __strip /bin/true
%global __brp_check_rpaths %{nil}
# Mantem o payload como veio: sem mexer em shebangs ou bits de execucao.
%global __brp_mangle_shebangs %{nil}

Name:           obsidian
Version:        %{obsidian_version}
Release:        1%{?dist}
Summary:        Base de conhecimento sobre arquivos Markdown locais

License:        LicenseRef-Obsidian-Proprietary
URL:            https://obsidian.md
Source0:        https://github.com/obsidianmd/obsidian-releases/releases/download/v%{version}/obsidian-%{version}.tar.gz

ExclusiveArch:  x86_64
AutoReqProv:    no

Requires:       gtk3
Requires:       nss
Requires:       alsa-lib
Requires:       libX11
Requires:       libXtst
Requires:       libnotify
Requires:       libsecret
Requires:       mesa-libgbm
Requires:       at-spi2-atk
Requires:       xdg-utils
Requires:       hicolor-icon-theme

%description
Obsidian e uma base de conhecimento extensivel que trabalha sobre uma pasta de
arquivos Markdown. Este pacote reempacota o tarball oficial para Linux sem
alterar os arquivos do aplicativo.

%prep
%autosetup -n obsidian-%{version}

%install
install -d %{buildroot}%{_libdir}/obsidian
cp -a . %{buildroot}%{_libdir}/obsidian/
# O Electron so usa o sandbox SUID quando os user namespaces estao bloqueados.
chmod 4755 %{buildroot}%{_libdir}/obsidian/chrome-sandbox

install -d %{buildroot}%{_bindir}
ln -s ../%{_lib}/obsidian/obsidian %{buildroot}%{_bindir}/obsidian

# O tarball nao traz lancador; StartupWMClass precisa casar com o app_id do Electron.
install -d %{buildroot}%{_datadir}/applications
cat > %{buildroot}%{_datadir}/applications/obsidian.desktop <<'DESKTOP'
[Desktop Entry]
Name=Obsidian
Comment=Base de conhecimento sobre arquivos Markdown locais
Exec=/usr/bin/obsidian %U
Terminal=false
Type=Application
Icon=obsidian
StartupWMClass=obsidian
Categories=Office;Utility;TextEditor;
MimeType=text/markdown;x-scheme-handler/obsidian;
DESKTOP

install -Dm 0644 resources/icon.png %{buildroot}%{_datadir}/icons/hicolor/512x512/apps/obsidian.png

%post
/usr/bin/gtk-update-icon-cache -q %{_datadir}/icons/hicolor &>/dev/null || :
/usr/bin/update-desktop-database -q %{_datadir}/applications &>/dev/null || :

%postun
/usr/bin/gtk-update-icon-cache -q %{_datadir}/icons/hicolor &>/dev/null || :
/usr/bin/update-desktop-database -q %{_datadir}/applications &>/dev/null || :

%files
%license LICENSE.electron.txt LICENSES.chromium.html
%{_bindir}/obsidian
%dir %{_libdir}/obsidian
%{_libdir}/obsidian/*
%{_datadir}/applications/obsidian.desktop
%{_datadir}/icons/hicolor/512x512/apps/obsidian.png

%changelog
* Mon Nov 02 2026 Joao <343659563+duqjf@users.noreply.github.com> - 1.15.0-1
- Versao definida pelo instalador, lancador obsidian.desktop e sandbox SUID
- debug_package antes das secoes (no original ficava dentro do changelog)

* Wed Mar 04 2026 Dhirandar <idhirandar@gmail.com> - 1.12.7-1
- RPM nativo para o Obsidian 1.12.7
