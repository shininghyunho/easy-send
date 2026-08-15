import 'dart:async';
import 'dart:io';

import '../models/device.dart';
import '../protocol.dart';

/// UDP 멀티캐스트 탐색 (PRD 4.2).
///
/// - 5초마다 announce 멀티캐스트, 수신한 announce에는 유니캐스트로 응답.
/// - 자기 fingerprint 패킷은 무시, 마지막 수신 후 15초 지난 기기는 목록에서 제거.
class DiscoveryService {
  DiscoveryService({required this.self});

  final DeviceInfo self;

  RawDatagramSocket? _socket;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  final _devices = <String, DiscoveredDevice>{};
  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();

  /// 기기 목록이 바뀔 때마다(추가·정보 변경·TTL 제거) 전체 목록을 내보낸다.
  Stream<List<DiscoveredDevice>> get devices => _controller.stream;

  List<DiscoveredDevice> get currentDevices =>
      List.unmodifiable(_devices.values);

  Future<void> start() async {
    // reusePort: 같은 기기에서 인스턴스 여러 개가 53318을 함께 물 수 있게 (개발·테스트 경로)
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      Protocol.discoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    socket.joinMulticast(InternetAddress(Protocol.multicastGroup));
    socket.listen((event) {
      if (event == RawSocketEvent.read) _onDatagram(socket.receive());
    });
    _socket = socket;
    _announceTimer =
        Timer.periodic(Protocol.announceInterval, (_) => announce());
    _pruneTimer = Timer.periodic(const Duration(seconds: 1), (_) => _prune());
    announce();
  }

  /// 즉시 announce 1회 — 시작 시와 UI 새로고침 버튼에서 호출.
  void announce() {
    _socket?.send(
      Announcement(info: self, announce: true).encode(),
      InternetAddress(Protocol.multicastGroup),
      Protocol.discoveryPort,
    );
  }

  void stop() {
    _announceTimer?.cancel();
    _pruneTimer?.cancel();
    _socket?.close();
    _socket = null;
    _devices.clear();
  }

  void _onDatagram(Datagram? datagram) {
    if (datagram == null) return;
    final message = Announcement.tryDecode(datagram.data);
    if (message == null) return;
    if (message.info.fingerprint == self.fingerprint) return;

    final known = _devices[message.info.fingerprint];
    _devices[message.info.fingerprint] = DiscoveredDevice(
      info: message.info,
      address: datagram.address,
      lastSeen: DateTime.now(),
    );
    if (known == null ||
        known.info.alias != message.info.alias ||
        known.info.port != message.info.port ||
        known.address != datagram.address) {
      _emit();
    }

    if (message.announce) {
      _socket?.send(
        Announcement(info: self, announce: false).encode(),
        datagram.address,
        datagram.port,
      );
    }
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(Protocol.deviceTtl);
    final before = _devices.length;
    _devices.removeWhere((_, d) => d.lastSeen.isBefore(cutoff));
    if (_devices.length != before) _emit();
  }

  void _emit() => _controller.add(currentDevices);
}
