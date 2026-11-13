# FILZA EXTERNAL V1000 V5

Esta versão parte diretamente do `Base.zip` fornecido.

- Versão de atualização: `5.0.7` (build `12`), superior à IPA anterior (`5.0.6`, build `11`).

- SHA-256 do arquivo de origem: `18c10605db6a9e04f3a7be09ad9076e41ec22f0d6258c9ce81f18159ca615fcc`
- Projeto: `TOMMY-EXTERNAL-20k7-master/ThreeOneOSFive.xcodeproj`
- Scheme: `FILZA EXTERNAL V1000`
- Bundle ID preservado da base: `com.apple.mobile.MobileHouseArrest`
- Backend Filza: `https://martins-license.duckdns.org/external` (`FILZA_EXTERNAL_0B55`)

## Alterações aplicadas

- Validação de integridade compatível com recursos de mídia reempacotados pelo iOS.
- Switch horizontal arrastável, seleção persistente e exclusividade apenas na mesma categoria.
- `Patchs`/`Patch` agrupados em `Outros`, com ativação e restauração exclusivamente manuais para AP, FF Normal e FF Max.
- Pacotes baixados com nomes opacos SHA-256 `.r7v`; o cache local é cifrado com AES-GCM e protegido por classe de arquivo do iOS em Application Support oculto.
- A descriptografia de pacotes ocorre em memória para inspeção/aplicação; o app não cria nem sincroniza `.workspaces` plaintext e remove diretórios legados no início.
- A proteção em repouso é verificada antes de um cache ser tratado como baixado; uma entrada plaintext legada é migrada ou descartada.
- Painel Filza, ícone/identidade sem arte Tommy e seis categorias online, incluindo `AP`.
- Tela de ativação em português do Brasil, com o versículo original de Provérbios 16:3 restaurado.
- O modo automático foi removido; AP, FF Normal e FF Max usam apenas o fluxo manual: ativar aos 40%, aguardar o lobby, desativar e voltar ao jogo.

## Build

O workflow GitHub Actions produz uma IPA unsigned. A assinatura para instalação deve ser feita separadamente.
