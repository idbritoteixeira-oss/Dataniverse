# Dataniverse Server

Servidor de banco de dados local em Flutter/Dart, com persistência JSON,
índices por campo e acesso TCP autenticado pela rede Wi-Fi.

## Comandos

- `flutter pub get` — instala as dependências Dart
- `flutter run` — executa o aplicativo em um dispositivo ou emulador
- `flutter analyze` — executa a análise estática
- `flutter test` — executa os testes de widget
- `flutter build apk --release` — gera o APK Android de produção

## Estrutura

- `lib/main.dart` — interface e controle do ciclo de vida do servidor
- `lib/config/server_config.dart` — configuração persistida em `config.json`
- `lib/database/enx_db.dart` — armazenamento JSON e índices `.db`
- `lib/network/dataniverse_server.dart` — servidores TCP, HTTP REST e WebSocket
- `android/` — projeto Android nativo e Gradle Wrapper
- `test/` — testes automatizados
- `.github/workflows/android_build.yml` — análise, testes, build e upload do APK

## Decisões

- O projeto usa exclusivamente Flutter e Dart.
- O aplicativo vive na raiz do repositório para que o GitHub Actions execute os
  comandos Flutter diretamente.
- O primeiro build usa Flutter SDK, `crypto`, `path_provider`,
  `network_info_plus`, `path`, `http` e `flutter_foreground_task`.
- O Android usa Java 17 e o Flutter Gradle Plugin Loader do template stable.

## Produto

O Dataniverse Server permite iniciar um banco JSON local, receber comandos
`AUTH`, `INSERT`, `UPDATE`, `DELETE`, `FIND_BY_ID`, `FIND_BY_INDEX`,
`LIST_TABLES` e `LIST_RECORDS` via TCP, HTTP REST (`POST /command`) ou
WebSocket (`/ws`), e acompanhar os eventos pela interface do aplicativo.
TCP e HTTP/WebSocket usam portas independentes configuráveis.
## User preferences

_Populate as you build — explicit user instructions worth remembering across sessions._

## Gotchas

_Populate as you build — sharp edges, "always run X before Y" rules._
