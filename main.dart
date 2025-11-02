import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:url_launcher/url_launcher.dart';

// ===================== CONFIG (reads Android Manifest via MethodChannel; falls back to --dart-define) =====================
class AppConfig {
  static String geminiApiKey = '';
  static String googleCseKey = '';
  static String googleCseCx  = '';

  static const MethodChannel _ch = MethodChannel('config/meta');

  static Future<void> load() async {
    try {
      final meta = await _ch.invokeMethod<Map>('getMeta');
      geminiApiKey = (meta?['GEMINI_API_KEY'] as String?) ?? '';
      googleCseKey = (meta?['GOOGLE_CSE_KEY'] as String?) ?? '';
      googleCseCx  = (meta?['GOOGLE_CSE_CX']  as String?) ?? '';

      // ✅ Log key presence for verification (masked for safety)
      debugPrint('[AppConfig] Keys loaded from AndroidManifest:');
      debugPrint('  GEMINI_API_KEY: ' + (geminiApiKey.isEmpty
          ? '❌ MISSING'
          : '✅ SET (' + geminiApiKey.substring(0, 5) + '...' + geminiApiKey.substring(geminiApiKey.length - 4) + ')'));
      debugPrint('  GOOGLE_CSE_KEY: ' + (googleCseKey.isEmpty ? '❌ MISSING' : '✅ SET'));
      debugPrint('  GOOGLE_CSE_CX: ' + (googleCseCx.isEmpty ? '❌ MISSING' : '✅ SET'));
    } catch (e) {
      // If MethodChannel fails (e.g., web or iOS), use fallback
      geminiApiKey = const String.fromEnvironment('GEMINI_API_KEY', defaultValue: '');
      googleCseKey = const String.fromEnvironment('GOOGLE_CSE_KEY', defaultValue: '');
      googleCseCx  = const String.fromEnvironment('GOOGLE_CSE_CX',  defaultValue: '');

      debugPrint('[AppConfig] ⚠️ Using fallback (fromEnvironment). Error: $e');
      debugPrint('  GEMINI_API_KEY: ' + (geminiApiKey.isEmpty ? 'MISSING' : 'SET'));
    }
  }
}

// ===================== MODELS =====================
class RecipeCardModel {
  final String title;
  final List<String> ingredients;
  final List<String> steps;
  final Map<String, dynamic>? nutrition;
  final String imageUrl;

  RecipeCardModel({
    required this.title,
    required this.ingredients,
    required this.steps,
    required this.imageUrl,
    this.nutrition,
  });

  Map<String, dynamic> toJson() => {
    'title': title,
    'ingredients': ingredients,
    'steps': steps,
    'imageUrl': imageUrl,
    'nutrition': nutrition,
  };

  factory RecipeCardModel.fromJson(Map<String, dynamic> j) => RecipeCardModel(
    title: j['title'],
    ingredients: (j['ingredients'] as List).map((e) => e.toString()).toList(),
    steps: (j['steps'] as List).map((e) => e.toString()).toList(),
    imageUrl: j['imageUrl'] ?? '',
    nutrition: j['nutrition'] == null ? null : Map<String, dynamic>.from(j['nutrition']),
  );
}

class HistoryItem {
  final String date; // ISO string
  final String recipeTitle;

  HistoryItem(this.date, this.recipeTitle);

  Map<String, dynamic> toJson() => {'date': date, 'recipeTitle': recipeTitle};
  factory HistoryItem.fromJson(Map<String, dynamic> j) => HistoryItem(j['date'], j['recipeTitle']);
}

// ===================== NOTIFICATIONS =====================
final FlutterLocalNotificationsPlugin _notifier = FlutterLocalNotificationsPlugin();
Future<void> initNotifications() async {
  const AndroidInitializationSettings initAndroid = AndroidInitializationSettings('@mipmap/ic_launcher');
  const InitializationSettings initSettings = InitializationSettings(android: initAndroid);
  await _notifier.initialize(initSettings);

  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'scan_eat_general',
    'ScanEat General',
    description: 'General updates and reminders',
    importance: Importance.defaultImportance,
  );
  await _notifier.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.createNotificationChannel(channel);
}

