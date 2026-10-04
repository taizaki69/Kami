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
separadas. Ninguna ejecución de GitHub Actions del cambio actual se ha
atribuido a las pruebas locales. El tarball se contrastó con el endpoint
oficial existente; el job nuevo todavía requiere su propia ejecución.

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
Las verificaciones Apple y el workflow Linux nuevo siguen pendientes de CI
para el commit que integre este trabajo.

La primera compilación de simulador del commit `94e4b80` detectó una
ambigüedad de `Category` al importar el SDK Apple. Las cinco anotaciones de
tipo de la UI se cualificaron como `KamiCore.Category`; el parser Linux no
había detectado ese conflicto de tipos. Las nuevas ejecuciones del
[PR #10](https://github.com/taizaki69/Kami/pull/10) deben confirmar el commit
corregido. El cuerpo del PR y el checkpoint local registran sus SHA y runs;
el fallo anterior no se considera una verificación Apple aprobada.
