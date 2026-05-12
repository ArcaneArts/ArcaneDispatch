import 'dart:io';

import 'network_interface_repository.dart';

class DispatchConfigException implements Exception {
  final String message;

  const DispatchConfigException(this.message);

  @override
  String toString() {
    return message;
  }
}

class RawWeightedAddress {
  final String target;
  final int weight;

  const RawWeightedAddress({required this.target, required this.weight});

  factory RawWeightedAddress.parse(String source) {
    String trimmed = source.trim();
    if (trimmed.isEmpty) {
      throw const DispatchConfigException('Address target cannot be empty.');
    }

    List<String> pieces = trimmed.split('/');
    if (pieces.length > 2) {
      throw DispatchConfigException('Invalid weighted address: $source');
    }

    int weight = 1;
    if (pieces.length == 2) {
      weight = int.tryParse(pieces[1]) ?? 0;
      if (weight <= 0) {
        throw DispatchConfigException(
          'Weight must be a positive integer: $source',
        );
      }
    }

    return RawWeightedAddress(target: pieces[0].trim(), weight: weight);
  }
}

class ResolvedWeightedAddress {
  final String label;
  final InternetAddress? ipv4;
  final InternetAddress? ipv6;
  final int weight;

  const ResolvedWeightedAddress({
    required this.label,
    required this.weight,
    this.ipv4,
    this.ipv6,
  });

  List<WeightedIp> get weightedIps {
    List<WeightedIp> result = <WeightedIp>[];
    if (ipv4 != null) {
      result.add(WeightedIp(address: ipv4!, weight: weight));
    }
    if (ipv6 != null) {
      result.add(WeightedIp(address: ipv6!, weight: weight));
    }
    return result;
  }

  @override
  String toString() {
    List<String> addresses = <String>[
      if (ipv4 != null) ipv4!.address,
      if (ipv6 != null) ipv6!.address,
    ];
    if (addresses.isEmpty) {
      return '$label/$weight';
    }
    return '$label/$weight (${addresses.join(', ')})';
  }
}

class WeightedIp {
  final InternetAddress address;
  final int weight;

  const WeightedIp({required this.address, required this.weight});
}

class WeightedAddressResolver {
  const WeightedAddressResolver();

  List<ResolvedWeightedAddress> resolve(
    List<RawWeightedAddress> rawAddresses,
    List<NetworkInterfaceSnapshot> interfaces,
  ) {
    Map<String, NetworkInterfaceSnapshot> interfacesByName =
        <String, NetworkInterfaceSnapshot>{
          for (NetworkInterfaceSnapshot interface in interfaces)
            interface.name: interface,
        };
    List<ResolvedWeightedAddress> resolved = <ResolvedWeightedAddress>[];

    for (RawWeightedAddress raw in rawAddresses) {
      NetworkInterfaceSnapshot? networkInterface = interfacesByName[raw.target];
      if (networkInterface != null) {
        resolved.add(_resolveInterface(raw, networkInterface));
        continue;
      }

      InternetAddress? parsed = InternetAddress.tryParse(raw.target);
      if (parsed == null) {
        throw DispatchConfigException(
          'Failed to parse `${raw.target}` as an IP address or interface name.',
        );
      }

      resolved.add(
        ResolvedWeightedAddress(
          label: parsed.address,
          weight: raw.weight,
          ipv4: parsed.type == InternetAddressType.IPv4 ? parsed : null,
          ipv6: parsed.type == InternetAddressType.IPv6 ? parsed : null,
        ),
      );
    }

    if (resolved.isEmpty) {
      throw const DispatchConfigException(
        'Select at least one interface or local address.',
      );
    }

    return resolved;
  }

  ResolvedWeightedAddress _resolveInterface(
    RawWeightedAddress raw,
    NetworkInterfaceSnapshot networkInterface,
  ) {
    InternetAddress? ipv4;
    InternetAddress? ipv6;

    for (InternetAddress address in networkInterface.validAddresses) {
      if (address.type == InternetAddressType.IPv4 && ipv4 == null) {
        ipv4 = address;
      } else if (address.type == InternetAddressType.IPv6 && ipv6 == null) {
        ipv6 = address;
      }
    }

    if (ipv4 == null && ipv6 == null) {
      throw DispatchConfigException(
        'No usable IP addresses found for `${networkInterface.name}`.',
      );
    }

    return ResolvedWeightedAddress(
      label: networkInterface.name,
      weight: raw.weight,
      ipv4: ipv4,
      ipv6: ipv6,
    );
  }
}

class WeightedRoundRobinDispatcher {
  final _WeightedRoundRobinState _ipv4;
  final _WeightedRoundRobinState _ipv6;

  WeightedRoundRobinDispatcher(List<ResolvedWeightedAddress> addresses)
    : _ipv4 = _WeightedRoundRobinState(
        _collect(addresses, InternetAddressType.IPv4),
      ),
      _ipv6 = _WeightedRoundRobinState(
        _collect(addresses, InternetAddressType.IPv6),
      );

  InternetAddress dispatch(InternetAddress remoteAddress) {
    _WeightedRoundRobinState state =
        remoteAddress.type == InternetAddressType.IPv6 ? _ipv6 : _ipv4;
    if (state.isEmpty) {
      String typeName = remoteAddress.type == InternetAddressType.IPv6
          ? 'IPv6'
          : 'IPv4';
      throw DispatchConfigException(
        'Address type mismatch: no configured local address can connect to '
        '${remoteAddress.address} ($typeName).',
      );
    }
    return state.next();
  }

  static List<WeightedIp> _collect(
    List<ResolvedWeightedAddress> addresses,
    InternetAddressType type,
  ) {
    List<WeightedIp> result = <WeightedIp>[];
    for (ResolvedWeightedAddress address in addresses) {
      for (WeightedIp ip in address.weightedIps) {
        if (ip.address.type == type) {
          result.add(ip);
        }
      }
    }
    return result;
  }
}

class _WeightedRoundRobinState {
  final List<WeightedIp> ips;
  int _index = 0;
  int _count = 0;

  _WeightedRoundRobinState(this.ips);

  bool get isEmpty {
    return ips.isEmpty;
  }

  InternetAddress next() {
    WeightedIp ip = ips[_index];
    _count += 1;
    if (_count == ip.weight) {
      _count = 0;
      _index = (_index + 1) % ips.length;
    }
    return ip.address;
  }
}
