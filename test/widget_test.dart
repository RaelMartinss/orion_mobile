import 'package:flutter_test/flutter_test.dart';

import 'package:orion_mobile/main.dart';

void main() {
  test('exposes the Orion app widget', () {
    expect(const OrionApp(), isA<OrionApp>());
  });
}
