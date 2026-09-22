# Dataniverse

Aplicativo Flutter para organizar, explorar e transformar dados em insights
mais claros.

## Comandos

- `flutter pub get` — instala as dependências Dart
- `flutter run` — executa o aplicativo em um dispositivo ou emulador
- `flutter run -d chrome` — executa a versão web
- `flutter analyze` — executa a análise estática
- `flutter test` — executa os testes de widget
- `flutter build apk --release` — gera o APK Android de produção

## Estrutura

- `lib/main.dart` — aplicativo inicial e tema do Dataniverse
- `android/` — projeto Android nativo e Gradle Wrapper
- `web/` — shell da aplicação Flutter Web
- `test/` — testes automatizados
- `.github/workflows/android_build.yml` — análise, testes, build e upload do APK

## Decisões

- O projeto usa exclusivamente Flutter e Dart.
- O aplicativo vive na raiz do repositório para que o GitHub Actions execute os
  comandos Flutter diretamente.
- O primeiro build usa apenas o Flutter SDK e `cupertino_icons`, mantendo as
  dependências pequenas e reprodutíveis.
- O Android usa Java 17 e o Flutter Gradle Plugin Loader do template stable.

## Produto

O Dataniverse começa com uma experiência de dashboard para visualizar coleções,
insights e atividade recente, servindo como base para as próximas telas.
## User preferences

_Populate as you build — explicit user instructions worth remembering across sessions._

## Gotchas

_Populate as you build — sharp edges, "always run X before Y" rules._
