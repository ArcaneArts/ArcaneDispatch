import 'dart:io';

import 'package:arcane_dispatch/core/network_interface_repository.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses weighted addresses with default and explicit weight', () {
    RawWeightedAddress plain = RawWeightedAddress.parse('en0');
    RawWeightedAddress weighted = RawWeightedAddress.parse('10.0.0.5/3');

    expect(plain.target, 'en0');
    expect(plain.weight, 1);
    expect(weighted.target, '10.0.0.5');
    expect(weighted.weight, 3);
  });

  test('resolves interface names and literal IP addresses', () {
    List<NetworkInterfaceSnapshot> interfaces = <NetworkInterfaceSnapshot>[
      NetworkInterfaceSnapshot(
        name: 'en0',
        index: 1,
        addresses: <InternetAddress>[
          InternetAddress('10.0.0.4'),
          InternetAddress('fd00::4'),
        ],
      ),
    ];

    List<ResolvedWeightedAddress> resolved = const WeightedAddressResolver()
        .resolve(<RawWeightedAddress>[
          RawWeightedAddress.parse('en0/2'),
          RawWeightedAddress.parse('192.168.1.50'),
        ], interfaces);

    expect(resolved, hasLength(2));
    expect(resolved.first.label, 'en0');
    expect(resolved.first.weight, 2);
    expect(resolved.first.ipv4!.address, '10.0.0.4');
    expect(resolved.first.ipv6!.address, 'fd00::4');
    expect(resolved.last.ipv4!.address, '192.168.1.50');
  });

  test(
    'weighted round robin preserves weighted sequence per address family',
    () {
      WeightedRoundRobinDispatcher dispatcher =
          WeightedRoundRobinDispatcher(<ResolvedWeightedAddress>[
            ResolvedWeightedAddress(
              label: 'a',
              weight: 2,
              ipv4: InternetAddress('10.0.0.1'),
            ),
            ResolvedWeightedAddress(
              label: 'b',
              weight: 1,
              ipv4: InternetAddress('10.0.0.2'),
            ),
          ]);
      InternetAddress remote = InternetAddress('93.184.216.34');

      expect(dispatcher.dispatch(remote).address, '10.0.0.1');
      expect(dispatcher.dispatch(remote).address, '10.0.0.1');
      expect(dispatcher.dispatch(remote).address, '10.0.0.2');
      expect(dispatcher.dispatch(remote).address, '10.0.0.1');
    },
  );

  test('throws when remote address family has no local match', () {
    WeightedRoundRobinDispatcher dispatcher =
        WeightedRoundRobinDispatcher(<ResolvedWeightedAddress>[
          ResolvedWeightedAddress(
            label: 'v4',
            weight: 1,
            ipv4: InternetAddress('10.0.0.1'),
          ),
        ]);

    expect(
      () => dispatcher.dispatch(InternetAddress('fd00::10')),
      throwsA(isA<DispatchConfigException>()),
    );
  });
}
