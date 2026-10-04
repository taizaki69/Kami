# Verificación de continuidad — 3 de octubre de 2026

Esta evidencia corresponde a la continuación de
`assistant/foolslide-20260920` sobre
`a479806ba81c71845ba0a154a096bf47736b7393`. Los cambios heredados de
`HostBridge.swift`, `CompatHTML.swift`, `PinnedInterpretedSource.swift` y
`FoolslideProbe.swift` estaban sin commit y fueron respaldados antes de
modificarlos. Las verificaciones Linux descritas aquí prueban paquetes
portables y fixtures deterministas; no prueban una sesión de lectura iOS,
disponibilidad de sitios, ni compatibilidad general con extensiones.

## Integridad del corpus

Los 27 APK vendorizados coincidieron con los SHA-256 de
`Tests/corpus/manifest.json`: 1,627,003 bytes en total. No se descargó ni se
reemplazó ningún APK para obtener ese resultado. El manifiesto mantiene sus
URLs, revisiones upstream y hashes fijados. El corpus distingue evidencia de
ejecución, medición estática y conformance de firmas; ninguna de esas
etiquetas establece confianza de un usuario ni concede admisión.

`CorpusLockTests` comprueba la correspondencia manifiesto/fetcher, los hashes,
las identidades Android y las firmas de todos los APK reales. Para los 19
lib 1.6 se exige además el fingerprint fijado de Keiyoushi
`9add655a78e96c4ec7a53ef89dccb557cb5d767489fac5e785d671a5a75d4da2`.
Los fixtures ejecutables lib 1.6 deben tener un perfil exacto cuyo conjunto de
source IDs coincida con su número de fuentes. Las fixtures AOSP conservan sus
casos válidos e inválidos separados; no se convierten en extensiones.

EternalMangas 1.6.28 y DocTruyen3Q 1.6.38 habían sido promovidos al catálogo
exacto y a pruebas deterministas en `72748b1` y `2bd3b78`, pero sus roles del
manifiesto continuaban en medición. Esta continuación corrige esa deuda sin
mover sus APK ni cambiar sus bytes o hashes. Sus paths históricos bajo
`measurement/` no determinan su rol. FoolSlide Customizable 1.6.6 se promovió
después de validar su contrato y sus límites: el corpus final mantiene
27 artefactos en 13 fixtures de ejecución (11 lib 1.6 y dos legacy), ocho
de medición lib 1.6 y seis AOSP de conformance. Las once extensiones
lib 1.6 tienen perfiles exactos; el rol de ejecución de los dos APK legacy
sólo refleja pruebas de constructor históricas y no les concede admisión.

## Explicación del delta heredado

Se capturó el binario de auditoría existente antes de recompilar:

```text
compat-audit SHA-256:
09a68f36b841efdce241cd4c370529ff4e35f122a655f68036ed8b9d01fc95fe
```

La auditoría estática heredada de los once APK del directorio histórico de
medición dio 11 analizados, cero errores, siete candidatos estructurales,
cuatro bloqueos de wrappers, cero invocaciones omitidas y cero opcodes
no soportados. La baseline anterior esperaba 387 superficies externas no
registradas; el binario heredado contó 374. Un inventario independiente de los
`method_ids` y de cada instrucción DEX explicó exactamente la diferencia:

| APK fijado | Baseline anterior | Auditoría heredada | Diferencia |
| --- | ---: | ---: | ---: |
| FoolSlide Customizable 1.6.6 | 65 | 52 | −13 |
| Hayalistic 1.6.59 | 91 | 90 | −1 |
| MangaPlus 1.6.65 | 68 | 67 | −1 |
| ReadManga 1.6.89 | 94 | 93 | −1 |
| Los otros siete APK | sin cambio | sin cambio | 0 |

Hayalistic, MangaPlus y ReadManga llaman la misma superficie
`static Lkotlin/collections/CollectionsKt;->lastOrNull(Ljava/util/List;)Ljava/lang/Object;`
que FoolSlide. La unión global pierde trece superficies, mientras que la suma
de los recuentos por APK pierde dieciséis. Es una reducción de registros
pendientes del instrumento estático; no significa que trece fallos de ejecución
de sitios se hayan resuelto.

