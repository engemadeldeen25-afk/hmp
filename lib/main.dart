import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:csv/csv.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:intl/intl.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Color(0xFF0A0E1A),
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const HmpApp());
}

// ============================================================
//  APP
// ============================================================
class HmpApp extends StatelessWidget {
  const HmpApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HMP',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00E5FF),
          secondary: Color(0xFF1E88E5),
          surface: Color(0xFF151B2E),
        ),
        scaffoldBackgroundColor: const Color(0xFF0A0E1A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0A0E1A),
          elevation: 0,
          centerTitle: false,
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF151B2E),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xFF2A3654)),
          ),
        ),
      ),
      home: const HomePage(),
    );
  }
}

// ============================================================
//  MODELS
// ============================================================
class LWDReading {
  final double evd;
  final double deflection;
  final double accel;
  final double velocity;
  final double angle;
  final DateTime time;

  LWDReading({
    required this.evd,
    required this.deflection,
    required this.accel,
    required this.velocity,
    required this.angle,
    required this.time,
  });
}

class TestPoint {
  final int id;
  final DateTime time;
  final double evd;
  final double deflection;
  final double latitude;
  final double longitude;
  final bool passed;

  TestPoint({
    required this.id,
    required this.time,
    required this.evd,
    required this.deflection,
    required this.latitude,
    required this.longitude,
    required this.passed,
  });
}

