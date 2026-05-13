import 'dart:io';

/// Direction of a byte movement through a transport pipe.
///
/// "Upstream" means client → remote (request body); "downstream" means
/// remote → client (response body). The policy engine doesn't currently care
/// which direction a byte moved in — speed caps and data caps apply to the
/// sum — but the directionality is useful for telemetry, future asymmetric
/// caps.
enum ByteDirection { upstream, downstream }

/// Hook invoked by a transport for every chunk of payload bytes it forwards.
///
/// Implementations should:
/// 1. Look up the per-link [TokenBucket] for [localAddress] and `await` until
///    it has [bytes] tokens (or return immediately if uncapped).
/// 2. Increment the per-link [DataMeter] by [bytes].
///
/// The transport calls this *before* the bytes are actually written, so the
/// throttling is effective at the wire level.
///
/// Returning before the bucket has enough tokens is allowed (the bucket may
/// be unlimited or the throttler may decide to drop a packet); transports
/// should still call the hook for every chunk so the meter stays accurate.
typedef ByteAccountant =
    Future<void> Function({
      required InternetAddress localAddress,
      required int bytes,
      required ByteDirection direction,
    });