Estas son las trece superficies que dejan de figurar en FoolSlide. Cada fila
aparece en un método DEX; `removeHeader` se invoca dos veces en ese método.

| Invocación | Identidad exacta del método | Invocaciones |
| --- | --- | ---: |
| direct | `Ljava/time/format/DateTimeFormatterBuilder;-><init>()V` | 1 |
| virtual | `Ljava/time/format/DateTimeFormatterBuilder;->appendPattern(Ljava/lang/String;)Ljava/time/format/DateTimeFormatterBuilder;` | 1 |
| virtual | `Ljava/time/format/DateTimeFormatterBuilder;->parseDefaulting(Ljava/time/temporal/TemporalField;J)Ljava/time/format/DateTimeFormatterBuilder;` | 1 |
| virtual | `Ljava/time/format/DateTimeFormatterBuilder;->toFormatter(Ljava/util/Locale;)Ljava/time/format/DateTimeFormatter;` | 1 |
| static | `Ljava/time/LocalDate;->now()Ljava/time/LocalDate;` | 1 |
| virtual | `Ljava/time/LocalDate;->getYear()I` | 1 |
| static | `Lkotlin/collections/CollectionsKt;->lastOrNull(Ljava/util/List;)Ljava/lang/Object;` | 1 |
| virtual | `Lokhttp3/Request$Builder;->method(Ljava/lang/String;Lokhttp3/RequestBody;)Lokhttp3/Request$Builder;` | 1 |
| virtual | `Lokhttp3/Request$Builder;->removeHeader(Ljava/lang/String;)Lokhttp3/Request$Builder;` | 2 |
| virtual | `Lorg/jsoup/nodes/Document;->createElement(Ljava/lang/String;)Lorg/jsoup/nodes/Element;` | 1 |
| virtual | `Lorg/jsoup/nodes/Element;->attr(Ljava/lang/String;Ljava/lang/String;)Lorg/jsoup/nodes/Element;` | 1 |
| virtual | `Lorg/jsoup/nodes/Element;->nextSibling()Lorg/jsoup/nodes/Node;` | 1 |
| virtual | `Lorg/jsoup/nodes/TextNode;->text()Ljava/lang/String;` | 1 |

El parche heredado añadió también
`Lorg/jsoup/nodes/Document;->toString()Ljava/lang/String;`: es la decimocuarta
registración, pero ningún APK de ese conjunto la referencia directamente.
Por ello no explica una superficie adicional del delta. La auditoría sólo
comprueba la registración exacta de la clase declarada en la invocación;
la resolución virtual por receptor puede ser distinta durante la ejecución.

## Selección de roles y baseline

La selección para la auditoría ahora usa el rol del manifiesto:

```bash
compat-audit gaps Tests/corpus --role measurement
```

El modo histórico `gaps <APK-o-directorio>` continúa siendo útil para una
inspección explícita. Cuando se usa `--role`, se validan la versión y el tamaño
del manifiesto, las rutas relativas, los roles y hashes, los paths duplicados,
la resolución de symlinks dentro del corpus y el tamaño de cada APK. El hash
se comprueba sobre el mismo buffer que recibe la auditoría. Una sustitución
posterior a la selección no puede actualizar silenciosamente el lock.
Las lecturas tienen un límite durante el acceso al archivo: bloques de hasta
64 KiB y, como máximo, un byte adicional al tope para detectar crecimiento.
La consulta previa del tamaño no se usa como único límite de memoria.
Las pruebas incluyen selección de un perfil promovido en un path histórico,
alteración de bytes después de seleccionar, escapes, duplicados, symlinks y
archivos demasiado grandes. El límite del manifiesto es 256 KiB y 512
artefactos; cada APK mantiene el límite de 128 MiB del verificador.

La baseline se deriva sólo de los APK cuyo rol es `measurement`. Corregir
roles retira registros del conjunto medido; registrar métodos de host reduce
sus superficies pendientes. Esas dos causas se mantienen separadas al
revisar los cambios. La baseline no concede admisión ni se usa para aprobar
un contrato de ejecución.