Future<void> showSimpleNotification(String title, String body) async {
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'scan_eat_general',
    'ScanEat General',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
  );
  const NotificationDetails details = NotificationDetails(android: androidDetails);
  await _notifier.show(0, title, body, details);
}

// ===================== STORAGE (SharedPreferences) =====================
class AppStore {
  static const _kUserName = 'user_full_name';
  static const _kUserEmail = 'user_email';
  static const _kUserPremium = 'user_is_premium';
  static const _kHistory = 'history_items';
  static const _kLoggedIn = 'logged_in';

  static Future<void> saveUser({required String name, required String email}) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kUserName, name);
    await p.setString(_kUserEmail, email);
  }

  static Future<(String?, String?)> getUser() async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_kUserName), p.getString(_kUserEmail));
  }

  static Future<void> setPremium(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kUserPremium, v);
  }

  static Future<bool> get isPremium async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kUserPremium) ?? false;
  }

  static Future<void> addHistory(HistoryItem item) async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_kHistory) ?? <String>[];
    raw.add(jsonEncode(item.toJson()));
    await p.setStringList(_kHistory, raw);
  }

  static Future<List<HistoryItem>> getHistory() async {
    final p = await SharedPreferences.getInstance();
    final raw = p.getStringList(_kHistory) ?? <String>[];
    return raw.map((e) => HistoryItem.fromJson(jsonDecode(e))).toList().reversed.toList();
  }

  static Future<void> setLoggedIn(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kLoggedIn, v);
  }

  static Future<bool> get isLoggedIn async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kLoggedIn) ?? false;
  }
}

// ===================== GEMINI HELPERS =====================
Future<List<RecipeCardModel>> generateRecipesFromImage(File imageFile) async {
  if (AppConfig.geminiApiKey.isEmpty) {
    debugPrint('[AI] Gemini key missing – using fallback recipes with Google images.');
    return await _dummyRecipesWithImages();
  }
  // If the key looks like an OpenRouter key (e.g., 'sk-or-...'), call Gemini via OpenRouter.
  if (AppConfig.geminiApiKey.startsWith('sk-')) {
    try {
      return await _generateWithOpenRouterGemini(imageFile);
    } catch (e) {
      debugPrint('[AI] OpenRouter path failed: $e — falling back to Google Gemini endpoint if possible.');
      // continue to try Google endpoint below
    }
  }
  try {
    final bytes = await imageFile.readAsBytes();
    final b64 = base64Encode(bytes);
    final uri = Uri.parse('https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=${AppConfig.geminiApiKey}');
    final body = {
      'contents': [
        {
          'parts': [
            {
              'text': 'You are a culinary assistant for a Filipino audience. Detect ingredients in the provided image and propose 3 Filipino-friendly recipes that use them. Return strict JSON with schema: {"recipes":[{"title":"...","ingredients":[...],"steps":[...],"nutrition":{"kcal":number,"protein_g":number,"fat_g":number,"carbs_g":number,"sodium_mg":number}}]}. No prose.'
            },
            {
              'inlineData': {
                'mimeType': 'image/jpeg',
                'data': b64,
              }
            }
          ]
        }
      ],
      'generationConfig': {
        'temperature': 0.7,
        'response_mime_type': 'application/json'
      }
    };

    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );

    if (resp.statusCode >= 200 && resp.statusCode < 300) {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final candidates = data['candidates'] as List?;
      if (candidates == null || candidates.isEmpty) {
        return _dummyRecipes();
      }
      final text = candidates[0]['content']['parts'][0]['text'] as String;
      final Map<String, dynamic> parsed = jsonDecode(text);
      final List recs = parsed['recipes'] ?? [];

      final results = <RecipeCardModel>[];
      for (final r in recs) {
        final title = r['title']?.toString() ?? 'Recipe';
        final imageUrl = await fetchFoodImage(title);
        results.add(RecipeCardModel(
          title: title,
          ingredients: (r['ingredients'] as List?)?.map((e) => e.toString()).toList() ?? [],
          steps: (r['steps'] as List?)?.map((e) => e.toString()).toList() ?? [],
          nutrition: r['nutrition'] == null ? null : Map<String, dynamic>.from(r['nutrition']),
          imageUrl: imageUrl,
        ));
      }
      return results.isEmpty ? _dummyRecipes() : results;
    } else {
      debugPrint('Gemini error: ${resp.statusCode} ${resp.body}');
      return await _dummyRecipesWithImages();
    }
  } catch (e) {
    debugPrint('Gemini network error: $e');
    return await _dummyRecipesWithImages();
  }
}

