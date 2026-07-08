import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Represents a single session history entry.
class SessionHistoryItem {
  final String url;
  final DateTime lastConnected;

  SessionHistoryItem({required this.url, required this.lastConnected});

  Map<String, dynamic> toJson() => {
        'url': url,
        'lastConnected': lastConnected.toIso8601String(),
      };

  factory SessionHistoryItem.fromJson(Map<String, dynamic> json) {
    return SessionHistoryItem(
      url: json['url'] as String,
      lastConnected: DateTime.parse(json['lastConnected'] as String),
    );
  }

  /// Attempt to parse a stored string, handling both old plain‑URL format
  /// and the new JSON format. Returns null if parsing fails.
  static SessionHistoryItem? tryParse(String stored) {
    // Try JSON first
    try {
      final map = jsonDecode(stored) as Map<String, dynamic>;
      return SessionHistoryItem.fromJson(map);
    } catch (_) {
      // Not JSON – treat as plain URL (old format)
      final trimmed = stored.trim();
      if (trimmed.isNotEmpty) {
        // Assign a default timestamp (e.g., now, but we can use a fixed date)
        // We'll use the current time when migrating, but better to use a
        // conservative old date so that it appears at the bottom.
        final defaultDate = DateTime(2000, 1, 1);
        return SessionHistoryItem(
          url: trimmed,
          lastConnected: defaultDate,
        );
      }
      return null;
    }
  }
}

class SessionSelectionScreen extends StatefulWidget {
  const SessionSelectionScreen({super.key});

  @override
  State<SessionSelectionScreen> createState() =>
      _SessionSelectionScreenState();
}

class _SessionSelectionScreenState extends State<SessionSelectionScreen> {
  List<SessionHistoryItem> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final storedList = prefs.getStringList('session_history') ?? [];
    final List<SessionHistoryItem> items = [];

    for (final entry in storedList) {
      final item = SessionHistoryItem.tryParse(entry);
      if (item != null) {
        items.add(item);
      }
    }

    // If the list contained old‑format entries, we should save them back in the new format.
    // We'll detect if any entry was parsed as plain URL (its timestamp is the default)
    // and resave the entire list as JSON.
    bool needsMigration = items.any(
      (item) => item.lastConnected == DateTime(2000, 1, 1),
    );

    if (needsMigration) {
      // Save the migrated list (with new format) so next load is faster.
      await _saveHistory(items, skipSetState: true);
    }

    // Sort by most recent first
    items.sort((a, b) => b.lastConnected.compareTo(a.lastConnected));

    setState(() {
      _history = items;
      _isLoading = false;
    });
  }

  Future<void> _saveHistory(
    List<SessionHistoryItem> newList, {
    bool skipSetState = false,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final jsonList = newList
        .map((item) => jsonEncode(item.toJson()))
        .toList();
    await prefs.setStringList('session_history', jsonList);
    if (!skipSetState) {
      setState(() {
        _history = newList;
      });
    }
  }

  void _connectToSession(String url) {
    final index = _history.indexWhere((item) => item.url == url);
    if (index != -1) {
      final updated = SessionHistoryItem(
        url: url,
        lastConnected: DateTime.now(),
      );
      final newList = List<SessionHistoryItem>.from(_history);
      newList[index] = updated;
      _saveHistory(newList);
    } else {
      final newItem = SessionHistoryItem(
        url: url,
        lastConnected: DateTime.now(),
      );
      final newList = List<SessionHistoryItem>.from(_history)..add(newItem);
      _saveHistory(newList);
    }
    Navigator.pushNamed(context, '/live', arguments: url);
  }

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
        content: const Text('This will remove all saved URLs.'),
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
                        item.url,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        'Last connected: ${_formatDateTime(item.lastConnected)}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => _deleteSession(index),
                        tooltip: 'Remove',
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