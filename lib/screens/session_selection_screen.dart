import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SessionSelectionScreen extends StatefulWidget {
  const SessionSelectionScreen({super.key});

  @override
  State<SessionSelectionScreen> createState() => _SessionSelectionScreenState();
}

class _SessionSelectionScreenState extends State<SessionSelectionScreen> {
  List<String> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('session_history') ?? [];
    setState(() {
      _history = list;
      _isLoading = false;
    });
  }

  Future<void> _saveHistory(List<String> newList) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('session_history', newList);
    setState(() {
      _history = newList;
    });
  }

  void _connectToSession(String url) {
    Navigator.pushReplacementNamed(
      context,
      '/live',
      arguments: url,
    );
  }

  void _deleteSession(int index) {
    final newList = List<String>.from(_history);
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
                    final url = _history[index];
                    return ListTile(
                      leading: const Icon(Icons.history), // ✅ FIXED: use 'history' (not 'history_off')
                      title: Text(
                        url,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => _deleteSession(index),
                        tooltip: 'Remove',
                      ),
                      onTap: () => _connectToSession(url),
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
          Icon(Icons.history, size: 80, color: Colors.grey), // ✅ FIXED here too
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