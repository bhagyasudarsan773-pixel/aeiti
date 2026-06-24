import 'dart:ui';
import 'dart:async';
import 'dart:convert'; // Required for JSON encoding/decoding
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // REQUIRED: Added for Clipboard support
import 'package:google_fonts/google_fonts.dart'; // REQUIRED: Google Fonts package
import 'package:shared_preferences/shared_preferences.dart'; // REQUIRED: Added SharedPreferences import
import 'package:flutter/foundation.dart'
    show kIsWeb; // Needed to check for FlutLab Web environment
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart'
    as http; // REQUIRED: For making REST API requests to Gemini

// IMPORTANT: Paste your OpenRouter API Key here (reversed string)
const String _hardcodedGeminiApiKey = 'PASTE_YOUR_KEY_HERE';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (kIsWeb) {
    // IMPORTANT: Replace these placeholders with your actual Web Config Keys from your Firebase Console.
    // Go to: Firebase Console -> Project Settings -> General -> Under "Your apps", select the Web app (create one if needed).
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: "AIzaSyDqd94T8-y0dluWcr0kMfWIxSR-3G3Rl5c",
        authDomain: "tide-ai-33348.firebaseapp.com",
        projectId: "tide-ai-33348",
        storageBucket: "tide-ai-33348.firebasestorage.app",
        messagingSenderId: "44808813180",
        appId: "1:44808813180:web:1732dee1cd83ddacd067f9",
      ),
    );
  } else {
    // Standard initialization for native Android/iOS
    await Firebase.initializeApp();
  }

  runApp(const TideApp());
}

// ----------------------------------------------------------------------
// CHATBOT MESSAGE MODEL
// ----------------------------------------------------------------------
class ChatMessage {
  final String text;
  final bool isUser;
  final DateTime timestamp;

  ChatMessage({
    required this.text,
    required this.isUser,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();
}

// ----------------------------------------------------------------------
// STATE MANAGEMENT & MODELS
// ----------------------------------------------------------------------
class Task {
  final String id;
  final String title;
  final String category;
  final String priority;
  bool isCompleted;
  final DateTime date;
  final DateTime? dueDate; // Added dueDate support

  Task({
    required this.title,
    required this.category,
    required this.priority,
    this.isCompleted = false,
    String? id,
    DateTime? date,
    this.dueDate,
  })  : id = id ?? '',
        date = date ?? DateTime.now();

  // Used for priority dot
  Color get dotColor {
    if (isCompleted) return Colors.transparent;
    switch (priority) {
      case 'High':
        return Colors.redAccent;
      case 'Medium':
        return Colors.orange;
      case 'Low':
        return appState.primaryColor;
      default:
        return Colors.teal;
    }
  }

  // Used for Color-Coded Category Chips (+200 XP requirement)
  Color get categoryColor {
    switch (category) {
      case 'Work':
        return Colors.blueAccent;
      case 'Personal':
        return Colors.green;
      case 'Study':
        return Colors.purpleAccent;
      case 'Health':
        return Colors.redAccent;
      case 'Finance':
        return Colors.amber;
      default:
        return appState.primaryColor;
    }
  }

  // Convert Task to JSON for Firestore
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'category': category,
      'priority': priority,
      'isCompleted': isCompleted,
      'date': date.toIso8601String(),
      'dueDate': dueDate?.toIso8601String(),
    };
  }

  // Create Task from Firestore Document
  factory Task.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>? ?? {};
    return Task(
      title: data['title'] ?? '',
      category: data['category'] ?? 'Work',
      priority: data['priority'] ?? 'Medium',
      isCompleted: data['isCompleted'] ?? false,
      id: doc.id,
      date: data['date'] != null ? DateTime.parse(data['date']) : null,
      dueDate: data['dueDate'] != null ? DateTime.parse(data['dueDate']) : null,
    );
  }
}

class AppState extends ChangeNotifier {
  bool isDarkMode = false;
  String userName = 'Sarah';
  String profilePicUrl =
      'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200&auto=format&fit=crop&q=60';
  List<Task> tasks = [];
  bool isLoading = true;

  // Tide AI Assistant state properties
  String geminiApiKey = '';
  List<ChatMessage> chatMessages = [];
  bool isChatLoading = false;

  // Guest & Offline Mode Support
  bool isGuestMode = false;

  User? _currentUser;
  StreamSubscription<User?>? _authSubscription;
  StreamSubscription<QuerySnapshot>? _tasksSubscription;
  StreamSubscription<DocumentSnapshot>? _userDocSubscription;

  // Helper method to decode the reversed key at runtime
  String _getDecodedKey(String reversedKey) {
    if (reversedKey == 'PASTE_YOUR_KEY_HERE') return '';
    return String.fromCharCodes(reversedKey.codeUnits.reversed);
  }

  AppState() {
    _initAuth();
    if (_hardcodedGeminiApiKey != 'PASTE_YOUR_KEY_HERE') {
      geminiApiKey = _getDecodedKey(_hardcodedGeminiApiKey.trim());
    } else {
      _loadApiKey();
    }
  }