// ============================================================
//  HOME PAGE
// ============================================================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  StreamSubscription<List<int>>? _sub;
  bool _scanning = false;
  bool _connected = false;
  String _status = "Disconnected";

  LWDReading _live = LWDReading(
    evd: 0,
    deflection: 0,
    accel: 0,
    velocity: 0,
    angle: 0,
    time: DateTime.now(),
  );
  final List<double> _waveform = List.filled(60, 0);
  final List<TestPoint> _tests = [];
  int _nextId = 1;

  double _calFactor = 1.0;
  String _calDate = 'Never';
  double _targetEvd = 40.0;
  final String _password = '2841198';
  late SharedPreferences _prefs;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  Future<void> _init() async {
    await Permission.location.request();
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();

    final scan = await Permission.bluetoothScan.status;
    final connect = await Permission.bluetoothConnect.status;

    if (!scan.isGranted || !connect.isGranted) {
      if (mounted) setState(() => _status = "Permissions denied");
      return;
    }

    _prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _calFactor = _prefs.getDouble('cal') ?? 1.0;
      _calDate = _prefs.getString('calDate') ?? 'Never';
      _targetEvd = _prefs.getDouble('target') ?? 40.0;
    });

    await Future.delayed(const Duration(milliseconds: 800));
    _startScan();
  }

  Future<void> _startScan() async {
    if (_scanning) return;

    if (!await FlutterBluePlus.isOn) {
      if (mounted) {
        setState(() => _status = "Bluetooth OFF");
        _snack("Please enable Bluetooth");
      }
      return;
    }

    setState(() {
      _scanning = true;
      _status = "Scanning...";
    });

    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    await Future.delayed(const Duration(milliseconds: 500));

    BluetoothDevice? foundDevice;

    final sub = FlutterBluePlus.scanResults.listen((results) {
      for (final r in results) {
        final name = r.device.platformName;
        final advName = r.advertisementData.advName;
        if (name.contains("LWD") || advName.contains("LWD")) {
          if (foundDevice == null) foundDevice = r.device;
        }
      }
    });

    try {
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
    } catch (_) {}

    await Future.delayed(const Duration(seconds: 11));
    await sub.cancel();
    try {
      await FlutterBluePlus.stopScan();
    } catch (_) {}

    if (!mounted) return;
    setState(() => _scanning = false);

    if (foundDevice != null) {
      _connect(foundDevice!);
    } else {
      setState(() => _status = "Not found");
      _snack("No LWD device found - tap scan again");
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() => _status = "Connecting...");

    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        await device.connect(timeout: const Duration(seconds: 15));
        await Future.delayed(const Duration(milliseconds: 700));

        final services = await device.discoverServices();
        BluetoothCharacteristic? target;

        for (final s in services) {
          for (final c in s.characteristics) {
            final u = c.uuid.toString().toLowerCase().replaceAll('-', '');
            if (u == "6e400002b5a3f393e0a9e50e24dcca9e") {
              target = c;
            }
          }
        }

        if (target == null) throw Exception("Characteristic not found");

        _device = device;
        _rx = target;
        await target.setNotifyValue(true);

        _sub = target.onValueReceived.listen((v) {
          final t = utf8.decode(v, allowMalformed: true);
          _onData(t);
        });

        setState(() {
          _connected = true;
          _status = "Online";
        });
        return;
      } catch (e) {
        if (attempt < 3) {
          try {
            await device.disconnect();
          } catch (_) {}
          await Future.delayed(const Duration(seconds: 2));
        }
      }
    }

    if (!mounted) return;
    setState(() {
      _connected = false;
      _status = "Failed";
    });
    _snack("Connection failed - try again");
  }

  Future<void> _disconnect() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _device = null;
    _rx = null;
    if (!mounted) return;
    setState(() {
      _connected = false;
      _status = "Disconnected";
    });
  }

  void _onData(String raw) {
    try {
      final t = raw.trim();
      if (!t.startsWith("{")) return;
      final m = jsonDecode(t) as Map<String, dynamic>;

      final evd = (m["evd"] ?? 0).toDouble() * _calFactor;
      final def = (m["def"] ?? 0).toDouble();
      final acc = (m["acc"] ?? 0).toDouble();
      final vel = (m["vel"] ?? 0).toDouble();
      final ang = (m["angle"] ?? 0).toDouble();

      if (!mounted) return;
      setState(() {
        _live = LWDReading(
          evd: evd,
          deflection: def,
          accel: acc,
          velocity: vel,
          angle: ang,
          time: DateTime.now(),
        );
        if (def > 0) {
          _waveform.add(def);
          if (_waveform.length > 60) _waveform.removeAt(0);
        }
      });

      if (def > 0.1 && evd > 0.5) _recordTest(evd, def);
    } catch (_) {}
  }

  Future<void> _recordTest(double evd, double def) async {
    if (_tests.isNotEmpty &&
        DateTime.now().difference(_tests.last.time).inSeconds < 2) {
      return;
    }

    double lat = 0, lng = 0;
    try {
      final pos = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
        timeLimit: const Duration(seconds: 2),
      );
      lat = pos.latitude;
      lng = pos.longitude;
    } catch (_) {}

    final p = TestPoint(
      id: _nextId++,
      time: DateTime.now(),
      evd: evd,
      deflection: def,
      latitude: lat,
      longitude: lng,
      passed: evd >= _targetEvd,
    );
    if (!mounted) return;
    setState(() => _tests.add(p));
  }

  void _showCalDialog() {
    final pass = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: const [
            Icon(Icons.lock_outline, color: Colors.amber),
            SizedBox(width: 8),
            Text('Calibration Access'),
          ],
        ),
        content: TextField(
          controller: pass,
          obscureText: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            hintText: 'Enter password',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (pass.text == _password) {
                Navigator.pop(ctx);
                _showCalEditor();
              } else {
                _snack('Wrong password');
              }
            },
            child: const Text('Unlock'),
          ),
        ],
      ),
    );
  }

  void _showCalEditor() {
    final factor = TextEditingController(text: _calFactor.toStringAsFixed(3));
    final target = TextEditingController(text: _targetEvd.toStringAsFixed(1));
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151B2E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Calibration Settings'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: factor,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'EVD Multiplier',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: target,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Target EVD (MN/m²)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            Text('Last update: $_calDate',
                style: const TextStyle(fontSize: 11, color: Colors.grey)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final f = double.tryParse(factor.text);
              final t = double.tryParse(target.text);
              if (f != null && f > 0 && t != null && t > 0) {
                await _prefs.setDouble('cal', f);
                await _prefs.setDouble('target', t);
                await _prefs.setString(
                    'calDate',
                    DateFormat('yyyy-MM-dd HH:mm').format(DateTime.now()));
                if (!mounted) return;
                setState(() {
                  _calFactor = f;
                  _targetEvd = t;
                  _calDate = _prefs.getString('calDate')!;
                });
                Navigator.pop(ctx);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    if (_tests.isEmpty) {
      _snack('No tests to export');
      return;
    }

    final rows = <List<dynamic>>[
      [
        'Test #',
        'Date',
        'Time',
        'EVD (MN/m²)',
        'Deflection (mm)',
        'Latitude',
        'Longitude',
        'Status'
      ],
    ];
    for (final t in _tests) {
      rows.add([
        t.id,
        DateFormat('yyyy-MM-dd').format(t.time),
        DateFormat('HH:mm:ss').format(t.time),
        t.evd.toStringAsFixed(1),
        t.deflection.toStringAsFixed(3),
        t.latitude.toStringAsFixed(6),
        t.longitude.toStringAsFixed(6),
        t.passed ? 'PASS' : 'FAIL',
      ]);
    }

    final csv = const ListToCsvConverter().convert(rows);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final f = File(
          '${dir.path}/HMP_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv');
      await f.writeAsString(csv);
      await Share.shareXFiles([XFile(f.path)],
          subject: 'HMP - Test Report');
      _snack('Report exported');
    } catch (e) {
      _snack('Export failed: $e');
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final passed = _live.evd >= _targetEvd;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF00E5FF).withOpacity(0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.speed, color: Color(0xFF00E5FF), size: 20),
            ),
            const SizedBox(width: 10),
            const Text(
              'HMP',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                letterSpacing: 2.5,
                fontSize: 20,
              ),
            ),
          ],
        ),
        actions: [
          _statusBadge(),
          IconButton(
            icon: const Icon(Icons.tune, color: Colors.amber),
            onPressed: _showCalDialog,
            tooltip: 'Calibration',
          ),
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : Icon(
                    _connected
                        ? Icons.bluetooth_connected
                        : Icons.bluetooth_searching,
                    color: _connected ? Colors.greenAccent : null,
                  ),
            onPressed: (_connected || _scanning) ? null : _startScan,
            tooltip: _connected ? 'Connected' : 'Scan',
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            onPressed: _connected ? _disconnect : null,
            color: _connected ? Colors.redAccent : Colors.grey,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildLiveCard(passed),
            const SizedBox(height: 16),
            _buildChartCard(),
            const SizedBox(height: 16),
            _buildStatsCard(),
            const SizedBox(height: 16),
            _buildActions(),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _statusBadge() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: _connected
              ? Colors.green.shade800.withOpacity(0.8)
              : (_status == "Scanning..." || _status == "Connecting...")
                  ? Colors.orange.shade800.withOpacity(0.8)
                  : Colors.red.shade800.withOpacity(0.8),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withOpacity(0.6),
                    blurRadius: 4,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _status,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLiveCard(bool passed) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF151B2E), Color(0xFF1E2740)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: passed ? Colors.green.withOpacity(0.4) : const Color(0xFF2A3654),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: passed
                ? Colors.green.withOpacity(0.15)
                : Colors.black.withOpacity(0.3),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _metric(
                'EVD MODULUS',
                _live.evd.toStringAsFixed(1),
                'MN/m²',
                const Color(0xFF00E5FF),
                46,
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  _metric(
                    'DEFLECTION',
                    _live.deflection.toStringAsFixed(3),
                    'mm',
                    Colors.orangeAccent,
                    26,
                  ),
                  const SizedBox(height: 10),
                  _metric(
                    'ACCEL',
                    _live.accel.toStringAsFixed(2),
                    'g',
                    Colors.purpleAccent,
                    18,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: passed
                        ? [Colors.green.shade700, Colors.green.shade900]
                        : [Colors.red.shade700, Colors.red.shade900],
                  ),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color:
                          (passed ? Colors.green : Colors.red).withOpacity(0.4),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    Icon(
                      passed ? Icons.verified : Icons.cancel,
                      color: Colors.white,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      passed ? 'PASS' : 'FAIL',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                        letterSpacing: 1.5,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: (_live.evd / 80).clamp(0.0, 1.0),
                        minHeight: 10,
                        backgroundColor: Colors.grey.shade900,
                        valueColor: AlwaysStoppedAnimation(
                          passed ? Colors.green : Colors.red,
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('0',
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade500)),
                        Text('Target ${_targetEvd.toStringAsFixed(0)}',
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade500)),
                        Text('80',
                            style: TextStyle(
                                fontSize: 10, color: Colors.grey.shade500)),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(color: Color(0xFF2A3654), height: 1),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _smallInfo(
                  Icons.speed, '${_live.velocity.toStringAsFixed(3)} m/s'),
              _smallInfo(
                  Icons.straighten, '${_live.angle.toStringAsFixed(1)}°'),
              _smallInfo(
                  Icons.timer, DateFormat('HH:mm:ss').format(_live.time)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _metric(
      String label, String value, String unit, Color color, double size) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade500,
            fontSize: 10,
            letterSpacing: 1.5,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: size,
                fontWeight: FontWeight.bold,
                color: color,
                letterSpacing: -1,
              ),
            ),
            const SizedBox(width: 4),
            Text(
              unit,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget _smallInfo(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 14, color: const Color(0xFF00E5FF).withOpacity(0.8)),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 11,
              fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  Widget _buildChartCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.show_chart, color: Color(0xFF00E5FF), size: 16),
              const SizedBox(width: 8),
              const Text(
                'DEFLECTION WAVEFORM',
                style: TextStyle(
                    color: Colors.grey,
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 150,
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 0.5,
                  getDrawingHorizontalLine: (_) => FlLine(
                    color: Colors.grey.shade900,
                    strokeWidth: 1,
                  ),
                ),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                minX: 0,
                maxX: 59,
                minY: -0.2,
                maxY: 2.5,
                lineBarsData: [
                  LineChartBarData(
                    spots: _waveform
                        .asMap()
                        .entries
                        .map((e) => FlSpot(e.key.toDouble(), e.value))
                        .toList(),
                    isCurved: true,
                    curveSmoothness: 0.35,
                    color: const Color(0xFF00E5FF),
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF00E5FF).withOpacity(0.35),
                          const Color(0xFF00E5FF).withOpacity(0.0),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsCard() {
    final passed = _tests.where((t) => t.passed).length;
    final failed = _tests.length - passed;
    final avg = _tests.isEmpty
        ? 0.0
        : _tests.map((t) => t.evd).reduce((a, b) => a + b) / _tests.length;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF151B2E),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF2A3654)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.analytics_outlined,
                  color: Color(0xFF1E88E5), size: 16),
              const SizedBox(width: 8),
              const Text(
                'TEST SUMMARY',
                style: TextStyle(
                    color: Colors.grey,
                    fontSize: 11,
                    letterSpacing: 1.5,
                    fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _stat('TOTAL', '${_tests.length}', Colors.white),
              _stat('PASS', '$passed', Colors.greenAccent),
              _stat('FAIL', '$failed', Colors.redAccent),
              _stat('AVG', avg.toStringAsFixed(1), const Color(0xFF00E5FF)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.grey.shade600,
            fontSize: 10,
            letterSpacing: 1,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return Row(
      children: [
        Expanded(
          child: ElevatedButton.icon(
            onPressed: _export,
            icon: const Icon(Icons.ios_share, size: 18),
            label: const Text('EXPORT',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5)),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1E88E5),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 4,
              shadowColor: const Color(0xFF1E88E5).withOpacity(0.5),
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: ElevatedButton.icon(
            onPressed: () {
              setState(() {
                _tests.clear();
                _nextId = 1;
                _waveform.fillRange(0, _waveform.length, 0);
              });
            },
            icon: const Icon(Icons.delete_sweep_outlined, size: 18),
            label: const Text('CLEAR',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red.shade900,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 16),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14)),
              elevation: 4,
              shadowColor: Colors.red.shade900.withOpacity(0.5),
            ),
          ),
        ),
      ],
    );
  }
}