Future<List<RecipeCardModel>> _dummyRecipesWithImages() async {
  final base = _dummyRecipes();
  final out = <RecipeCardModel>[];
  for (final r in base) {
    // Force-unique image selection per run via Unsplash `sig` if CSE fails
    final googleOrUnsplash = await fetchFoodImage(r.title);
    out.add(RecipeCardModel(
      title: r.title,
      ingredients: r.ingredients,
      steps: r.steps,
      nutrition: r.nutrition,
      imageUrl: googleOrUnsplash,
    ));
  }
  return out;
}

Future<String> fetchFoodImage(String query) async {
  try {
    if (AppConfig.googleCseKey.isNotEmpty && AppConfig.googleCseCx.isNotEmpty) {
      final url = Uri.parse('https://www.googleapis.com/customsearch/v1?searchType=image&q=${Uri.encodeQueryComponent('$query food')}&key=${AppConfig.googleCseKey}&cx=${AppConfig.googleCseCx}&num=1');
      final resp = await http.get(url);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final items = data['items'] as List?;
        if (items != null && items.isNotEmpty) {
          return items.first['link'];
        }
      } else {
        debugPrint('[CSE] HTTP ${resp.statusCode}: ${resp.body}');
        return 'https://source.unsplash.com/featured/?${Uri.encodeComponent(query)},food';
      }
    }
    // Fallback to Unsplash Source (no key, rotates images)
    return 'https://source.unsplash.com/featured/?${Uri.encodeComponent(query)},food';
  } catch (_) {
    return 'https://source.unsplash.com/featured/?${Uri.encodeComponent(query)},food';
  }
}

List<RecipeCardModel> _dummyRecipes() => [
  RecipeCardModel(
    title: 'Chicken Adobo',
    ingredients: ['Chicken', 'Garlic', 'Soy Sauce', 'Vinegar', 'Pepper', 'Bay Leaf', 'Oil'],
    steps: [
      'Marinate chicken in soy sauce, vinegar, garlic, pepper, bay leaf (30 mins).',
      'Sauté garlic, brown chicken in oil.',
      'Pour marinade + water, simmer until tender and sauce reduces.'
    ],
    imageUrl: 'https://source.unsplash.com/featured/?adobo,filipino,food&sig=${DateTime.now().millisecondsSinceEpoch}',
    nutrition: {'kcal': 420, 'protein_g': 25, 'fat_g': 20, 'carbs_g': 12, 'sodium_mg': 900},
  ),
  RecipeCardModel(
    title: 'Garlic Chicken Stir-fry',
    ingredients: ['Chicken', 'Garlic', 'Soy Sauce', 'Sugar', 'Oil'],
    steps: ['Slice chicken', 'Stir-fry garlic', 'Add chicken + sauce', 'Toss until glossy'],
    imageUrl: 'https://source.unsplash.com/featured/?garlic%20chicken,food&sig=${DateTime.now().millisecondsSinceEpoch + 1}',
    nutrition: {'kcal': 380, 'protein_g': 28, 'fat_g': 14, 'carbs_g': 18, 'sodium_mg': 800},
  ),
  RecipeCardModel(
    title: 'Tinola',
    ingredients: ['Chicken', 'Ginger', 'Garlic', 'Onion', 'Green Papaya', 'Chili Leaves', 'Fish Sauce'],
    steps: ['Sauté aromatics', 'Add chicken', 'Pour water and simmer', 'Add papaya then leaves'],
    imageUrl: 'https://source.unsplash.com/featured/?tinola,filipino,soup&sig=${DateTime.now().millisecondsSinceEpoch + 2}',
    nutrition: {'kcal': 260, 'protein_g': 26, 'fat_g': 15, 'carbs_g': 2, 'sodium_mg': 900},
  ),
];

// ===================== APP =====================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initNotifications();
  await AppConfig.load();
  runApp(const ScanEatApp());
}

class ScanEatApp extends StatelessWidget {
  const ScanEatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Scan Eat',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green.shade700),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const _Bootstrapper(),
    );
  }
}