La baseline final mide ocho APK: Hayalistic, Komga, MangaPandaOnl, MangaPlus,
NHentai.xxx, PixivComic, ReadManga y XCOMIC. Registra cuatro candidatos
estructurales, cuatro APK bloqueados por wrappers y 359 superficies externas
no registradas. Los métodos/instrucciones y bloqueos de esos ocho APK
permanecen iguales a la baseline anterior; sólo los tres usos compartidos de
`lastOrNull` reducen sus recuentos individuales en uno. El resultado se
calculó desde dos ejecuciones de la auditoría con salida idéntica byte a byte.

| Paso | Conjunto auditado | Superficies pendientes |
| --- | --- | ---: |
| Baseline anterior | once APK de medición anteriores | 387 |
| Registraciones de host heredadas | los mismos once APK | 374 |
| Corrección de roles EternalMangas/DocTruyen3Q | nueve mediciones | 373 |
| Promoción de FoolSlide | ocho mediciones | 359 |

Retirar un APK del conjunto medido puede retirar superficies exclusivas del
recuento; no prueba que esas APIs se hayan implementado. Por eso el último
descenso de catorce se registra como cambio de selección, separado del
descenso de trece causado por registraciones de host.

## Pruebas de límites independientes

`FoolSlideBoundaryTests` comprueba la identidad de release del catálogo,
rechazo de bytes alterados y de otro APK firmado, límites de tamaño, claves y
tipos de preferencias no medidos y URL con host vacío, credenciales,
query, fragmento o caracteres de control. También verifica que filtros y
entradas del modelo rechazadas no llegan al transporte, y que imágenes con
URL inseguras o demasiado grandes no producen una solicitud.

Las regresiones del host cubren el presupuesto compartido de nodos para
elementos desprendidos, atributos globales y por elemento, sustitución sin
aumentar su recuento, límites de strings al modificar o serializar HTML, y
presupuesto de selectores compartido. El nuevo presupuesto acumulado de
mutación cobra tags, claves y valores aceptados, incluidas sustituciones,
para limitar almacenamiento y trabajo repetido. Una mutación rechazada deja
el valor anterior intacto. La solicitud OkHttp previa también se conserva
cuando `Request.Builder.method` recibe un body inválido, un body para
GET/HEAD, POST sin body o un método fuera del subconjunto medido.

La prueba del contrato de búsqueda registra el comportamiento exacto del
APK: pedir página dos repite el mismo POST de búsqueda, sin cambiar su URL
ni añadir un campo de paginación. Esta evidencia no se presenta como
paginación independiente de resultados de búsqueda. Las otras operaciones
probadas también usan respuestas offline; no se visitaron sitios de mangas.

## Linux y Apple

El workflow Swift CI conserva la suite y el CLI optimizado de macOS y añade
Ubuntu 24.04 con Swift 6.3.3 desde el tarball oficial fijado por SHA-256
`da8272a5fddccd65b1529ed0e52e04526e2eadd4237d58d6220efeb973c6cd19`.
Ejecuta MihonCompatKit, KamiCore, el CLI optimizado y la selección de medición
por manifiesto. Instala los headers SQLite y crea un módulo temporal
`SQLite3`, comprueba su importación y ejecuta la suite KamiCore con SQLite
habilitado. Esto impide que una suite portable sin ese módulo se confunda
con pruebas reales de persistencia y admisión.

Los workflows iOS Build e IPA Package permanecen como verificaciones Apple
separadas. El tarball se contrastó con el endpoint oficial existente. El
registro inicial local precedió a CI; los resultados publicados para `ecc97bc`
se detallan al final de esta sección de continuidad.

## Registro de resultados

