import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:arcane_dispatch/core/socks_proxy_server.dart';
import 'package:arcane_dispatch/core/weighted_address.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'proxies SOCKS5 connect traffic through selected source address',
    () async {
      _EchoServer echo = await _EchoServer.start();
      SocksProxyServer proxy = SocksProxyServer();
      await proxy.start(
        listenAddress: InternetAddress.loopbackIPv4,
        port: 0,
        addresses: <ResolvedWeightedAddress>[
          ResolvedWeightedAddress(
            label: 'loopback',
            weight: 1,
            ipv4: InternetAddress.loopbackIPv4,
          ),
        ],
      );

      Socket client = await Socket.connect(
        InternetAddress.loopbackIPv4,
        proxy.boundPort!,
      );
      _SocketReader reader = _SocketReader(client);

      client.add(<int>[0x05, 0x01, 0x00]);
      await client.flush();
      expect(await reader.readExact(2), <int>[0x05, 0x00]);

      client.add(<int>[
        0x05,
        0x01,
        0x00,
        0x01,
        127,
        0,
        0,
        1,
        echo.port >> 8,
        echo.port & 0xff,
      ]);
      await client.flush();
      List<int> status = await reader.readExact(10);
      expect(status[1], 0x00);

      client.add(utf8.encode('ping'));
      await client.flush();
      expect(utf8.decode(await reader.readExact(4)), 'ping');

      client.destroy();
      await proxy.stop();
      await echo.stop();
    },
  );

  test('proxies SOCKS4 connect traffic', () async {
    _EchoServer echo = await _EchoServer.start();
    SocksProxyServer proxy = SocksProxyServer();
    await proxy.start(
      listenAddress: InternetAddress.loopbackIPv4,
      port: 0,
      addresses: <ResolvedWeightedAddress>[
        ResolvedWeightedAddress(
          label: 'loopback',
          weight: 1,
          ipv4: InternetAddress.loopbackIPv4,
        ),
      ],
    );

    Socket client = await Socket.connect(
      InternetAddress.loopbackIPv4,
      proxy.boundPort!,
    );
    _SocketReader reader = _SocketReader(client);

    client.add(<int>[
      0x04,
      0x01,
      echo.port >> 8,
      echo.port & 0xff,
      127,
      0,
      0,
      1,
      0x00,
    ]);
    await client.flush();
    List<int> status = await reader.readExact(8);
    expect(status[1], 0x5a);

    client.add(utf8.encode('pong'));
    await client.flush();
    expect(utf8.decode(await reader.readExact(4)), 'pong');

    client.destroy();
    await proxy.stop();
    await echo.stop();
  });
}

class _EchoServer {
  final ServerSocket server;
  final List<StreamSubscription<Uint8List>> subscriptions;

  _EchoServer(this.server, this.subscriptions);

  int get port {
    return server.port;
  }

  static Future<_EchoServer> start() async {
    ServerSocket server = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    List<StreamSubscription<Uint8List>> subscriptions =
        <StreamSubscription<Uint8List>>[];
    server.listen((Socket socket) {
      subscriptions.add(
        socket.listen((Uint8List data) {
          socket.add(data);
        }),
      );
    });
    return _EchoServer(server, subscriptions);
  }

  Future<void> stop() async {
    for (StreamSubscription<Uint8List> subscription in subscriptions) {
      await subscription.cancel();
    }
    await server.close();
  }
}

class _SocketReader {
  final StreamIterator<Uint8List> _iterator;
  Uint8List? _chunk;
  int _offset = 0;

  _SocketReader(Socket socket) : _iterator = StreamIterator<Uint8List>(socket);

  Future<List<int>> readExact(int length) async {
    List<int> result = <int>[];
    while (result.length < length) {
      result.add(await _readByte());
    }
    return result;
  }

  Future<int> _readByte() async {
    if (_chunk == null || _offset >= _chunk!.length) {
      bool moved = await _iterator.moveNext();
      if (!moved) {
        throw StateError('Socket closed');
      }
      _chunk = _iterator.current;
      _offset = 0;
    }
    int value = _chunk![_offset];
    _offset += 1;
    return value;
  }
}
