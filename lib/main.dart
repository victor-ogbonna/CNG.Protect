import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_gauges/gauges.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

// -----------------------------------------------------------
// 1. CONFIGURATION & SERVICES
// -----------------------------------------------------------
const firebaseOptions = FirebaseOptions(
    apiKey: "AIzaSyDVK5F-wcrpVTqCcFdb1hiDSq5xnY4szQY", 
    appId: "1:826381084764:android:1faf29fa6bc5b8d89b1e99", 
    messagingSenderId: "826381084764", 
    projectId: "cng-protect",
    databaseURL: "https://cng-protect-default-rtdb.firebaseio.com/",
    storageBucket: "cng-protect.firebasestorage.app",
    authDomain: "cng-protect.firebaseapp.com"
);

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin = FlutterLocalNotificationsPlugin();

Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: firebaseOptions);
  debugPrint("Background Message: ${message.messageId}");
}

// -----------------------------------------------------------
// 2. MAIN ENTRY
// -----------------------------------------------------------
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // 1. Initialize Firebase
  try {
    await Firebase.initializeApp(options: firebaseOptions);
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
  } catch (e) {
    debugPrint("FIREBASE INIT ERROR: $e");
  }
  
  // 2. Initialize Local Notifications
  // Matches 'launcher_icon' in pubspec.yaml
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('@mipmap/launcher_icon');
      
  const InitializationSettings initializationSettings =
      InitializationSettings(android: initializationSettingsAndroid);
      
  await flutterLocalNotificationsPlugin.initialize(initializationSettings);

  // 3. Initialize DB
  await HistoryDatabase.instance.database;

  // 4. Anonymous Login (Required for Database Access)
  try {
    await FirebaseAuth.instance.signInAnonymously();
  } catch (e) {
    debugPrint("AUTH ERROR: $e");
  }

  // 5. Load Theme Preference
  final prefs = await SharedPreferences.getInstance();
  final String themeString = prefs.getString('themeMode') ?? 'system';
  ThemeMode savedThemeMode = ThemeMode.system;
  if (themeString == 'light') savedThemeMode = ThemeMode.light;
  if (themeString == 'dark') savedThemeMode = ThemeMode.dark;

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => ThemeProvider(initialTheme: savedThemeMode)),
        ChangeNotifierProvider(create: (_) => RealtimeDataNotifier()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'CNG Protect',
          themeMode: themeProvider.themeMode,
          theme: ThemeData.light(useMaterial3: true),
          darkTheme: ThemeData.dark(useMaterial3: true),
          home: const MainNavigationShell(),
        );
      },
    );
  }
}

// -----------------------------------------------------------
// 3. NAVIGATION SHELL
// -----------------------------------------------------------
class MainNavigationShell extends StatefulWidget {
  const MainNavigationShell({super.key});
  @override
  State<MainNavigationShell> createState() => _MainNavigationShellState();
}

class _MainNavigationShellState extends State<MainNavigationShell> {
  int _selectedIndex = 0;
  final List<Widget> _screens = [
    const DashboardScreen(),       
    const AlertHistoryScreen(),    
    const DeviceManagementScreen(),
    const SettingsScreen(),        
  ];

  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  void _requestPermissions() async {
    await flutterLocalNotificationsPlugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
    await FirebaseMessaging.instance.requestPermission();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Dashboard'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: 'History'),
          BottomNavigationBarItem(icon: Icon(Icons.devices), label: 'Devices'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: 'Settings'),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.green,
        unselectedItemColor: Colors.grey,
        onTap: (index) => setState(() => _selectedIndex = index),
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}

// -----------------------------------------------------------
// 4. THE WATCHDOG & DATA NOTIFIER
// -----------------------------------------------------------
class RealtimeDataNotifier with ChangeNotifier {
  int _gasLevel = 0; 
  double _temperature = 0.0;
  final List<FlSpot> _tempHistory = []; 
  double _timeCounter = 0;
  
  // --- OFFLINE DETECTION ---
  bool _isConnected = false;
  Timer? _watchdogTimer;
  DateTime? _lastAlertTime;

