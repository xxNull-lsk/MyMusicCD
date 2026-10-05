import 'package:flutter_test/flutter_test.dart';

import 'package:my_music_cd/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const MyMusicCDApp());
    expect(find.text('我的音乐CD'), findsOneWidget);
  });
}
