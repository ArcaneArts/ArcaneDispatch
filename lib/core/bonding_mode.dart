/// Bonding strategies the user can choose between at runtime.
///
/// Mirrors Speedify's modes 1:1:
///
/// * [speed]     — Maximize aggregate throughput. Each packet is sent on the
///                  link with the most send credit (BBR-style scheduler).
/// * [redundant] — Each packet is sent on *every* eligible link; the receiver
///                  de-duplicates. Latency = min link latency.
/// * [streaming] — Low-latency variant of [speed]: shallow per-link buffers,
///                  real-time queue, optional duplicate-on-loss for RT flows.
/// * [local]     — Peer-to-peer bonding to a paired device on the same LAN
///                  (no Speed Server relay).
enum BondingMode { speed, redundant, streaming, local }

/// Serialization helpers for [BondingMode] so it can survive Hive / IPC.
extension BondingModeCodec on BondingMode {
  /// Stable wire string. Kept lowercase + ASCII so it round-trips through
  /// JSON and `UserDefaults` without quoting concerns.
  String get wireName {
    switch (this) {
      case BondingMode.speed:
        return 'speed';
      case BondingMode.redundant:
        return 'redundant';
      case BondingMode.streaming:
        return 'streaming';
      case BondingMode.local:
        return 'local';
    }
  }

  /// Parse a [BondingMode] from its [wireName]. Returns [fallback] (default
  /// [BondingMode.speed]) for unknown / null values so config files survive
  /// forward-compat surprises.
  static BondingMode parse(Object? value, {BondingMode fallback = BondingMode.speed}) {
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
