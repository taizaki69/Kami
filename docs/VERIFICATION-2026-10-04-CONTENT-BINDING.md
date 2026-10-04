# Verificación del origen durable de FoolSlide — 4 de octubre de 2026

La rama `assistant/foolslide-content-binding-20261004` parte de
`b122ee94870b7b457739b5226b73de2943d24b1c`
([PR #16](https://github.com/taizaki69/Kami/pull/16)). Ese checkpoint del lector
pasó Linux 371 Compat + 270 Core/SQLite, macOS 371 Compat + 273 Core,
compilaciones de simulador/dispositivo y generación de IPA.

## Alcance

Schema 7 conserva la dirección de origen de Foo fuera de sus preferencias.
La migración infiere una vez a partir de datos anteriores acotados y válidos;
el origen no confirmado queda explícito. Reinstalar, perder ajustes o borrar
metadatos de instalación no borra una dirección ya conocida. Guardar ajustes
requiere coincidencia exacta cuando existen manga y conserva la autenticación
del APK y la decisión de activar por separado.

Las revisiones del origen y las preferencias se comprueban en la misma
transacción. La lectura usa bytes UTF-8 estrictos y límites antes de materializar
valores. Exportar consulta el origen durable. Los checks de ejecución y resultados
incluyen su revisión; Detail, el lector online y LibraryService lo validan antes
de pedir contenido. Ver [contratos y exclusiones](SOURCE_CONTENT_BINDING.md).

## Evidencia local

Swift 6.3.3 en Linux pasa **371/371** pruebas de MihonCompatKit y **291/291**
de Core con SQLite. La suite portable de Core pasa **95/95** por separado.
Las 21 regresiones nuevas cubren migración/rollback,
conservación sin APK, reinstalación, primera configuración de contenido
existente, bloqueo por URL distinta, Unicode/porcentaje/mayúsculas, revisiones
caducadas o agotadas, datos malformados, el límite inclusivo de 4096 bytes,
`INSERT OR REPLACE` y rechazo antes de
invocar proveedores inyectados. Dos caminos de guardado también rechazan una
URL de manga con composición Unicode distinta para el mismo ID físico.

El parse de SwiftUI y `git diff --check` pasan. Los registros distinguen estas
comprobaciones locales de la compilación Apple. Los checkpoints y logs locales están en
`.git/checkpoints/20261004-foolslide-content-binding/`.

El [PR #17](https://github.com/taizaki69/Kami/pull/17) quedó listo y sin fusionar
en `b15344da383a33b6a2d56d83fe2ed0f46d4a0877`.
[Swift CI](https://github.com/taizaki69/Kami/actions/runs/37238383693) pasó
371 Compat + 291 Core/SQLite en Linux y 371 Compat + 294 Core en macOS.
[iOS Build](https://github.com/taizaki69/Kami/actions/runs/37238383701) compiló
simulador y dispositivo; [IPA Package](https://github.com/taizaki69/Kami/actions/runs/37238383716)
generó el IPA sin firmar. El merge de CI `d29acd5` tiene el mismo árbol
`9fcdb9741557cdc5de89945c17f701d7d2c1e17d` que el head publicado.

No se habilitan restore, nuevas versiones de APK ni sitios reales. Faltan
preview inmutable, fusión atómica y las barreras generales de operaciones y
escenas. La interacción y el rendimiento en dispositivo requieren evidencia
propia; no se deducen de pruebas SQLite o de compilar el IPA.
