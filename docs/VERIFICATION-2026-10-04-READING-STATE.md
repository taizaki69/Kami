# Verificación del estado de lectura — 4 de octubre de 2026

La rama `assistant/atomic-reader-state-20261004` parte de
`7bcbe7cb94c80527dd371a746fe591308f91aa49`
([PR #15](https://github.com/taizaki69/Kami/pull/15)), cuya verificación exacta
en Linux, macOS, simulador, dispositivo e IPA está registrada en el
[checkpoint anterior](VERIFICATION-2026-10-04-NATIVE-BACKUPS.md).

## Alcance

Página, historial y leído al terminar pasan a una sola transacción. La acción
manual de leído/no leído confirma su resultado antes de cambiar el checkmark.
Los targets provienen del mismo snapshot que el capítulo y quedan vinculados
al Store, al epoch durable y a las identidades UTF-8 de manga/capítulo. Se
retiran los métodos públicos anteriores que aceptaban sólo IDs.

El lector conserva esos targets durante reintentos, lectura offline/online y
navegación. Verifica contexto tras las esperas y cierra leases rechazados.
La cola propiedad de AppModel conserva el último guardado aunque desaparezca
la vista; los errores retenidos permiten reintentar el intent original.
Ver [Reading state](READING_STATE.md) para contratos, límites y exclusiones.

## Estado de verificación

La suite MihonCompatKit pasa **371/371** en Linux con Swift 6.3.3, y Core con
el módulo SQLite pasa **270/270**. La suite portable de Core pasa **95/95**
por separado. Las 47 regresiones nuevas se distribuyen en 31 casos de persistencia
y 16 de la cola de escritura.

La persistencia cubre migración desde schema 5, epoch durable y corrupto,
targets ajenos/caducados, identidades exactas, capítulos ocultos/descargados,
límites de tipos/textos/conteos, movimiento hacia atrás, conservación del
bookmark/duración y rollback de toda la operación ante fallos de historial.
La primera ejecución encontró un error en una fixture que modificaba dos
mangas; se acotó al ID pretendido y el rerun enfocado pasó **31/31**.

La cola usa compuertas deterministas para suspender escrituras sin sleeps.
Comprueba cancelación del observador/cierre, conservación de la operación
propiedad de la app, coalescencia con el último índice y evidencia de fin,
orden de «No leído», reintento exacto, rechazo de reintentos superados,
fallos independientes por campo, límites de pendientes/errores y una frontera
de espera que no incluye escrituras posteriores. El aviso de errores omitidos
sobrevive al éxito del último reintento hasta su reconocimiento explícito.

La revisión independiente de Core y la cola no dejó defectos concretos
pendientes. La integración verifica el target después de esperas, invalida
sincrónicamente la carga al seleccionar otro capítulo y mantiene los fallos
fuera de la vida de la vista. Antes de salir o vaciar las páginas, captura un
cambio que SwiftUI aún no haya notificado, sin repetir un índice ya encolado.
El parse de SwiftUI y `git diff --check` pasan.
La publicación y los workflows Apple deben verificar el commit final; no se
deduce su resultado de estas pruebas Linux.

Logs, revisiones y estado de publicación se guardan en
`.git/checkpoints/20261004-atomic-reader-state/`. Los resultados finales y el
PR deben identificar el commit exacto. Un parse de SwiftUI en Linux no es
una compilación Apple ni una prueba de interacción en un dispositivo.

## Trabajo restante

No se habilita restauración. Faltan binding durable de Foo, invalidación entre
escenas, barreras para intents y operaciones pendientes, protección de otros
productores de cambios, preview inmutable y fusión atómica. La rotación del
epoch deberá pertenecer a esa transacción de restore; no existe una API pública
para rotarlo por separado. Tampoco se demuestra rendimiento/memoria en iOS,
interacción con Files ni ejecución de nuevos APK o sitios reales.
