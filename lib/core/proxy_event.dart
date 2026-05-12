import 'dart:io';

enum ProxyEventType { info, connectionOpened, connectionClosed, warning, error }

class ProxyEvent {
  final ProxyEventType type;
  final DateTime timestamp;
  final String message;
  final InternetAddress? localAddress;
  final InternetAddress? remoteAddress;
  final int? remotePort;

  ProxyEvent({
    required this.type,
    required this.message,
    DateTime? timestamp,
    this.localAddress,
    this.remoteAddress,
    this.remotePort,
  }) : timestamp = timestamp ?? DateTime.now();

  String get label {
    switch (type) {
      case ProxyEventType.info:
        return 'Info';
      case ProxyEventType.connectionOpened:
        return 'Open';
      case ProxyEventType.connectionClosed:
        return 'Closed';
      case ProxyEventType.warning:
        return 'Warn';
      case ProxyEventType.error:
        return 'Error';
    }
  }
}
