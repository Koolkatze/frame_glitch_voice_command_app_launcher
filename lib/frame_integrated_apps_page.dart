import 'package:flutter/material.dart';
import 'package:frame_glitch_voice_command_app_launcher/home_page.dart';

class FrameIntegratedAppsPage extends StatefulWidget {
  final Map<String, String> appWakeWords;
  final Function(Map<String, String>) onSave;

  const FrameIntegratedAppsPage({
    super.key,
    required this.appWakeWords,
    required this.onSave,
  });

  @override
  _FrameIntegratedAppsPageState createState() =>
      _FrameIntegratedAppsPageState();
}

class _FrameIntegratedAppsPageState extends State<FrameIntegratedAppsPage> {
  late Map<String, String> _appWakeWords;
  final TextEditingController _wakeWordController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _appWakeWords = Map.from(widget.appWakeWords);
  }

  @override
  void dispose() {
    _wakeWordController.dispose();
    super.dispose();
  }

  void _updateWakeWord(String app, String newWakeWord) {
    if (mounted) {
      setState(() {
        _appWakeWords[app] = newWakeWord;
      });
    }
    widget.onSave(_appWakeWords);
  }

  void _deleteWakeWord(String app) {
    if (mounted) {
      setState(() {
        _appWakeWords.remove(app);
      });
    }
    widget.onSave(_appWakeWords);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const HomePage(),
              ),
            );
          },
        ),
        title: const Text('Frame Integrated Apps'),
      ),
      body: ListView(
        children: _appWakeWords.entries.map((entry) {
          return ListTile(
            title: Text(entry.key),
            subtitle: Text('Wake Word: ${entry.value}'),
            trailing: IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () {
                _wakeWordController.text = entry.value;
                showDialog(
                  context: context,
                  builder: (context) {
                    return AlertDialog(
                      title: Text('Edit Wake Word for ${entry.key}'),
                      content: TextField(
                        controller: _wakeWordController,
                        decoration: const InputDecoration(
                          labelText: 'Wake Word',
                        ),
                      ),
                      actions: [
                        TextButton(
                          child: const Text('Cancel'),
                          onPressed: () {
                            Navigator.of(context).pop();
                          },
                        ),
                        TextButton(
                          child: const Text('Save'),
                          onPressed: () {
                            _updateWakeWord(
                                entry.key, _wakeWordController.text);
                            Navigator.of(context).pop();
                          },
                        ),
                        TextButton(
                          child: const Text('Delete'),
                          onPressed: () {
                            _deleteWakeWord(entry.key);
                            Navigator.of(context).pop();
                          },
                        ),
                      ],
                    );
                  },
                );
              },
            ),
          );
        }).toList(),
      ),
    );
  }
}
