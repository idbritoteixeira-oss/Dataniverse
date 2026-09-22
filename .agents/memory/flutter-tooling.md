---
name: Flutter tooling
description: Environment constraint for local Flutter and Android validation.
---

The local development environment does not provide Flutter, Dart, or Java, and
the available runtime modules do not include Flutter.

**Why:** The project must remain buildable through the GitHub Actions workflow,
which installs Java 17 and Flutter stable before running the Android build.

**How to apply:** Validate project structure, configuration, XML, JSON, and
workflow files locally; use the CI workflow as the source of truth for
`flutter pub get`, `flutter analyze`, `flutter test`, and `flutter build apk`.