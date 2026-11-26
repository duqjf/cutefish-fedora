# cutefish-fedora

Scripts para instalar o desktop Cutefish e o Reef (apps do Mac) num Fedora, mais a reinstalação dos meus programas e configurações.

- [`cutefish-fedora/`](cutefish-fedora/): compila o Cutefish a partir dos repositórios do GitHub e reempacota o Reef como RPM. As notas do porte estão em [`reef-fedora-porte.md`](cutefish-fedora/reef-fedora-porte.md).
- [`fedora-reinstall/`](fedora-reinstall/): programas e configurações pessoais (Fedora KDE ou Arch). Veja o [README](fedora-reinstall/README.md).

## Instalação nova

```bash
git clone https://github.com/duqjf/cutefish-fedora ~/Downloads/cutefish-fedora
cd ~/Downloads/cutefish-fedora/cutefish-fedora
./cutefish-fedora-build.sh all
```

O código do Cutefish é clonado em `~/cutefish` (`SRC=` muda o lugar).

## De onde vem cada repositório

[`cutefish-fedora/repos.conf`](cutefish-fedora/repos.conf) lista os repositórios que vêm de um fork meu, com os patches para o Fedora na branch `fedora`. Os outros vêm de `github.com/cutefishos`, na branch padrão. Num repositório com fork, `origin` é o fork e `upstream` é o cutefishos.

Com o Reef, só o `cutefish-toolkit` fica fixado no commit do nightly do Debian, porque o Reef é binário e depende do ABI C++ dele. O resto segue o upstream.

## Mexer no código e sincronizar

1. Edite em `~/cutefish/<repo>` e commite na branch `fedora`. Se o repositório ainda não tiver fork, crie o fork no GitHub e acrescente uma linha em `repos.conf`.
2. Para trazer o upstream:

   ```bash
   ./cutefish-fedora-build.sh sync          # atualiza tudo e faz rebase dos forks
   PUSH=1 ./cutefish-fedora-build.sh sync   # idem, e envia as branches para os forks
   ```

   Se houver conflito, nada muda e o script mostra o comando para resolver à mão.
3. `./cutefish-fedora-build.sh build` recompila.

Edições não commitadas não se perdem no `clone` ou no `sync`: ficam no stash durante a troca e são reaplicadas.
