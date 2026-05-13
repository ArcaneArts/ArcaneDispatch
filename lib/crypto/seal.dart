/// Sealed-frame wrapper for the bonded transport (Dart side).
///
/// Mirror of `speed-server/crypto/seal.go`. See that file for the wire
/// layout; this file is a literal port.
library;

import 'dart:typed_data';

import 'noise.dart';

/// First two bytes of every sealed frame. Distinct from the bonded
/// plaintext magic so misrouted packets get rejected at the right layer.
const int sealedMagic = 0xDA02;

/// Wire-format version. Bump on layout changes.
const int sealedVersion = 1;

/// Fixed prefix size in bytes.
const int sealedHeaderSize = 12;

/// Decoded header of a sealed frame.
class SealedHeader {
  final int magic;
  final int version;
  final int flags;
  final int nonce;

  const SealedHeader({
    required this.magic,
    required this.version,
    required this.flags,
    required this.nonce,
  });
}

/// Wraps [plaintext] under [transport]'s send key and returns the wire
/// bytes (header + ciphertext+tag).
///
/// The header is included in the AEAD additional-data so any
/// in-transit tampering of the header bytes fails the AEAD check.
Future<Uint8List> seal(NoiseTransport transport, Uint8List plaintext) async {
  // First pass: capture the would-be nonce so we can build the header AD.
  int nonce = transport.sendNonce;
  Uint8List hdr = _headerBytes(nonce, flags: 0);
  ({int nonce, Uint8List ciphertext}) sealed = await transport.seal(
    hdr,
    plaintext,
  );
  // Sanity check — the transport must have used the nonce we
  // predicted. If this ever fires, someone is interleaving seal() calls
  // on a transport that's supposed to be single-owner.
  if (sealed.nonce != nonce) {
    throw StateError(
      'crypto: seal nonce drift (predicted $nonce, got ${sealed.nonce})',
    );
  }
  Uint8List out = Uint8List(hdr.length + sealed.ciphertext.length);
  out.setRange(0, hdr.length, hdr);
  out.setRange(hdr.length, out.length, sealed.ciphertext);
  return out;
}

/// Parse just the header from [buf]. Throws on short input, bad magic,
/// bad version, or reserved flag bits.
SealedHeader decodeSealedHeader(Uint8List buf) {
  if (buf.length < sealedHeaderSize) {
    throw StateError(
      'crypto: sealed frame too short: ${buf.length} < $sealedHeaderSize',
    );
  }
  ByteData bd = ByteData.sublistView(buf);
  int magic = bd.getUint16(0);
  if (magic != sealedMagic) {
    throw StateError(
      'crypto: bad sealed magic: 0x${magic.toRadixString(16).padLeft(4, '0')}',
    );
  }
  int version = bd.getUint8(2);
  if (version != sealedVersion) {
    throw StateError('crypto: unsupported sealed version: $version');
  }
  int flags = bd.getUint8(3);
  if (flags != 0) {
    throw StateError(
      'crypto: reserved sealed flag bits set: 0x${flags.toRadixString(16)}',
    );
  }
  int nonce = bd.getUint64(4);
  return SealedHeader(
    magic: magic,
    version: version,
    flags: flags,
    nonce: nonce,
  );
}

/// AEAD-decrypts a wire-format sealed frame.
///
/// Caller is responsible for replay-window gatekeeping; `openSealed`
/// only enforces the AEAD tag.
Future<Uint8List> openSealed(
  NoiseTransport transport,
  SealedHeader hdr,
  Uint8List ciphertext,
) async {
  Uint8List ad = _headerBytes(hdr.nonce, flags: hdr.flags);
  // Recompute the header bytes from `hdr` so a tampered Magic/Version
  // also fails the AEAD check (they were authenticated via AD on the
  // sender).
  return await transport.open(hdr.nonce, ad, ciphertext);
}

Uint8List _headerBytes(int nonce, {required int flags}) {
  Uint8List hdr = Uint8List(sealedHeaderSize);
  ByteData bd = ByteData.sublistView(hdr);
  bd.setUint16(0, sealedMagic);
  bd.setUint8(2, sealedVersion);
  bd.setUint8(3, flags);
  bd.setUint64(4, nonce);
  return hdr;
}
