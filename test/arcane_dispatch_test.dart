import 'package:flutter_test/flutter_test.dart';

import 'bonded/bonded_suite.dart' as bonded;
import 'core/core_suite.dart' as core;
import 'crypto/crypto_suite.dart' as crypto;
import 'policy/policy_suite.dart' as policy;
import 'probes/probes_suite.dart' as probes;
import 'surface_suite.dart' as surface;
import 'transport/transport_suite.dart' as transport;

void main() {
  group('bonded', bonded.main);
  group('core', core.main);
  group('crypto', crypto.main);
  group('policy', policy.main);
  group('probes', probes.main);
  group('surface', surface.main);
  group('transport', transport.main);
}
