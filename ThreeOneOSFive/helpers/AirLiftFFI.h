// AirLiftFFI.h
// Bridge header: declarações C das funções FFI fornecidas pelo AirliftFFI.xcframework
// Usado pelo Swift via ThreeOneOSFive-Bridging-Header.h
//
// IMPORTANTE: Este header inclui o idevice.h que já define todos
// os types (AdapterHandle, RsdHandshakeHandle, AfcClientHandle, etc.)
// e as funções FFI. Não redefinir types aqui.

#ifndef AIRLIFT_FFI_H
#define AIRLIFT_FFI_H

#include <stdint.h>
#include <stdbool.h>
#include <sys/types.h>
#include <sys/socket.h>

// O header público do AirliftFFI expõe as operações de pairing, AirTraffic,
// streaming ZIP, FileService e exploração. Ele vem da XCFramework gerada no
// workflow antes da compilação do app.
#include "airlift.h"

// Incluir também o header principal do idevice FFI
// (HEADER_SEARCH_PATHS aponta para ThreeOneOSFive/libs/). Ele contém os tipos
// e operações RSD/AFC usados diretamente pelo transporte Swift.
#include "idevice.h"

#endif // AIRLIFT_FFI_H