  // Load API key from SharedPreferences
  Future<void> _loadApiKey() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      geminiApiKey = prefs.getString('geminiApiKey') ?? '';
      notifyListeners();
    } catch (e) {
      // Quietly fail
    }
  }

  // Update and persist API key
  Future<void> updateApiKey(String key) async {
    geminiApiKey = key.trim();
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('geminiApiKey', geminiApiKey);
    } catch (e) {
      // Quietly fail
    }
  }

  // Enable Guest Mode & Load local tasks
  Future<void> enableGuestMode() async {
    isGuestMode = true;
    _cancelSubscriptions();

    try {
      final prefs = await SharedPreferences.getInstance();
      userName = prefs.getString('guest_userName') ?? 'Sarah (Guest)';
      profilePicUrl = prefs.getString('guest_profilePicUrl') ??
          'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200&auto=format&fit=crop&q=60';
      isDarkMode = prefs.getBool('guest_isDarkMode') ?? false;
    } catch (e) {
      userName = 'Sarah (Guest)';
      profilePicUrl =
          'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200&auto=format&fit=crop&q=60';
      isDarkMode = false;
    }

    chatMessages = [];
    await _loadLocalTasks();
  }

  // Load guest/offline tasks locally
  Future<void> _loadLocalTasks() async {
    isLoading = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final String? tasksJson = prefs.getString('local_tasks');
      if (tasksJson != null) {
        final List<dynamic> decoded = jsonDecode(tasksJson);
        tasks = decoded.map((item) {
          return Task(
            title: item['title'] ?? '',
            category: item['category'] ?? 'Work',
            priority: item['priority'] ?? 'Medium',
            isCompleted: item['isCompleted'] ?? false,
            id: item['id'] ?? DateTime.now().millisecondsSinceEpoch.toString(),
            date: item['date'] != null
                ? DateTime.parse(item['date'])
                : DateTime.now(),
            dueDate: item['dueDate'] != null
                ? DateTime.parse(item['dueDate'])
                : null,
          );
        }).toList();
      } else {
        // Create default tasks if empty
        tasks = [
          Task(
            id: 'default-1',
            title: 'Explore Tide App features',
            category: 'Work',
            priority: 'High',
            isCompleted: false,
            date: DateTime.now(),
            dueDate: DateTime.now().add(const Duration(days: 1)),
          ),
          Task(
            id: 'default-2',
            title: 'Configure my Gemini API Key',
            category: 'Study',
            priority: 'Medium',
            isCompleted: false,
            date: DateTime.now(),
            dueDate: DateTime.now().add(const Duration(days: 2)),
          ),
          Task(
            id: 'default-3',
            title: 'Take a mindful walking break',
            category: 'Health',
            priority: 'Low',
            isCompleted: true,
            date: DateTime.now(),
          ),
        ];
        await _saveLocalTasks();
      }
    } catch (e) {
      debugPrint("Error loading local tasks: $e");
    }
    isLoading = false;
    notifyListeners();
  }

  // Save guest/offline tasks locally
  Future<void> _saveLocalTasks() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final List<Map<String, dynamic>> encoded = tasks
          .map((t) => {
                'id': t.id,
                'title': t.title,
                'category': t.category,
                'priority': t.priority,
                'isCompleted': t.isCompleted,
                'date': t.date.toIso8601String(),
                'dueDate': t.dueDate?.toIso8601String(),
              })
          .toList();
      await prefs.setString('local_tasks', jsonEncode(encoded));
    } catch (e) {
      debugPrint("Error saving local tasks: $e");
    }
  }

  // Guest Logout
  Future<void> logout() async {
    isGuestMode = false;
    _cancelSubscriptions();
    tasks = [];
    chatMessages = [];
    userName = 'Guest';
    profilePicUrl =
        'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200&auto=format&fit=crop&q=60';
    isDarkMode = false;
    isLoading = false;
    try {
      await FirebaseAuth.instance.signOut();
    } catch (e) {
      // Quietly fail
    }
    notifyListeners();
  }

  // Set up authentication state listener
  void _initAuth() {
    try {
      _authSubscription =
          FirebaseAuth.instance.authStateChanges().listen((user) {
        _currentUser = user;
        if (user != null) {
          isGuestMode = false;
          _listenToUserData(user.uid);
          _listenToTasks(user.uid);
        } else {
          if (!isGuestMode) {
            _cancelSubscriptions();
            tasks = [];
            chatMessages = []; // Reset chat thread on logout
            userName = 'Guest';
            profilePicUrl =
                'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200&auto=format&fit=crop&q=60';
            isDarkMode = false;
            isLoading = false;
            notifyListeners();
          }
        }
      }, onError: (e) {
        debugPrint("FirebaseAuth state listener error: $e");
      });
    } catch (e) {
      debugPrint("Firebase Auth unavailable: $e");
      isLoading = false;
      notifyListeners();
    }
  }

  // Listen to Firestore for user profile information (real-time)
  void _listenToUserData(String uid) {
    try {
      _userDocSubscription?.cancel();
      _userDocSubscription = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .snapshots()
          .listen((doc) {
        if (doc.exists) {
          final data = doc.data() ?? {};
          userName = data['userName'] ?? 'Sarah';
          profilePicUrl = data['profilePicUrl'] ??
              'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200&auto=format&fit=crop&q=60';
          isDarkMode = data['isDarkMode'] ?? false;
          notifyListeners();
        }
      });
    } catch (e) {
      debugPrint("Error listening to user data: $e");
    }
  }

  // Listen to Firestore for user tasks (real-time)
  void _listenToTasks(String uid) {
    isLoading = true;
    notifyListeners();

    try {
      _tasksSubscription?.cancel();
      _tasksSubscription = FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('tasks')
          .orderBy('date', descending: true)
          .snapshots()
          .listen((snapshot) {
        tasks = snapshot.docs.map((doc) => Task.fromFirestore(doc)).toList();
        isLoading = false;
        notifyListeners();
      }, onError: (e) {
        isLoading = false;
        notifyListeners();
      });
    } catch (e) {
      debugPrint("Error listening to tasks: $e");
      isLoading = false;
      notifyListeners();
    }
  }

  void _cancelSubscriptions() {
    _tasksSubscription?.cancel();
    _userDocSubscription?.cancel();
  }

  @override
  void dispose() {
    _authSubscription?.cancel();
    _cancelSubscriptions();
    super.dispose();
  }

  // Seeding initial profile for new accounts
  Future<void> createNewUserRecord(String uid, String name) async {
    await FirebaseFirestore.instance.collection('users').doc(uid).set({
      'userName': name,
      'profilePicUrl':
          'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200&auto=format&fit=crop&q=60',
      'isDarkMode': false,
    });
  }

  // Theme Styling Properties
  Color get primaryColor => isDarkMode
      ? const Color(0xFF4DB6AC)
      : const Color(0xFF006B5F); // Figma Palette (+100 XP)
  Color get textColor => isDarkMode ? Colors.white : Colors.black87;
  Color get subTextColor => isDarkMode ? Colors.white60 : Colors.black54;
  Color get cardColor => isDarkMode
      ? Colors.black.withOpacity(0.4)
      : Colors.white.withOpacity(0.4);
  String get bgImage => isDarkMode
      ? 'https://images.unsplash.com/photo-1505142468610-359e7d316be0?auto=format&fit=crop&w=800&q=80'
      : 'https://images.unsplash.com/photo-1507525428034-b723cf961d3e?auto=format&fit=crop&w=800&q=80';

  int get ongoingCount => tasks.where((t) => !t.isCompleted).length;
  int get finishedCount => tasks.where((t) => t.isCompleted).length;
  double get completionPercentage =>
      tasks.isEmpty ? 0 : (finishedCount / tasks.length);

  // Firestore Database Operations
  Future<void> addTask(String title, String priority, DateTime? dueDate) async {
    String category = 'Personal'; // Default fallback
    if (geminiApiKey.isNotEmpty) {
      category = await _categorizeTaskWithAI(title);
    } else {
      category = _categorizeTaskLocally(title);
    }

    if (isGuestMode || _currentUser == null) {
      final newTask = Task(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        title: title,
        priority: priority,
        category: category,
        isCompleted: false,
        date: DateTime.now(),
        dueDate: dueDate,
      );
      tasks.insert(0, newTask);
      await _saveLocalTasks();
      notifyListeners();
      return;
    }

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .collection('tasks')
          .add({
        'title': title,
        'priority': priority,
        'category': category,
        'isCompleted': false,
        'date': DateTime.now().toIso8601String(),
        'dueDate': dueDate?.toIso8601String(),
      });
    } catch (e) {
      debugPrint("Error adding task to Firestore: $e");
    }
  }

  // AI Task Categorization Helper
  Future<String> _categorizeTaskWithAI(String title) async {
    try {
      final url = Uri.parse('https://openrouter.ai/api/v1/chat/completions');
      final prompt =
          "Categorize the task title: \"$title\" into exactly one of these categories: Work, Personal, Study, Health, Finance. Respond with ONLY the category name. Do not include any punctuation, formatting, or extra words.";

      final body = jsonEncode({
        'model': 'openrouter/free',
        'messages': [
          {'role': 'user', 'content': prompt}
        ]
      });

      final response = await http.post(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $geminiApiKey',
        },
        body: body,
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final text = data['choices'][0]['message']['content'] as String;
        final cleanText = text.trim();
        final allowedCategories = [
          'Work',
          'Personal',
          'Study',
          'Health',
          'Finance'
        ];
        for (var cat in allowedCategories) {
          if (cleanText.toLowerCase().contains(cat.toLowerCase())) {
            return cat;
          }
        }
      }
    } catch (e) {
      debugPrint("AI categorization error: $e");
    }
    return _categorizeTaskLocally(title);
  }

  String _categorizeTaskLocally(String title) {
    final t = title.toLowerCase();
    if (t.contains('work') ||
        t.contains('office') ||
        t.contains('meeting') ||
        t.contains('project') ||
        t.contains('boss') ||
        t.contains('client') ||
        t.contains('presentation') ||
        t.contains('interview')) {
      return 'Work';
    } else if (t.contains('study') ||
        t.contains('homework') ||
        t.contains('exam') ||
        t.contains('class') ||
        t.contains('learn') ||
        t.contains('course') ||
        t.contains('read') ||
        t.contains('math') ||
        t.contains('assignment')) {
      return 'Study';
    } else if (t.contains('gym') ||
        t.contains('workout') ||
        t.contains('health') ||
        t.contains('doctor') ||
        t.contains('med') ||
        t.contains('run') ||
        t.contains('exercise') ||
        t.contains('sleep') ||
        t.contains('dentist') ||
        t.contains('hospital')) {
      return 'Health';
    } else if (t.contains('pay') ||
        t.contains('finance') ||
        t.contains('bank') ||
        t.contains('buy') ||
        t.contains('bill') ||
        t.contains('rent') ||
        t.contains('tax') ||
        t.contains('money') ||
        t.contains('credit') ||
        t.contains('subscription') ||
        t.contains('shopping')) {
      return 'Finance';
    }
    return 'Personal';
  }

  // AI Semantic Search State Variables
  bool isSemanticSearchLoading = false;
  bool isSemanticSearchActive = false;
  List<String>? semanticSearchResultIds;

  Future<void> performSemanticSearch(String query) async {
    if (query.trim().isEmpty) {
      clearSemanticSearch();
      return;
    }

    isSemanticSearchActive = true;
    isSemanticSearchLoading = true;
    notifyListeners();

    if (geminiApiKey.isEmpty || tasks.isEmpty) {
      _performLocalSemanticSearch(query);
      isSemanticSearchLoading = false;
      notifyListeners();
      return;
    }

    try {
      try {
        final url = Uri.parse('https://openrouter.ai/api/v1/chat/completions');

        final tasksJson = tasks
            .map((t) => {
                  'id': t.id,
                  'title': t.title,
                  'category': t.category,
                  'priority': t.priority,
                  'dueDate': t.dueDate?.toIso8601String(),
                  'isCompleted': t.isCompleted,
                })
            .toList();

        final prompt =
            "You are a semantic search engine for the Tide task manager app.\n"
            "The user is searching for tasks with the query: \"$query\".\n"
            "Here is the user's task list in JSON format:\n"
            "${jsonEncode(tasksJson)}\n\n"
            "Filter and rank the tasks by relevance to the query. For example, if they ask 'What do I need to do this weekend?', find tasks that are due on the weekend or have weekend-related titles.\n"
            "Return ONLY a JSON list of matching task IDs (strings) in order of relevance, for example: [\"id1\", \"id2\"]. "
            "Do not return any other text, code blocks, or explanations. If no tasks are relevant, return [].";

        final body = jsonEncode({
          'model': 'openrouter/free',
          'messages': [
            {'role': 'user', 'content': prompt}
          ]
        });

        final response = await http.post(
          url,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $geminiApiKey',
          },
          body: body,
        );

        if (response.statusCode == 200) {
          final data = jsonDecode(response.body);
          String text = data['choices'][0]['message']['content'] as String;
          text = text.replaceAll('```json', '').replaceAll('```', '').trim();
          final List<dynamic> decoded = jsonDecode(text);
          semanticSearchResultIds = decoded.map((e) => e.toString()).toList();
        } else {
          debugPrint(
              "OpenRouter semantic search error: ${response.statusCode} ${response.body}");
          _performLocalSemanticSearch(query);
        }
      } catch (e) {
        debugPrint("Semantic search exception: $e");
        _performLocalSemanticSearch(query);
      }
    } finally {
      isSemanticSearchLoading = false;
      notifyListeners();
    }
  }

  // Local rule-based fallback search engine
  void _performLocalSemanticSearch(String query) {
    final cleanQuery = query.toLowerCase();

    bool wantsWeekend = cleanQuery.contains('weekend');
    bool wantsToday =
        cleanQuery.contains('today') || cleanQuery.contains('now');

    final matchedTasks = tasks.where((t) {
      final title = t.title.toLowerCase();
      final category = t.category.toLowerCase();

      // Keyword matches
      if (title.contains(cleanQuery) || category.contains(cleanQuery)) {
        return true;
      }

      // Pseudo-semantic fallback
      if (wantsWeekend) {
        if (t.dueDate != null) {
          final weekday = t.dueDate!.weekday;
          return weekday == DateTime.saturday || weekday == DateTime.sunday;
        }
      }
      if (wantsToday) {
        if (t.dueDate != null) {
          final today = DateTime.now();
          return t.dueDate!.year == today.year &&
              t.dueDate!.month == today.month &&
              t.dueDate!.day == today.day;
        }
      }
      return false;
    }).toList();

    semanticSearchResultIds = matchedTasks.map((t) => t.id).toList();
  }

  void clearSemanticSearch() {
    semanticSearchResultIds = null;
    isSemanticSearchActive = false;
    isSemanticSearchLoading = false;
    notifyListeners();
  }

  void restoreTask(String id, Map<String, dynamic> taskData) async {
    if (isGuestMode || _currentUser == null) {
      final restored = Task(
        id: id,
        title: taskData['title'] ?? '',
        priority: taskData['priority'] ?? 'Medium',
        category: taskData['category'] ?? 'Personal',
        isCompleted: taskData['isCompleted'] ?? false,
        date: taskData['date'] != null
            ? DateTime.parse(taskData['date'])
            : DateTime.now(),
        dueDate: taskData['dueDate'] != null
            ? DateTime.parse(taskData['dueDate'])
            : null,
      );
      tasks.insert(0, restored);
      await _saveLocalTasks();
      notifyListeners();
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .collection('tasks')
          .doc(id)
          .set(taskData);
    } catch (e) {
      debugPrint("Error restoring task in Firestore: $e");
    }
  }

  void toggleTask(String id) async {
    if (isGuestMode || _currentUser == null) {
      final taskIndex = tasks.indexWhere((t) => t.id == id);
      if (taskIndex != -1) {
        tasks[taskIndex].isCompleted = !tasks[taskIndex].isCompleted;
        await _saveLocalTasks();
        notifyListeners();
      }
      return;
    }
    final taskIndex = tasks.indexWhere((t) => t.id == id);
    if (taskIndex != -1) {
      final task = tasks[taskIndex];
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(_currentUser!.uid)
            .collection('tasks')
            .doc(id)
            .update({'isCompleted': !task.isCompleted});
      } catch (e) {
        debugPrint("Error toggling task in Firestore: $e");
      }
    }
  }

  void deleteTask(String id) async {
    if (isGuestMode || _currentUser == null) {
      tasks.removeWhere((t) => t.id == id);
      await _saveLocalTasks();
      notifyListeners();
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .collection('tasks')
          .doc(id)
          .delete();
    } catch (e) {
      debugPrint("Error deleting task in Firestore: $e");
    }
  }

  Future<void> updateUserName(String name) async {
    userName = name;
    notifyListeners();
    if (isGuestMode || _currentUser == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('guest_userName', userName);
      } catch (e) {
        // Quietly fail
      }
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .update({'userName': userName});
    } catch (e) {
      debugPrint("Error updating username in Firestore: $e");
    }
  }

  Future<void> updateProfilePic(String url) async {
    profilePicUrl = url;
    notifyListeners();
    if (isGuestMode || _currentUser == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('guest_profilePicUrl', profilePicUrl);
      } catch (e) {
        // Quietly fail
      }
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .update({'profilePicUrl': profilePicUrl});
    } catch (e) {
      debugPrint("Error updating profile picture in Firestore: $e");
    }
  }

  Future<void> toggleTheme() async {
    isDarkMode = !isDarkMode;
    notifyListeners();
    if (isGuestMode || _currentUser == null) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool('guest_isDarkMode', isDarkMode);
      } catch (e) {
        // Quietly fail
      }
      return;
    }
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(_currentUser!.uid)
          .update({'isDarkMode': isDarkMode});
    } catch (e) {
      debugPrint("Error updating theme in Firestore: $e");
    }
  }

  // ----------------------------------------------------------------------
  // CHATBOT SEND MESSAGE & PROCESSING LOGIC
  // ----------------------------------------------------------------------
  Future<void> sendChatMessage(String text) async {
    if (text.trim().isEmpty) return;

    chatMessages.add(ChatMessage(text: text, isUser: true));
    isChatLoading = true;
    notifyListeners();

    try {
      String responseText;
      if (geminiApiKey.isEmpty) {
        responseText = _localFallbackQuery(text);
      } else {
        responseText = await _queryGemini(text);
        // Fallback to offline assistant if Gemini is overloaded (503) or rate limited (429)
        if (responseText.contains("Gemini API Error (Status 503)") ||
            responseText.contains("Gemini API Error (Status 429)")) {
          responseText = _localFallbackQuery(text);
        }
      }
      chatMessages.add(ChatMessage(text: responseText, isUser: false));
    } catch (e) {
      // Fallback on exception
      chatMessages
          .add(ChatMessage(text: _localFallbackQuery(text), isUser: false));
    } finally {
      isChatLoading = false;
      notifyListeners();
    }
  }

  // Local static response generator for out-of-the-box offline utility
  String _localFallbackQuery(String query) {
    final q = query.toLowerCase();

    // 1. Most overdue task query handling
    if (q.contains('overdue')) {
      final now = DateTime.now();
      final overdueTasks = tasks.where((t) {
        if (t.isCompleted || t.dueDate == null) return false;
        return t.dueDate!.isBefore(now);
      }).toList();

      if (overdueTasks.isEmpty) {
        return "🎉 Great news! You have no overdue tasks right now.";
      }

      // Sort by due date (oldest first) to find the most overdue task
      overdueTasks.sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
      final mostOverdue = overdueTasks.first;
      final diff = now.difference(mostOverdue.dueDate!);
      final days = diff.inDays;
      final hours = diff.inHours % 24;

      String timeAgo = "";
      if (days > 0) {
        timeAgo = "$days day(s) and $hours hour(s)";
      } else {
        timeAgo = "$hours hour(s)";
      }

      return "🚨 Your most overdue task is:\n\n"
          "**[${mostOverdue.category}] ${mostOverdue.title}**\n"
          "• Priority: ${mostOverdue.priority}\n"
          "• Due: ${mostOverdue.dueDate!.toLocal()}\n"
          "• Overdue by: $timeAgo\n\n"
          "Try to tackle this first!";
    }

    // 2. Summarize this week query handling
    if (q.contains('week') &&
        (q.contains('summarize') ||
            q.contains('summary') ||
            q.contains('tasks') ||
            q.contains('this'))) {
      final now = DateTime.now();
      final startOfWeek = now.subtract(Duration(days: now.weekday - 1));
      final endOfWeek = startOfWeek.add(const Duration(days: 7));

      final weekTasks = tasks.where((t) {
        if (t.dueDate == null) return false;
        return t.dueDate!.isAfter(startOfWeek) &&
            t.dueDate!.isBefore(endOfWeek);
      }).toList();

      if (weekTasks.isEmpty) {
        return "You have no tasks scheduled for this week.";
      }

      final completedCount = weekTasks.where((t) => t.isCompleted).length;
      final pendingCount = weekTasks.where((t) => !t.isCompleted).length;
      final taskLines = weekTasks.map((t) {
        final statusSymbol = t.isCompleted ? "✅" : "⏳";
        return "$statusSymbol [${t.category}] ${t.title} (Due: ${t.dueDate!.day}/${t.dueDate!.month})";
      }).join("\n");

      return "📅 **Weekly Summary**\n"
          "• Total Tasks: ${weekTasks.length}\n"
          "• Completed: $completedCount\n"
          "• Pending: $pendingCount\n\n"
          "**Scheduled Tasks:**\n$taskLines";
    }

    // 3. Suggest tasks for project query handling
    if (q.contains('suggest') ||
        q.contains('project') ||
        q.contains('recommend')) {
      return "💡 Here are some suggested tasks to boost your project organization:\n\n"
          "1. 📋 **Define Project Scope & Deliverables**: Break down the overall objective into clear milestones.\n"
          "2. 🗓️ **Create Timeline & Set Deadlines**: Establish a schedule with clear due dates.\n"
          "3. 🤝 **Identify Key Resources**: List any tools, documentation, or contacts you will need.\n"
          "4. 🔍 **Conduct First Review Checkpoint**: Schedule a session to evaluate initial progress.";
    }

    if (q.contains('hello') || q.contains('hi') || q.contains('hey')) {
      return "Hello $userName! I am Tide AI, your local productivity assistant. 🌊\n\n"
          "I am running in local mode to keep your data completely private and secure on your device. "
          "I can still analyze your tasks! Try asking me:\n"
          "• *'what is my most overdue task'* or *'what is overdue?'*\n"
          "• *'summarize this week'* or *'list my tasks'*\n"
          "• *'suggest tasks for my project'*\n"
          "• *'how many tasks left'* or *'how many are completed?'*";
    }

    if (q.contains('how many') &&
        (q.contains('done') ||
            q.contains('completed') ||
            q.contains('finished'))) {
      return "You have completed **$finishedCount** tasks! That's ${(completionPercentage * 100).toInt()}% of your total workload. Keep riding the wave!";
    }

    if (q.contains('how many') &&
        (q.contains('left') ||
            q.contains('pending') ||
            q.contains('ongoing') ||
            q.contains('remaining'))) {
      return "You have **$ongoingCount** pending tasks left to finish today.";
    }

    if (q.contains('how many') && q.contains('tasks')) {
      return "You have a total of **${tasks.length}** tasks in your stream (**$ongoingCount** ongoing, **$finishedCount** finished).";
    }

    if (q.contains('high') && q.contains('priority')) {
      final highTasks =
          tasks.where((t) => t.priority == 'High' && !t.isCompleted).toList();
      if (highTasks.isEmpty) {
        return "Good news! You have no pending High priority tasks right now.";
      }
      final taskList =
          highTasks.map((t) => "- [${t.category}] ${t.title}").join("\n");
      return "Here are your pending High priority tasks:\n$taskList";
    }

    if (q.contains('what tasks') ||
        q.contains('list tasks') ||
        q.contains('my tasks') ||
        q.contains('summarize')) {
      if (tasks.isEmpty) {
        return "Your task stream is empty! Click the '+' button to add some tasks.";
      }

      List<Task> filteredList = tasks;
      String categoryPrefix = "";

      if (q.contains('work')) {
        filteredList = tasks.where((t) => t.category == 'Work').toList();
        categoryPrefix = "Work ";
      } else if (q.contains('personal')) {
        filteredList = tasks.where((t) => t.category == 'Personal').toList();
        categoryPrefix = "Personal ";
      } else if (q.contains('study')) {
        filteredList = tasks.where((t) => t.category == 'Study').toList();
        categoryPrefix = "Study ";
      } else if (q.contains('health')) {
        filteredList = tasks.where((t) => t.category == 'Health').toList();
        categoryPrefix = "Health ";
      } else if (q.contains('finance')) {
        filteredList = tasks.where((t) => t.category == 'Finance').toList();
        categoryPrefix = "Finance ";
      }

      if (filteredList.isEmpty) {
        return "You have no tasks in the ${categoryPrefix.trim()} category.";
      }

      final taskList = filteredList
          .map((t) =>
              "- ${t.isCompleted ? '✓' : '•'} [${t.category}] ${t.title} (${t.priority} Priority)")
          .join("\n");
      return "Here is your ${categoryPrefix}task summary:\n$taskList";
    }

    return "I'm Tide AI, your local productivity assistant! 🌊\n\n"
        "I can help you analyze your tasks without sending any data online. Try asking me:\n"
        "• *'what is my most overdue task'* or *'what is overdue?'*\n"
        "• *'summarize this week'* or *'list my tasks'*\n"
        "• *'suggest tasks for my project'*\n"
        "• *'how many tasks left'* or *'how many are completed?'*\n"
        "• *'high priority'* to see critical tasks.";
  }

  // Diagnostically retrieve all models available to this specific API key
  Future<List<String>> listAvailableModels() async {
    return ['openrouter/free'];
  }

  // REST API connection client for OpenRouter
  Future<String> _queryGemini(String userQuery) async {
    final url = Uri.parse('https://openrouter.ai/api/v1/chat/completions');

    final tasksText = tasks.isEmpty
        ? "No tasks currently."
        : tasks
            .map((t) =>
                "- [${t.category}] ${t.title} (${t.priority} Priority, ${t.isCompleted ? 'Completed' : 'Pending'}${t.dueDate != null ? ', due: ${t.dueDate!.toIso8601String()}' : ''})")
            .join("\n");

    final systemInstructionText =
        "You are Tide AI, a helpful, encouraging productivity assistant for the Tide task manager app.\n"
        "Below are the user's current tasks in the app. Use this list to answer the user's questions about their tasks, schedule, priorities, or categories.\n"
        "Make sure to address the following user questions specifically if asked:\n"
        "- 'What's my most overdue task?': Find incomplete tasks with a due date in the past, and identify the one that is furthest in the past.\n"
        "- 'Summarize this week': Provide a summary of tasks due this week, completed tasks, and pending tasks.\n"
        "- 'Suggest tasks for my project': Suggest 3-5 relevant, actionable tasks that the user can add to their task list.\n\n"
        "Be concise, friendly, and structured. Use bullet points or markdown where appropriate. Use emojis where relevant.\n\n"
        "User's Name: $userName\n"
        "Current Time: ${DateTime.now().toLocal()}\n\n"
        "Current Tasks:\n$tasksText";

    List<Map<String, dynamic>> messages = [];
    messages.add({
      "role": "system",
      "content": systemInstructionText
    });

    for (var msg in chatMessages) {
      final role = msg.isUser ? "user" : "assistant";
      messages.add({
        "role": role,
        "content": msg.text
      });
    }

    final body = jsonEncode({
      "model": "openrouter/free",
      "messages": messages,
    });

    final response = await http.post(
      url,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $geminiApiKey',
      },
      body: body,
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      try {
        final text = data['choices'][0]['message']['content'] as String;
        return text.trim();
      } catch (e) {
        return "Received an unexpected response format from the OpenRouter server.";
      }
    } else {
      final errorData = jsonDecode(response.body);
      String errorMsg = errorData['error']?['message'] ?? 'Unknown API Error';

      return "OpenRouter API Error (Status ${response.statusCode}): $errorMsg";
    }
  }
}

