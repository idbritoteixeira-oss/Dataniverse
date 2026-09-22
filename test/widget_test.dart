import 'package:dataniverse_server/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('exibe a tela inicial do Dataniverse Server', (tester) async {
    await tester.pumpWidget(const DataniverseServerApp());
    await tester.pumpAndSettle();

    expect(find.text('Dataniverse Server'), findsOneWidget);
    expect(find.text('Configuração'), findsOneWidget);
    expect(find.text('Log do servidor'), findsOneWidget);
  });
}