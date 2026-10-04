# Verificación de backups — 4 de octubre de 2026

La rama `assistant/backup-decoding-20261004` parte del checkpoint de descargas
`c794982271b95b4c6d91e73917b5392363e481ce`
([PR #13](https://github.com/taizaki69/Kami/pull/13)). El objetivo general sigue
activo. Esta entrega prepara la lectura de backups; no implementa exportación,
restauración en SQLite ni una interfaz de importación.

## Formato y límites comprobados

Los productores Mihon fijados en [compatibilidad de backups](BACKUP_COMPATIBILITY.md)
escriben gzip/protobuf y aceptan protobuf sin comprimir. La documentación y el
lector anteriores suponían incorrectamente zstd actual y zlib histórico. Ahora
se comprueban CRC de cabecera y contenido, ISIZE, límites de expansión y consumo
completo de un único miembro gzip. La política rechaza miembros concatenados y
bytes sobrantes; el entry point de índices conserva su contrato anterior.

El cursor específico de backups valida tipos wire, longitudes/varints, UTF-8,
campos requeridos y presupuestos acumulados. Un manga/capítulo/historial soportado
pero malformado falla como conjunto; no se descarta mediante `try?`/`compactMap`.
Los mensajes no soportados permanecen opacos y aparecen en un informe finito por
ámbito/tipo, sin copiar preferencias, secretos o permisos de repositorio.

Los datos interpretados conservan IDs y valores Long completos, el valor
predeterminado `favorite=true`, el orden de categoría como referencia de
pertenencia, metadatos, progreso de capítulos e historial. Las fechas conservan
las unidades de origen. Campos singulares duplicados usan el último valor válido;
un valor anterior inválido sigue causando error. Cabeceras que parecen zlib/zstd
no invalidan un protobuf raw que se interpreta correctamente.

## Evidencia independiente y regresiones

`Tests/backups/` contiene cinco pares raw/gzip producidos con Kotlin 2.4.20 y
kotlinx.serialization 1.11.0, más expectativas JSON generadas por el decoder
Kotlin. La receta, las herramientas y los archivos quedan fijados por hash y
procedencia. El productor usa declaraciones mínimas escritas para estas pruebas;
no se ejecutó Android ni se obtuvo un backup de un usuario. JRE, compilador y
jars se mantienen fuera del repositorio y no son dependencias de la app o CI.
Una regeneración con herramientas recién extraídas reprodujo exactamente los
15 archivos raw/gzip/JSON fijados. Los cinco archivos de herramientas y
dependencias se volvieron a contrastar con metadata oficial.

Las fixtures cubren `favorite=true` omitido y `false` explícito, categorías y
fuentes sin manga inicial, backup vacío, IDs mayores de 2^53 y extremos Int64,
progreso/orden/duración mayores de Int32, Float32 y campos anulables. Swift
compara todos los campos soportados con las expectativas Kotlin y verifica los
hashes, tanto para raw como gzip. Python verifica por separado wire tags,
omisiones de defaults, CRC/tamaño y consumo del gzip.

Las 38 pruebas nuevas se distribuyen en:

- 24 del esquema, cobertura opaca, límites y cancelación.
- Ocho del contenedor gzip con compresión almacenada, Huffman fijo y dinámico
  producida por Python/zlib; incluyen todos sus prefijos truncados, cabeceras
  opcionales, FHCRC, CRC de contenido, ISIZE, concatenación y límites exactos.
- Seis de interoperabilidad con el serializer Kotlin y sus locks de procedencia.

En Linux con Swift 6.3.3 pasan **371/371 MihonCompatKit**, **181/181 KamiCore con
SQLite** y **66/66 KamiCore portable**. Se conservan todos los tests anteriores;
la nueva evidencia no amplía admisión de APK ni modifica el corpus o sus hashes.

Los 27 APK del lock se verifican sin reemplazarlos. El CLI optimizado compila y
la auditoría del rol measurement conserva ocho artefactos, cuatro candidatos
estructurales, cuatro bloqueados por wrappers y 359 gaps, con cero errores y
cero opcodes no soportados. Reducir un recuento estático no probaría ejecución.

El [PR #14](https://github.com/taizaki69/Kami/pull/14) quedó listo, sin merge, en
`8b7d98046dd04cd1ba99d2e27ee856629876f64e`. Su
[Swift CI](https://github.com/taizaki69/Kami/actions/runs/37226517208) pasó con
371 Compat + 181 Core/SQLite en Linux y 371 Compat + 184 Core en macOS.
[iOS Build](https://github.com/taizaki69/Kami/actions/runs/37226517222) compiló
simulador y dispositivo;
[IPA Package](https://github.com/taizaki69/Kami/actions/runs/37226517185) produjo
el artefacto unsigned 11311689959 de 4.413.732 bytes, SHA-256
`61eb98e180116440263023a0b29d46355d13385e0eaec570582344f7936c0b11`.
Los tres workflows declaran ese mismo head SHA. Logs, hashes y metadata quedan
en `.git/checkpoints/20261004-backup-decoding/`.

## Lo que falta para restaurar

La [entrega nativa posterior](VERIFICATION-2026-10-04-NATIVE-BACKUPS.md) añade
exportación versionada a Files. Quedan lectura acotada desde Files, preview
inmutable, fusión atómica y protección contra previews/lectores obsoletos. El
snapshot debe incluir capítulos ocultos, todo el historial, duración y estado
durable de descubrimientos. Se necesitan identidad de despliegue para Foo y
evidencia independiente para cualquier traducción de IDs/URLs de MangaDex.

La interpretación de bytes no instala ni activa extensiones, no concede
confianza, no hace requests y no escribe datos de biblioteca. No demuestra
fidelidad de campos omitidos, compatibilidad con todos los forks, restauración
integral, uso físico de iOS, rendimiento con bibliotecas grandes o disponibilidad
de sitios de manga.