  int get gasLevel => _gasLevel; 
  double get temperature => _temperature;
  List<FlSpot> get tempHistory => _tempHistory;
  bool get isConnected => _isConnected;

  RealtimeDataNotifier() {
    FirebaseDatabase.instance
        .ref('cng_protect/devices/device_01/live_data')
        .onValue
        .listen((event) {
          final data = event.snapshot.value;
          if (data != null && data is Map) {
            
            _isConnected = true;
            _resetWatchdog(); 

            _gasLevel = (data['gas_level'] as int?) ?? 0;
            _temperature = (data['temperature'] as num?)?.toDouble() ?? 0.0;
            
            _timeCounter++; 
            _tempHistory.add(FlSpot(_timeCounter, _temperature));
            if (_tempHistory.length > 20) _tempHistory.removeAt(0);

            _checkThresholds();
            notifyListeners();
          }
        }, onError: (error) {
          debugPrint("DATABASE LISTENER ERROR: $error");
        });
    
    _resetWatchdog();
  }

  void _resetWatchdog() {
    _watchdogTimer?.cancel();
    _watchdogTimer = Timer(const Duration(seconds: 15), () {
      if (_isConnected) {
        _isConnected = false;
        notifyListeners(); 
      }
    });
  }

  void _checkThresholds() {
    if (_lastAlertTime != null && DateTime.now().difference(_lastAlertTime!).inSeconds < 60) return;

    if (_gasLevel > 1100 || _temperature >= 40) {
      _triggerLocalNotification(
        "CRITICAL ALERT!", 
        "Gas: $_gasLevel | Temp: $_temperature. Check Vehicle!"
      );
      _lastAlertTime = DateTime.now();
    }
  }

  Future<void> _triggerLocalNotification(String title, String body) async {
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'cng_alerts', 'CNG Alerts',
      importance: Importance.max, 
      priority: Priority.high, 
      color: Colors.red,
    );
    const NotificationDetails details = NotificationDetails(android: androidDetails);
    
    await flutterLocalNotificationsPlugin.show(0, title, body, details);
    
    HistoryDatabase.instance.createAlert(AlertItem(
      title: title, message: body, timestamp: DateTime.now().toString()
    ));
  }
}

