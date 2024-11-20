import 'dart:async';
import 'dart:math';
import 'package:frame_glitch_voice_command_app_launcher/home_page.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:logging/logging.dart';
import 'package:share_plus/share_plus.dart';
import 'package:frame_glitch_voice_command_app_launcher/rx/photo.dart';
//import 'auto_start_frame_app.dart';
import 'package:frame_glitch_voice_command_app_launcher/simple_frame_app.dart';
import 'package:frame_glitch_voice_command_app_launcher/tx/camera_settings.dart';
import 'package:flutter/services.dart';
import 'package:frame_glitch_voice_command_app_launcher/tx/sprite.dart';
import 'package:frame_glitch_voice_command_app_launcher/brilliant_bluetooth.dart';

final _log = Logger("MainApp");

class CameraApp extends StatefulWidget {
  final ApplicationState connectionState;
  final Function onDisconnect;
  final BrilliantDevice? frame; // Add this line

  const CameraApp({
    super.key,
    required this.connectionState,
    required this.onDisconnect,
    required this.frame, // Add this line
  });
  @override
  CameraAppState createState() => CameraAppState();
}

class CameraAppState extends State<CameraApp> with SimpleFrameAppState {
  // stream subscription to pull application data back from camera
  StreamSubscription<Uint8List>? _photoStream;

  // the list of images to show in the scolling list view
  final List<Image> _imageList = [];
  final List<StatelessWidget> _imageMeta = [];
  final List<Uint8List> _jpegBytes = [];
  final Stopwatch _stopwatch = Stopwatch();

  // camera settings
  int _qualityIndex = 0;
  final List<double> _qualityValues = [10, 25, 50, 100];
  bool _isAutoExposure = true;

  // autoexposure/gain parameters
  int _meteringIndex = 2;
  final List<String> _meteringValues = ['SPOT', 'CENTER_WEIGHTED', 'AVERAGE'];
  int _autoExpGainTimes =
      1; // val >= 0; number of times auto exposure and gain algorithm will be run every _autoExpInterval ms
  int _autoExpInterval =
      100; // 0<= val <= 255; sleep time between runs of the autoexposure algorithm
  double _exposure = 0.18; // 0.0 <= val <= 1.0
  double _exposureSpeed = 0.5; // 0.0 <= val <= 1.0
  int _shutterLimit = 16383; // 4 < val < 16383
  int _analogGainLimit = 248; // 0 <= val <= 248
  double _whiteBalanceSpeed = 0.5; // 0.0 <= val <= 1.0

  // manual exposure/gain parameters
  int _manualShutter = 800; // 4 < val < 16383
  int _manualAnalogGain = 124; // 0 <= val <= 248
  int _manualRedGain = 64; // 0 <= val <= 1023
  int _manualGreenGain = 64; // 0 <= val <= 1023
  int _manualBlueGain = 64; // 0 <= val <= 1023

  MainAppState() {
    Logger.root.level = Level.INFO;
    Logger.root.onRecord.listen((record) {
      debugPrint('${record.level.name}: ${record.time}: ${record.message}');
    });
  }

