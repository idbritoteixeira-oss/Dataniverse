import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:network_info_plus/network_info_plus.dart';

import 'config/server_config.dart';
import 'database/enx_db.dart';
import 'network/dataniverse_server.dart';
import 'ui/db_editor_page.dart';

// ──────────────────────────────────────────────
// #2 / #3  FOREGROUND TASK HANDLER
// Roda em isolate separado; mantém servidor vivo
// quando o app está minimizado e exibe ícone +
// texto na barra de status do sistema.
// ──────────────────────────────────────────────
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_DataniverseTaskHandler());
}

class _DataniverseTaskHandler extends TaskHandler {
  DataniverseServer? _server;

  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {
    final config = await ServerConfig.load();
    final db = EnXDB(basePath: config.basePath);
    _server = DataniverseServer(config: config, database: db);
    await _server!.start();
    FlutterForegroundTask.updateService(
      notificationTitle: 'Dataniverse · Online',
      notificationText: 'Porta ${config.port} · aguardando conexões',
    );
  }

  @override
  Future<void> onRepeatEvent(DateTime timestamp) async {
    // Atualiza a notificação com o número de conexões ativas
    final count = _server?.connectionCount ?? 0;
    FlutterForegroundTask.updateService(
      notificationTitle: 'Dataniverse · Online',
      notificationText:
          'Porta ${_server?.config.port ?? '?'} · $count conexão(ões) ativa(s)',
    );
  }

  @override
  Future<void> onDestroy(DateTime timestamp) async {
    await _server?.stop();
    _server = null;
  }

  @override
  void onReceiveData(Object data) {
    // Pode receber comandos do UI via sendData() no futuro
  }

  @override
  void onNotificationButtonPressed(String id) {}

  @override
  void onNotificationDismissed() {}
}

// ──────────────────────────────────────────────
typedef ServerConfigLoader = Future<ServerConfig> Function();
typedef WifiIpLoader = Future<String?> Function();

void main() {
  // Necessário para flutter_foreground_task
  WidgetsFlutterBinding.ensureInitialized();
  FlutterForegroundTask.initCommunicationPort();
  runApp(const DataniverseServerApp());
}

class DataniverseServerApp extends StatelessWidget {
  const DataniverseServerApp({
    super.key,
    this.configLoader,
    this.wifiIpLoader,
  });

  final ServerConfigLoader? configLoader;
  final WifiIpLoader? wifiIpLoader;

  @override
  Widget build(BuildContext context) {
    const ink = Color(0xFF172033);
    const indigo = Color(0xFF4F46E5);

    return MaterialApp(
      title: 'Dataniverse Server',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: indigo,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F7FB),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F7FB),
          foregroundColor: ink,
          elevation: 0,
          surfaceTintColor: Colors.transparent,
        ),
        cardTheme: const CardThemeData(
          color: Colors.white,
          elevation: 0,
          margin: EdgeInsets.zero,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: Color(0xFFE4E8F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: const BorderSide(color: indigo, width: 1.5),
          ),
        ),
      ),
      home: WithForegroundTask(
        child: DataniverseServerPage(
          configLoader: configLoader,
          wifiIpLoader: wifiIpLoader,
        ),
      ),
    );
  }
}

class DataniverseServerPage extends StatefulWidget {
  const DataniverseServerPage({
    super.key,
    this.configLoader,
    this.wifiIpLoader,
  });

  final ServerConfigLoader? configLoader;
  final WifiIpLoader? wifiIpLoader;

  @override
  State<DataniverseServerPage> createState() => _DataniverseServerPageState();
}

class _DataniverseServerPageState extends State<DataniverseServerPage> {
  final _portController = TextEditingController();
  final _httpPortController = TextEditingController();
  final _passwordController = TextEditingController();
  final _basePathController = TextEditingController();
  final _networkInfo = NetworkInfo();
  final List<String> _logs = [];

  DataniverseServer? _server;
  ServerConfig? _config;
  String _localIp = 'Não detectado';
  String _publicIp = '...';
  String? _loadError;
  bool _loading = true;
  bool _saving = false;
  bool _enableTcp = true;
  bool _enableHttp = true;
  bool _enableWebSocket = true;

  bool get _isRunning => _server?.isRunning ?? false;
  int get _connectionCount => _server?.connectionCount ?? 0;

  @override
  void initState() {
    super.initState();
    _initForegroundTask();
    unawaited(_initialize());
  }

