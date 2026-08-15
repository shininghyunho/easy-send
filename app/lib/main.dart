import 'package:easy_send_core/easy_send_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/app_controller.dart';
import 'src/approval_dialog.dart';
import 'src/providers.dart';
import 'src/tabs/receive_tab.dart';
import 'src/tabs/send_tab.dart';
import 'src/tabs/settings_tab.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await AppController.start();
  runApp(ProviderScope(
    overrides: [appControllerProvider.overrideWithValue(controller)],
    child: const EasySendApp(),
  ));
}

class EasySendApp extends ConsumerStatefulWidget {
  const EasySendApp({super.key});

  @override
  ConsumerState<EasySendApp> createState() => _EasySendAppState();
}

class _EasySendAppState extends ConsumerState<EasySendApp> {
  @override
  void initState() {
    super.initState();
    ref.read(appControllerProvider).approvalHandler = _onApprovalRequest;
  }

  Future<bool> _onApprovalRequest(TransferRequest request) async {
    final context = navigatorKey.currentContext;
    if (context == null) return false;
    final approved = await showApprovalDialog(context, request);
    return approved == true;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'easy-send',
      navigatorKey: navigatorKey,
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [ReceiveTab(), SendTab(), SettingsTab()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.download), label: '받기'),
          NavigationDestination(icon: Icon(Icons.send), label: '보내기'),
          NavigationDestination(icon: Icon(Icons.settings), label: '설정'),
        ],
      ),
    );
  }
}