// -----------------------------------------------------------
// 5. DASHBOARD SCREEN
// -----------------------------------------------------------
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final data = Provider.of<RealtimeDataNotifier>(context);
    
    Color color = Colors.green;
    String text = "SAFE";
    
    if (!data.isConnected) {
      color = Colors.grey;
      text = "DISCONNECTED";
    } else if (data.gasLevel > 1100) { 
      color = Colors.red; 
      text = "DANGER - LEAK DETECTED"; 
    } else if (data.temperature >= 40) {
      color = Colors.orange;
      text = "HIGH TEMP";
    } else if (data.gasLevel > 800) {
      color = Colors.orange;
      text = "WARNING";
    }

    // Using .withValues() for modern Flutter compatibility
    return Scaffold(
      appBar: AppBar(title: const Text("CNG Protect")),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            children: [
              // CONNECTIVITY BADGE
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: data.isConnected 
                    ? Colors.green.withValues(alpha: 0.1) 
                    : Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20)
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.circle, size: 10, color: data.isConnected ? Colors.green : Colors.red),
                    const SizedBox(width: 8),
                    Text(
                      data.isConnected ? "Cloud Connected" : "Offline",
                      style: TextStyle(
                        fontWeight: FontWeight.bold, 
                        fontSize: 12, 
                        color: data.isConnected ? Colors.green : Colors.red
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 15),

              // MAIN STATUS BOX
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(15),
                  border: Border.all(color: color, width: 2),
                ),
                child: Text(text, textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color)),
              ),
              const SizedBox(height: 20),

              // GAUGE
              SizedBox(
                height: 250,
                child: SfRadialGauge(
                  axes: <RadialAxis>[
                    RadialAxis(
                      minimum: 0, maximum: 1100, 
                      ranges: <GaugeRange>[
                        GaugeRange(startValue: 0, endValue: 800, color: Colors.green),
                        GaugeRange(startValue: 800, endValue: 1000, color: Colors.orange),
                        GaugeRange(startValue: 1000, endValue: 1100, color: Colors.red),
                      ],
                      pointers: <GaugePointer>[
                        NeedlePointer(value: data.isConnected ? data.gasLevel.toDouble() : 0)
                      ],
                      annotations: <GaugeAnnotation>[
                         GaugeAnnotation(
                           widget: Text(
                             data.isConnected ? '${data.gasLevel} PPM' : '--', 
                             style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20)
                           ), 
                           positionFactor: 0.5, angle: 90
                         )
                      ]
                    )
                  ],
                ),
              ),

              // TEMPERATURE
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.thermostat, color: Colors.blue),
                  Text(
                    data.isConnected ? " ${data.temperature.toStringAsFixed(1)} °C" : " -- °C", 
                    style: const TextStyle(fontSize: 22)
                  ),
                ],
              ),
              const SizedBox(height: 30),

              // HISTORY CHART
              SizedBox(
                height: 180,
                child: data.tempHistory.isEmpty 
                 ? const Center(child: Text("Waiting for data..."))
                 : LineChart(
                    LineChartData(
                      minY: 0, maxY: 50,
                      lineBarsData: [
                        LineChartBarData(
                          spots: data.tempHistory,
                          isCurved: true, 
                          color: Colors.blue, 
                          barWidth: 3, 
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(show: true, color: Colors.blue.withValues(alpha: 0.1)),
                        ),
                      ],
                      titlesData: FlTitlesData(
                        show: true,
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true, reservedSize: 30, interval: 25,
                            getTitlesWidget: (value, meta) {
                              if (value == 0 || value == 25 || value == 50) {
                                return const Text("0", style: TextStyle(fontSize: 12));
                              }
                              return Text(value.toInt().toString(), style: const TextStyle(fontSize: 12));
                            }
                          )
                        ),
                        bottomTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                      ),
                      gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: 25),
                      borderData: FlBorderData(show: true, border: Border.all(color: Colors.grey.withValues(alpha: 0.3))),
                    ),
                  ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// -----------------------------------------------------------
// 6. SETTINGS & THEME
// -----------------------------------------------------------
class ThemeProvider with ChangeNotifier {
  ThemeMode _themeMode;
  ThemeProvider({required ThemeMode initialTheme}) : _themeMode = initialTheme;
  ThemeMode get themeMode => _themeMode;
  void setTheme(ThemeMode mode) async {
    _themeMode = mode;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    String modeString = 'system';
    if (mode == ThemeMode.light) modeString = 'light';
    if (mode == ThemeMode.dark) modeString = 'dark';
    await prefs.setString('themeMode', modeString);
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}
class _SettingsScreenState extends State<SettingsScreen> {
  bool _notificationsEnabled = true; 
  @override void initState() { super.initState(); _loadSettings(); }
  _loadSettings() async { final prefs = await SharedPreferences.getInstance(); setState(() { _notificationsEnabled = prefs.getBool('notifications') ?? true; }); }
  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    return Scaffold(
      appBar: AppBar(title: const Text("Settings")),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        SwitchListTile(
          title: const Text("Receive Push Alerts"), 
          value: _notificationsEnabled, 
          onChanged: (val) async { 
             setState(() => _notificationsEnabled = val); 
             final prefs = await SharedPreferences.getInstance(); 
             prefs.setBool('notifications', val);
          }
        ),
        const Divider(),
        const Padding(padding: EdgeInsets.symmetric(vertical: 10), child: Text("App Theme", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.blue))),
        