  // ──────────────────────────────────────────────
  // #2 / #3  Configura o foreground service
  // ──────────────────────────────────────────────
  void _initForegroundTask() {
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'dataniverse_channel',
        channelName: 'Dataniverse Server',
        channelDescription:
            'Mantém o servidor de banco de dados ativo em segundo plano.',
        channelImportance: NotificationChannelImportance.LOW,
        priority: NotificationPriority.LOW,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: true,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        eventAction: ForegroundTaskEventAction.repeat(5000),
        autoRunOnBoot: true,
        autoRunOnMyPackageReplaced: true,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  Future<void> _initialize() async {
    try {
      final config =
          await (widget.configLoader ?? ServerConfig.load)();
      _portController.text = config.port.toString();
      _httpPortController.text = config.httpPort.toString();
      _passwordController.text = config.password;
      _basePathController.text = config.basePath;
      _enableTcp = config.enableTcp;
      _enableHttp = config.enableHttp;
      _enableWebSocket = config.enableWebSocket;
      _installServer(config);
      await _refreshIpAddress();
      _addLog('Configurações carregadas de config.json.');
    } catch (error) {
      _loadError = 'Não foi possível carregar a configuração: $error';
      _addLog(_loadError!);
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _installServer(ServerConfig config) {
    _config = config;
    _server = DataniverseServer(
      config: config,
      database: EnXDB(basePath: config.basePath),
      onLog: _addLog,
      onConnectionsChanged: (_) {
        if (mounted) setState(() {});
      },
    );
  }

  Future<void> _refreshIpAddress() async {
    // IP local (Wi-Fi)
    try {
      final ip =
          await (widget.wifiIpLoader ?? _networkInfo.getWifiIP)();
      if (mounted && ip != null && ip.isNotEmpty) {
        setState(() => _localIp = ip);
      }
    } catch (error) {
      _addLog('Não foi possível detectar o IP Wi-Fi: $error');
    }

    // #1 IP público — lido do servidor após ele detectar
    if (_server?.publicIp != null) {
      setState(() => _publicIp = _server!.publicIp!);
    }
  }

  Future<bool> _persistForm({bool showFeedback = true}) async {
    if (_isRunning || _config == null || _saving) return false;

    final port = int.tryParse(_portController.text.trim());
    final httpPort = int.tryParse(_httpPortController.text.trim());
    final password = _passwordController.text.trim();
    final basePath = _basePathController.text.trim();

    if (port == null || port < 1 || port > 65535) {
      _showMessage('Informe uma porta entre 1 e 65535.');
      return false;
    }
    if (httpPort == null || httpPort < 1 || httpPort > 65535) {
      _showMessage('Informe uma porta HTTP entre 1 e 65535.');
      return false;
    }
    if (!_enableTcp && !_enableHttp) {
      _showMessage('Ative TCP ou HTTP antes de iniciar o servidor.');
      return false;
    }
    if (_enableTcp && _enableHttp && port == httpPort) {
      _showMessage('As portas TCP e HTTP precisam ser diferentes.');
      return false;
    }
    if (password.isEmpty) {
      _showMessage('A senha não pode ficar vazia.');
      return false;
    }
    if (basePath.isEmpty) {
      _showMessage('Informe o caminho das pastas de armazenamento.');
      return false;
    }

    setState(() => _saving = true);
    try {
      final config = _config!.copyWith(
        port: port,
        httpPort: httpPort,
        password: password,
        basePath: basePath,
        enableTcp: _enableTcp,
        enableHttp: _enableHttp,
        enableWebSocket: _enableHttp && _enableWebSocket,
      );
      await config.save();
      _installServer(config);
      _addLog('Configurações salvas em config.json.');
      if (showFeedback) _showMessage('Configurações salvas.');
      return true;
    } catch (error) {
      _showMessage('Erro ao salvar configuração: $error');
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ──────────────────────────────────────────────
  // #2 Inicia servidor + foreground service
  // ──────────────────────────────────────────────
  Future<void> _startServer() async {
    if (_isRunning) return;
    final saved = await _persistForm(showFeedback: false);
    if (!saved || _server == null) return;

    try {
      await _server!.start();

      // Inicia o Android Foreground Service
      await FlutterForegroundTask.startService(
        serviceId: 1000,
        notificationTitle: 'Dataniverse · Iniciando',
        notificationText: 'Porta ${_config!.port}',
        // Ícone na barra de status — aponta para <meta-data> no AndroidManifest
        notificationIcon: const NotificationIcon(
          metaDataName: 'com.dataniverse.notification_icon',
        ),
        callback: startCallback,
      );

      if (mounted) setState(() {});
      _showMessage(
        'Servidor Dataniverse iniciado. '
        'TCP: ${_config!.enableTcp ? _config!.port : 'off'} · '
        'HTTP: ${_config!.enableHttp ? _config!.httpPort : 'off'}.',
      );

      // Aguarda um pouco e atualiza IP público
      Future.delayed(const Duration(seconds: 3), () async {
        if (mounted && _server?.publicIp != null) {
          setState(() => _publicIp = _server!.publicIp!);
        }
      });
    } catch (error) {
      _addLog('Falha ao iniciar servidor: $error');
      _showMessage('Não foi possível iniciar o servidor: $error');
    }
  }

  // ──────────────────────────────────────────────
  // #2 Para servidor + foreground service
  // ──────────────────────────────────────────────
  Future<void> _stopServer() async {
    if (!_isRunning) return;
    await _server?.stop();
    await FlutterForegroundTask.stopService();
    if (mounted) setState(() {});
    _showMessage('Servidor Dataniverse parado.');
  }

  void _addLog(String message) {
    _logs.add(message);
    if (_logs.length > 200) _logs.removeAt(0);
    if (mounted) setState(() {});
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    unawaited(_server?.stop());
    _portController.dispose();
    _passwordController.dispose();
    _httpPortController.dispose();
    _basePathController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 20,
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BrandMark(),
            SizedBox(width: 10),
            Text(
              'Dataniverse Server',
              style: TextStyle(fontWeight: FontWeight.w800),
            ),
          ],
        ),
        actions: [
          // #5 Botão para o editor da DB
          if (_config != null)
            IconButton(
              tooltip: 'Editor da base de dados',
              icon: const Icon(Icons.table_view_rounded),
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => DbEditorPage(
                    database: EnXDB(basePath: _config!.basePath),
                  ),
                ),
              ),
            ),
          IconButton(
            tooltip: 'Atualizar IPs',
            onPressed: _refreshIpAddress,
            icon: const Icon(Icons.wifi_rounded),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final horizontalPadding =
                constraints.maxWidth >= 900 ? 64.0 : 20.0;
            final wideLayout = constraints.maxWidth >= 900;

            return SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                24,
                horizontalPadding,
                40,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1160),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PageHeader(isRunning: _isRunning),
                      if (_loadError != null) ...[
                        const SizedBox(height: 16),
                        _ErrorBanner(message: _loadError!),
                      ],
                      const SizedBox(height: 24),
                      _StatusCard(
                        isRunning: _isRunning,
                        localIp: _localIp,
                        publicIp: _publicIp,
                        port: _config?.port ?? 8080,
                        httpPort: _config?.httpPort ?? 8081,
                        enableTcp: _config?.enableTcp ?? true,
                        enableHttp: _config?.enableHttp ?? true,
                        connectionCount: _connectionCount,
                      ),
                      const SizedBox(height: 20),
                      if (wideLayout)
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: _buildSettingsCard()),
                            const SizedBox(width: 20),
                            Expanded(child: _buildLogCard()),
                          ],
                        )
                      else ...[
                        _buildSettingsCard(),
                        const SizedBox(height: 20),
                        _buildLogCard(),
                      ],
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSettingsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeading(
              icon: Icons.tune_rounded,
              title: 'Configuração',
              subtitle: 'Defina como o servidor será acessado.',
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _portController,
              enabled: !_isRunning && !_saving,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Porta TCP',
                prefixIcon: Icon(Icons.settings_ethernet_rounded),
                helperText: 'Padrão: 8080  ·  Configure o port forwarding no roteador para acesso externo',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _httpPortController,
              enabled: !_isRunning && !_saving,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Porta HTTP / WebSocket',
                prefixIcon: Icon(Icons.http_rounded),
                helperText: 'Padrão: 8081  ·  REST em /command e WebSocket em /ws',
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _enableTcp,
              onChanged: _isRunning || _saving
                  ? null
                  : (value) => setState(() => _enableTcp = value),
              title: const Text('Servidor TCP'),
              subtitle: const Text('Protocolo JSON por linhas'),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _enableHttp,
              onChanged: _isRunning || _saving
                  ? null
                  : (value) {
                      setState(() {
                        _enableHttp = value;
                        if (!value) {
                          _enableWebSocket = false;
                        }
                      });
                    },
              title: const Text('Servidor HTTP REST'),
              subtitle: const Text('Endpoint POST /command'),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              value: _enableWebSocket,
              onChanged: !_enableHttp || _isRunning || _saving
                  ? null
                  : (value) => setState(() => _enableWebSocket = value),
              title: const Text('WebSocket'),
              subtitle: const Text('Conexão persistente em /ws'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _passwordController,
              enabled: !_isRunning && !_saving,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Senha de autenticação',
                prefixIcon: Icon(Icons.lock_outline_rounded),
                helperText: 'Obrigatória no comando AUTH',
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _basePathController,
              enabled: !_isRunning && !_saving,
              decoration: const InputDecoration(
                labelText: 'Caminho dos dados',
                prefixIcon: Icon(Icons.folder_outlined),
                helperText: 'Onde records/ e index/ serão criados',
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _isRunning || _saving
                        ? null
                        : () => _persistForm(),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Salvar config.json'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed:
                        _isRunning || _saving ? _stopServer : _startServer,
                    icon: Icon(
                      _isRunning
                          ? Icons.stop_circle_outlined
                          : Icons.play_circle_outline_rounded,
                    ),
                    label: Text(
                        _isRunning ? 'Parar servidor' : 'Iniciar servidor'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeading(
              icon: Icons.receipt_long_outlined,
              title: 'Log do servidor',
              subtitle: 'Requisições e eventos em tempo real.',
            ),
            const SizedBox(height: 16),
            Container(
              height: 330,
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: const Color(0xFF101827),
                borderRadius: BorderRadius.circular(14),
              ),
              child: _logs.isEmpty
                  ? const Align(
                      alignment: Alignment.topLeft,
                      child: Text(
                        'Aguardando eventos...',
                        style: TextStyle(
                          color: Color(0xFF9AA7BD),
                          fontFamily: 'monospace',
                        ),
                      ),
                    )
                  : ListView.separated(
                      reverse: true,
                      itemCount: _logs.length,
                      separatorBuilder: (_, __) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final log = _logs[_logs.length - 1 - index];
                        return Text(
                          log,
                          style: const TextStyle(
                            color: Color(0xFFD7E0F0),
                            fontFamily: 'monospace',
                            fontSize: 12,
                            height: 1.35,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────
// Widgets de UI (sem alteração estrutural, com
// _StatusCard recebendo localIp e publicIp)
// ──────────────────────────────────────────────

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.isRunning});

  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Banco de dados na internet.',
                style:
                    Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.7,
                        ),
              ),
              const SizedBox(height: 8),
              Text(
                'Controle o acesso TCP, armazene registros JSON e consulte '
                'índices de qualquer lugar via IP público.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        _StatusPill(isRunning: isRunning),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.isRunning,
    required this.localIp,
    required this.publicIp,
    required this.port,
    required this.httpPort,
    required this.enableTcp,
    required this.enableHttp,
    required this.connectionCount,
  });

  final bool isRunning;
  final String localIp;
  final String publicIp;
  final int port;
  final int httpPort;
  final bool enableTcp;
  final bool enableHttp;
  final int connectionCount;

  String _endpoint(String host) {
    final endpoints = <String>[
      if (enableTcp) 'TCP:$port',
      if (enableHttp) 'HTTP:$httpPort',
    ];
    return endpoints.isEmpty ? host : '$host ${endpoints.join(' · ')}';
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Wrap(
          spacing: 28,
          runSpacing: 18,
          children: [
            // #1 IP local
            _MetricTile(
              icon: Icons.router_outlined,
              label: 'IP local (rede)',
              value: isRunning ? _endpoint(localIp) : localIp,
              accent: Theme.of(context).colorScheme.primary,
            ),
            // #1 IP público
            _MetricTile(
              icon: Icons.language_rounded,
              label: 'IP público (internet)',
              value: isRunning ? _endpoint(publicIp) : publicIp,
              accent: const Color(0xFF0B8F71),
            ),
            _MetricTile(
              icon: isRunning
                  ? Icons.check_circle_outline_rounded
                  : Icons.pause_circle_outline_rounded,
              label: 'Status',
              value: isRunning ? 'Rodando' : 'Parado',
              accent: isRunning
                  ? const Color(0xFF0B8F71)
                  : const Color(0xFF718096),
            ),
            _MetricTile(
              icon: Icons.people_outline_rounded,
              label: 'Conexões ativas',
              value: connectionCount.toString(),
              accent: const Color(0xFFE07A2D),
            ),
          ],
        ),
      ),
    );
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
  });

  final IconData icon;
  final String label;
  final String value;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 210,
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: accent.withValues(alpha: 0.12),
            child: Icon(icon, color: accent, size: 20),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context)
                            .colorScheme
                            .onSurfaceVariant,
                      ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style:
                      Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color:
                          Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.isRunning});

  final bool isRunning;

  @override
  Widget build(BuildContext context) {
    final color = isRunning
        ? const Color(0xFF0B8F71)
        : const Color(0xFF718096);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(30),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.circle, size: 9, color: color),
            const SizedBox(width: 8),
            Text(
              isRunning ? 'Servidor online' : 'Servidor parado',
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onErrorContainer,
        ),
      ),
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        borderRadius: BorderRadius.circular(9),
      ),
      child: const Icon(
        Icons.dns_rounded,
        color: Colors.white,
        size: 18,
      ),
    );
  }
}
