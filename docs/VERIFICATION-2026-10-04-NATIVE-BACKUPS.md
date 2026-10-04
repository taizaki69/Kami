# Verificación de exportación nativa — 4 de octubre de 2026

La rama `assistant/native-library-backups-20261004` parte de
`8b7d98046dd04cd1ba99d2e27ee856629876f64e`
([PR #14](https://github.com/taizaki69/Kami/pull/14)). Implementa exportación
nativa de biblioteca a Files. El objetivo general sigue activo y la
restauración todavía no está disponible.

## Comportamiento implementado

La pantalla Library backups prepara una copia, muestra fecha, tamaño y
recuentos y abre el exportador del sistema. Los bytes se preparan fuera del
actor principal. Cancelar o cerrar impide publicar resultados tardíos; la
cancelación llega al trabajo de snapshot/codec. La app rechaza exportar desde
su base temporal de respaldo cuando falla el almacenamiento persistente.
El mensaje de archivo guardado aparece solamente tras el callback de éxito
de Files. La pantalla indica expresamente que no hay restauración.

El [formato JSON nativo v1](NATIVE_BACKUPS.md) conserva todos los campos de
biblioteca representados por el esquema actual: manga fuera de la biblioteca,
categorías vacías, capítulos ocultos, historial completo/duración y registros
de descubrimiento. Los Int64 usan strings decimales canónicos; las identidades
y su igualdad conservan bytes UTF-8 exactos. Las fechas retienen sus unidades
persistidas y no se inventan valores para datos dañados.

La extracción usa una sola transacción de lectura. Antes de materializar datos
comprueba recuentos, tipos SQLite, longitudes y relaciones. Texto leído como
BLOB permite rechazar NUL y UTF-8 inválido sin truncamiento. El JSON se valida
léxicamente antes de Foundation: límites de bytes, profundidad, valores,
strings, claves y elementos; duplicados, escapes y colisiones Unicode.
El escritor comprueba capacidad antes de cada append, incluso con expansión
por escapes. Las políticas son inmutables y sólo admiten límites inferiores.

FoolSlide incluye su dirección exacta cuando la procedencia persistida es
coherente, aunque esté deshabilitado o falte el APK. Datos de procedencia
inválidos se representan como `unresolved` y no se corrigen. La revisión halló
que columnas con afinidad INTEGER podían guardar TEXT/BLOB grandes; el
preflight ahora verifica su tipo antes de llamar a los mappers existentes.
El archivo no contiene autoridad, APK, preferencias ejecutables, descargas ni
ledgers operacionales. No se instala, activa o ejecuta una extensión al exportar.

## Pruebas locales

Con Swift 6.3.3 en Linux pasan:

- **371/371 MihonCompatKit**.
- **223/223 KamiCore con SQLite**.
- **95/95 KamiCore portable**.
- Parse sintáctico de todos los archivos SwiftUI y `git diff --check`.

Hay **42 regresiones nuevas**: 29 del codec y 13 del snapshot. Cubren campos
completos, extremos Int64/valores superiores a 2^53, orden canónico, texto e
identidades Unicode, baseline ausente frente a cero, claves desconocidas,
referencias ambiguas/rotas, tipos inválidos, límites inclusivos y cancelación.
Una biblioteca sintética de 205 capítulos/historial demuestra que los 200
elementos de la consulta de UI no recortan el backup y que los capítulos
ocultos conservan estado. También se conservan URLs conocidas sin fila de
capítulo y fechas/duración mayores que Int32.
Doce categorías con posiciones repetidas y un orden diferente al de sus IDs
mantienen su secuencia y pertenencias al codificar/decodificar; las claves
locales del archivo conservan el orden de los empates.

Los casos de Foo comprueban URL exacta, APK ausente, deshabilitado, hashes,
signers, IDs, fingerprint/schema y JSON de preferencias dañados, así como
diez corrupciones TEXT/BLOB en las cinco columnas numéricas leídas. Las
aserciones comparan clase de almacenamiento y bytes de todas las columnas
de procedencia antes/después. Errores y cancelación se siguen de una
transacción en el mismo LibraryStore para comprobar la liberación del snapshot.

Estas fixtures se construyen con DTOs y SQLite temporales; no son backups
capturados de una instalación de iOS. La implementación y los tests no
modifican MihonCompatKit, el corpus APK ni su admisión. Los resultados
anteriores del CLI/corpus siguen perteneciendo al checkpoint padre.

Los logs, revisiones, hashes y publicación se guardan en
`.git/checkpoints/20261004-native-library-backups/`. El PR de esta entrega
registra los workflows Apple y sus artefactos para el head exacto publicado.
La compilación local y la revisión de código no prueban interacción con Files,
cancelación del picker/proveedores, uso físico de iOS o consumo de memoria
con bibliotecas grandes.

## Continuación necesaria

Faltan lectura acotada desde Files, preview inmutable, fusión atómica y
protección contra lectores/previews/operaciones de fuente obsoletos. Restaurar
Foo requiere binding durable y conflictos explícitos; los metadatos del
backup nunca otorgan configuración ejecutable o confianza. Importar Mihon
añade mapeo verificado de IDs/URLs y cobertura de campos omitidos. Esta
entrega no demuestra ninguna de esas operaciones.
