import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'proxy_event.dart';
import 'weighted_address.dart';

typedef ProxyEventSink = void Function(ProxyEvent event);

class SocksProxyServer {
  final ProxyEventSink? onEvent;
  final Duration connectTimeout;
  final InternetAddress Function(String address) addressParser;

  ServerSocket? _server;
  WeightedRoundRobinDispatcher? _dispatcher;
  List<ResolvedWeightedAddress> _addresses = <ResolvedWeightedAddress>[];
  StreamSubscription<Socket>? _subscription;

  SocksProxyServer({
    this.onEvent,
    this.connectTimeout = const Duration(seconds: 30),
    this.addressParser = InternetAddress.new,
  });

  bool get isRunning {
    return _server != null;
  }

  int? get boundPort {
    return _server?.port;
  }

  Future<void> start({
    required InternetAddress listenAddress,
    required int port,
    required List<ResolvedWeightedAddress> addresses,
  }) async {
    if (isRunning) {
      throw StateError('Proxy is already running.');
    }
    if (addresses.isEmpty) {
      throw const DispatchConfigException(
        'Select at least one local address before starting the proxy.',
      );
    }

    _addresses = List<ResolvedWeightedAddress>.unmodifiable(addresses);
    _dispatcher = WeightedRoundRobinDispatcher(_addresses);
    _server = await ServerSocket.bind(listenAddress, port);
    _subscription = _server!.listen(_handleClient);
    _emit(
      ProxyEvent(
        type: ProxyEventType.info,
        message:
            'SOCKS proxy started on ${listenAddress.address}:${_server!.port}',
      ),
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _server?.close();
    _server = null;
    _dispatcher = null;
    _emit(
      ProxyEvent(type: ProxyEventType.info, message: 'SOCKS proxy stopped'),
    );
  }

  void _handleClient(Socket client) {
    unawaited(_serveClient(client));
  }

  Future<void> _serveClient(Socket client) async {
    _SocketCursor cursor = _SocketCursor(client);
    Socket? remote;
    InternetAddress? localAddress;
    InternetAddress? remoteAddress;
    int? remotePort;
    try {
      int version = await cursor.readByte();
      if (version == 0x05) {
        _ConnectResult result = await _handleSocks5(cursor, client);
        remote = result.socket;
        localAddress = result.localAddress;
        remoteAddress = result.remoteAddress;
        remotePort = result.remotePort;
      } else if (version == 0x04) {
        _ConnectResult result = await _handleSocks4(cursor, client);
        remote = result.socket;
        localAddress = result.localAddress;
        remoteAddress = result.remoteAddress;
        remotePort = result.remotePort;
      } else {
        await _handleUnknownVersion(version, cursor);
        return;
      }

      _emit(
        ProxyEvent(
          type: ProxyEventType.connectionOpened,
          message:
              'Connection ${client.remoteAddress.address} -> ${remoteAddress.address}:$remotePort via ${localAddress.address}',
          localAddress: localAddress,
          remoteAddress: remoteAddress,
          remotePort: remotePort,
        ),
      );
      await _pipeMultiple(client, remote, cursor);
      _emit(
        ProxyEvent(
          type: ProxyEventType.connectionClosed,
          message: 'Connection closed for ${remoteAddress.address}:$remotePort',
          localAddress: localAddress,
          remoteAddress: remoteAddress,
          remotePort: remotePort,
        ),
      );
    } catch (error) {
      _emit(
        ProxyEvent(
          type: ProxyEventType.warning,
          message: error.toString(),
          localAddress: localAddress,
          remoteAddress: remoteAddress,
          remotePort: remotePort,
        ),
      );
    } finally {
      client.destroy();
      remote?.destroy();
    }
  }

  Future<_ConnectResult> _handleSocks5(
    _SocketCursor cursor,
    Socket client,
  ) async {
    int methodCount = await cursor.readByte();
    List<int> methods = await cursor.readExact(methodCount);
    if (!methods.contains(0x00)) {
      await _writeAll(client, <int>[0x05, 0xff]);
      throw const SocksProtocolException(
        'Only NOAUTH SOCKS5 authentication is supported.',
      );
    }
    await _writeAll(client, <int>[0x05, 0x00]);

    int version = await cursor.readByte();
    int command = await cursor.readByte();
    await cursor.readByte();
    int addressType = await cursor.readByte();
    if (version != 0x05) {
      await _writeSocks5Status(client, 0x01);
      throw SocksProtocolException('Invalid SOCKS5 request version: $version');
    }
    if (command != 0x01) {
      await _writeSocks5Status(client, 0x07);
      throw SocksProtocolException('Unsupported SOCKS5 command: $command');
    }

    _RemoteEndpoint remote = await _readSocks5Endpoint(cursor, addressType);
    return _connectRemote(
      client: client,
      remote: remote,
      onErrorStatus: (int status) => _writeSocks5Status(client, status),
      onSuccess: () => _writeSocks5Status(client, 0x00),
      errorMapper: _mapSocks5Status,
    );
  }

  Future<_RemoteEndpoint> _readSocks5Endpoint(
    _SocketCursor cursor,
    int addressType,
  ) async {
    InternetAddress address;
    if (addressType == 0x01) {
      address = InternetAddress.fromRawAddress(
        Uint8List.fromList(await cursor.readExact(4)),
      );
    } else if (addressType == 0x04) {
      address = InternetAddress.fromRawAddress(
        Uint8List.fromList(await cursor.readExact(16)),
      );
    } else if (addressType == 0x03) {
      int domainLength = await cursor.readByte();
      String domain = utf8.decode(await cursor.readExact(domainLength));
      address = await _resolveDomain(domain);
    } else {
      throw SocksProtocolException(
        'Unsupported SOCKS5 address type: $addressType',
      );
    }
    int port = await _readPort(cursor);
    return _RemoteEndpoint(address: address, port: port);
  }

  Future<_ConnectResult> _handleSocks4(
    _SocketCursor cursor,
    Socket client,
  ) async {
    int command = await cursor.readByte();
    if (command != 0x01) {
      await _writeSocks4Status(client, 0x5b);
      throw SocksProtocolException('Unsupported SOCKS4 command: $command');
    }

    int port = await _readPort(cursor);
    List<int> rawIp = await cursor.readExact(4);
    await cursor.readUntilZero();

    InternetAddress address;
    bool isSocks4a =
        rawIp[0] == 0 && rawIp[1] == 0 && rawIp[2] == 0 && rawIp[3] != 0;
    if (isSocks4a) {
      String domain = utf8.decode(await cursor.readUntilZero());
      address = await _resolveDomain(domain);
    } else {
      address = InternetAddress.fromRawAddress(Uint8List.fromList(rawIp));
    }

    return _connectRemote(
      client: client,
      remote: _RemoteEndpoint(address: address, port: port),
      onErrorStatus: (_) => _writeSocks4Status(client, 0x5b),
      onSuccess: () => _writeSocks4Status(client, 0x5a),
      errorMapper: (_) => 0x5b,
    );
  }

  Future<_ConnectResult> _connectRemote({
    required Socket client,
    required _RemoteEndpoint remote,
    required Future<void> Function(int status) onErrorStatus,
    required Future<void> Function() onSuccess,
    required int Function(Object error) errorMapper,
  }) async {
    WeightedRoundRobinDispatcher? dispatcher = _dispatcher;
    if (dispatcher == null) {
      await onErrorStatus(0x01);
      throw StateError('Proxy dispatcher is not available.');
    }

    InternetAddress localAddress = dispatcher.dispatch(remote.address);
    try {
      Socket remoteSocket = await Socket.connect(
        remote.address,
        remote.port,
        sourceAddress: localAddress,
        timeout: connectTimeout,
      );
      remoteSocket.setOption(SocketOption.tcpNoDelay, true);
      await onSuccess();
      return _ConnectResult(
        socket: remoteSocket,
        localAddress: localAddress,
        remoteAddress: remote.address,
        remotePort: remote.port,
      );
    } catch (error) {
      await onErrorStatus(errorMapper(error));
      throw SocksProtocolException(
        'Failed to connect to ${remote.address.address}:${remote.port} via ${localAddress.address}: $error',
      );
    }
  }

  Future<InternetAddress> _resolveDomain(String domain) async {
    if (domain.trim().isEmpty) {
      throw const SocksProtocolException('Remote domain cannot be empty.');
    }
    List<InternetAddress> addresses = await InternetAddress.lookup(domain);
    if (addresses.isEmpty) {
      throw SocksProtocolException('Failed to resolve $domain.');
    }
    return addresses.first;
  }

  Future<int> _readPort(_SocketCursor cursor) async {
    List<int> bytes = await cursor.readExact(2);
    return (bytes[0] << 8) | bytes[1];
  }

  Future<void> _handleUnknownVersion(int version, _SocketCursor cursor) async {
    String first = String.fromCharCode(version);
    const Set<String> httpPrefixes = <String>{
      'C',
      'G',
      'P',
      'H',
      'D',
      'O',
      'T',
    };
    if (httpPrefixes.contains(first)) {
      List<int> sample = <int>[version];
      sample.addAll(
        await cursor.readAvailable(
          maxBytes: 1023,
          idleTimeout: const Duration(milliseconds: 15),
        ),
      );
      String text = utf8.decode(sample, allowMalformed: true);
      String firstLine = text.split('\r\n').first;
      throw SocksProtocolException(
        'The proxy received `$firstLine`, which looks like HTTP. Configure the client as SOCKS, not HTTP.',
      );
    }
    throw SocksProtocolException('Unsupported SOCKS version byte: $version');
  }

  int _mapSocks5Status(Object error) {
    if (error is SocketException) {
      int? code = error.osError?.errorCode;
      if (code == 51 || code == 101) {
        return 0x03;
      }
      if (code == 60 || code == 110) {
        return 0x06;
      }
      if (code == 61 || code == 111) {
        return 0x05;
      }
      if (code == 65 || code == 113) {
        return 0x04;
      }
    }
    return 0x01;
  }

  Future<void> _writeSocks5Status(Socket socket, int status) {
    return _writeAll(socket, <int>[0x05, status, 0x00, 0x01, 0, 0, 0, 0, 0, 0]);
  }

  Future<void> _writeSocks4Status(Socket socket, int status) {
    return _writeAll(socket, <int>[0x00, status, 0, 0, 0, 0, 0, 0]);
  }

  Future<void> _writeAll(Socket socket, List<int> bytes) async {
    socket.add(bytes);
    await socket.flush();
  }

  Future<void> _pipeMultiple(
    Socket client,
    Socket remote,
    _SocketCursor clientCursor,
  ) async {
    Future<void> clientToRemote = clientCursor.pipeTo(remote);
    Future<void> remoteToClient = _pipeSocket(remote, client);

    await Future.any(<Future<void>>[clientToRemote, remoteToClient]);
    client.destroy();
    remote.destroy();
    await Future.wait<void>(<Future<void>>[
      clientToRemote.catchError((Object _) {}),
      remoteToClient.catchError((Object _) {}),
    ]);
  }

  Future<void> _pipeSocket(Socket source, Socket destination) async {
    await for (Uint8List chunk in source) {
      destination.add(chunk);
      await destination.flush();
    }
  }

  void _emit(ProxyEvent event) {
    onEvent?.call(event);
  }
}

class SocksProtocolException implements Exception {
  final String message;

