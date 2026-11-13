# Continuidade do FILZA 2.0

## Estado atual

Este projeto é o **FILZA 2.0**. A branch principal é `main`.

Alteração concluída: o modo automático foi removido completamente da IPA. O aplicativo usa somente o modo Manual, por padrão e sem preferência automática persistida.

O fluxo manual vale para:

- AP;
- FF Normal;
- FF Max.

No modo Manual, o usuário toca no patch para ativá-lo, entra no jogo até aproximadamente 40%, aguarda o lobby e toca novamente no patch para desativá-lo. O aplicativo não inicia timer, não aplica patch automaticamente ao abrir o jogo e não retoma ciclos automáticos ao voltar do segundo plano.

## Commits relevantes

- `fed3c65` — Remove automatic patch modes
- `ffe06f4` — Fix manual patch flow scope
- `abbf903` — Fix ContentView closing scope

O último commit publicado é `abbf903`.

## Repositório atual

`https://github.com/minhacontadaniel708-byte/FILZA-2.0`

Branch: `main`

## Build da IPA

A IPA é unsigned e precisa ser compilada em macOS pelo GitHub Actions. O workflow está em:

`.github/workflows/build.yml`

Ele executa validações, compila o archive com `CODE_SIGNING_ALLOWED=NO`, empacota `Filza-External-V1000-unsigned.ipa` e publica o artefato:

`Filza-External-V1000-unsigned-ipa`

O script local é `build_unsigned.sh`, mas requer macOS/Xcode (`xcodebuild`). Em Linux não é possível compilar diretamente este projeto iOS.

A última tentativa falhou por indisponibilidade do runner macOS do GitHub, antes de executar os passos do job (`runner_id: 0`). Uma reexecução foi solicitada.

## Ao continuar em outra conta

1. Clonar este repositório ou importar o conteúdo para o novo repositório autorizado.
2. Ler este arquivo antes de modificar o projeto.
3. Conferir se `main` contém `abbf903` ou um commit posterior.
4. Não reintroduzir `automaticPatchMode`, `PatchTimerCoordinator`, `startGameLaunchTimer`, `resumeAutomaticCycleIfNeeded` ou estados `pendingPatch*` automáticos.
5. Executar `python3 tools/validate_patch_security.py`.
6. Executar o workflow macOS para gerar a IPA unsigned.
7. Baixar o artefato `Filza-External-V1000-unsigned-ipa` somente após o workflow concluir com sucesso.

## Observação sobre contas

A continuidade não depende da memória de uma conta específica: o estado do projeto, os commits, as instruções e o procedimento de build ficam registrados neste repositório e neste arquivo.