final AppState appState = AppState();

// ----------------------------------------------------------------------
// APP SHELL (Google Fonts Theme)
// ----------------------------------------------------------------------
class TideApp extends StatelessWidget {
  const TideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, child) {
          final textTheme = appState.isDarkMode
              ? GoogleFonts.poppinsTextTheme(ThemeData.dark().textTheme)
              : GoogleFonts.poppinsTextTheme(ThemeData.light().textTheme);

          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'Tide',
            theme: ThemeData(
              textTheme: textTheme,
              brightness:
                  appState.isDarkMode ? Brightness.dark : Brightness.light,
              colorScheme: ColorScheme.fromSeed(
                seedColor: appState.primaryColor,
                brightness:
                    appState.isDarkMode ? Brightness.dark : Brightness.light,
              ),
            ),
            home: _getHomeRoute(),
          );
        });
  }

  Widget _getHomeRoute() {
    final Uri currentUri = Uri.base;
    final String? ownerId = currentUri.queryParameters['ownerId'];
    final String? shareId = currentUri.queryParameters['shareId'];
    if (ownerId != null && shareId != null) {
      return SharedTasksScreen(ownerId: ownerId, shareId: shareId);
    }
    return const TideAppHomeWrapper();
  }
}

// ----------------------------------------------------------------------
// SHARED WIDGETS
// ----------------------------------------------------------------------
class GlassCard extends StatelessWidget {
  final Widget child;
  final double padding;