// Decides whether to show Auth or Welcome
class _Bootstrapper extends StatefulWidget {
  const _Bootstrapper();
  @override
  State<_Bootstrapper> createState() => _BootstrapperState();
}

class _BootstrapperState extends State<_Bootstrapper> {
  String? _email;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final loggedIn = await AppStore.isLoggedIn;
    if (!loggedIn) {
      setState(() => _email = null);
      return;
    }
    final (_, email) = await AppStore.getUser();
    setState(() => _email = email);
  }

  @override
  Widget build(BuildContext context) {
    if (_email == null) return const AuthPage();
    return const WelcomePage();
  }
}

// ===================== AUTH PAGE =====================
class AuthPage extends StatefulWidget {
  const AuthPage({super.key});
  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_email.text.isEmpty || _password.text.isEmpty || _name.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Please fill all fields')));
      return;
    }
    await AppStore.saveUser(name: _name.text.trim(), email: _email.text.trim());
    await AppStore.setLoggedIn(true);
    if (mounted) Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const WelcomePage()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background image from assets
          Image.asset(
            'assets/images/auth_bg.png',
            fit: BoxFit.cover,
          ),
          Container(color: const Color(0xFF019354).withOpacity(0.35)),

          Center(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.88),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const [
                      BoxShadow(
                        color: Colors.black26,
                        blurRadius: 8,
                        offset: Offset(0, 4),
                      ),
                    ],
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _input('Full Name', 'Enter your Full Name', _name),
                        const SizedBox(height: 12),
                        _input('Email', 'example@gmail.com', _email),
                        const SizedBox(height: 12),
                        _input('Password', 'Enter your Password', _password, obscure: true),
                        const SizedBox(height: 16),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFD6A33A),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                          ),
                          onPressed: _signIn,
                          child: const Text('Sign In', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(height: 16),

                        Row(
                          children: const [
                            Expanded(child: Divider(thickness: 1)),
                            SizedBox(width: 8),
                            Text('Or continue with'),
                            SizedBox (width: 8),
                            Expanded(child: Divider(thickness: 1)),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _socialIcon('assets/icons/facebook.png', Icons.facebook, size: 28),
                            const SizedBox(width: 20),
                            _socialIcon('assets/icons/google.png', Icons.g_mobiledata, size: 34),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _input(String label, String hint, TextEditingController c, {bool obscure = false}) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      TextField(controller: c, obscureText: obscure, decoration: InputDecoration(hintText: hint, border: OutlineInputBorder(borderRadius: BorderRadius.circular(8))))
    ]);
  }

  Widget _socialIcon(String assetPath, IconData fallback, {double size = 28}) {
    return SizedBox(
      width: size + 6,
      height: size + 6,
      child: Image.asset(
        assetPath,
        width: size,
        height: size,
        fit: BoxFit.contain,
        errorBuilder: (_, __, ___) => Icon(fallback, size: size),
      ),
    );
  }
}

