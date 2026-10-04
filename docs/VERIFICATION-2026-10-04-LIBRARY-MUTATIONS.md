# Verificación de contextos de biblioteca — 4 de octubre de 2026

La rama `assistant/library-mutation-contexts-20261004` parte de
`1c6b43e2a199171766358e51ab9d8e2c5c93a22f`
([PR #18](https://github.com/taizaki69/Kami/pull/18)), verificado en Linux,
macOS, simulador/dispositivo e IPA. El
[registro de identidad de capítulos](VERIFICATION-2026-10-04-CHAPTER-IDENTITY.md)
identifica esos workflows y su árbol.

Las escrituras de categorías, pertenencia a la biblioteca y resultados de
fuentes requieren ahora un contexto opaco emitido con sus datos. La transacción
rechaza otra instancia de Store, una generación caducada o un estado de época
inválido. Las pantallas conservan el contexto antes de programar la operación;
los servicios lo retienen mientras esperan al proveedor. El
[contrato](LIBRARY_MUTATIONS.md) detalla las APIs y límites.

Verificación local con Swift 6.3.3 en Linux:

- **310/310 Core con SQLite**, mediante el módulo de sistema conservado en
  `.git/checkpoints/20261003-continuation/sqlite-module`.
- **97/97 Core portable**, compilado por separado sin ese módulo.
- **371/371 MihonCompatKit**; no cambia la admisión ni el runtime de APK.
- Parse de todos los archivos SwiftUI y `git diff --check` satisfactorios.

Las 14 pruebas nuevas cubren contextos emparejados con snapshots (incluido
un manga aún no guardado), once variantes de escritura de categorías/pertenencia,
otra instancia de Store, cambios ordinarios, época ausente/tipo inválido/blob
excesivo, rollback tardío y reintento, resultados de fuentes existentes/nuevas,
escaneo, solicitudes rechazadas antes del proveedor y operaciones suspendidas
o encoladas. Los gates usan continuaciones y expectativas, sin sleeps ni red.
Se comparan snapshots de exportación y descarga para detectar efectos laterales.
La rotación de época ocurre solo por SQL de fixture: no existe API de restore.

Tres pruebas anteriores de rollback se adaptaron al error finito de almacenamiento
en vez del error SQLite interno; mantienen todas sus aserciones de integridad.
La prueba de cancelación del escaneo ahora pasa el contexto capturado antes
de crear la tarea, por lo que alcanza la API de producción sin renovar el contexto.
El helper de fixtures separa la lectura de la aserción de XCTest para propagar
CancellationError sin registrarlo como un fallo inesperado.

Los logs, revisión y evidencia de publicación quedan bajo
`.git/checkpoints/20261004-library-mutation-contexts/`. El PR de implementación
registra los workflows y artefactos del commit publicado; un parse Linux no
demuestra compilación ni interacción Apple.

Restore sigue deshabilitado. Faltan la barrera compartida de operaciones,
invalidación entre escenas, preview inmutable y fusión atómica. No se afirma
seguridad de todas las rutas encoladas, interacción física, disponibilidad de
sitios ni compatibilidad con APK adicionales.
