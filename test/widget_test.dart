import 'package:dataniverse_server/config/server_config.dart';
import 'package:dataniverse_server/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('exibe a tela inicial do Dataniverse Server', (tester) async {
    final config = ServerConfig(
      port: 8080,
      password: 'test-password',
      basePath: '/tmp/dataniverse_test_data',
    );

    await tester.pumpWidget(
      DataniverseServerApp(
        configLoader: () async => config,
        wifiIpLoader: () async => '192.168.1.100',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Dataniverse Server'), findsOneWidget);
    expect(find.text('Configuração'), findsOneWidget);
    expect(find.text('Log do servidor'), findsOneWidget);
  });
}