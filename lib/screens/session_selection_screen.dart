import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:developer' as developer;
import '../route_observer.dart';

class SessionHistoryItem {
  final String url;
  String name;                // editable display name
  final DateTime firstConnected; // first connection date
  DateTime lastConnected;     // last connection date (for sorting)

  SessionHistoryItem({
    required this.url,
    required this.name,
    required this.firstConnected,
    required this.lastConnected,
  });

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        'firstConnected': firstConnected.toIso8601String(),
        'lastConnected': lastConnected.toIso8601String(),
      };

  factory SessionHistoryItem.fromJson(Map<String, dynamic> json) {
    return SessionHistoryItem(
      url: json['url'] as String,
      name: json['name'] as String? ?? 'Session', // fallback for legacy
      firstConnected: DateTime.parse(json['firstConnected'] as String),
      lastConnected: DateTime.parse(json['lastConnected'] as String),
    );
  }

  static SessionHistoryItem? tryParse(String stored) {
    try {
      final map = jsonDecode(stored) as Map<String, dynamic>;
      // Legacy migration: if fields missing, populate sensible defaults
      if (!map.containsKey('name') || !map.containsKey('firstConnected')) {
        final url = map['url'] as String;
        final last = map['lastConnected'] != null
            ? DateTime.parse(map['lastConnected'] as String)
            : DateTime(2000, 1, 1);
        final name = map['name'] as String? ?? url;
        final first = map['firstConnected'] != null
            ? DateTime.parse(map['firstConnected'] as String)
            : last;
        return SessionHistoryItem(
          url: url,
          name: name,
          firstConnected: first,
          lastConnected: last,
        );
      }
      return SessionHistoryItem.fromJson(map);
    } catch (_) {
      // Handle plain string fallback
      final trimmed = stored.trim();
      if (trimmed.isNotEmpty) {
        final now = DateTime.now();
        return SessionHistoryItem(
          url: trimmed,
          name: 'Session at ${_formatDateTime(now)}',
          firstConnected: now,
          lastConnected: now,
        );
      }
      return null;
    }
  }

  // Helper for default name formatting
  static String _formatDateTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

class SessionSelectionScreen extends StatefulWidget {
  const SessionSelectionScreen({super.key});

  @override
  State<SessionSelectionScreen> createState() =>
      _SessionSelectionScreenState();
}

