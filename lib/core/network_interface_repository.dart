import 'dart:io';

typedef AddressBindValidator = Future<bool> Function(InternetAddress address);

class NetworkInterfaceSnapshot {
  final String name;
  final int index;
  final List<InternetAddress> addresses;

  const NetworkInterfaceSnapshot({
    required this.name,
    required this.index,
    required this.addresses,
  });

  List<InternetAddress> get validAddresses {
    return addresses.where(NetworkInterfaceRepository.isUsableAddress).toList();
  }

  bool get hasUsableAddresses {
    return validAddresses.isNotEmpty;
  }
}

class NetworkInterfaceRepository {
  final AddressBindValidator bindValidator;

  const NetworkInterfaceRepository({this.bindValidator = defaultBindValidator});

  Future<List<NetworkInterfaceSnapshot>> listUsableInterfaces() async {
    List<NetworkInterface> interfaces = await NetworkInterface.list(
      includeLoopback: false,
      includeLinkLocal: false,
      type: InternetAddressType.any,
    );
    List<NetworkInterfaceSnapshot> snapshots = <NetworkInterfaceSnapshot>[];

    for (NetworkInterface interface in interfaces) {
      List<InternetAddress> usable = <InternetAddress>[];
      for (InternetAddress address in interface.addresses) {
        if (!isUsableAddress(address)) {
          continue;
        }
        if (await bindValidator(address)) {
          usable.add(address);
        }
      }
      if (usable.isEmpty) {
        continue;
      }
      snapshots.add(
        NetworkInterfaceSnapshot(
          name: interface.name,
          index: interface.index,
          addresses: usable,
        ),
      );
    }

    snapshots.sort((NetworkInterfaceSnapshot a, NetworkInterfaceSnapshot b) {
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return snapshots;
  }

  static bool isUsableAddress(InternetAddress address) {
    if (address.isLoopback) {
      return false;
    }
    List<int> bytes = address.rawAddress;
    if (address.type == InternetAddressType.IPv4) {
      return !(bytes.length >= 2 && bytes[0] == 169 && bytes[1] == 254);
    }
    if (address.type == InternetAddressType.IPv6) {
      return !(bytes.length >= 2 &&
          bytes[0] == 0xfe &&
          (bytes[1] & 0xc0) == 0x80);
    }
    return false;
  }

  static Future<bool> defaultBindValidator(InternetAddress address) async {
    ServerSocket? socket;
    try {
      socket = await ServerSocket.bind(
        address,
        0,
        v6Only: address.type == InternetAddressType.IPv6,
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      await socket?.close();
    }
  }
}
