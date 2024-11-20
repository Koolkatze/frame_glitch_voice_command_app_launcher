import 'package:flutter/material.dart';
import '../frame_integrated_apps_page.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_apps/device_apps.dart';
import 'dart:convert';
import '../edit_wake_words_page.dart';
import 'package:logging/logging.dart';
import '../main_camera.dart';
import 'package:frame_glitch_voice_command_app_launcher/simple_frame_app.dart';
import 'package:frame_glitch_voice_command_app_launcher/tx/code.dart';
import 'package:frame_glitch_voice_command_app_launcher/tx/plain_text.dart';

void main() => runApp(const HomePage());

final _log = Logger("HomePage");

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  HomeAppState createState() => HomeAppState();
}

class HomeAppState extends State<HomePage> with SimpleFrameAppState {
  HomeAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint(
          '${record.level.name}: [${record.loggerName}] ${record.time}: ${record.message}');
    });
  }
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _isListening = false;
  Map<String, String> _appWakeWords = {};
  List<Application> _installedApps = [];
  Application? _selectedApp;
  bool _isLoading = true;
  String _searchQuery = '';
  final TextEditingController _wakeWordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadWakeWords();
    _loadInstalledApps();
  }

  @override
  void dispose() {
    _wakeWordController.dispose();
    super.dispose();
  }

  void _loadWakeWords() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    setState(() {
      String? appWakeWordsJson = prefs.getString('app_wake_words');
      if (appWakeWordsJson != null) {
        Map<String, dynamic> decodedMap = jsonDecode(appWakeWordsJson);
        _appWakeWords = Map<String, String>.from(decodedMap);
      } else {
        _appWakeWords = {}; // Initialize with an empty map if no data is stored
      }
    });
  }

  ApplicationState getConnectionState() {
    return currentState;
  }

  void _saveWakeWords() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_wake_words', jsonEncode(_appWakeWords));
  }

  Future<void> _loadInstalledApps() async {
    setState(() {
      _isLoading = true;
    });

    try {
      List<Application> apps = await DeviceApps.getInstalledApplications(
        includeAppIcons: true,
        includeSystemApps: true,
        onlyAppsWithLaunchIntent: false,
      );

      apps.sort(
          (a, b) => a.appName.toLowerCase().compareTo(b.appName.toLowerCase()));

      setState(() {
        _installedApps = apps;
        _isLoading = false;
      });
    } catch (e) {
      print("Error loading installed apps: $e");
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _toggleListening() {
    if (_isListening) {
      _stopListening();
    } else {
      _startListening();
    }
  }

  void _startListening() async {
    if (await _speech.initialize()) {
      setState(() {
        _isListening = true;
      });
      _speech.listen(
        onResult: (result) {
          if (result.finalResult) {
            _processVoiceCommand(result.recognizedWords);
          }
        },
      );
    }
  }

  void _stopListening() {
    _speech.stop();
    setState(() {
      _isListening = false;
    });
  }

  void _processVoiceCommand(String command) {
    _appWakeWords.forEach((packageName, wakeWord) {
      if (command.toLowerCase().contains(wakeWord.toLowerCase())) {
        _launchApp(packageName);
      }
    });
    String? framesCameraWakeWord = _appWakeWords['Frames Camera'];
    if (framesCameraWakeWord != null &&
        command.toLowerCase().contains(framesCameraWakeWord.toLowerCase())) {
      _launchFramesCamera();
    }
  }

  void _launchFramesCamera() {
    print('Launching Frames Camera');
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => CameraApp(
          connectionState: currentState,
          onDisconnect: disconnectFrame,
          frame: frame, // Pass the frame object
        ),
      ),
    );
  }

  Future<void> _launchApp(String packageName) async {
    print('Attempting to launch app: $packageName');
    try {
      bool launched = await DeviceApps.openApp(packageName);
      if (launched) {
        print('Successfully launched app: $packageName');
        await Future.delayed(const Duration(seconds: 2));
        _startListening();
      } else {
        print('Failed to launch app: $packageName');
      }
    } catch (e) {
      print('Error launching app: $e');
    }
  }

  List<Application> get _filteredApps {
    return _installedApps
        .where((app) =>
            app.appName.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            app.packageName.toLowerCase().contains(_searchQuery.toLowerCase()))
        .toList();
  }

  void _saveWakeWord() {
    if (_selectedApp != null && _wakeWordController.text.isNotEmpty) {
      setState(() {
        _appWakeWords[_selectedApp!.packageName] = _wakeWordController.text;
      });
      _saveWakeWords();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Wake word saved for ${_selectedApp!.appName}')),
      );
      _wakeWordController.clear();
      _selectedApp = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame GLITCH Launcher',
      theme: ThemeData(
        brightness: Brightness.dark,
        primarySwatch: Colors.yellow,
      ),
      home: Scaffold(
        appBar: AppBar(title: const Text('Frame GLITCH Launcher'), actions: [
          getBatteryWidget(),
          ElevatedButton(
            onPressed: () async {
              await scanForFrame();
              if (currentState == ApplicationState.connected) {
                setState(() {});
              }
            },
            child: const Text('Connect'),
          ),
          ElevatedButton(
            onPressed: () async {
              await disconnectFrame();
              setState(() {});
            },
            child: const Text('Disconnect'),
          ),
        ]),
        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const DrawerHeader(
                decoration: BoxDecoration(color: Colors.yellow),
                child: Text('Menu', style: TextStyle(color: Colors.black)),
              ),
              ListTile(
                title: const Text('Edit Wake Words'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => EditWakeWordsPage(
                        appWakeWords: _appWakeWords,
                        onSave: (newAppWakeWords) {
                          setState(() {
                            _appWakeWords = newAppWakeWords;
                            _saveWakeWords();
                          });
                        },
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                title: const Text('Frame Integrated Apps'),
                onTap: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => FrameIntegratedAppsPage(
                        appWakeWords: _appWakeWords,
                        onSave: (newAppWakeWords) {
                          setState(() {
                            _appWakeWords = newAppWakeWords;
                            _saveWakeWords();
                          });
                        },
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                title: const Text('Launch Frames Camera'),
                onTap: () {
                  Navigator.pop(context);
                  _launchFramesCamera();
                },
              ),
            ],
          ),
        ),
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('Connection Status: ${currentState.toString()}'),
                  const SizedBox(height: 16),
                  if (_selectedApp != null) ...[
                    Text('Set wake word for: ${_selectedApp!.appName}',
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    TextField(
                      controller: _wakeWordController,
                      decoration: const InputDecoration(
                        labelText: 'Wake Word',
                        hintText: 'Enter wake word for the selected app',
                      ),
                    ),
                    const SizedBox(height: 8),
                    ElevatedButton(
                      onPressed: _saveWakeWord,
                      child: const Text('Save Wake Word'),
                    ),
                  ],
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: _toggleListening,
                    child: Text(
                        _isListening ? 'Stop Listening' : 'Start Listening'),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    decoration: const InputDecoration(
                      labelText: 'Search Apps',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                    },
                  ),
                  const SizedBox(height: 16),
                  Text('All Installed Apps (${_installedApps.length})',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  _isLoading
                      ? const CircularProgressIndicator()
                      : SizedBox(
                          height: 400,
                          child: ListView.builder(
                            itemCount: _filteredApps.length,
                            itemBuilder: (context, index) {
                              Application app = _filteredApps[index];
                              bool isSelected = _selectedApp == app;
                              String? appWakeWord =
                                  _appWakeWords[app.packageName];
                              return ListTile(
                                leading: app is ApplicationWithIcon
                                    ? Image.memory(app.icon,
                                        width: 40, height: 40)
                                    : const Icon(Icons.android),
                                title: Text(app.appName),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(app.packageName),
                                    if (appWakeWord != null)
                                      Text('Wake word: $appWakeWord'),
                                  ],
                                ),
                                trailing: Checkbox(
                                  value: isSelected,
                                  onChanged: (bool? value) {
                                    setState(() {
                                      if (value == true) {
                                        _selectedApp = app;
                                        _wakeWordController.text =
                                            _appWakeWords[app.packageName] ??
                                                '';
                                      } else {
                                        _selectedApp = null;
                                        _wakeWordController.clear();
                                      }
                                    });
                                  },
                                ),
                              );
                            },
                          ),
                        ),
                ]),
          ),
        ),
      ),
    );
  }

  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    try {
      // TODO do something, e.g. send some text, wait a while, send a clear message
      // Check the assets/frame_app.lua to find the corresponding frameside handling for these arbitrarily-chosen msgCodes
      await frame!.sendMessage(TxPlainText(msgCode: 0x12, text: 'Say a wake'));

      await Future.delayed(const Duration(seconds: 10));

      await frame!.sendMessage(TxCode(msgCode: 0x10));

      currentState = ApplicationState.ready;
      if (mounted) setState(() {});
    } catch (e) {
      _log.fine(() => 'Error executing application logic: $e');
      currentState = ApplicationState.ready;
      if (mounted) setState(() {});
    }
  }

  @override
  Future<void> cancel() async {
    // TODO any logic while canceling?

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }
}