// ===================== WELCOME / ONBOARDING =====================
class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF019354),
      body: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final h = c.maxHeight;

          const fw = 393.0;
          const fh = 852.0;
          double sx(double x) => x * (w / fw);
          double sy(double y) => y * (h / fh);

          return Stack(
            children: [

              Positioned(
                left: sx(83),
                top: sy(102),
                child: Container(
                  width: sx(243),
                  height: sy(231),
                  decoration: const BoxDecoration(
                    color: Color(0xFF11FF00),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                left: sx(22),
                top: sy(176),
                child: Container(
                  width: sx(160),
                  height: sy(157),
                  decoration: const BoxDecoration(
                    color: Color(0xFF8CF56A),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                left: sx(246),
                top: sy(60),
                child: Container(
                  width: sx(160),
                  height: sy(157),
                  decoration: const BoxDecoration(
                    color: Color(0xFF219419),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                left: sx(122),
                top: sy(43),
                child: Container(
                  width: sx(61),
                  height: sy(58),
                  decoration: const BoxDecoration(
                    color: Color(0xFF55B535),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
              Positioned(
                left: sx(47),
                top: sy(109),
                child: Container(
                  width: sx(61),
                  height: sy(58),
                  decoration: const BoxDecoration(
                    color: Color(0xFF48F010),
                    shape: BoxShape.circle,
                  ),
                ),
              ),

              Positioned(
                left: sx(-18),
                top: sy(72),
                child: SizedBox(
                  width: sx(421),
                  height: sy(421),
                  child: Image.asset(
                    'assets/images/welcome_phone.png',
                    fit: BoxFit.cover,
                  ),
                ),
              ),

              Positioned(
                left: sx(-74),
                top: sy(347),
                child: Container(
                  width: sx(541),
                  height: sy(483),
                  color: Colors.white,
                ),
              ),
              Positioned(
                left: sx(-14),
                top: sy(489),
                child: Container(
                  width: sx(419),
                  height: sy(426),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x3F000000),
                        blurRadius: 4,
                        offset: Offset(0, 4),
                      )
                    ],
                    borderRadius: BorderRadius.circular(0),
                  ),
                ),
              ),

              // Title + description
              Positioned(
                left: sx(37),
                top: sy(493),
                child: SizedBox(
                  width: sx(335),
                  child: Text(
                    'Welcome to Scan Eat!\n\nThis quick guide will show you how to easily scan your food and discover delicious recipes. ',
                    style: const TextStyle(
                      color: Color(0xFF019354),
                      fontSize: 24,
                      fontWeight: FontWeight.w400,
                      height: 1.25,
                    ),
                  ),
                ),
              ),

              // SKIP & NEXT buttons (exact size/position from Figma; still responsive via scaling)
              Positioned(
                left: sx(33),
                top: sy(725),
                child: Container(
                  width: sx(152),
                  height: sy(56),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD9D9D9),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const HomePage()),
                    ),
                    child: const Text('SKIP', style: TextStyle(color: Colors.black, fontSize: 20)),
                  ),
                ),
              ),
              Positioned(
                left: sx(204),
                top: sy(725),
                child: Container(
                  width: sx(152),
                  height: sy(56),
                  decoration: BoxDecoration(
                    color: const Color(0xFF55B535),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pushReplacement(
                      MaterialPageRoute(builder: (_) => const HomePage()),
                    ),
                    child: const Text('NEXT', style: TextStyle(color: Colors.white, fontSize: 20)),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ===================== HOME =====================
class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  List<RecipeCardModel> cards = [];
  File? lastImage;

  @override
  void initState() {
    super.initState();
    showSimpleNotification('New recipe ideas are ready for you!', 'Open the app to explore.');
  }

  Future<void> _openCamera() async {
    final picker = ImagePicker();
    final x = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
    if (x != null) {
      setState(() => lastImage = File(x.path));
      // Navigate to scan page
      if (!mounted) return;
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => ScanPage(image: File(x.path), onGenerate: (list) {
        setState(() => cards = list);
      })));
    }
  }

  void _openHistory() async {
    final history = await AppStore.getHistory();
    showModalBottomSheet(context: context, builder: (_) => _HistorySheet(history: history));
  }

  void _openAccount() async {
    final (name, email) = await AppStore.getUser();
    final isPremium = await AppStore.isPremium;
    showModalBottomSheet(context: context, builder: (_) => _AccountSheet(name: name ?? '-', email: email ?? '-', isPremium: isPremium));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Background image (tries .png then falls back to .jpg)
          Image.asset(
            'assets/images/background_image_page.png',
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Image.asset(
              'assets/images/background_image_page.jpg',
              fit: BoxFit.cover,
            ),
          ),
          // Green tint overlay to match the mock hue
          Container(color: const Color(0xFF019354).withOpacity(0.28)),

          // Foreground content
          SafeArea(
            child: Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: 150,
                  child: IgnorePointer(
                    child: Container(
                      decoration: const BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [Colors.white, Colors.transparent],
                        ),
                      ),
                    ),
                  ),
                ),

                // MAIN CONTENT
                ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  children: [
                    // Header (menu + bell) and title/subtitle
                    Row(
                      children: [
                        IconButton(onPressed: _openHistory, icon: const Icon(Icons.menu), color: Colors.white),
                        const Spacer(),
                        IconButton(onPressed: _openAccount, icon: const Icon(Icons.notifications_active_rounded), color: const Color(0xFFD6A33A)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      'Scan Here',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontStyle: FontStyle.italic,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.3,
                        height: 1.2,
                        shadows: [Shadow(color: Colors.black26, blurRadius: 2, offset: Offset(0, 1))],
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Padding(
                      padding: EdgeInsets.only(right: 8.0),
                      child: Text(
                        'Make sure ingredients are clearly visible.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.white, fontSize: 14.0),
                      ),
                    ),
                    const SizedBox(height: 16),

                    Container(
                      margin: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFE0AD3A), width: 12),
                      ),
                      padding: const EdgeInsets.all(8),
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: AspectRatio(
                          aspectRatio: 334 / 425,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: lastImage != null
                                ? Image.file(lastImage!, fit: BoxFit.cover)
                                : Image.asset('assets/images/auth_bg.png', fit: BoxFit.cover),
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(height: 18),
                    const Text(
                      "Can't scan? No worries! Just enter your ingredients here.",
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w400),
                    ),

                    if (cards.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 320,
                        child: ListView.separated(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemCount: cards.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 12),
                          itemBuilder: (_, i) => _RecipeCard(card: cards[i]),
                        ),
                      ),
                    ],

                    const SizedBox(height: 110), // space for the floating bottom bar
                  ],
                ),

                // BOTTOM ACTION BAR (rounded white with three actions)
                Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                    child: Container(
                      height: 88,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: const [
                          BoxShadow(color: Color(0x33000000), blurRadius: 8, offset: Offset(0, 4)),
                        ],
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            onPressed: _openHistory,
                            icon: const Icon(Icons.file_download_outlined),
                            color: const Color(0xFF019354),
                            iconSize: 30,
                          ),
                          // big camera button with gradient, rim, and shadow
                          Transform.translate(
                            offset: const Offset(0, -8),
                            child: SizedBox(
                              width: 82,
                              height: 82,
                              child: Stack(
                                alignment: Alignment.center,
                                children: [
                                  // Soft drop shadow
                                  Container(
                                    width: 76,
                                    height: 76,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      boxShadow: [
                                        BoxShadow(color: Color(0x55000000), blurRadius: 14, offset: Offset(0, 6)),
                                      ],
                                    ),
                                  ),
                                  // Gradient button
                                  Container(
                                    width: 76,
                                    height: 76,
                                    decoration: const BoxDecoration(
                                      shape: BoxShape.circle,
                                      gradient: LinearGradient(
                                        begin: Alignment.topCenter,
                                        end: Alignment.bottomCenter,
                                        colors: [Color(0xFF3E8D3E), Color(0xFF2E7030)],
                                      ),
                                    ),
                                  ),
                                  // Subtle white rim
                                  Container(
                                    width: 76,
                                    height: 76,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      border: Border.all(color: Colors.white.withOpacity(0.28), width: 2),
                                    ),
                                  ),
                                  // Camera icon
                                  IconButton(
                                    onPressed: _openCamera,
                                    icon: const Icon(Icons.photo_camera),
                                    color: Colors.white,
                                    iconSize: 30,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          IconButton(
                            onPressed: _openAccount,
                            icon: _UtensilsStarIcon(),
                            color: const Color(0xFF019354),
                            iconSize: 30,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RecipeCard extends StatelessWidget {
  final RecipeCardModel card;
  const _RecipeCard({required this.card});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 260,
      decoration: BoxDecoration(color: const Color(0xFFE9B956), borderRadius: BorderRadius.circular(18)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 10.0),
          child: Column(children: [
            Text(card.title.toUpperCase(), textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
          ]),
        ),
        Expanded(
          child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                card.imageUrl.isNotEmpty
                    ? card.imageUrl
                    : 'https://source.unsplash.com/featured/?${Uri.encodeComponent(card.title)},food',
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: Colors.black12,
                  alignment: Alignment.center,
                  child: const Icon(Icons.image_not_supported, color: Colors.black45),
                ),
              )
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.all(12.0),
          child: ElevatedButton(onPressed: () {
            Navigator.of(context).push(MaterialPageRoute(builder: (_) => RecipePage(card: card)));
          }, child: const Text('View Recipe')),
        )
      ]),
    );
  }
}

