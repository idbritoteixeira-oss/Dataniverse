# Dataniverse

Aplicativo Flutter para organizar, explorar e transformar dados em insights mais claros.

## Run & Operate

- `flutter pub get` — install Dart and Flutter dependencies
- `flutter run` — run the mobile app on a connected device/emulator
- `flutter run -d chrome` — run the web target
- `flutter analyze` — static analysis
- `flutter test` — widget tests
- `flutter build apk --release` — production Android APK
- `pnpm --filter @workspace/api-server run dev` — run the API server (port 5000)
- `pnpm run typecheck` — full typecheck across all packages
- `pnpm run build` — typecheck + build all packages
- `pnpm --filter @workspace/api-spec run codegen` — regenerate API hooks and Zod schemas from the OpenAPI spec
- `pnpm --filter @workspace/db run push` — push DB schema changes (dev only)
- Required env: `DATABASE_URL` — Postgres connection string

## Stack

- Flutter / Dart, Material 3
- pnpm workspaces, Node.js 24, TypeScript 5.9
- API: Express 5
- DB: PostgreSQL + Drizzle ORM
- Validation: Zod (`zod/v4`), `drizzle-zod`
- API codegen: Orval (from OpenAPI spec)
- Build: esbuild (CJS bundle)

## Where things live

- `lib/main.dart` — initial Dataniverse app and theme
- `android/` — Android Gradle project and native entry point
- `web/` — Flutter web shell
- `.github/workflows/android_build.yml` — CI build, analysis, tests, and APK artifact

## Architecture decisions

- The Flutter application lives at the repository root so GitHub Actions can run the standard Flutter commands without extra working-directory configuration.
- The initial app uses only Flutter SDK and `cupertino_icons`, keeping the first build dependency-light and reproducible.
- Android uses Java 17 and the Flutter Gradle plugin loader required by current stable Flutter templates.

## Product

O Dataniverse começa com uma experiência de dashboard para visualizar coleções,
insights e atividade recente, servindo como base para as próximas telas do
produto.

## User preferences

_Populate as you build — explicit user instructions worth remembering across sessions._

## Gotchas

_Populate as you build — sharp edges, "always run X before Y" rules._

## Pointers

- See the `pnpm-workspace` skill for workspace structure, TypeScript setup, and package details
