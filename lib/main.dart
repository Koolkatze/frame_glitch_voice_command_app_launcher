import 'package:flutter/material.dart';
//import 'package:frame_sdk/frame_sdk.dart';
//import 'package:frame_sdk/bluetooth.dart';
import 'package:permission_handler/permission_handler.dart';
import 'home_page.dart';
//import 'package:flutter/material.dart';
//import 'package:logging/logging.dart';

//import 'package:simple_frame_app/simple_frame_app.dart';
//import 'package:simple_frame_app/tx/code.dart';
//import 'package:simple_frame_app/tx/plain_text.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Permission.bluetooth.request();
  await Permission.storage.request();
  await Permission.microphone.request();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Glitch Launcher',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.yellow,
      ),
      home: const HomePage(),
    );
  }
}
