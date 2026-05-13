/// Bonding strategies the relay-backed transport can choose between.
enum BondingMode { speed, redundant }

extension BondingModeCodec on BondingMode {
  String get wireName {
    switch (this) {
      case BondingMode.speed:
        return 'speed';
      case BondingMode.redundant:
        return 'redundant';
    }
  }

  static BondingMode parse(
    Object? value, {
    BondingMode fallback = BondingMode.speed,
  }) {
    if (value is BondingMode) {
      return value;
    }
    if (value is String) {
      for (BondingMode mode in BondingMode.values) {
        if (mode.wireName == value) {
          return mode;
        }
      }
    }
    return fallback;
  }
}