  const GlassCard({super.key, required this.child, this.padding = 20.0});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          return ClipRRect(
            borderRadius: BorderRadius.circular(24.0),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
              child: Container(
                padding: EdgeInsets.all(padding),
                decoration: BoxDecoration(
                  color: appState.cardColor,
                  borderRadius: BorderRadius.circular(24.0),
                  border: Border.all(color: Colors.white.withOpacity(0.3)),
                ),
                child: child,
              ),
            ),
          );
        });
  }
}

class BackgroundWrapper extends StatelessWidget {
  final Widget child;
  const BackgroundWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) => Container(
              decoration: BoxDecoration(
                  image: DecorationImage(
                      image: NetworkImage(appState.bgImage),
                      fit: BoxFit.cover)),
              child: child,
            ));
  }
}

class TopBar extends StatelessWidget {
  final String? title;
  const TopBar({super.key, this.title});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  CircleAvatar(
                      radius: 16,
                      backgroundImage: NetworkImage(appState.profilePicUrl)),
                  if (title != null) ...[
                    const SizedBox(width: 12),
                    Text(title!,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: appState.primaryColor))
                  ],
                ],
              ),
              Row(
                children: [
                  // Sparkling auto_awesome button to launch the AI chatbot panel
                  IconButton(
                    icon: ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [Colors.purpleAccent, Colors.blueAccent],
                      ).createShader(bounds),
                      child:
                          const Icon(Icons.auto_awesome, color: Colors.white),
                    ),
                    onPressed: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (context) => const AIChatSheet(),
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  Icon(Icons.notifications_none, color: appState.primaryColor),
                ],
              ),
            ],
          );
        });
  }
}

Widget buildDismissibleTask(BuildContext context, Task task) {
  return Dismissible(
    key: Key(task.id),
    direction: DismissDirection.endToStart,
    background: Container(
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20.0),
      margin: const EdgeInsets.only(bottom: 12.0),
      decoration: BoxDecoration(
        color: Colors.redAccent.withOpacity(0.8),
        borderRadius: BorderRadius.circular(24.0),
      ),
      child: const Icon(Icons.delete, color: Colors.white),
    ),
    onDismissed: (direction) {
      final taskData = task.toJson();
      final taskId = task.id;
      appState.deleteTask(taskId);
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Deleted "${task.title}"'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              appState.restoreTask(taskId, taskData);
            },
          ),
        ),
      );
    },
    child: TaskListItem(task: task),
  );
}

// ----------------------------------------------------------------------
// 1. SPLASH / LOGIN & SIGN UP SCREEN
// ----------------------------------------------------------------------
class SplashLoginScreen extends StatefulWidget {
  const SplashLoginScreen({super.key});

  @override
  State<SplashLoginScreen> createState() => _SplashLoginScreenState();
}

class _SplashLoginScreenState extends State<SplashLoginScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isSignUpMode = false; // Toggles Sign In vs Sign Up forms
  bool _isLoading = false; // Local loader during API interaction

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submitAuth() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();
    final name = _nameController.text.trim();

    if (email.isEmpty || password.isEmpty || (_isSignUpMode && name.isEmpty)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Please fill out all fields.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
      return;
    }

    setState(() => _isLoading = true);

    try {
      if (_isSignUpMode) {
        // Sign Up Flow
        final UserCredential cred = await FirebaseAuth.instance
            .createUserWithEmailAndPassword(email: email, password: password);

        if (cred.user != null) {
          await cred.user!.updateDisplayName(name);
          await appState.createNewUserRecord(cred.user!.uid, name);
        }
      } else {
        // Sign In Flow
        await FirebaseAuth.instance
            .signInWithEmailAndPassword(email: email, password: password);
      }
    } on FirebaseAuthException catch (e) {
      String errorMessage;
      switch (e.code) {
        case 'email-already-in-use':
          errorMessage =
              'This email address is already registered. Please sign in instead.';
          break;
        case 'weak-password':
          errorMessage =
              'The password is too weak. Please use at least 6 characters.';
          break;
        case 'invalid-email':
          errorMessage = 'Please enter a valid email address.';
          break;
        case 'user-not-found':
          errorMessage = 'No account found with this email. Please sign up!';
          break;
        case 'wrong-password':
          errorMessage = 'Incorrect password. Please try again.';
          break;
        case 'user-disabled':
          errorMessage = 'This user account has been disabled.';
          break;
        case 'operation-not-allowed':
          errorMessage =
              'Email/Password accounts are disabled in your Firebase console.';
          break;
        default:
          errorMessage =
              '[${e.code}]: ${e.message ?? "An error occurred during authentication."}';
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error: ${e.toString()}'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: BackgroundWrapper(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: AnimatedBuilder(
                  animation: appState,
                  builder: (context, _) {
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                              color: appState.cardColor,
                              borderRadius: BorderRadius.circular(16)),
                          child: Icon(Icons.waves,
                              color: appState.primaryColor, size: 40),
                        ),
                        const SizedBox(height: 10),
                        Text('Tide',
                            style: TextStyle(
                                fontSize: 32,
                                fontWeight: FontWeight.bold,
                                color: appState.primaryColor,
                                letterSpacing: 1.5)),
                        const SizedBox(height: 30),
                        GlassCard(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                  _isSignUpMode
                                      ? 'Create Account'
                                      : 'Welcome Back',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.bold,
                                      color: appState.primaryColor)),
                              const SizedBox(height: 8),
                              Text(
                                  _isSignUpMode
                                      ? 'Sign up to start tracking your waves'
                                      : 'Sign in to access your dashboard',
                                  textAlign: TextAlign.center,
                                  style: TextStyle(color: appState.textColor)),
                              const SizedBox(height: 24),

                              // Username Input Field (Only in Sign Up Mode)
                              if (_isSignUpMode) ...[
                                TextField(
                                  controller: _nameController,
                                  style: TextStyle(color: appState.textColor),
                                  decoration: InputDecoration(
                                      filled: true,
                                      fillColor: appState.cardColor,
                                      hintText: 'Username',
                                      hintStyle: TextStyle(
                                          color: appState.subTextColor),
                                      prefixIcon: Icon(Icons.person_outline,
                                          color: appState.subTextColor),
                                      border: OutlineInputBorder(
                                          borderRadius:
                                              BorderRadius.circular(12),
                                          borderSide: BorderSide.none)),
                                ),
                                const SizedBox(height: 16),
                              ],

                              // Email Input Field
                              TextField(
                                controller: _emailController,
                                keyboardType: TextInputType.emailAddress,
                                style: TextStyle(color: appState.textColor),
                                decoration: InputDecoration(
                                    filled: true,
                                    fillColor: appState.cardColor,
                                    hintText: 'Email Address',
                                    hintStyle:
                                        TextStyle(color: appState.subTextColor),
                                    prefixIcon: Icon(Icons.email_outlined,
                                        color: appState.subTextColor),
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide.none)),
                              ),
                              const SizedBox(height: 16),

                              // Password Input Field
                              TextField(
                                controller: _passwordController,
                                obscureText: true,
                                style: TextStyle(color: appState.textColor),
                                decoration: InputDecoration(
                                    filled: true,
                                    fillColor: appState.cardColor,
                                    hintText: 'Password',
                                    hintStyle:
                                        TextStyle(color: appState.subTextColor),
                                    prefixIcon: Icon(Icons.lock_outline,
                                        color: appState.subTextColor),
                                    border: OutlineInputBorder(
                                        borderRadius: BorderRadius.circular(12),
                                        borderSide: BorderSide.none)),
                              ),

                              if (!_isSignUpMode)
                                Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton(
                                        onPressed: () {
                                          final email =
                                              _emailController.text.trim();
                                          if (email.isEmpty) {
                                            ScaffoldMessenger.of(context)
                                                .showSnackBar(
                                              const SnackBar(
                                                content: Text(
                                                    'Please enter your email to reset password.'),
                                                backgroundColor:
                                                    Colors.redAccent,
                                                behavior:
                                                    SnackBarBehavior.floating,
                                              ),
                                            );
                                            return;
                                          }
                                          FirebaseAuth.instance
                                              .sendPasswordResetEmail(
                                                  email: email);
                                          ScaffoldMessenger.of(context)
                                              .showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                  'Password reset email sent to $email'),
                                              backgroundColor:
                                                  appState.primaryColor,
                                              behavior:
                                                  SnackBarBehavior.floating,
                                            ),
                                          );
                                        },
                                        child: Text('Forgot Password?',
                                            style: TextStyle(
                                                color:
                                                    appState.primaryColor)))),
                              const SizedBox(height: 16),

                              ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                    backgroundColor: appState.primaryColor,
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 16),
                                    shape: RoundedRectangleBorder(
                                        borderRadius:
                                            BorderRadius.circular(12))),
                                onPressed: _isLoading ? null : _submitAuth,
                                child: _isLoading
                                    ? const SizedBox(
                                        height: 20,
                                        width: 20,
                                        child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            color: Colors.white),
                                      )
                                    : Row(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                            Text(
                                                _isSignUpMode
                                                    ? 'Sign Up'
                                                    : 'Sign In',
                                                style: const TextStyle(
                                                    fontSize: 16)),
                                            const SizedBox(width: 8),
                                            const Icon(Icons.arrow_forward,
                                                size: 20)
                                          ]),
                              ),
                              const SizedBox(height: 20),

                              // Mode Switch Toggle Button
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _isSignUpMode = !_isSignUpMode;
                                    _nameController.clear();
                                    _passwordController.clear();
                                  });
                                },
                                child: Text(
                                  _isSignUpMode
                                      ? 'Already have an account? Sign In'
                                      : "Don't have an account? Sign Up",
                                  style: TextStyle(
                                      color: appState.primaryColor,
                                      fontWeight: FontWeight.bold),
                                ),
                              ),
                              const SizedBox(height: 10),

                              // Guest Mode Bypass Button
                              OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  side: BorderSide(
                                      color: appState.primaryColor
                                          .withOpacity(0.5)),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 16),
                                  shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12)),
                                ),
                                onPressed: () {
                                  appState.enableGuestMode();
                                },
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.person_outline,
                                        color: appState.primaryColor, size: 20),
                                    const SizedBox(width: 8),
                                    Text('Continue as Guest (Offline Mode)',
                                        style: TextStyle(
                                            color: appState.primaryColor,
                                            fontSize: 14,
                                            fontWeight: FontWeight.bold)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    );
                  }),
            ),
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 2. MAIN DASHBOARD
// ----------------------------------------------------------------------
class MainDashboard extends StatefulWidget {
  const MainDashboard({super.key});