        Center(
          child: SegmentedButton<ThemeMode>(
            segments: const <ButtonSegment<ThemeMode>>[
              ButtonSegment<ThemeMode>(
                  value: ThemeMode.system,
                  label: Text('System'),
                  icon: Icon(Icons.brightness_auto)),
              ButtonSegment<ThemeMode>(
                  value: ThemeMode.light,
                  label: Text('Light'),
                  icon: Icon(Icons.light_mode)),
              ButtonSegment<ThemeMode>(
                  value: ThemeMode.dark,
                  label: Text('Dark'),
                  icon: Icon(Icons.dark_mode)),
            ],
            selected: <ThemeMode>{themeProvider.themeMode},
            onSelectionChanged: (Set<ThemeMode> newSelection) {
              themeProvider.setTheme(newSelection.first);
            },
          ),
        ),
      ]),
    );
  }
}

// -----------------------------------------------------------
// 7. OTHER SCREENS
// -----------------------------------------------------------
class AlertHistoryScreen extends StatefulWidget {
  const AlertHistoryScreen({super.key});
  @override
  State<AlertHistoryScreen> createState() => _AlertHistoryScreenState();
}
class _AlertHistoryScreenState extends State<AlertHistoryScreen> {
  late Future<List<AlertItem>> _alertsFuture;
  @override void initState() { super.initState(); _refreshList(); }
  void _refreshList() { setState(() { _alertsFuture = HistoryDatabase.instance.readAllAlerts(); }); }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Alert History"), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshList)]),
      body: FutureBuilder<List<AlertItem>>(
        future: _alertsFuture,
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final alerts = snapshot.data!;
          if (alerts.isEmpty) return const Center(child: Text("No alerts yet."));
          return ListView.builder(
            itemCount: alerts.length,
            itemBuilder: (context, index) {
              final alert = alerts[index];
              return Card(child: ListTile(
                leading: const Icon(Icons.warning, color: Colors.orange),
                title: Text(alert.title), subtitle: Text(alert.message), trailing: Text(alert.timestamp.substring(11, 16)),
              ));
            },
          );
        },
      ),
    );
  }
}

class DeviceManagementScreen extends StatelessWidget {
  const DeviceManagementScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("My Devices")),
      body: ListView(
        padding: const EdgeInsets.all(10),
        children: [
          // CONST added here for optimization
          const Card(child: ListTile(leading: Icon(Icons.directions_car, color: Colors.green, size: 40), title: Text("Toyota Corolla"), subtitle: Text("Status: Online"), trailing: Icon(Icons.circle, color: Colors.green))),
          const SizedBox(height: 10),
          Card(
            color: Theme.of(context).brightness == Brightness.dark ? Colors.grey[900] : Colors.grey[200],
            // CONST added here for optimization
            child: const ListTile(
              leading: Icon(Icons.directions_car, color: Colors.grey, size: 40), 
              title: Text("Honda Civic", style: TextStyle(color: Colors.grey)), 
              subtitle: Text("Status: Offline", style: TextStyle(color: Colors.redAccent)), 
              trailing: Icon(Icons.circle, color: Colors.redAccent)
            )
          ),
        ],
      ),
    );
  }
}

// -----------------------------------------------------------
// 8. DATABASE HELPERS
// -----------------------------------------------------------
class AlertItem {
  final int? id; final String title; final String message; final String timestamp;
  AlertItem({this.id, required this.title, required this.message, required this.timestamp});
  Map<String, dynamic> toMap() => {'title': title, 'message': message, 'timestamp': timestamp};
}

class HistoryDatabase {
  static final HistoryDatabase instance = HistoryDatabase._init();
  static Database? _database;
  HistoryDatabase._init();
  Future<Database> get database async { if (_database != null) return _database!; _database = await openDatabase(p.join(await getDatabasesPath(), 'alerts.db'), version: 1, onCreate: (db, v) => db.execute('CREATE TABLE alerts (id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT, message TEXT, timestamp TEXT)')); return _database!; }
  Future<void> createAlert(AlertItem alert) async { final db = await instance.database; await db.insert('alerts', alert.toMap()); }
  Future<List<AlertItem>> readAllAlerts() async { final db = await instance.database; final result = await db.query('alerts', orderBy: 'timestamp DESC'); return result.map((json) => AlertItem(id: json['id'] as int?, title: json['title'] as String, message: json['message'] as String, timestamp: json['timestamp'] as String)).toList(); }
}