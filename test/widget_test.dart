import 'package:dataniverse/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('exibe a tela inicial do Dataniverse', (tester) async {
    await tester.pumpWidget(const DataniverseApp());

    expect(find.text('Dataniverse'), findsOneWidget);
    expect(find.text('Olá, explorador.'), findsOneWidget);
    expect(find.text('Seu universo de dados começa aqui.'), findsOneWidget);
    expect(find.text('Criar coleção'), findsOneWidget);
  });
}