Los logs y snapshots locales están en
`.git/checkpoints/20261003-continuation/` y el respaldo heredado en
`.git/checkpoints/20261003-before-continuation/`. Incluyen los hashes del
corpus, el hash del binario de auditoría y el inventario de invocaciones nuevo.
`corpus-boundaries-focused.log` registra 17/17 pruebas focalizadas verdes:
13 `FoolSlideBoundaryTests` y cuatro selecciones de `CorpusLockTests`.
`corpus-lock-promoted.log` registra las siete pruebas completas del lock
verdes, incluidas firmas, roles y baseline. El contrato final registrado en
`foolslide-contract-verified.log` pasa 31/31: ocho pruebas de fuente, ocho
de host, trece de límites independientes y dos de jerarquía externa.
`foolslide-shared-surface-regressions.log` registra 58/58 regresiones
compartidas verdes sobre solicitudes, HTML, interceptores y perfiles previos.
`measurement-role-9.txt` registra el estado intermedio después de corregir
EternalMangas y DocTruyen3Q: nueve mediciones, cinco candidatos estructurales,
cuatro APK bloqueados por wrappers, 373 superficies pendientes, cero errores,
cero invocaciones omitidas y cero opcodes no soportados. La corrección de
roles baja 374 a 373 en la unión; se distingue del descenso heredado
387 a 374 sobre los once APK anteriores.
`measurement-role-8-first.txt` y `measurement-role-8-repeat.txt` son idénticos:
ocho mediciones, cuatro candidatos estructurales, cuatro APK bloqueados por
wrappers, 359 superficies pendientes y cero errores, invocaciones omitidas
u opcodes no soportados. El binario que produjo esas capturas tiene SHA-256
`43c06075eb30a72fc7db1d25c82beb98f848c858f7cb1bd862b0cbd1acbefa7b`.
`integrated-packages.log` registra la suite conjunta Linux con
317/317 MihonCompatKit y 26/26 KamiCore portable, sin fallos.
`integrated-core-sqlite.log` registra 45/45 KamiCore con el módulo SQLite
habilitado, incluyendo persistencia y admisión. Los 27 paths y hashes de APK
se volvieron a contrastar después de las tres promociones de rol y permanecen
idénticos al checkpoint inicial. `integrated-release-build.log` registra la
compilación del CLI optimizado terminada en 91.95 segundos. Dos auditorías
optimizadas por rol también produjeron salida idéntica, con SHA-256 de salida
`e9337a6debb95b1e33683db4d48d490d1ec8766e44f9c8e5c0ae32f50744420d`.
El binario Release tiene SHA-256
`1ab66669c0b90957eda6a57fdccf99d89815af57bbd52a790ad17665e8c4ce44`.
Al capturar esos logs locales todavía faltaba CI Apple y la ejecución del
workflow Linux nuevo; ese estado inicial fue reemplazado por la evidencia
publicada a continuación.

