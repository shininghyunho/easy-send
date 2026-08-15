import 'package:easy_send_core/easy_send_core.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_controller.dart';
import 'send_controller.dart';

/// main()에서 실제 인스턴스로 override된다.
final appControllerProvider = Provider<AppController>(
    (ref) => throw UnimplementedError('main()에서 override'));

final discoveredDevicesProvider = StreamProvider<List<DiscoveredDevice>>(
    (ref) => ref.watch(appControllerProvider).devices);

final sendControllerProvider =
    NotifierProvider<SendController, SendProgress?>(SendController.new);