// ===================== SCAN PAGE =====================
class ScanPage extends StatefulWidget {
  final File image;
  final void Function(List<RecipeCardModel>) onGenerate;
  const ScanPage({super.key, required this.image, required this.onGenerate});
  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
  bool loading = false;

  Future<void> _generate() async {
    setState(() => loading = true);
    try {
      final cards = await generateRecipesFromImage(widget.image);
      widget.onGenerate(cards);
      if (mounted) Navigator.of(context).pop();
      await showSimpleNotification('New recipes are ready!', 'Tap to see suggestions.');
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Here')),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF0ba360), Color(0xFF3cba92)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        ),
        child: SafeArea(
          child: Column(children: [
            const SizedBox(height: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Container(
                  decoration: BoxDecoration(border: Border.all(color: const Color(0xFFE9B956), width: 6), borderRadius: BorderRadius.circular(8)),
                  child: ClipRRect(borderRadius: BorderRadius.circular(2), child: Image.file(widget.image, fit: BoxFit.cover)),
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.only(bottom: 8.0),
              child: Text("Make sure ingredients are clearly visible.", style: TextStyle(color: Colors.white)),
            ),
            Padding(
              padding: const EdgeInsets.all(16.0),
              child: ElevatedButton.icon(onPressed: loading ? null : _generate, icon: const Icon(Icons.auto_awesome), label: Text(loading ? 'Generating...' : 'Generate Recipes')),
            )
          ]),
        ),
      ),
    );
  }
}

