# Dataniverse

Aplicativo Flutter inicial para organizar, explorar e transformar dados em
insights mais claros.

## Requisitos

- Flutter no canal `stable`
- Dart compatível com o SDK definido em `pubspec.yaml`

## Executar localmente

```bash
flutter pub get
flutter run
```

Para abrir no navegador:

```bash
flutter run -d chrome
```

## Verificações

```bash
flutter analyze
flutter test
```

## Build Android

```bash
flutter build apk --release
```

O workflow `.github/workflows/android_build.yml` executa análise, testes e
build automaticamente em pushes para `main` ou manualmente pelo GitHub
Actions. O APK fica disponível como o artefato `release-apk`.