  @override
  State<MainDashboard> createState() => _MainDashboardState();
}

class _MainDashboardState extends State<MainDashboard> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const HomeScreen(),
    const TaskStreamScreen(),
    const CalendarScreen(),
    const FocusScreen(),
    const ProfileScreen(),
  ];

  void _showAddTaskModal() {
    showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (context) => const AddTaskModal());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          return Scaffold(
            extendBody: true,
            body: BackgroundWrapper(child: _screens[_currentIndex]),
            floatingActionButton: _currentIndex != 3
                ? FloatingActionButton(
                    backgroundColor: appState.primaryColor,
                    onPressed: _showAddTaskModal,
                    child: const Icon(Icons.add, color: Colors.white))
                : null,
            bottomNavigationBar: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(30),
                  boxShadow: [
                    BoxShadow(
                        color: Colors.black.withOpacity(0.1),
                        blurRadius: 20,
                        offset: const Offset(0, 10))
                  ]),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20.0, sigmaY: 20.0),
                  child: BottomNavigationBar(
                    currentIndex: _currentIndex,
                    onTap: (index) => setState(() => _currentIndex = index),
                    backgroundColor: appState.isDarkMode
                        ? Colors.black.withOpacity(0.6)
                        : Colors.white.withOpacity(0.7),
                    type: BottomNavigationBarType.fixed,
                    selectedItemColor: appState.primaryColor,
                    unselectedItemColor: appState.subTextColor,
                    showSelectedLabels: true,
                    showUnselectedLabels: true,
                    selectedFontSize: 10,
                    unselectedFontSize: 10,
                    elevation: 0,
                    items: const [
                      BottomNavigationBarItem(
                          icon: Icon(Icons.home_filled), label: 'Home'),
                      BottomNavigationBarItem(
                          icon: Icon(Icons.list_alt), label: 'Tasks'),
                      BottomNavigationBarItem(
                          icon: Icon(Icons.calendar_today), label: 'Calendar'),
                      BottomNavigationBarItem(
                          icon: Icon(Icons.timelapse), label: 'Focus'),
                      BottomNavigationBarItem(
                          icon: Icon(Icons.person_outline), label: 'Profile'),
                    ],
                  ),
                ),
              ),
            ),
          );
        });
  }
}

// ----------------------------------------------------------------------
// 3. HOME SCREEN
// ----------------------------------------------------------------------
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 10),
                  const TopBar(),
                  const SizedBox(height: 24),
                  Text('Good afternoon, ${appState.userName}',
                      style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: appState.primaryColor)),
                  Text('The tide is with you today.',
                      style:
                          TextStyle(fontSize: 14, color: appState.textColor)),
                  const SizedBox(height: 24),
                  Row(
                    children: [
                      Expanded(
                          child: StatCard(
                              number: '${appState.ongoingCount}',
                              label: 'Ongoing')),
                      const SizedBox(width: 12),
                      Expanded(
                          child: StatCard(
                              number: '${appState.finishedCount}',
                              label: 'Finished')),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                            color: appState.cardColor,
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: appState.primaryColor, width: 3)),
                        child: Text(
                            '${(appState.completionPercentage * 100).toInt()}%',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                                color: appState.textColor)),
                      )
                    ],
                  ),
                  const SizedBox(height: 32),
                  Text("Today's Waves",
                      style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                          color: appState.primaryColor)),
                  const SizedBox(height: 16),
                  Expanded(
                    child: appState.isLoading
                        ? Center(
                            child: CircularProgressIndicator(
                                color: appState.primaryColor))
                        : appState.tasks.isEmpty
                            ? Center(
                                child: Text("No tasks! You're caught up.",
                                    style:
                                        TextStyle(color: appState.textColor)))
                            : ListView.builder(
                                itemCount: appState.tasks.length,
                                itemBuilder: (context, index) =>
                                    buildDismissibleTask(
                                        context, appState.tasks[index])),
                  ),
                ],
              ),
            ),
          );
        });
  }
}

class StatCard extends StatelessWidget {
  final String number;
  final String label;
  const StatCard({super.key, required this.number, required this.label});

  @override
  Widget build(BuildContext context) {
    return GlassCard(
      padding: 16,
      child: Column(
        children: [
          Text(number,
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: appState.primaryColor)),
          Text(label, style: TextStyle(fontSize: 12, color: appState.textColor))
        ],
      ),
    );
  }
}

class TaskListItem extends StatelessWidget {
  final Task task;
  const TaskListItem({super.key, required this.task});

  bool _isOverdue(Task task) {
    if (task.isCompleted) return false;
    if (task.dueDate == null) return false;
    return task.dueDate!.isBefore(DateTime.now());
  }

  String _formatListDateTime(DateTime dt) {
    final List<String> months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec"
    ];
    return "${months[dt.month - 1]} ${dt.day}, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          final overdue = _isOverdue(task);
          return Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: GlassCard(
              padding: 16,
              child: InkWell(
                onTap: () => appState.toggleTask(task.id),
                child: Row(
                  children: [
                    Icon(
                        task.isCompleted
                            ? Icons.check_circle
                            : Icons.circle_outlined,
                        color: task.isCompleted
                            ? appState.primaryColor
                            : (overdue
                                ? Colors.redAccent
                                : appState.subTextColor)),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(task.title,
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  decoration: task.isCompleted
                                      ? TextDecoration.lineThrough
                                      : null,
                                  color: task.isCompleted
                                      ? appState.subTextColor
                                      : appState.textColor)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 2),
                                decoration: BoxDecoration(
                                    color: task.categoryColor.withOpacity(0.2),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                        color: task.categoryColor
                                            .withOpacity(0.5))),
                                child: Text(task.category,
                                    style: TextStyle(
                                        fontSize: 10,
                                        fontWeight: FontWeight.bold,
                                        color: task.categoryColor)),
                              ),
                              Text('${task.priority} Priority',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: appState.subTextColor)),
                              if (task.dueDate != null) ...[
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.access_time,
                                        size: 12,
                                        color: overdue
                                            ? Colors.redAccent
                                            : appState.subTextColor),
                                    const SizedBox(width: 4),
                                    Text(
                                      _formatListDateTime(task.dueDate!),
                                      style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: overdue
                                              ? FontWeight.bold
                                              : FontWeight.normal,
                                          color: overdue
                                              ? Colors.redAccent
                                              : appState.subTextColor),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (!task.isCompleted) ...[
                      Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color:
                                  overdue ? Colors.redAccent : task.dotColor)),
                      const SizedBox(width: 12),
                    ],
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 20),
                      color: Colors.redAccent.withOpacity(0.7),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () {
                        final taskData = task.toJson();
                        final taskId = task.id;
                        appState.deleteTask(taskId);
                        ScaffoldMessenger.of(context).clearSnackBars();
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('Deleted "${task.title}"'),
                            behavior: SnackBarBehavior.floating,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12)),
                            action: SnackBarAction(
                              label: 'Undo',
                              onPressed: () {
                                appState.restoreTask(taskId, taskData);
                              },
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          );
        });
  }
}

// ----------------------------------------------------------------------
// 4. TASK STREAM SCREEN (Filters by Category & Search Matching)
// ----------------------------------------------------------------------
class TaskStreamScreen extends StatefulWidget {
  const TaskStreamScreen({super.key});

  @override
  State<TaskStreamScreen> createState() => _TaskStreamScreenState();
}

