# Verificación de identidad de capítulos — 4 de octubre de 2026

La rama `assistant/exact-chapter-url-identity-20261004` parte de
`b15344da383a33b6a2d56d83fe2ed0f46d4a0877`
([PR #17](https://github.com/taizaki69/Kami/pull/17)), verificado en Linux,
macOS, simulador/dispositivo e IPA. El [registro anterior](VERIFICATION-2026-10-04-CONTENT-BINDING.md)
identifica sus workflows.

Swift compara como iguales ciertos textos Unicode con bytes distintos.
Usar esas cadenas como claves de capítulos podía omitir un capítulo,
actualizar la fila equivocada o no detectar una desaparición. SQLite conserva
esas URLs como claves distintas. La reconciliación ahora usa los bytes UTF-8
exactos para capítulos entrantes, filas existentes y descubrimientos conocidos.
Los duplicados exactos conservan sus primeros metadatos y orden.

El ID de un descubrimiento sigue siendo una cadena opaca, ahora ASCII formada
por el ID del manga y Base64 de los bytes de la URL. Así la paginación de
AppModel y las listas SwiftUI no colapsan ambos capítulos. La igualdad del
cursor también distingue sus bytes; el orden y las consultas SQL no cambian.
Estos IDs de presentación no se persisten ni son claves exportadas.

Cinco pruebas nuevas fallaron sobre el padre sin modificar, con 25 aserciones
que reprodujeron el problema. Después de la corrección pasan **5/5** y la suite
completa de Core/SQLite pasa **296/296** con Swift 6.3.3 en Linux. Core portable
pasa **96/96** por separado. Cubren inserción y duplicados, dos filas previas,
progreso/leído/bookmark, historial/duración, reapertura, desaparición y pausa
de la descarga correcta, reaparición, detalle, escaneo repetido y paginación.
MihonCompatKit no cambia respecto al padre verificado con **371/371** pruebas.

Los logs, revisión y snapshot publicado quedan bajo
`.git/checkpoints/20261004-exact-chapter-url-identity/`. El PR de implementación
registra los workflows y artefactos del commit final; Linux no demuestra por
sí solo compilación o interacción Apple.

No hay migración de esquema ni cambio de admisión de extensiones. Un capítulo
omitido anteriormente necesita un nuevo refresh exitoso para volver a entrar.
No se habilita restore ni se demuestra compatibilidad con nuevos APK o sitios.
Las barreras entre operaciones/escenas, preview inmutable y fusión atómica
siguen pendientes.