  const SocksProtocolException(this.message);

  @override
  String toString() {
    return message;
  }
}

class _ConnectResult {
  final Socket socket;
  final InternetAddress localAddress;
  final InternetAddress remoteAddress;
  final int remotePort;

  const _ConnectResult({
    required this.socket,
    required this.localAddress,
    required this.remoteAddress,
    required this.remotePort,
  });
}

class _RemoteEndpoint {
  final InternetAddress address;
  final int port;

  const _RemoteEndpoint({required this.address, required this.port});
}

class _SocketCursor {
  final Socket socket;
  late final StreamIterator<Uint8List> _iterator;
  Uint8List? _chunk;
  int _offset = 0;

  _SocketCursor(this.socket) {
    _iterator = StreamIterator<Uint8List>(socket);
  }

  Future<int> readByte() async {
    await _ensureByte();
    Uint8List chunk = _chunk!;
    int value = chunk[_offset];
    _offset += 1;
    return value;
  }

  Future<List<int>> readExact(int length) async {
    List<int> result = <int>[];
    while (result.length < length) {
      result.add(await readByte());
    }
    return result;
  }

  Future<List<int>> readUntilZero() async {
    List<int> result = <int>[];
    while (true) {
      int byte = await readByte();
      if (byte == 0) {
        return result;
      }
      result.add(byte);
    }
  }