class _TaskStreamScreenState extends State<TaskStreamScreen> {
  String selectedFilter = 'All Tasks';
  String searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _shareCurrentList(BuildContext context) async {
    final ownerId = FirebaseAuth.instance.currentUser?.uid;
    if (ownerId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please sign in to share your tasks.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    // Show progress dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      final shareDocRef = FirebaseFirestore.instance
          .collection('users')
          .doc(ownerId)
          .collection('shared_lists')
          .doc(); // Generates auto-ID

      final shareId = shareDocRef.id;

      // Copy metadata
      await shareDocRef.set({
        'title': "${appState.userName}'s $selectedFilter Stream",
        'ownerName': appState.userName,
        'createdAt': DateTime.now().toIso8601String(),
      });

      // Copy tasks
      final List<Task> tasksToShare = appState.tasks.where((t) {
        if (selectedFilter == 'All Tasks') return true;
        return t.category == selectedFilter;
      }).toList();

      final tasksCollection = shareDocRef.collection('tasks');
      final batch = FirebaseFirestore.instance.batch();
      for (var task in tasksToShare) {
        final docRef = tasksCollection.doc();
        batch.set(docRef, task.toJson());
      }
      await batch.commit();

      // Dismiss loading indicator
      Navigator.pop(context);

      // Generate link preserving subpaths for FlutLab Web sandbox routing
      final Uri currentUri = Uri.base;
      final Uri shareUri = currentUri.replace(
        queryParameters: {
          'ownerId': ownerId,
          'shareId': shareId,
        },
      );
      final String shareUrl = shareUri.toString();

      bool copySuccessful = true;
      try {
        // Copy to clipboard
        await Clipboard.setData(ClipboardData(text: shareUrl));
      } catch (e) {
        copySuccessful = false;
        debugPrint("Clipboard write blocked: ${e.toString()}");
      }

      // Show success dialog
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor:
              appState.isDarkMode ? Colors.grey[900] : Colors.white,
          title: Row(
            children: [
              Icon(
                copySuccessful ? Icons.check_circle_outline : Icons.link,
                color: appState.primaryColor,
              ),
              const SizedBox(width: 10),
              Text(
                copySuccessful ? 'Link Copied!' : 'Shareable Link',
                style: TextStyle(color: appState.textColor),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copySuccessful
                    ? 'A read-only link of your "$selectedFilter" tasks has been copied to your clipboard. Share it with anyone!'
                    : 'We could not copy the link automatically due to browser sandbox restrictions. Please copy the link manually from the box below:',
                style: TextStyle(color: appState.textColor),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                width: double.infinity,
                decoration: BoxDecoration(
                  color: appState.cardColor,
                  borderRadius: BorderRadius.circular(12),
                  border:
                      Border.all(color: appState.primaryColor.withOpacity(0.2)),
                ),
                child: SelectableText(
                  shareUrl,
                  style: TextStyle(
                    fontSize: 12,
                    color: appState.primaryColor,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text('Close',
                  style: TextStyle(
                      color: appState.primaryColor,
                      fontWeight: FontWeight.bold)),
            ),
          ],
        ),
      );
    } catch (e) {
      // Dismiss loading
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to share list: ${e.toString()}'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          var filteredTasks = appState.tasks;
          if (appState.isSemanticSearchActive &&
              appState.semanticSearchResultIds != null) {
            final ids = appState.semanticSearchResultIds!;
            filteredTasks = ids
                .map((id) {
                  final matches = appState.tasks.where((t) => t.id == id);
                  return matches.isNotEmpty ? matches.first : null;
                })
                .whereType<Task>()
                .toList();
          } else {
            if (selectedFilter != 'All Tasks') {
              filteredTasks = appState.tasks
                  .where((t) => t.category == selectedFilter)
                  .toList();
            }

            if (searchQuery.isNotEmpty) {
              filteredTasks = filteredTasks
                  .where((t) =>
                      t.title.toLowerCase().contains(searchQuery.toLowerCase()))
                  .toList();
            }
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  const TopBar(title: 'Tasks'),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        selectedFilter,
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: appState.primaryColor),
                      ),
                      ElevatedButton.icon(
                        onPressed: () => _shareCurrentList(context),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: appState.primaryColor,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(20),
                          ),
                        ),
                        icon: const Icon(Icons.share, size: 14),
                        label: const Text('Share Stream',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _searchController,
                    onChanged: (val) {
                      setState(() {
                        searchQuery = val;
                      });
                      if (appState.isSemanticSearchActive) {
                        // Clear active search if input becomes empty
                        if (val.isEmpty) {
                          appState.clearSemanticSearch();
                        }
                      }
                    },
                    onSubmitted: (val) {
                      if (val.isNotEmpty) {
                        appState.performSemanticSearch(val);
                      }
                    },
                    style: TextStyle(color: appState.textColor),
                    decoration: InputDecoration(
                      hintText: appState.isSemanticSearchActive
                          ? 'Semantic search with AI...'
                          : 'Search tasks...',
                      hintStyle: TextStyle(color: appState.subTextColor),
                      prefixIcon: Icon(
                        appState.isSemanticSearchActive
                            ? Icons.auto_awesome
                            : Icons.search,
                        color: appState.primaryColor,
                      ),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (searchQuery.isNotEmpty)
                            IconButton(
                              icon: Icon(Icons.clear,
                                  color: appState.subTextColor),
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  searchQuery = '';
                                });
                                appState.clearSemanticSearch();
                              },
                            ),
                          IconButton(
                            icon: ShaderMask(
                              shaderCallback: (bounds) => LinearGradient(
                                colors: appState.isSemanticSearchActive
                                    ? [Colors.purpleAccent, Colors.blueAccent]
                                    : [
                                        appState.subTextColor.withOpacity(0.5),
                                        appState.subTextColor.withOpacity(0.5)
                                      ],
                              ).createShader(bounds),
                              child: const Icon(
                                Icons.auto_awesome,
                                color: Colors.white,
                              ),
                            ),
                            tooltip: 'AI Semantic Search',
                            onPressed: () {
                              if (appState.isSemanticSearchActive) {
                                appState.clearSemanticSearch();
                              } else {
                                if (searchQuery.isNotEmpty) {
                                  appState.performSemanticSearch(searchQuery);
                                } else {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                          'Type a query to search semantically (e.g. "What do I need to do this weekend?")'),
                                      behavior: SnackBarBehavior.floating,
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                        ],
                      ),
                      filled: true,
                      fillColor: appState.cardColor,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(16),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _buildFilterChip('All Tasks', Colors.white),
                        _buildFilterChip('Work', Colors.blueAccent),
                        _buildFilterChip('Personal', Colors.green),
                        _buildFilterChip('Study', Colors.purpleAccent),
                        _buildFilterChip('Health', Colors.redAccent),
                        _buildFilterChip('Finance', Colors.amber),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Expanded(
                    child: appState.isLoading ||
                            appState.isSemanticSearchLoading
                        ? Center(
                            child: CircularProgressIndicator(
                                color: appState.primaryColor))
                        : filteredTasks.isEmpty
                            ? Center(
                                child: Text(
                                    searchQuery.isNotEmpty
                                        ? "No matching tasks found."
                                        : "No tasks in this category.",
                                    style:
                                        TextStyle(color: appState.textColor)))
                            : ListView.builder(
                                itemCount: filteredTasks.length,
                                itemBuilder: (context, index) =>
                                    buildDismissibleTask(
                                        context, filteredTasks[index])),
                  )
                ],
              ),
            ),
          );
        });
  }

  Widget _buildFilterChip(String label, Color colorTag) {
    bool isSelected = selectedFilter == label;
    return GestureDetector(
      onTap: () => setState(() => selectedFilter = label),
      child: Container(
        margin: const EdgeInsets.only(right: 10),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? colorTag : appState.cardColor,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: isSelected ? colorTag : colorTag.withOpacity(0.5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : appState.textColor,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 5. CALENDAR SCREEN
// ----------------------------------------------------------------------
class CalendarScreen extends StatelessWidget {
  const CalendarScreen({super.key});

  @override
  Widget build(BuildContext context) {
    DateTime now = DateTime.now();
    int daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    int currentDay = now.day;
    int firstDayWeekday = DateTime(now.year, now.month, 1).weekday;
    int offset = firstDayWeekday == 7 ? 0 : firstDayWeekday;

    List<String> months = [
      "January",
      "February",
      "March",
      "April",
      "May",
      "June",
      "July",
      "August",
      "September",
      "October",
      "November",
      "December"
    ];
    String monthName = months[now.month - 1];
    List<String> daysOfWeek = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];

    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 10),
                  const TopBar(title: 'Calendar'),
                  const SizedBox(height: 20),
                  GlassCard(
                    padding: 16,
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(monthName,
                                style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.bold,
                                    color: appState.textColor)),
                            Row(children: [
                              Icon(Icons.chevron_left,
                                  color: appState.subTextColor),
                              Icon(Icons.chevron_right,
                                  color: appState.subTextColor)
                            ])
                          ],
                        ),
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceAround,
                          children: daysOfWeek
                              .map((day) => Text(day,
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: appState.subTextColor)))
                              .toList(),
                        ),
                        const SizedBox(height: 10),
                        GridView.builder(
                          shrinkWrap: true,
                          physics: const NeverScrollableScrollPhysics(),
                          gridDelegate:
                              const SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: 7, childAspectRatio: 1.2),
                          itemCount: daysInMonth + offset,
                          itemBuilder: (context, index) {
                            if (index < offset) return Container();
                            int day = index - offset + 1;
                            bool isToday = day == currentDay;
                            return Container(
                              margin: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                  color: isToday
                                      ? appState.primaryColor
                                      : Colors.transparent,
                                  shape: BoxShape.circle),
                              child: Center(
                                child: Text(
                                  '$day',
                                  style: TextStyle(
                                      color: isToday
                                          ? Colors.white
                                          : appState.textColor,
                                      fontWeight: isToday
                                          ? FontWeight.bold
                                          : FontWeight.normal),
                                ),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text("Today, $currentDay",
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: appState.textColor)),
                      Text("${appState.tasks.length} Tasks",
                          style: TextStyle(color: appState.subTextColor)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Expanded(
                    child: appState.isLoading
                        ? Center(
                            child: CircularProgressIndicator(
                                color: appState.primaryColor))
                        : appState.tasks.isEmpty
                            ? Center(
                                child: Text("No tasks for today.",
                                    style:
                                        TextStyle(color: appState.textColor)))
                            : ListView.builder(
                                itemCount: appState.tasks.length,
                                itemBuilder: (context, index) =>
                                    buildDismissibleTask(
                                        context, appState.tasks[index])),
                  )
                ],
              ),
            ),
          );
        });
  }
}

// ----------------------------------------------------------------------
// 6. FOCUS SCREEN (Pomodoro Timer)
// ----------------------------------------------------------------------
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});

  @override
  State<FocusScreen> createState() => _FocusScreenState();
}

class _FocusScreenState extends State<FocusScreen> {
  static const int defaultTime = 25 * 60;
  int timeLeft = defaultTime;
  Timer? timer;
  bool isRunning = false;