La primera compilación de simulador del commit `94e4b80` detectó una
ambigüedad de `Category` al importar el SDK Apple. Las cinco anotaciones de
tipo de la UI se cualificaron como `KamiCore.Category`; el parser Linux no
había detectado ese conflicto de tipos. Las nuevas ejecuciones del
[PR #10](https://github.com/taizaki69/Kami/pull/10) confirmaron el commit
corregido `ecc97bc20adbb57dd62c4d1618319306a3f02c08`:

- [Swift CI 37164772232](https://github.com/taizaki69/Kami/actions/runs/37164772232):
  Linux y macOS pasan 317 pruebas MihonCompatKit y 45 KamiCore con SQLite cada
  uno; el CLI optimizado compila. Linux conserva ocho mediciones y 359 gaps.
- [iOS Build 37164772212](https://github.com/taizaki69/Kami/actions/runs/37164772212):
  simulador y dispositivo genérico sin firma compilan correctamente.
- [IPA Package 37164772208](https://github.com/taizaki69/Kami/actions/runs/37164772208):
  genera el artefacto unsigned `11289615627` (3,642,440 bytes; digest del
  archivo del artefacto `sha256:e1c8b106897b9c02171a4d5cd97dbe65328d4788f0b78721cf927c059f385ac2`).

Apple usa Xcode 16.4 / Swift 6.1.2; Linux usa Swift 6.3.3. El fallo anterior
no se considera una verificación Apple aprobada. Estos resultados pertenecen
a `ecc97bc`, no prueban los cambios de preferencias descritos a continuación.

## Continuación de preferencias persistidas

`assistant/source-preferences-20261003` parte de `ecc97bc`. El contrato de
producto cubre únicamente FoolSlide Customizable 1.6.6: URL HTTPS y booleano
`adult`. Validar un borrador no construye DEX ni transportes, ni concede
admisión. El documento persistido contiene valores completos y tipados,
identidad exacta, versión de esquema y revisión; no incorpora las antiguas
preferencias genéricas ni estado de confianza, cookies o políticas de red.

Las pruebas SQLite reales comprueban reapertura, migración del esquema 2 a 3,
configuración deshabilitada, conservación de confianza/progreso/historial,
reautenticación del APK al guardar, compare-and-swap, límites UTF-8, tipos y
campos desconocidos, documento corrupto y rollback de fallos inducidos mediante
triggers. La readmisión de la misma identidad conserva ajustes; un cambio de
identidad los invalida dentro de la misma transacción de instalación.

La URL sólo puede cambiar si no hay ningún manga guardado bajo ese source ID.
Se prueban ambos órdenes de la carrera: guardar primero la URL rechaza el
resultado antiguo sin insertar manga/capítulos; guardar primero el resultado
impide cambiar la URL. Un snapshot de configuración incompleto o antiguo no
puede eludir esa comprobación. `LibraryService.refresh` y la pantalla de detalle
usan la escritura transaccional con el token de configuración del runtime.

Los fixtures reales verifican que los valores restaurados producen el GET o
POST adulto correspondiente del APK. Baozi mantiene banner `0` cuando un
conjunto parcial omite esa clave; no se añade un formulario para sus modos no
medidos. La selección de perfiles, roles y los 27 APK no cambian en esta fase.

La revisión de vida útil cubre referencias retenidas después de reemplazar o
retirar una fuente, peticiones antiguas y respuestas tardías de transportes no
cooperativos, rechazo de reasignar una imagen a otra instancia y recuperación
del presupuesto de operaciones. La caché separa campos HTTP de IDs internos;
dos pruebas evitan que cabeceras con nombres coincidentes suplanten esos IDs.
Cancelar un waiter rechaza su resultado y conserva la descarga/caché para los
demás. Un ejecutor de imagen ocupa un solo slot de vida útil. Estas propiedades
no revocan bytes ya entregados ni añaden permisos de ejecución de APK.

Los resultados de esta fase se conservan en
`.git/checkpoints/20261003-source-preferences/`. `integrated-compat.log` registra
332/332 pruebas de MihonCompatKit; `integrated-core-sqlite.log` registra 79/79
pruebas Core con SQLite real y `integrated-core-portable.log` registra 37/37
sin el módulo SQLite. El CLI Release compila en 49.67 segundos y su
SHA-256 es `d0a174d778705f6a15442312b671f97b0f39a7e0727a2d8f75ec28652470a2fd`.
La auditoría por rol produce exactamente la salida de la fase anterior
(`e9337a6debb95b1e33683db4d48d490d1ec8766e44f9c8e5c0ae32f50744420d`): ocho
mediciones, cuatro candidatos estructurales, cuatro bloqueos de wrappers, 359
superficies pendientes y cero errores, invocaciones omitidas u opcodes no
soportados. El parser Linux acepta los 13 archivos de la app, pero ese parse
no es typecheck Apple ni una prueba de interacción.
El cuerpo del PR de esta rama registra el SHA y los workflows que verifican
la implementación publicada; la compilación o el IPA no prueban una sesión
real de lectura, rendimiento físico, sitios vivos ni compatibilidad general.

La publicación de preferencias se verificó en el commit exacto
`0ae9c4ded6e5dd01f577798122789827ec2e3842` del
[PR #11](https://github.com/taizaki69/Kami/pull/11):

- [Swift CI 37167605576](https://github.com/taizaki69/Kami/actions/runs/37167605576):
  Linux y macOS pasan 332 pruebas MihonCompatKit y 79 Core con SQLite cada
  uno; ambos compilan el CLI optimizado.
- [iOS Build 37167605433](https://github.com/taizaki69/Kami/actions/runs/37167605433):
  simulador y dispositivo genérico sin firma compilan correctamente.
- [IPA Package 37167605408](https://github.com/taizaki69/Kami/actions/runs/37167605408):
  artefacto unsigned `11290686076`, 3,806,697 bytes, digest del archivo
  `sha256:5553c69529f1a283e2411924f344856f46263429bb4a732ec19694873d08d7ab`.

Estos resultados corresponden al checkpoint de preferencias, anterior a las
actualizaciones de biblioteca descritas a continuación.

## Actualizaciones manuales e historial

`assistant/library-updates-20261003` parte de `0ae9c4d`. La migración 4 conserva
IDs, lectura, marcadores e historial de capítulos que ya no aparecen en una
respuesta. Sólo los capítulos actuales se muestran en el catálogo. Un ledger
por manga y URL impide anunciar de nuevo capítulos que desaparecen y vuelven.
La primera consulta exitosa, incluso vacía, establece una baseline silenciosa;
las siguientes consultas desde Detalle o desde el escáner registran novedades
si el manga pertenece a la biblioteca. Las importaciones directas no generan
notificaciones históricas.

Cada revisión captura los mangas de la biblioteca y la revisión de su
pertenencia. Retirar y volver a añadir un manga invalida el resultado anterior.
Metadata, capítulos, descubrimientos y resultado del manga se guardan en una
transacción que vuelve a comprobar la configuración autenticada de la fuente.
El escáner limita la concurrencia a tres fuentes distintas y serializa los
mangas de cada fuente. Una fuente ausente o deshabilitada no se activa.
`ONLY_FETCH_ONCE` se respeta después de la primera baseline exitosa; las
actualizaciones explícitas de Detalle siguen disponibles.

Cancelar invalida el ID durable de la revisión, conserva los resultados
confirmados y descarta callbacks tardíos. Una segunda revisión espera a que
termine el trabajo cancelado. La recuperación local marca las revisiones
interrumpidas sin empezar peticiones. Los motivos persistidos son valores
finitos; no guardan respuestas, URLs ni textos de errores del transporte.
El feed usa cursor estable y un botón para cargar más, en lugar de truncar
silenciosamente después de 500 capítulos. Historial y Actualizaciones vuelven
a consultar el capítulo y sus vecinos al abrirlo para recuperar el progreso
actual. Leer las listas no marca capítulos como leídos.

MangaDex nativo usa el transporte acotado y cancelable compartido. Los errores
HTTP y los agregados de capítulos incompletos fallan antes de guardar un
catálogo; una respuesta vacía explícita sigue siendo válida. Se comprueban
también respuestas tardías no cooperativas, el presupuesto de 16 MiB y los
contadores de paginación. No se consultó MangaDex ni ningún sitio de manga
para estas pruebas.

La evidencia de esta fase se guarda en
`.git/checkpoints/20261003-library-updates/`. Swift 6.3.3 pasa las suites
integradas: 332/332 MihonCompatKit, 121/121 Core con SQLite real y 45/45 Core
portable sin ese módulo. Dentro de las 121 están las 20 pruebas del ledger,
13 de coordinación, ocho de MangaDex y una de persistencia de la estrategia
de actualización. La primera ejecución del filtro de coordinación detectó
una precondición errónea en su fixture: `replaceChapters` ya había establecido
la baseline que el test esperaba atribuir al escáner. Se corrigió la fixture
para empezar sin carga previa; el filtro final y la suite integrada pasan.

Dos regresiones adicionales de coordinación cubren un error de commit SQLite,
que debe informarse como almacenamiento y no como fallo del sitio, y dos
escrituras terminales fallidas, tras las cuales otra revisión explícita puede
recuperar el registro como interrumpido y volver a empezar. El parse de los
14 archivos Swift de App y `git diff --check` pasan. Ese parse no es typecheck
Apple. El cuerpo del PR registra el commit publicado y sus workflows Apple;
los resultados de PR #11 no se atribuyen a estos cambios. Esta fase conserva
los perfiles, APK y baseline de compatibilidad anteriores.

## Descargas manuales y lectura local

`assistant/offline-downloads-20261003` parte de `36e038a` (PR #12). La migración
5 añade trabajos con revisión e identidad de intento, recibos de páginas,
publicación preparada/completa y limpieza pendiente. Filas del antiguo scaffold
se migran a pausadas/no verificadas. Retirar un manga, cambiar configuración o
deshabilitar/reemplazar una fuente invalida los intentos pendientes; lectura,
marcadores, historial y descargas ya terminadas se conservan.

La cola manual procesa un capítulo y una página cada vez. Usa el `ImageRequest`
de la fuente con su ejecutor y ámbito originales, una caché desactivada y
reservas previas de espacio. Cancelar invalida primero SQLite y después cancela
y drena las peticiones. Reintentar obtiene una fuente y lista de páginas nuevas,
empezando desde cero. El límite de 4.096 ejecutores interpretados ahora devuelve
indisponibilidad en vez de perder el ejecutor y usar sólo URL/cabeceras.

El almacenamiento usa directorios UUID, nombres ordinales, manifiestos canónicos
y hashes SHA-256. No sigue symlinks ni acepta enlaces a archivos externos. Una
revisión independiente encontró el cierre entre `linkat(temp, final)` y
`unlinkat(temp)`: quedaban dos nombres internos para el mismo inode y la limpieza
los rechazaba. La corrección permite exclusivamente esa pareja interna con dos
enlaces exactos; la regresión reproduce página/manifiesto en staging/publicado
y conserva el rechazo de enlaces externos y archivos especiales.

La apertura offline comprueba la generación completa en SQLite, el manifiesto,
los recibos y todos los archivos esperados; cada página vuelve a comprobar tamaño
y hash antes de decodificarse. Una lease mantiene los archivos de un lector
abierto mientras el borrado bloquea lectores nuevos. Cerrar la última lease
permite limpiar y confirmar el borrado. Los fallos locales no disparan red.
Si la app no puede abrir su base durable, el fallback en memoria no obtiene
autoridad para reconciliar o borrar la carpeta real de descargas.

En Linux, Swift 6.3.3 pasa 333/333 MihonCompatKit, 175/175 Core con SQLite real y
60/60 Core portable. Las 54 pruebas añadidas a Core/SQLite incluyen 22 de
persistencia, 17 del coordinador, 11 del filesystem, tres de snapshots/caché y
una que rechaza validación de imágenes cuando ImageIO no está disponible.
El coordinador cubre respuesta tardía después de cancelar, registro revocado,
retry desde cero, fallo de commit y fallo de escritura terminal, recuperación
local, reserva previa a ejecución y lectura sin consultar el proveedor de
fuentes. El decoder real tiene pruebas específicas para ejecutarse en Apple;
las fixtures Linux del filesystem no se atribuyen a ImageIO.

El CLI optimizado compila. Las 27 fixtures bloqueadas se verifican sin cambiar
APK ni manifest; la auditoría de ocho measurement conserva cuatro candidatos
estructurales, cuatro bloqueados por wrappers, 359 gaps, cero errores y cero
opcodes no soportados. Estos recuentos estáticos no amplían compatibilidad.
Logs y checkpoints: `.git/checkpoints/20261003-offline-downloads/`. El PR de
implementación registra el commit y sus resultados Apple exactos. Compilación
de simulador/dispositivo e IPA no prueban interacción, rendimiento físico,
transferencias de fondo ni disponibilidad de sitios reales.

### Corrección detectada en Apple — 4 de octubre

El primer commit de descargas, `b0fc130`, compiló para simulador y dispositivo
y generó su IPA sin firma. Linux pasó 333 pruebas de compatibilidad y 175 Core.
En macOS, las 333 de compatibilidad pasaron, pero una de las 178 Core falló:
ImageIO aceptaba un PNG truncado de la regresión y lo declaraba completo.
Ese resultado no se considera una verificación satisfactoria del PR.

La corrección comprueba primero la estructura PNG: límites y orden de chunks,
CRCs, cabecera única y bloque IEND vacío al final. El decoder de ImageIO sigue
siendo necesario para interpretar píxeles; otros formatos conservan sus
comprobaciones ImageIO. Seis regresiones portables prueban truncamiento en
cada posición después de la firma, CRCs y longitudes corruptos, orden, chunks
desconocidos y cancelación. La prueba Apple original se conserva y añade PNG
sin IEND y CRC corrupto.

Tras la corrección, Linux pasa 181/181 Core con SQLite y 66/66 Core portable.
Los logs `core-sqlite-png-final.log`, `core-portable-png-final.log` y la evidencia
del fallo inicial quedan en el mismo checkpoint. El PR registra los workflows
del commit corregido; los builds anteriores no se atribuyen a ese nuevo hash.