  Future<List<int>> readAvailable({
    required int maxBytes,
    required Duration idleTimeout,
  }) async {
    List<int> result = <int>[];
    while (result.length < maxBytes) {
      try {
        int byte = await readByte().timeout(idleTimeout);
        result.add(byte);
      } on TimeoutException {
        break;
      }
    }
    return result;
  }

  Future<void> pipeTo(Socket destination) async {
    Uint8List? buffered = takeBufferedBytes();
    if (buffered != null && buffered.isNotEmpty) {
      destination.add(buffered);
      await destination.flush();
    }
    while (await _iterator.moveNext()) {
      destination.add(_iterator.current);
      await destination.flush();
    }
  }

  Uint8List? takeBufferedBytes() {
    Uint8List? chunk = _chunk;
    if (chunk == null || _offset >= chunk.length) {
      return null;
    }
    Uint8List remaining = Uint8List.fromList(chunk.sublist(_offset));
    _offset = chunk.length;
    return remaining;
  }

  Future<void> _ensureByte() async {
    if (_chunk != null && _offset < _chunk!.length) {
      return;
    }
    bool hasNext = await _iterator.moveNext();
    if (!hasNext) {
      throw const SocksProtocolException(
        'Socket closed during SOCKS handshake.',
      );
    }
    _chunk = _iterator.current;
    _offset = 0;
    if (_chunk!.isEmpty) {
      await _ensureByte();
    }
  }
}