// ===================== RECIPE PAGE =====================
class RecipePage extends StatelessWidget {
  final RecipeCardModel card;
  const RecipePage({super.key, required this.card});

  Future<void> _markDone() async {
    await AppStore.addHistory(HistoryItem(DateTime.now().toIso8601String(), card.title));
    await showSimpleNotification('Recipe saved', 'Added ${card.title} to history.');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context)), title: Text(card.title.toUpperCase())),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(colors: [Color(0xFF0ba360), Color(0xFF3cba92)], begin: Alignment.topCenter, end: Alignment.bottomCenter),
        ),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _glassPanel(title: 'Ingredients', child: Text(card.ingredients.join('\n')))),
                const SizedBox(width: 12),
                Expanded(child: _glassPanel(title: 'Instruction', child: Text(card.steps.asMap().entries.map((e) => '${e.key + 1}. ${e.value}').join('\n\n')))),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: _glassPanel(
                    title: 'Nutrition',
                    child: Text(card.nutrition == null
                        ? '—'
                        : 'Calories: ~${card.nutrition!['kcal']} kcal\nProtein: ~${card.nutrition!['protein_g']}g\nFat: ~${card.nutrition!['fat_g']}g\nCarbohydrates: ~${card.nutrition!['carbs_g']}g\nSodium: ~${card.nutrition!['sodium_mg']}mg'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.network(card.imageUrl, height: 140, fit: BoxFit.cover))),
              ]),
              const SizedBox(height: 16),
              ElevatedButton.icon(onPressed: _markDone, icon: const Icon(Icons.check_circle_outline), label: const Text('Mark as Done')),
            ],
          ),
        ),
      ),
    );
  }

  Widget _glassPanel({required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(12), border: Border.all(color: Colors.white24)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        const SizedBox(height: 8),
        DefaultTextStyle(style: const TextStyle(color: Colors.white), child: child),
      ]),
    );
  }
}

// ===================== SHEETS =====================
class _HistorySheet extends StatelessWidget {
  final List<HistoryItem> history;
  const _HistorySheet({required this.history});
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Saved History', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          const SizedBox(height: 12),
          if (history.isEmpty) const Text('No history yet.') else ...history.map((h) => ListTile(leading: const Icon(Icons.history), title: Text(h.recipeTitle), subtitle: Text(h.date.substring(0, 10)))).toList(),
        ]),
      ),
    );
  }
}

class _AccountSheet extends StatefulWidget {
  final String name;
  final String email;
  final bool isPremium;
  const _AccountSheet({required this.name, required this.email, required this.isPremium});
  @override
  State<_AccountSheet> createState() => _AccountSheetState();
}

class _AccountSheetState extends State<_AccountSheet> {
  bool busy = false;