  @override
  void initState() {
    super.initState();
    currentState = widget.connectionState;
    frame = widget.frame;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      connectAndStartAndRun();
    });
  }

  @override
  Future<void> startApplication() async {
    currentState = ApplicationState.starting;
    if (mounted) setState(() {});

    // try to get the Frame into a known state by making sure there's no main loop running
    frame!.sendBreakSignal();
    await Future.delayed(const Duration(milliseconds: 500));

    // clear the previous content from the display and show a temporary loading screen while
    // we send over our scripts and resources
    await showLoadingScreen();
    await Future.delayed(const Duration(milliseconds: 100));

    // only if there are lua files to send to Frame (e.g. frame_app.lua companion app, other helper functions, minified versions)
    List<String> luaFiles = _filterLuaFiles(
        (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets());

    if (luaFiles.isNotEmpty) {
      for (var pathFile in luaFiles) {
        String fileName = pathFile.split('/').last;
        // send the lua script to the Frame
        await frame!.uploadScript(fileName, pathFile);
      }

      // kick off the main application loop: if there is only one lua file, use it;
      // otherwise require a file called "assets/frame_app.min.lua", or "assets/frame_app.lua".
      // In that case, the main app file should add require() statements for any dependent modules
      if (luaFiles.length != 1 &&
          !luaFiles.contains('assets/frame_app.min.lua') &&
          !luaFiles.contains('assets/frame_app.lua')) {
        _log.fine('Multiple Lua files uploaded, but no main file to require()');
      } else {
        if (luaFiles.length == 1) {
          String fileName = luaFiles[0]
              .split('/')
              .last; // e.g. "assets/my_file.min.lua" -> "my_file.min.lua"
          int lastDotIndex = fileName.lastIndexOf(".lua");
          String bareFileName = fileName.substring(
              0, lastDotIndex); // e.g. "my_file.min.lua" -> "my_file.min"

          await frame!
              .sendString('require("$bareFileName")', awaitResponse: true);
        } else if (luaFiles.contains('assets/frame_app.min.lua')) {
          await frame!
              .sendString('require("frame_app.min")', awaitResponse: true);
        } else if (luaFiles.contains('assets/frame_app.lua')) {
          await frame!.sendString('require("frame_app")', awaitResponse: true);
        }

        // load all the Sprites from assets/sprites
        await _uploadSprites(_filterSpriteAssets(
            (await AssetManifest.loadFromAssetBundle(rootBundle))
                .listAssets()));
      }
    } else {
      await frame!.clearDisplay();
      await Future.delayed(const Duration(milliseconds: 100));
    }

    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Future<void> stopApplication() async {
    currentState = ApplicationState.stopping;
    if (mounted) setState(() {});

    // send a break to stop the Lua app loop on Frame
    await frame!.sendBreakSignal();
    await Future.delayed(const Duration(milliseconds: 500));

    // only if there are lua files uploaded to Frame (e.g. frame_app.lua companion app, other helper functions, minified versions)
    List<String> luaFiles = _filterLuaFiles(
        (await AssetManifest.loadFromAssetBundle(rootBundle)).listAssets());

    if (luaFiles.isNotEmpty) {
      // clean up by deregistering any handler
      await frame!.sendString('frame.bluetooth.receive_callback(nil);print(0)',
          awaitResponse: true);

      for (var file in luaFiles) {
        // delete any prior scripts
        await frame!.sendString(
            'frame.file.remove("${file.split('/').last}");print(0)',
            awaitResponse: true);
      }
    }

    currentState = ApplicationState.connected;
    if (mounted) setState(() {});
  }

  /// When given the full list of Assets, return only the Lua files
  /// Note that returned file strings will be 'assets/my_file.lua' or 'assets/my_other_file.min.lua' which we need to use to find the asset in Flutter,
  /// but we need to file.split('/').last if we only want the file name when writing/deleting the file on Frame in the root of its filesystem
  List<String> _filterLuaFiles(List<String> files) {
    return files.where((name) => name.endsWith('.lua')).toList();
  }

  /// Loops over each of the sprites in the assets/sprites directory (and declared in pubspec.yaml) and returns an entry with
  /// each sprite associated with a message_type key: the two hex digits in its filename,
  /// e.g. 'assets/sprites/1f_mysprite.png' has a message type of 0x1f. This message is used to key the messages in the frameside lua app
  Map<int, String> _filterSpriteAssets(List<String> files) {
    var spriteFiles = files
        .where((String pathFile) =>
            pathFile.startsWith('assets/sprites/') && pathFile.endsWith('.png'))
        .toList();

    // Create the map from hexadecimal integer prefix to sprite name
    final Map<int, String> spriteMap = {};

    for (final String sprite in spriteFiles) {
      // Extract the part of the filename without the directory and extension
      final String fileName =
          sprite.split('/').last; // e.g., "12_spriteone.png"

      // Extract the hexadecimal prefix and the sprite name
      final String hexPrefix = fileName.split('_').first; // e.g., "12"

      // Convert the hexadecimal prefix to an integer
      final int? hexValue = int.tryParse(hexPrefix, radix: 16);

      if (hexValue == null) {
        _log.severe('invalid hex prefix: $hexPrefix for asset $sprite');
      } else {
        // Add the hex value and sprite to the map
        spriteMap[hexValue] = sprite;
      }
    }

    return spriteMap;
  }

  Future<void> _uploadSprites(Map<int, String> spriteMap) async {
    for (var entry in spriteMap.entries) {
      try {
        var sprite = TxSprite.fromPngBytes(
            msgCode: entry.key,
            pngBytes:
                Uint8List.sublistView(await rootBundle.load(entry.value)));

        // send sprite to Frame with its associated message type
        await frame!.sendMessage(sprite);
        await Future.delayed(const Duration(milliseconds: 200));
      } catch (e) {
        _log.severe('$e');
      }
    }
  }

  Future<void> _checkConnectionAndStart() async {
    if (currentState == ApplicationState.connected) {
      // The Frame is connected, start the camera functionality
      startApplication();
    } else {
      // Show a message that the Frame is not connected

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
            content: Text(
                'Frame is not connected. Please connect from the home page.')),
      );
    }

    if (currentState == ApplicationState.ready) {
      // don't await this one for run() functions that keep running a main loop, so initState() can complete
      run();
    }
  }

  Future<void> connectAndStartAndRun() async {
    if (currentState == ApplicationState.disconnected) {
      await scanOrReconnectFrame();

      // TODO this is the bit that shouldn't be necessary - scanOrReconnectFrame should only return when it's connected but it currently doesn't
      await Future.delayed(const Duration(seconds: 6));

      if (currentState == ApplicationState.connected && frame != null) {
        await startApplication();

        if (currentState == ApplicationState.ready) {
          // don't await this one for run() functions that keep running a main loop, so initState() can complete
          run();
        }
      }
    }
  }

  ApplicationState getConnectionState() {
    return currentState;
  }

  @override
  Future<void> run() async {
    currentState = ApplicationState.running;
    if (mounted) setState(() {});

    try {
      // the image data as a list of bytes that accumulates with each packet
      StatelessWidget meta;

      if (_isAutoExposure) {
        meta = AutoExpImageMetadata(
            _qualityValues[_qualityIndex].toInt(),
            _autoExpGainTimes,
            _autoExpInterval,
            _meteringValues[_meteringIndex],
            _exposure,
            _exposureSpeed,
            _shutterLimit,
            _analogGainLimit,
            _whiteBalanceSpeed);
      } else {
        meta = ManualExpImageMetadata(
            _qualityValues[_qualityIndex].toInt(),
            _manualShutter,
            _manualAnalogGain,
            _manualRedGain,
            _manualGreenGain,
            _manualBlueGain);
      }

      try {
        // set up the data response handler for the photos
        _photoStream =
            RxPhoto(qualityLevel: _qualityValues[_qualityIndex].toInt())
                .attach(frame!.dataResponse)
                .listen((imageData) {
          // received a whole-image Uint8List with jpeg header and footer included
          _stopwatch.stop();

          // unsubscribe from the image stream now (to also release the underlying data stream subscription)
          _photoStream?.cancel();

          try {
            Image im = Image.memory(imageData);

            // add the size and elapsed time to the image metadata widget
            if (meta is AutoExpImageMetadata) {
              meta.size = imageData.length;
              meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;
            } else if (meta is ManualExpImageMetadata) {
              meta.size = imageData.length;
              meta.elapsedTimeMs = _stopwatch.elapsedMilliseconds;
            }

            _log.fine(
                'Image file size in bytes: ${imageData.length}, elapsedMs: ${_stopwatch.elapsedMilliseconds}');

            setState(() {
              _imageList.insert(0, im);
              _imageMeta.insert(0, meta);
              _jpegBytes.insert(0, imageData);
            });

            currentState = ApplicationState.ready;
            if (mounted) setState(() {});
          } catch (e) {
            _log.severe('Error converting bytes to image: $e');
          }
        });
      } catch (e) {
        _log.severe('Error reading image data response: $e');
        // unsubscribe from the image stream now (to also release the underlying data stream subscription)
        _photoStream?.cancel();
      }

      // send the lua command to request a photo from the Frame
      _stopwatch.reset();
      _stopwatch.start();

      // Send the respective settings for autoexposure or manual
      if (_isAutoExposure) {
        await frame!.sendMessage(TxCameraSettings(
          msgCode: 0x0d,
          qualityIndex: _qualityIndex,
          autoExpGainTimes: _autoExpGainTimes,
          autoExpInterval: _autoExpInterval,
          meteringIndex: _meteringIndex,
          exposure: _exposure,
          exposureSpeed: _exposureSpeed,
          shutterLimit: _shutterLimit,
          analogGainLimit: _analogGainLimit,
          whiteBalanceSpeed: _whiteBalanceSpeed,
        ));
      } else {
        await frame!.sendMessage(TxCameraSettings(
          msgCode: 0x0d,
          qualityIndex: _qualityIndex,
          autoExpGainTimes: 0,
          manualShutter: _manualShutter,
          manualAnalogGain: _manualAnalogGain,
          manualRedGain: _manualRedGain,
          manualGreenGain: _manualGreenGain,
          manualBlueGain: _manualBlueGain,
        ));
      }
    } catch (e) {
      _log.severe('Error executing application: $e');
    }
  }

  /// cancel the current photo
  @override
  Future<void> cancel() async {
    currentState = ApplicationState.ready;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Frame Camera',
      theme: ThemeData.dark(),
      home: Scaffold(
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
            title: const Text("Frame Camera"),
            actions: [getBatteryWidget()]),
        drawer: Drawer(
          child: ListView(
            padding: EdgeInsets.zero,
            children: <Widget>[
              const DrawerHeader(
                decoration: BoxDecoration(
                  color: Colors.blue,
                ),
                child: Text(
                  'Camera Settings',
                  style: TextStyle(color: Colors.white, fontSize: 24),
                ),
              ),
              ListTile(
                title: const Text('Quality'),
                subtitle: Slider(
                  value: _qualityIndex.toDouble(),
                  min: 0,
                  max: _qualityValues.length - 1,
                  divisions: _qualityValues.length - 1,
                  label: _qualityValues[_qualityIndex].toString(),
                  onChanged: (value) {
                    setState(() {
                      _qualityIndex = value.toInt();
                    });
                  },
                ),
              ),
              SwitchListTile(
                title: const Text('Auto Exposure/Gain'),
                value: _isAutoExposure,
                onChanged: (bool value) {
                  setState(() {
                    _isAutoExposure = value;
                  });
                },
                subtitle: Text(_isAutoExposure ? 'Auto' : 'Manual'),
              ),
              if (_isAutoExposure) ...[
                // Widgets visible in Auto mode
                ListTile(
                  title: const Text('Auto Exposure/Gain Runs'),
                  subtitle: Slider(
                    value: _autoExpGainTimes.toDouble(),
                    min: 1,
                    max: 30,
                    divisions: 29,
                    label: _autoExpGainTimes.toInt().toString(),
                    onChanged: (value) {
                      setState(() {
                        _autoExpGainTimes = value.toInt();
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Auto Exposure Interval (ms)'),
                  subtitle: Slider(
                    value: _autoExpInterval.toDouble(),
                    min: 0,
                    max: 255,
                    divisions: 255,
                    label: _autoExpInterval.toInt().toString(),
                    onChanged: (value) {
                      setState(() {
                        _autoExpInterval = value.toInt();
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Metering'),
                  subtitle: DropdownButton<int>(
                    value: _meteringIndex,
                    onChanged: (int? newValue) {
                      setState(() {
                        _meteringIndex = newValue!;
                      });
                    },
                    items: _meteringValues
                        .map<DropdownMenuItem<int>>((String value) {
                      return DropdownMenuItem<int>(
                        value: _meteringValues.indexOf(value),
                        child: Text(value),
                      );
                    }).toList(),
                  ),
                ),
                ListTile(
                  title: const Text('Exposure'),
                  subtitle: Slider(
                    value: _exposure,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: _exposure.toString(),
                    onChanged: (value) {
                      setState(() {
                        _exposure = value;
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Exposure Speed'),
                  subtitle: Slider(
                    value: _exposureSpeed,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: _exposureSpeed.toString(),
                    onChanged: (value) {
                      setState(() {
                        _exposureSpeed = value;
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Shutter Limit'),
                  subtitle: Slider(
                    value: _shutterLimit.toDouble(),
                    min: 4,
                    max: 16383,
                    divisions: 10,
                    label: _shutterLimit.toStringAsFixed(0),
                    onChanged: (value) {
                      setState(() {
                        _shutterLimit = value.toInt();
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Analog Gain Limit'),
                  subtitle: Slider(
                    value: _analogGainLimit.toDouble(),
                    min: 0,
                    max: 248,
                    divisions: 8,
                    label: _analogGainLimit.toStringAsFixed(0),
                    onChanged: (value) {
                      setState(() {
                        _analogGainLimit = value.toInt();
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('White Balance Speed'),
                  subtitle: Slider(
                    value: _whiteBalanceSpeed,
                    min: 0,
                    max: 1,
                    divisions: 20,
                    label: _whiteBalanceSpeed.toString(),
                    onChanged: (value) {
                      setState(() {
                        _whiteBalanceSpeed = value;
                      });
                    },
                  ),
                ),
              ] else ...[
                // Widgets visible in Manual mode
                ListTile(
                  title: const Text('Manual Shutter'),
                  subtitle: Slider(
                    value: _manualShutter.toDouble(),
                    min: 4,
                    max: 16383,
                    divisions: 100,
                    label: _manualShutter.toStringAsFixed(0),
                    onChanged: (value) {
                      setState(() {
                        _manualShutter = value.toInt();
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Manual Analog Gain'),
                  subtitle: Slider(
                    value: _manualAnalogGain.toDouble(),
                    min: 0,
                    max: 248,
                    divisions: 50,
                    label: _manualAnalogGain.toStringAsFixed(0),
                    onChanged: (value) {
                      setState(() {
                        _manualAnalogGain = value.toInt();
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Red Gain'),
                  subtitle: Slider(
                    value: _manualRedGain.toDouble(),
                    min: 0,
                    max: 1023,
                    divisions: 100,
                    label: _manualRedGain.toStringAsFixed(0),
                    onChanged: (value) {
                      setState(() {
                        _manualRedGain = value.toInt();
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Green Gain'),
                  subtitle: Slider(
                    value: _manualGreenGain.toDouble(),
                    min: 0,
                    max: 1023,
                    divisions: 100,
                    label: _manualGreenGain.toStringAsFixed(0),
                    onChanged: (value) {
                      setState(() {
                        _manualGreenGain = value.toInt();
                      });
                    },
                  ),
                ),
                ListTile(
                  title: const Text('Blue Gain'),
                  subtitle: Slider(
                    value: _manualBlueGain.toDouble(),
                    min: 0,
                    max: 1023,
                    divisions: 100,
                    label: _manualBlueGain.toStringAsFixed(0),
                    onChanged: (value) {
                      setState(() {
                        _manualBlueGain = value.toInt();
                      });
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
        body: Flex(direction: Axis.vertical, children: [
          Expanded(
            // scrollable list view for multiple photos
            child: ListView.separated(
              itemBuilder: (context, index) {
                return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.rotationZ(-pi * 0.5),
                            child: GestureDetector(
                                onTap: () => _shareImage(_imageList[index],
                                    _imageMeta[index], _jpegBytes[index]),
                                child: _imageList[index])),
                        _imageMeta[index],
                      ],
                    ));
              },
              separatorBuilder: (context, index) => const Divider(height: 30),
              itemCount: _imageList.length,
            ),
          ),
        ]),
        floatingActionButton: getFloatingActionButtonWidget(
            const Icon(Icons.camera_alt), const Icon(Icons.cancel)),
        persistentFooterButtons: getFooterButtonsWidget(),
      ),
    );
  }

  void _shareImage(
      Image image, StatelessWidget metadata, Uint8List jpegBytes) async {
    try {
      // Share the image bytes as a JPEG file
      img.Image im = img.decodeImage(jpegBytes)!;
      // rotate the image 90 degrees counterclockwise since the Frame camera is rotated 90 clockwise
      img.Image rotatedImage = img.copyRotate(im, angle: 270);

      await Share.shareXFiles(
        [
          XFile.fromData(Uint8List.fromList(img.encodeJpg(rotatedImage)),
              mimeType: 'image/jpeg', name: 'image.jpg')
        ],
        text: 'Frame camera image',
      );
    } catch (e) {
      _log.severe('Error preparing image for sharing: $e');
    }
  }
}

class AutoExpImageMetadata extends StatelessWidget {
  final int quality;
  final int exposureRuns;
  final int exposureInterval;
  final String metering;
  final double exposure;
  final double exposureSpeed;
  final int shutterLimit;
  final int analogGainLimit;
  final double whiteBalanceSpeed;

  AutoExpImageMetadata(
      this.quality,
      this.exposureRuns,
      this.exposureInterval,
      this.metering,
      this.exposure,
      this.exposureSpeed,
      this.shutterLimit,
      this.analogGainLimit,
      this.whiteBalanceSpeed,
      {super.key});

  late int size;
  late int elapsedTimeMs;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Text(
            'Quality: $quality\nExposureRuns: $exposureRuns\nExpInterval: $exposureInterval\nMetering: $metering'),
        const Spacer(),
        Text(
            '\nExposure: $exposure\nExposureSpeed: $exposureSpeed\nShutterLim: $shutterLimit\nAnalogGainLim: $analogGainLimit'),
        const Spacer(),
        Text(
            '\nWBSpeed: $whiteBalanceSpeed\nSize: ${(size / 1024).toStringAsFixed(1)} kb\nTime: $elapsedTimeMs ms'),
      ],
    );
  }
}

class ManualExpImageMetadata extends StatelessWidget {
  final int quality;
  final int shutter;
  final int analogGain;
  final int redGain;
  final int greenGain;
  final int blueGain;

  ManualExpImageMetadata(this.quality, this.shutter, this.analogGain,
      this.redGain, this.greenGain, this.blueGain,
      {super.key});

  late int size;
  late int elapsedTimeMs;

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      Text('Quality: $quality\nShutter: $shutter\nAnalogGain: $analogGain'),
      const Spacer(),
      Text('RedGain: $redGain\nGreenGain: $greenGain\nBlueGain: $blueGain'),
      const Spacer(),
      Text(
          'Size: ${(size / 1024).toStringAsFixed(1)} kb\nTime: $elapsedTimeMs ms'),
    ]);
  }
}