class _SessionSelectionScreenState extends State<SessionSelectionScreen>
    with RouteAware {
  List<SessionHistoryItem> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    super.dispose();
  }

  @override
  void didPopNext() {
    _loadHistory(); // refresh on return
  }

  // ---------- History loading / saving ----------

  Future<void> _loadHistory() async {
    setState(() => _isLoading = true);
    final prefs = await SharedPreferences.getInstance();
    final storedList = prefs.getStringList('session_history') ?? [];
    final List<SessionHistoryItem> items = [];

    for (final entry in storedList) {
      final item = SessionHistoryItem.tryParse(entry);
      if (item != null) items.add(item);
    }

    // Sort by lastConnected descending
    items.sort((a, b) => b.lastConnected.compareTo(a.lastConnected));
    setState(() {
      _history = items;
      _isLoading = false;
    });
  }

  Future<void> _saveHistory(List<SessionHistoryItem> newList) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = newList
        .map((item) => jsonEncode(item.toJson()))
        .toList();
    await prefs.setStringList('session_history', jsonList);
    setState(() => _history = newList);
  }

  // ---------- URL resolution ----------

  Future<String> _resolveUrl(String input) async {
    input = input.trim();

    if (input.startsWith('ws://') || input.startsWith('wss://')) {
      return input;
    }

    if (!input.startsWith('http://') && !input.startsWith('https://')) {
      throw Exception('Invalid URL format.');
    }

    final response = await http.get(Uri.parse(input));
    if (response.statusCode != 200) {
      throw Exception('Server returned HTTP ${response.statusCode}');
    }

    final body = response.body;
    final sessionIdRegex = RegExp(r'window\.sessionId\s*=\s*"([^"]+)"');
    final match = sessionIdRegex.firstMatch(body);
    if (match == null) {
      throw Exception('Could not find window.sessionId in the page.');
    }
    final sessionId = match.group(1)!;
    developer.log('Resolved session ID: $sessionId');

    final uri = Uri.parse(input);
    return '${uri.scheme}://${uri.host}/webapi/stream?channel=$sessionId';
  }

  // ---------- Connect to session ----------

  Future<void> _connectToSession(String shortUrl) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    String resolvedUrl;
    try {
      if (shortUrl.contains('/stream?channel=')) {
        resolvedUrl = shortUrl;
      } else {
        resolvedUrl = await _resolveUrl(shortUrl);
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to resolve: $e'), backgroundColor: Colors.red),
        );
      }
      return;
    }

    // Update or add session
    final now = DateTime.now();
    final index = _history.indexWhere((item) => item.url == shortUrl);
    List<SessionHistoryItem> newList;
    if (index != -1) {
      // Update lastConnected only; keep name and firstConnected
      final updated = SessionHistoryItem(
        url: shortUrl,
        name: _history[index].name,
        firstConnected: _history[index].firstConnected,
        lastConnected: now,
      );
      newList = List<SessionHistoryItem>.from(_history);
      newList[index] = updated;
    } else {
      // New session: default name = "Session at HH:MM"
      final defaultName = 'Session at ${_formatTime(now)}';
      final newItem = SessionHistoryItem(
        url: shortUrl,
        name: defaultName,
        firstConnected: now,
        lastConnected: now,
      );
      newList = List<SessionHistoryItem>.from(_history)..add(newItem);
    }
    await _saveHistory(newList);

    if (mounted) {
      Navigator.pop(context);
      Navigator.pushNamed(context, '/live', arguments: resolvedUrl);
    }
  }

  // ---------- Edit name ----------

  Future<void> _editName(int index) async {
    final item = _history[index];
    final controller = TextEditingController(text: item.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Session Name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newName != null && newName.isNotEmpty) {
      final updated = SessionHistoryItem(
        url: item.url,
        name: newName,
        firstConnected: item.firstConnected,
        lastConnected: item.lastConnected,
      );
      final newList = List<SessionHistoryItem>.from(_history);
      newList[index] = updated;
      await _saveHistory(newList);
    }
  }

  // ---------- Delete / clear ----------

  void _deleteSession(int index) {
    final newList = List<SessionHistoryItem>.from(_history);
    newList.removeAt(index);
    _saveHistory(newList);
  }

  void _clearAllSessions() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear all sessions?'),
        content: const Text('This will remove all saved URLs and names.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await _saveHistory([]);
    }
  }

  // ---------- Formatting ----------

  String _formatDateTime(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inDays == 0) {
      return 'Today at ${_formatTime(dt)}';
    } else if (diff.inDays == 1) {
      return 'Yesterday at ${_formatTime(dt)}';
    } else {
      return '${dt.day}/${dt.month}/${dt.year} ${_formatTime(dt)}';
    }
  }

  String _formatTime(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  // ---------- Build ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Session'),
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: _clearAllSessions,
              tooltip: 'Clear all',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final item = _history[index];
                    return ListTile(
                      leading: const Icon(Icons.history),
                      title: Text(
                        item.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            item.url,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12),
                          ),
                          Text(
                            'Last connected: ${_formatDateTime(item.lastConnected)}',
                            style: const TextStyle(fontSize: 12, color: Colors.grey),
                          ),
                        ],
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.edit, size: 20),
                            onPressed: () => _editName(index),
                            tooltip: 'Edit name',
                          ),
                          IconButton(
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: () => _deleteSession(index),
                            tooltip: 'Remove',
                          ),
                        ],
                      ),
                      onTap: () => _connectToSession(item.url),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          Navigator.pushNamed(context, '/scan');
        },
        icon: const Icon(Icons.qr_code_scanner),
        label: const Text('Scan New QR'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text(
            'No previous sessions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          SizedBox(height: 8),
          Text(
            'Tap the button below to scan a QR code.',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}