  void startTimer() {
    setState(() => isRunning = true);
    timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (timeLeft > 0) {
        setState(() => timeLeft--);
      } else {
        stopTimer();
      }
    });
  }

  void stopTimer() {
    timer?.cancel();
    setState(() => isRunning = false);
  }

  void resetTimer() {
    stopTimer();
    setState(() => timeLeft = defaultTime);
  }

  String get timerText {
    int minutes = timeLeft ~/ 60;
    int seconds = timeLeft % 60;
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          return SafeArea(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Deep Work',
                      style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: appState.primaryColor)),
                  Text('Focus on the Tide',
                      style:
                          TextStyle(fontSize: 16, color: appState.textColor)),
                  const SizedBox(height: 60),
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                          width: 250,
                          height: 250,
                          decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: appState.primaryColor.withOpacity(0.3),
                                  width: 10),
                              color: appState.cardColor)),
                      Container(
                        width: 230,
                        height: 230,
                        decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: appState.primaryColor, width: 6)),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(timerText,
                                  style: TextStyle(
                                      fontSize: 50,
                                      fontWeight: FontWeight.bold,
                                      color: appState.primaryColor)),
                              Text(isRunning ? 'In Flow State' : 'Paused',
                                  style: TextStyle(color: appState.textColor)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 60),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                          icon: const Icon(Icons.refresh, size: 30),
                          color: appState.primaryColor,
                          onPressed: resetTimer),
                      const SizedBox(width: 20),
                      GestureDetector(
                        onTap: isRunning ? stopTimer : startTimer,
                        child: Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: appState.primaryColor),
                            child: Icon(
                                isRunning ? Icons.pause : Icons.play_arrow,
                                color: Colors.white,
                                size: 32)),
                      ),
                      const SizedBox(width: 20),
                      IconButton(
                          icon: const Icon(Icons.stop, size: 30),
                          color: appState.primaryColor,
                          onPressed: resetTimer),
                    ],
                  )
                ],
              ),
            ),
          );
        });
  }
}

