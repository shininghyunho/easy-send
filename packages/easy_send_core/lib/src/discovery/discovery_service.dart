import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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
  bool _stopped = false;
  Timer? _announceTimer;
  Timer? _pruneTimer;
  final _devices = <String, DiscoveredDevice>{};
  final _controller = StreamController<List<DiscoveredDevice>>.broadcast();

  /// 기기 목록이 바뀔 때마다(추가·정보 변경·TTL 제거) 전체 목록을 내보낸다.
  Stream<List<DiscoveredDevice>> get devices => _controller.stream;

  List<DiscoveredDevice> get currentDevices =>
      List.unmodifiable(_devices.values);

  Future<void> start() async {
    _stopped = false;
    await _bind();
    _announceTimer =
        Timer.periodic(Protocol.announceInterval, (_) => announce());
    _pruneTimer = Timer.periodic(const Duration(seconds: 1), (_) => _prune());
    announce();
  }

  /// OS가 소켓을 닫으면(Android 백그라운드 전환 실측) announce 주기에서
  /// 재호출돼 자연 복구된다.
  Future<RawDatagramSocket> _bind() async {
    // reusePort: 같은 기기에서 인스턴스 여러 개가 53318을 함께 물 수 있게 (개발·테스트 경로)
    final socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      Protocol.discoveryPort,
      reuseAddress: true,
      reusePort: true,
    );
    // 기본 인터페이스 하나에만 조인하면 VPN(utun 등)이 선택될 수 있어 전부 조인
    for (final interface in await _interfaces()) {
      try {
        socket.joinMulticast(
            InternetAddress(Protocol.multicastGroup), interface);
      } catch (_) {
        // 멀티캐스트 미지원 인터페이스(P2P VPN 등)는 건너뛴다
      }
    }
    socket.broadcastEnabled = true;
    socket.listen((event) {
      if (event == RawSocketEvent.read) _onDatagram(socket.receive());
      if (event == RawSocketEvent.closed && identical(_socket, socket)) {
        _socket = null;
      }
    }, onError: (_) {
      // 송신 실패(EPERM 등)가 스트림 에러로 와도 탐색 소켓을 유지한다
    }, onDone: () {
      if (identical(_socket, socket)) _socket = null;
    });
    _socket = socket;
    return socket;
  }

  /// 즉시 announce 1회 — 시작 시와 UI 새로고침 버튼에서 호출.
  /// 송신 인터페이스를 순회 지정한다 — 기본 인터페이스 하나로만 보내면
  /// VPN 쪽으로 나가 같은 LAN 기기가 못 받는다.
  /// 멀티캐스트와 함께 서브넷 브로드캐스트로도 보낸다 — 소비자 AP 상당수가
  /// mDNS 외 멀티캐스트 그룹을 버리는 것을 실측(A54↔mac)으로 확인.
  Future<void> announce() async {
    if (_stopped) return;
    var socket = _socket;
    if (socket == null) {
      try {
        socket = await _bind();
      } catch (_) {
        return; // 다음 주기에 재시도
      }
    }
    final data = Announcement(info: self, announce: true).encode();
    for (final interface in await _interfaces()) {
      for (final address in interface.addresses) {
        try {
          socket.setRawOption(RawSocketOption(
            RawSocketOption.levelIPv4,
            RawSocketOption.IPv4MulticastInterface,
            address.rawAddress,
          ));
          socket.send(data, InternetAddress(Protocol.multicastGroup),
              Protocol.discoveryPort);
          socket.send(
              data, _broadcastOf(address), Protocol.discoveryPort);
        } catch (_) {
          // 송신 불가 인터페이스는 건너뛴다
        }
      }
    }
  }

  /// dart:io가 넷마스크를 안 주므로 /24 가정 — 홈 LAN 관례, 빗나가면
  /// 멀티캐스트·IP 직접 입력이 여전히 퇴로.
  static InternetAddress _broadcastOf(InternetAddress address) {
    final raw = Uint8List.fromList(address.rawAddress)..[3] = 255;
    return InternetAddress.fromRawAddress(raw);
  }

  static Future<List<NetworkInterface>> _interfaces() =>
      NetworkInterface.list(
          type: InternetAddressType.IPv4, includeLoopback: false);

  void stop() {
    _stopped = true;
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
      try {
        _socket?.send(
          Announcement(info: self, announce: false).encode(),
          datagram.address,
          datagram.port,
        );
      } catch (_) {
        // 응답 실패는 다음 announce 주기에 자연 복구된다
      }
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