  Future<void> _upgrade() async {
    setState(() => busy = true);
    await Future.delayed(const Duration(seconds: 1));
    await AppStore.setPremium(true);
    if (mounted) setState(() => busy = false);
    await showSimpleNotification('Premium Unlocked', 'Meal Planner and more features enabled!');
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.name, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          Text(widget.email),
          const SizedBox(height: 12),
          Row(children: [
            Chip(label: Text(widget.isPremium ? 'Premium' : 'Free')),
            const SizedBox(width: 8),
            if (!widget.isPremium)
              ElevatedButton(onPressed: busy ? null : _upgrade, child: Text(busy ? 'Processing...' : 'Upgrade to Premium')),
          ]),
          const SizedBox(height: 10),
          TextButton.icon(onPressed: () => launchUrl(Uri.parse('https://gcash.com')), icon: const Icon(Icons.payment), label: const Text('Pay with GCash / PayPal / Card (demo)')),
          const SizedBox(height: 6),
          ElevatedButton.icon(
            onPressed: () async {
              final sp = await SharedPreferences.getInstance();
              await sp.clear();
              await AppStore.setLoggedIn(false);
              if (context.mounted) {
                Navigator.of(context).pushAndRemoveUntil(
                  MaterialPageRoute(builder: (_) => const AuthPage()),
                      (_) => false,
                );
              }
            },
            icon: const Icon(Icons.logout),
            label: const Text('Log out'),
          ),
        ]),
      ),
    );
  }
}

Widget _UtensilsStarIcon() {
  return SizedBox(
    width: 30,
    height: 30,
    child: Stack(
      clipBehavior: Clip.none,
      children: const [
        Positioned.fill(child: Icon(Icons.restaurant_outlined, color: Color(0xFF019354), size: 30)),
        Positioned(right: -2, top: -2, child: Icon(Icons.star, color: Color(0xFFE0AD3A), size: 12)),
      ],
    ),
  );
}

// Uses OpenRouter (OpenAI-compatible) endpoint to call a Gemini model
Future<List<RecipeCardModel>> _generateWithOpenRouterGemini(File imageFile) async {
  // Uses OpenRouter (OpenAI-compatible) endpoint to call a Gemini model
  final bytes = await imageFile.readAsBytes();
  final b64 = base64Encode(bytes);
  final dataUrl = 'data:image/jpeg;base64,$b64';

  final uri = Uri.parse('https://openrouter.ai/api/v1/chat/completions');
  final messages = [
    {
      'role': 'system',
      'content':
          'You are a culinary assistant for a Filipino audience. Detect ingredients in the provided image and propose 3 Filipino-friendly recipes that use them. Return strict JSON with schema: {"recipes":[{"title":"...","ingredients":[...],"steps":[...],"nutrition":{"kcal":number,"protein_g":number,"fat_g":number,"carbs_g":number,"sodium_mg":number}}]}. No prose.'
    },
    {
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Analyze this image and produce recipes.'},
        {'type': 'image_url', 'image_url': {'url': dataUrl}},
      ]
    }
  ];

  final resp = await http.post(
    uri,
    headers: {
      'Authorization': 'Bearer ${AppConfig.geminiApiKey}',
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://github.com/scanet/app',
      'X-Title': 'Scan Eat (Flutter)',
    },
    body: jsonEncode({
      // Pick a Gemini model available on OpenRouter
      'model': 'google/gemini-2.0-flash-001',
      'messages': messages,
      'temperature': 0.7,
      'response_format': {'type': 'json_object'},
    }),
  );

  if (resp.statusCode >= 200 && resp.statusCode < 300) {
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final content = data['choices'][0]['message']['content'];
    final Map<String, dynamic> parsed = jsonDecode(content);
    final List recs = parsed['recipes'] ?? [];

    final results = <RecipeCardModel>[];
    for (final r in recs) {
      final title = r['title']?.toString() ?? 'Recipe';
      final imageUrl = await fetchFoodImage(title);
      results.add(RecipeCardModel(
        title: title,
        ingredients: (r['ingredients'] as List?)?.map((e) => e.toString()).toList() ?? [],
        steps: (r['steps'] as List?)?.map((e) => e.toString()).toList() ?? [],
        nutrition: r['nutrition'] == null ? null : Map<String, dynamic>.from(r['nutrition']),
        imageUrl: imageUrl,
      ));
    }
    return results.isEmpty ? _dummyRecipes() : results;
  } else {
    debugPrint('[OpenRouter] HTTP ${resp.statusCode}: ${resp.body}');
    return _dummyRecipes();
  }
}