// ----------------------------------------------------------------------
// 7. PROFILE SCREEN
// ----------------------------------------------------------------------
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  void _showEditNameDialog(BuildContext context) {
    final controller = TextEditingController(text: appState.userName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: appState.isDarkMode ? Colors.grey[900] : Colors.white,
        title:
            Text('Edit Username', style: TextStyle(color: appState.textColor)),
        content: TextField(
          controller: controller,
          style: TextStyle(color: appState.textColor),
          decoration: InputDecoration(
            hintText: 'Enter your name',
            hintStyle: TextStyle(color: appState.subTextColor),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: appState.primaryColor),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                Text('Cancel', style: TextStyle(color: appState.subTextColor)),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.trim().isNotEmpty) {
                appState.updateUserName(controller.text.trim());
              }
              Navigator.pop(context);
            },
            child: Text('Save',
                style: TextStyle(
                    color: appState.primaryColor, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showAvatarSelectionDialog(BuildContext context) {
    final List<String> avatars = [
      'https://images.unsplash.com/photo-1494790108377-be9c29b29330?w=200&auto=format&fit=crop&q=60',
      'https://images.unsplash.com/photo-1535713875002-d1d0cf377fde?w=200&auto=format&fit=crop&q=60',
      'https://images.unsplash.com/photo-1438761681033-6461ffad8d80?w=200&auto=format&fit=crop&q=60',
      'https://images.unsplash.com/photo-1570295999919-56ceb5ecca61?w=200&auto=format&fit=crop&q=60',
      'https://images.unsplash.com/photo-1534528741775-53994a69daeb?w=200&auto=format&fit=crop&q=60',
      'https://images.unsplash.com/photo-1507003211169-0a1dd7228f2d?w=200&auto=format&fit=crop&q=60',
    ];

    final customUrlController =
        TextEditingController(text: appState.profilePicUrl);

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: appState.isDarkMode ? Colors.grey[900] : Colors.white,
        title: Text('Select Profile Picture',
            style: TextStyle(color: appState.textColor)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                itemCount: avatars.length,
                itemBuilder: (context, index) {
                  final url = avatars[index];
                  return GestureDetector(
                    onTap: () {
                      appState.updateProfilePic(url);
                      Navigator.pop(context);
                    },
                    child: Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: appState.profilePicUrl == url
                              ? appState.primaryColor
                              : Colors.transparent,
                          width: 3,
                        ),
                      ),
                      child: CircleAvatar(
                        backgroundImage: NetworkImage(url),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              Text('Or paste a custom image URL:',
                  style: TextStyle(fontSize: 12, color: appState.subTextColor)),
              const SizedBox(height: 8),
              TextField(
                controller: customUrlController,
                style: TextStyle(color: appState.textColor),
                decoration: InputDecoration(
                  hintText: 'https://example.com/avatar.jpg',
                  hintStyle: TextStyle(color: appState.subTextColor),
                  enabledBorder: UnderlineInputBorder(
                    borderSide: BorderSide(color: appState.primaryColor),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child:
                Text('Cancel', style: TextStyle(color: appState.subTextColor)),
          ),
          TextButton(
            onPressed: () {
              if (customUrlController.text.trim().isNotEmpty) {
                appState.updateProfilePic(customUrlController.text.trim());
              }
              Navigator.pop(context);
            },
            child: Text('Save Custom',
                style: TextStyle(
                    color: appState.primaryColor, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: appState,
        builder: (context, _) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20.0),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Icon(Icons.arrow_back, color: appState.primaryColor),
                          Text('Tide',
                              style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: appState.primaryColor)),
                          Icon(Icons.more_vert, color: appState.subTextColor)
                        ]),
                    const SizedBox(height: 20),
                    GlassCard(
                      child: Column(
                        children: [
                          GestureDetector(
                            onTap: () => _showAvatarSelectionDialog(context),
                            child: Stack(
                              alignment: Alignment.bottomRight,
                              children: [
                                CircleAvatar(
                                    radius: 40,
                                    backgroundImage:
                                        NetworkImage(appState.profilePicUrl)),
                                Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: appState.primaryColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.camera_alt,
                                      size: 14, color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(appState.userName,
                                  style: TextStyle(
                                      fontSize: 22,
                                      fontWeight: FontWeight.bold,
                                      color: appState.primaryColor)),
                              const SizedBox(width: 8),
                              IconButton(
                                icon: Icon(Icons.edit,
                                    size: 18, color: appState.primaryColor),
                                onPressed: () => _showEditNameDialog(context),
                              ),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                  color: appState.cardColor,
                                  borderRadius: BorderRadius.circular(12)),
                              child: Text('Tide Member',
                                  style: TextStyle(
                                      color: appState.primaryColor,
                                      fontSize: 12)))
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Text('Settings',
                            style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: appState.primaryColor))),
                    const SizedBox(height: 10),
                    GlassCard(
                      padding: 10,
                      child: Column(
                        children: [
                          ListTile(
                              leading: Icon(
                                  appState.isDarkMode
                                      ? Icons.dark_mode
                                      : Icons.light_mode,
                                  color: appState.primaryColor),
                              title: Text('App Theme',
                                  style: TextStyle(color: appState.textColor)),
                              trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(appState.isDarkMode ? 'Dark' : 'Light',
                                        style: TextStyle(
                                            color: appState.subTextColor)),
                                    Icon(Icons.chevron_right,
                                        color: appState.subTextColor)
                                  ]),
                              onTap: () => appState.toggleTheme()),
                          Divider(
                              height: 1, color: Colors.white.withOpacity(0.2)),
                          ListTile(
                              leading: const Icon(Icons.logout,
                                  color: Colors.redAccent),
                              title: const Text('Sign Out',
                                  style: TextStyle(
                                      color: Colors.redAccent,
                                      fontWeight: FontWeight.bold)),
                              onTap: () async {
                                await appState.logout();
                              }),
                        ],
                      ),
                    ),
                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ),
          );
        });
  }
}

// ----------------------------------------------------------------------
// 8. ADD TASK BOTTOM SHEET
// ----------------------------------------------------------------------
class AddTaskModal extends StatefulWidget {
  const AddTaskModal({super.key});

  @override
  State<AddTaskModal> createState() => _AddTaskModalState();
}

class _AddTaskModalState extends State<AddTaskModal> {
  final TextEditingController _titleController = TextEditingController();
  String selectedPriority = 'Medium';
  DateTime? selectedDueDate;

  void _submitTask() {
    if (_titleController.text.trim().isEmpty) return;
    appState.addTask(
        _titleController.text.trim(), selectedPriority, selectedDueDate);
    Navigator.pop(context);
  }

  String _formatDateTime(DateTime dt) {
    final List<String> months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec"
    ];
    final String month = months[dt.month - 1];
    final String hour = dt.hour.toString().padLeft(2, '0');
    final String minute = dt.minute.toString().padLeft(2, '0');
    return "$month ${dt.day}, $hour:$minute";
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: appState.isDarkMode ? Colors.grey[900] : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(30))),
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom + 30,
          top: 20,
          left: 24,
          right: 24),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                    icon: Icon(Icons.close, color: appState.textColor),
                    onPressed: () => Navigator.pop(context)),
                Text('NEW TASK',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: appState.subTextColor)),
                const SizedBox(width: 48),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _titleController,
              autofocus: true,
              style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: appState.textColor),
              decoration: InputDecoration(
                  hintText: 'What are you working on?',
                  border: InputBorder.none,
                  hintStyle:
                      TextStyle(color: appState.subTextColor.withOpacity(0.3))),
            ),
            const SizedBox(height: 20),
            Text('PRIORITY',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: appState.subTextColor)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(child: _buildPriorityChip('High', Colors.redAccent)),
                const SizedBox(width: 8),
                Expanded(child: _buildPriorityChip('Medium', Colors.orange)),
                const SizedBox(width: 8),
                Expanded(
                    child: _buildPriorityChip('Low', appState.primaryColor)),
              ],
            ),
            const SizedBox(height: 20),
            Text('CATEGORY',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: appState.subTextColor)),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: appState.primaryColor.withOpacity(0.08),
                border:
                    Border.all(color: appState.primaryColor.withOpacity(0.2)),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(Icons.auto_awesome,
                      color: appState.primaryColor, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'AI will automatically categorize this task into Work, Personal, Study, Health, or Finance based on the title.',
                      style: TextStyle(
                          color: appState.textColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w500),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Text('DUE DATE',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: appState.subTextColor)),
            const SizedBox(height: 10),
            InkWell(
              onTap: () async {
                final DateTime? date = await showDatePicker(
                  context: context,
                  initialDate: selectedDueDate ?? DateTime.now(),
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now().add(const Duration(days: 3650)),
                );
                if (date != null) {
                  final TimeOfDay? time = await showTimePicker(
                    context: context,
                    initialTime: TimeOfDay.fromDateTime(
                        selectedDueDate ?? DateTime.now()),
                  );
                  setState(() {
                    if (time != null) {
                      selectedDueDate = DateTime(
                        date.year,
                        date.month,
                        date.day,
                        time.hour,
                        time.minute,
                      );
                    } else {
                      selectedDueDate = date;
                    }
                  });
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                decoration: BoxDecoration(
                  border:
                      Border.all(color: appState.subTextColor.withOpacity(0.3)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      selectedDueDate == null
                          ? 'No due date set'
                          : 'Due: ${_formatDateTime(selectedDueDate!)}',
                      style: TextStyle(
                          color: selectedDueDate == null
                              ? appState.subTextColor
                              : appState.textColor,
                          fontWeight: FontWeight.bold),
                    ),
                    Icon(Icons.calendar_today, color: appState.primaryColor),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 30),
            SizedBox(
              width: double.infinity,
              height: 55,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                    backgroundColor: appState.primaryColor,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16))),
                onPressed: _submitTask,
                icon: const Icon(Icons.add_task, color: Colors.white),
                label: const Text('Add Task',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            )
          ],
        ),
      ),
    );
  }

  Widget _buildPriorityChip(String label, Color color) {
    bool isSelected = selectedPriority == label;
    return GestureDetector(
      onTap: () => setState(() => selectedPriority = label),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
            color: isSelected ? color.withOpacity(0.2) : Colors.transparent,
            border: Border.all(color: isSelected ? color : Colors.black12),
            borderRadius: BorderRadius.circular(12)),
        child: Center(
            child: Text(label,
                style: TextStyle(
                    color: color, fontWeight: FontWeight.bold, fontSize: 12))),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 9. TIDE AI CHAT BOTTOM SHEET PANEL
// ----------------------------------------------------------------------
class AIChatSheet extends StatefulWidget {
  const AIChatSheet({super.key});

  @override
  State<AIChatSheet> createState() => _AIChatSheetState();
}

class _AIChatSheetState extends State<AIChatSheet> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    // Seed initial greeting message if the session chat history is empty
    if (appState.chatMessages.isEmpty) {
      appState.chatMessages.add(ChatMessage(
        text:
            "Hi ${appState.userName}! I am Tide AI. Ask me anything about your tasks, or select a suggestion below to get started!",
        isUser: false,
      ));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _sendMessage([String? text]) async {
    final messageText = text ?? _messageController.text;
    if (messageText.trim().isEmpty) return;

    if (text == null) {
      _messageController.clear();
    }

    await appState.sendChatMessage(messageText);
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, _) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.8,
          decoration: BoxDecoration(
              color: appState.isDarkMode ? Colors.grey[900] : Colors.white,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(30))),
          padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom, top: 16),
          child: SafeArea(
            child: Column(
              children: [
                // Handle Bar
                Container(
                  width: 40,
                  height: 5,
                  decoration: BoxDecoration(
                    color: appState.subTextColor.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                const SizedBox(height: 12),
                // Header Row
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          ShaderMask(
                            shaderCallback: (bounds) => const LinearGradient(
                              colors: [Colors.purpleAccent, Colors.blueAccent],
                            ).createShader(bounds),
                            child: const Icon(Icons.auto_awesome,
                                color: Colors.white, size: 28),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Tide AI',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                      color: appState.primaryColor)),
                              Text('Local Productivity Assistant',
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: appState.subTextColor)),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(
                          width: 48), // Empty spacer to balance layout
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Divider(
                    height: 1, color: appState.subTextColor.withOpacity(0.15)),

                // Chat Messages Thread
                Expanded(
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    itemCount: appState.chatMessages.length,
                    itemBuilder: (context, index) {
                      final msg = appState.chatMessages[index];
                      return _buildChatBubble(msg);
                    },
                  ),
                ),

                // Processing/Loading Indicator
                if (appState.isChatLoading)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: appState.primaryColor,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text("Tide AI is thinking...",
                            style: TextStyle(
                                fontSize: 12, color: appState.subTextColor)),
                      ],
                    ),
                  ),

                // Quick Action Suggestion Chips (Shown on empty conversation)
                if (appState.chatMessages.length == 1 &&
                    !appState.isChatLoading)
                  Container(
                    height: 40,
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      children: [
                        _buildSuggestionChip("Summarize my day"),
                        _buildSuggestionChip("What is my next priority?"),
                        _buildSuggestionChip("How many pending tasks left?"),
                        _buildSuggestionChip("List my study tasks"),
                      ],
                    ),
                  ),

                // Input Bar
                Padding(
                  padding: const EdgeInsets.only(
                      left: 20, right: 20, bottom: 20, top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _messageController,
                          style: TextStyle(color: appState.textColor),
                          textInputAction: TextInputAction.send,
                          onSubmitted: (val) => _sendMessage(),
                          decoration: InputDecoration(
                            hintText: "Ask Tide AI about your tasks...",
                            hintStyle: TextStyle(
                                color: appState.subTextColor.withOpacity(0.6)),
                            filled: true,
                            fillColor: appState.isDarkMode
                                ? Colors.grey[850]
                                : Colors.grey[100],
                            contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 12),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      CircleAvatar(
                        backgroundColor: appState.primaryColor,
                        radius: 22,
                        child: IconButton(
                          icon: const Icon(Icons.send,
                              color: Colors.white, size: 18),
                          onPressed: () => _sendMessage(),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSuggestionChip(String queryText) {
    return GestureDetector(
      onTap: () => _sendMessage(queryText),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: appState.primaryColor.withOpacity(0.08),
          border: Border.all(color: appState.primaryColor.withOpacity(0.2)),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          queryText,
          style: TextStyle(
            color: appState.primaryColor,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildChatBubble(ChatMessage message) {
    final isMe = message.isUser;
    return Align(
      alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints:
            BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.75),
        decoration: BoxDecoration(
          color: isMe
              ? appState.primaryColor
              : (appState.isDarkMode ? Colors.grey[800] : Colors.grey[200]),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: isMe ? const Radius.circular(16) : Radius.zero,
            bottomRight: isMe ? Radius.zero : const Radius.circular(16),
          ),
        ),
        child: Text(
          message.text,
          style: TextStyle(
            color: isMe ? Colors.white : appState.textColor,
            fontSize: 14,
          ),
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------
// 10. TIDE APP HOME WRAPPER
// ----------------------------------------------------------------------
class TideAppHomeWrapper extends StatelessWidget {
  const TideAppHomeWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: appState,
      builder: (context, child) {
        if (appState.isGuestMode) {
          return const MainDashboard();
        }
        return StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(
                  child: CircularProgressIndicator(),
                ),
              );
            }
            if (snapshot.hasData && snapshot.data != null) {
              return const MainDashboard();
            }
            return const SplashLoginScreen();
          },
        );
      },
    );
  }
}

// ----------------------------------------------------------------------
// 11. SHARED TASKS SCREEN (READ-ONLY VIEW)
// ----------------------------------------------------------------------
class SharedTasksScreen extends StatefulWidget {
  final String ownerId;
  final String shareId;

  const SharedTasksScreen({
    super.key,
    required this.ownerId,
    required this.shareId,
  });

  @override
  State<SharedTasksScreen> createState() => _SharedTasksScreenState();
}

class _SharedTasksScreenState extends State<SharedTasksScreen> {
  bool _isLoading = true;
  String _listTitle = "Shared Tasks";
  String _ownerName = "User";
  List<Task> _tasks = [];
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadSharedData();
  }

  Future<void> _loadSharedData() async {
    try {
      final docRef = FirebaseFirestore.instance
          .collection('users')
          .doc(widget.ownerId)
          .collection('shared_lists')
          .doc(widget.shareId);

      final docSnap = await docRef.get();
      if (!docSnap.exists) {
        setState(() {
          _errorMessage = "The shared list does not exist or has been deleted.";
          _isLoading = false;
        });
        return;
      }

      final meta = docSnap.data() ?? {};
      _listTitle = meta['title'] ?? "Shared Tasks";
      _ownerName = meta['ownerName'] ?? "User";

      final tasksSnap = await docRef.collection('tasks').get();
      final tasksList =
          tasksSnap.docs.map((doc) => Task.fromFirestore(doc)).toList();

      setState(() {
        _tasks = tasksList;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = "Error loading shared list: ${e.toString()}";
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: BackgroundWrapper(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                              color: appState.cardColor,
                              shape: BoxShape.circle),
                          child: Icon(Icons.link,
                              color: appState.primaryColor, size: 20),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          "Shared View",
                          style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: appState.primaryColor),
                        ),
                      ],
                    ),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: appState.primaryColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                      ),
                      onPressed: () {
                        Navigator.pushReplacement(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const TideAppHomeWrapper(),
                          ),
                        );
                      },
                      child: const Text('Go to App'),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                if (_isLoading)
                  Expanded(
                    child: Center(
                      child: CircularProgressIndicator(
                          color: appState.primaryColor),
                    ),
                  )
                else if (_errorMessage != null)
                  Expanded(
                    child: Center(
                      child: GlassCard(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.error_outline,
                                size: 48, color: Colors.redAccent),
                            const SizedBox(height: 16),
                            Text(
                              _errorMessage!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: appState.textColor),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else ...[
                  Text(
                    _listTitle,
                    style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        color: appState.primaryColor),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Shared by $_ownerName • Read-Only",
                    style: TextStyle(fontSize: 14, color: appState.textColor),
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: _tasks.isEmpty
                        ? Center(
                            child: Text(
                              "No tasks in this shared stream.",
                              style: TextStyle(color: appState.textColor),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _tasks.length,
                            itemBuilder: (context, index) {
                              final task = _tasks[index];
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12.0),
                                child: GlassCard(
                                  padding: 16,
                                  child: Row(
                                    children: [
                                      Icon(
                                        task.isCompleted
                                            ? Icons.check_circle
                                            : Icons.circle_outlined,
                                        color: task.isCompleted
                                            ? appState.primaryColor
                                            : appState.subTextColor,
                                      ),
                                      const SizedBox(width: 16),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Text(
                                              task.title,
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                decoration: task.isCompleted
                                                    ? TextDecoration.lineThrough
                                                    : null,
                                                color: task.isCompleted
                                                    ? appState.subTextColor
                                                    : appState.textColor,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                Container(
                                                  padding: const EdgeInsets
                                                          .symmetric(
                                                      horizontal: 8,
                                                      vertical: 2),
                                                  decoration: BoxDecoration(
                                                    color: task.categoryColor
                                                        .withOpacity(0.2),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            8),
                                                    border: Border.all(
                                                      color: task.categoryColor
                                                          .withOpacity(0.5),
                                                    ),
                                                  ),
                                                  child: Text(
                                                    task.category,
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight:
                                                          FontWeight.bold,
                                                      color: task.categoryColor,
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                                Text(
                                                  '${task.priority} Priority',
                                                  style: TextStyle(
                                                    fontSize: 11,
                                                    color:
                                                        appState.subTextColor,
                                                  ),
                                                ),
                                                if (task.dueDate != null) ...[
                                                  const SizedBox(width: 8),
                                                  Icon(Icons.access_time,
                                                      size: 12,
                                                      color: appState
                                                          .subTextColor),
                                                  const SizedBox(width: 4),
                                                  Text(
                                                    _formatSharedDateTime(
                                                        task.dueDate!),
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color:
                                                          appState.subTextColor,
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _formatSharedDateTime(DateTime dt) {
    final List<String> months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec"
    ];
    return "${months[dt.month - 1]} ${dt.day}, ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }
}
