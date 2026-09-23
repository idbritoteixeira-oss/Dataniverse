# Dataniverse Server

Servidor de banco de dados local em Flutter/Dart. Ele pode escutar conexões
TCP, HTTP REST e WebSocket na rede local, persiste registros JSON por rota de
tabela e mantém índices locais para consultas rápidas por campo.

## Requisitos

- Flutter no canal `stable`
- Dart compatível com o SDK definido em `pubspec.yaml`

## Executar

```bash
flutter pub get
flutter run
```

O alvo recomendado é um dispositivo ou emulador Android conectado à mesma rede
dos clientes. O aplicativo exibe os IPs local e público, as portas configuradas,
o estado do servidor e as conexões ativas.

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

## Protocolos

O aplicativo permite ativar ou desativar TCP, HTTP REST e WebSocket na tela de
configuração. O TCP usa a porta configurada como `port` (padrão `8080`). HTTP e
WebSocket compartilham a porta configurada como `httpPort` (padrão `8081`).

### TCP

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

### HTTP REST

O endpoint HTTP recebe a senha no header `X-Password` e o comando no corpo JSON:

```bash
curl -X POST http://IP_DO_ANDROID:8081/command \
  -H 'Content-Type: application/json' \
  -H 'X-Password: enx123' \
  -d '{"action":"INSERT","table":"ottsvision/logs","data":{"level":"info","message":"ok"},"seedShard":"seed_1"}'
```

Também estão disponíveis:

```text
GET  /         página de status
GET  /health   status JSON sem executar comandos
POST /command  operações autenticadas
```

### WebSocket

O WebSocket usa a mesma porta HTTP, no caminho `/ws`. A primeira mensagem de
cada conexão deve ser:

```json
{"action":"AUTH","password":"enx123"}
```

Depois da autenticação, envie os mesmos comandos JSON usados no TCP. Cada
resposta WebSocket é um objeto JSON, sem necessidade de quebra de linha.

HTTP e WebSocket facilitam o uso por clientes web e proxies, mas não removem
NAT, CGNAT ou bloqueios do provedor. Para acesso pela internet, ainda é
necessário port forwarding, túnel reverso ou um relay público.

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