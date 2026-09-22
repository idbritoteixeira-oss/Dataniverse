# Dataniverse Server

Servidor de banco de dados local em Flutter/Dart. Ele escuta conexões TCP na
rede Wi-Fi, persiste registros JSON por rota de tabela e mantém índices locais
para consultas rápidas por campo.

## Requisitos

- Flutter no canal `stable`
- Dart compatível com o SDK definido em `pubspec.yaml`

## Executar

```bash
flutter pub get
flutter run
```

O alvo recomendado é um dispositivo ou emulador Android conectado à mesma rede
dos clientes. O aplicativo exibe o IP local detectado, a porta configurada, o
estado do servidor e as conexões ativas.

## Banco local

Os dados são criados dentro do caminho configurado, com uma estrutura como:

```text
<basePath>/
└── ottsvision/
    └── logs/
        └── seed_1/
            ├── records/
            │   └── <id>.json
            └── index/
                └── idx_level.db
```

Cada registro recebe `id`, `created_at` e `action_hash` com SHA-256 quando
esses campos não são enviados pelo cliente. As configurações ficam no arquivo
`config.json` do diretório de documentos da aplicação.

## Protocolo TCP

As mensagens usam JSON delimitado por quebra de linha. O primeiro comando de
cada conexão deve autenticar o cliente:

```json
{"action":"AUTH","password":"enx123"}
```

Depois da autenticação, os comandos disponíveis são:

```json
{"action":"INSERT","table":"ottsvision/logs","data":{"level":"info","message":"ok"},"seedShard":"seed_1"}
{"action":"FIND_BY_ID","table":"ottsvision/logs","id":"<id>","seedShard":"seed_1"}
{"action":"FIND_BY_INDEX","table":"ottsvision/logs","field":"level","value":"info","seedShard":"seed_1"}
```

Todas as respostas seguem este formato:

```json
{"status":"SUCCESS","message":"...","data":{}}
```

## Verificações

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

O workflow `.github/workflows/android_build.yml` executa `pub get`, análise,
testes e build automaticamente em pushes para `main` ou manualmente pelo
GitHub Actions. O APK fica disponível como o artefato `release-apk`.