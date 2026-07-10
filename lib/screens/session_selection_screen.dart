import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:developer' as developer;
import 'package:wakelock/wakelock.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../route_observer.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:html/parser.dart' as html_parser;  // for parsing HTML
import 'package:html/dom.dart' as dom;


// ========== SessionHistoryItem (unchanged) ==========
class SessionHistoryItem {
  final String url;
  String name;
  final DateTime firstConnected;
  DateTime lastConnected;

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
      name: json['name'] as String? ?? 'Session',
      firstConnected: DateTime.parse(json['firstConnected'] as String),
      lastConnected: DateTime.parse(json['lastConnected'] as String),
    );
  }

  static SessionHistoryItem? tryParse(String stored) {
    try {
      final map = jsonDecode(stored) as Map<String, dynamic>;
      if (!map.containsKey('name') || !map.containsKey('firstConnected')) {
        final url = map['url'] as String;
        final last = map['lastConnected'] != null
            ? DateTime.parse(map['lastConnected'] as String)
            : DateTime(2000, 1, 1);
        final first = map['firstConnected'] != null
            ? DateTime.parse(map['firstConnected'] as String)
            : last;
        final name = _formatDateForName(first);
        return SessionHistoryItem(
          url: url,
          name: name,
          firstConnected: first,
          lastConnected: last,
        );
      }
      return SessionHistoryItem.fromJson(map);
    } catch (_) {
      final trimmed = stored.trim();
      if (trimmed.isNotEmpty) {
        final now = DateTime.now();
        return SessionHistoryItem(
          url: trimmed,
          name: _formatDateForName(now),
          firstConnected: now,
          lastConnected: now,
        );
      }
      return null;
    }
  }

  static String _formatDateForName(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

// ========== Settings Keys ==========
const String _kThemeModeKey = 'theme_mode';
const String _kKeepScreenOnKey = 'keep_screen_on';

// ========== Screen ==========
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
  final Set<int> _selectedIndices = {};
  String _themeMode = 'system';
  bool _keepScreenOn = false;

  @override
  void initState() {
    super.initState();
    _loadHistory();
    _loadSettings();
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
    _loadHistory();
  }

  // ---------- Settings loading / saving ----------
  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _themeMode = prefs.getString(_kThemeModeKey) ?? 'system';
      _keepScreenOn = prefs.getBool(_kKeepScreenOnKey) ?? false;
    });
    if (_keepScreenOn) {
      await Wakelock.enable();
    } else {
      await Wakelock.disable();
    }
  }

  Future<void> _saveThemeMode(String mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kThemeModeKey, mode);
    setState(() => _themeMode = mode);
  }

  Future<void> _saveKeepScreenOn(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kKeepScreenOnKey, value);
    setState(() => _keepScreenOn = value);
    if (value) {
      await Wakelock.enable();
    } else {
      await Wakelock.disable();
    }
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
    items.sort((a, b) => b.lastConnected.compareTo(a.lastConnected));
    setState(() {
      _history = items;
      _isLoading = false;
      _selectedIndices.clear();
    });
  }

  Future<void> _saveHistory(List<SessionHistoryItem> newList) async {
    newList.sort((a, b) => b.lastConnected.compareTo(a.lastConnected));
    final prefs = await SharedPreferences.getInstance();
    final jsonList = newList.map((item) => jsonEncode(item.toJson())).toList();
    await prefs.setStringList('session_history', jsonList);
    setState(() {
      _history = newList;
      _selectedIndices.clear();
    });
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
    final now = DateTime.now();
    final index = _history.indexWhere((item) => item.url == shortUrl);
    List<SessionHistoryItem> newList;
    if (index != -1) {
      final updated = SessionHistoryItem(
        url: shortUrl,
        name: _history[index].name,
        firstConnected: _history[index].firstConnected,
        lastConnected: now,
      );
      newList = List<SessionHistoryItem>.from(_history);
      newList[index] = updated;
    } else {
      final defaultName = _formatDateForName(now);
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
      Navigator.pushNamed(
        context,
        '/live',
        arguments: {
          'resolvedUrl': resolvedUrl,
          'originalUrl': shortUrl,
        },
      );
    }
  }

  String _formatDateForName(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
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

  // ---------- Delete ----------
  void _deleteSession(int index) {
    final newList = List<SessionHistoryItem>.from(_history);
    newList.removeAt(index);
    _saveHistory(newList);
  }

  void _toggleSelection(int index) {
    setState(() {
      if (_selectedIndices.contains(index)) {
        _selectedIndices.remove(index);
      } else {
        _selectedIndices.add(index);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedIndices.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete selected sessions?'),
        content: Text('This will remove ${_selectedIndices.length} session(s).'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final sorted = _selectedIndices.toList()..sort((a, b) => b.compareTo(a));
    final newList = List<SessionHistoryItem>.from(_history);
    for (var idx in sorted) {
      newList.removeAt(idx);
    }
    await _saveHistory(newList);
  }

  Future<void> _deleteAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete all sessions?'),
        content: const Text('This will remove all saved sessions.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete All', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _saveHistory([]);
  }

  // ---------- Settings Dialog ----------
  Future<void> _showSettingsDialog() async {
    return showDialog(
      context: context,
      builder: (context) => _SettingsDialog(
        initialTheme: _themeMode,
        initialKeepOn: _keepScreenOn,
        onSave: (theme, keepOn) async {
          await _saveThemeMode(theme);
          await _saveKeepScreenOn(keepOn);
        },
      ),
    );
  }

  // ---------- Formatting for display ----------
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

  // ---------- Language map fetch ----------
  Future<Map<String, String>> _fetchLanguageNameToIndexMap(String sessionUrl) async {
    try {
      final response = await http.get(Uri.parse(sessionUrl));
      if (response.statusCode != 200) return {};
      final body = response.body;
      final langIndexRegex = RegExp(r'data-lang-index="([^"]+)"');
      final match = langIndexRegex.firstMatch(body);
      if (match == null) return {};
      final raw = match.group(1)!.replaceAll('&quot;', '"');
      final Map<String, dynamic> map = jsonDecode(raw);
      final result = <String, String>{};
      for (final entry in map.entries) {
        final name = entry.key;
        if (!name.contains('Audio') && !name.contains('Correction')) {
          result[name] = entry.value.toString();
        }
      }
      return result;
    } catch (e) {
      developer.log('Failed to fetch language map: $e');
      return {};
    }
  }

  Future<String?> _extractSessionIdFromUrl(String url) async {
    try {
      final uri = Uri.parse(url);
      final channel = uri.queryParameters['channel'];
      if (channel != null && channel.isNotEmpty) {
        return channel;
      }
      final response = await http.get(Uri.parse(url));
      if (response.statusCode != 200) return null;
      final body = response.body;
      final sessionIdRegex = RegExp(r'window\.sessionId\s*=\s*"([^"]+)"');
      final match = sessionIdRegex.firstMatch(body);
      return match?.group(1);
    } catch (e) {
      developer.log('Error extracting session ID: $e');
      return null;
    }
  }

  Future<void> _showLanguageDialog(String sessionUrl) async {
    final sessionId = await _extractSessionIdFromUrl(sessionUrl);
    if (!mounted) return;
    if (sessionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not extract session ID from URL.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    final langMap = await _fetchLanguageNameToIndexMap(sessionUrl);
    if (!mounted) return;
    Navigator.pop(context);

    if (langMap.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No text languages available for this session.'),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    final names = langMap.keys.toList()..sort((a, b) {
      if (a == 'Transcript') return -1;
      if (b == 'Transcript') return 1;
      return a.compareTo(b);
    });

    final selectedName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Language'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: names.length,
            itemBuilder: (context, index) {
              final name = names[index];
              return ListTile(
                title: Text(name),
                onTap: () => Navigator.pop(context, name),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

    if (selectedName != null && mounted) {
      await _fetchAndSharePdf(sessionId, selectedName);
    }
  }

  // ====================================================================
  // NEW: PDF generation with HTML parsing and pagination
  // ====================================================================

  /// Load the Noto Sans font once, reused across pages.
  Future<pw.Font> _loadFont() async {
    try {
      final fontData = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
      if (kDebugMode) {
        print('✅ NotoSans loaded successfully');
      }
      return pw.Font.ttf(fontData.buffer.asByteData());
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Font load failed, using Helvetica: $e');
      }
      return pw.Font.helvetica();
    }
  }

  /// Convert HTML string to a list of PDF widgets.
  List<pw.Widget> _parseHtmlToPdfWidgets(String html, pw.Font font) {
    final document = html_parser.parse(html);
    final body = document.body;
    if (body == null) return [];

    final List<pw.Widget> widgets = [];

    void addTextBlock(String text, {double fontSize = 12, bool bold = false, double spacing = 4}) {
      final trimmed = text.trim();
      if (trimmed.isNotEmpty) {
        widgets.add(pw.Text(
          trimmed,
          style: pw.TextStyle(
            fontSize: fontSize,
            fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
            font: font,
          ),
        ));
        widgets.add(pw.SizedBox(height: spacing));
      }
    }

    void addTextWithLineBreaks(String text, {double fontSize = 12, double spacing = 4}) {
      final lines = text.split('\n');
      for (var line in lines) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          widgets.add(pw.Text(
            trimmed,
            style: pw.TextStyle(fontSize: fontSize, font: font),
          ));
          widgets.add(pw.SizedBox(height: spacing));
        }
      }
    }

    void processNode(dom.Node node) {
      if (kDebugMode) {
        print('🔍 Processing node: ${node.runtimeType}, text: "${node.text}"');
      }
      if (node is dom.Element) {
        if (kDebugMode) {
          print('  📌 Element: ${node.localName}');
        }
        switch (node.localName) {
          case 'h1':
            addTextBlock(node.text, fontSize: 24, bold: true, spacing: 8);
            break;
          case 'h2':
            addTextBlock(node.text, fontSize: 18, bold: true, spacing: 6);
            break;
          case 'h3':
            addTextBlock(node.text, fontSize: 16, bold: true, spacing: 4);
            break;
          case 'p':
            addTextBlock(node.text, fontSize: 12, spacing: 6);
            break;
          case 'br':
            widgets.add(pw.SizedBox(height: 6));
            break;
          case 'ul':
          case 'ol':
            // For lists, we still want to iterate over children (li elements)
            for (var child in node.children) {
              if (child.localName == 'li') {
                final bullet = node.localName == 'ul' ? '• ' : '${widgets.length + 1}. ';
                addTextBlock('$bullet${child.text}', fontSize: 12, spacing: 4);
              }
            }
            widgets.add(pw.SizedBox(height: 6));
            break;
          case 'div':
          case 'section':
          case 'article':
            // ✅ FIX: use .nodes to include text nodes inside these containers
            for (var child in node.nodes) {
              processNode(child);
            }
            break;
          default:
            // ✅ FIX: already uses .nodes (good)
            for (var child in node.nodes) {
              processNode(child);
            }
            break;
        }
      } else if (node is dom.Text) {
        if (kDebugMode) {
          print('  📝 Text node: "${node.text}"');
        }
        final text = node.text;
        if (text.trim().isNotEmpty) {
          addTextWithLineBreaks(text, fontSize: 12, spacing: 4);
        }
      }
    }

    // ✅ FIX: use body.nodes instead of body.children to include direct text nodes
    for (var child in body.nodes) {
      processNode(child);
    }

    // Fallback (in case something still goes wrong)
    if (widgets.isEmpty || widgets.every((w) => w is pw.SizedBox)) {
      final fullText = body.text.trim();
      if (fullText.isNotEmpty) {
        final lines = fullText.split('\n');
        for (var line in lines) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            widgets.add(pw.Text(trimmed, style: pw.TextStyle(fontSize: 12, font: font)));
            widgets.add(pw.SizedBox(height: 4));
          }
        }
      }
    }

    return widgets;
  }
  
  /// Generate PDF from HTML with proper formatting and pagination.
  Future<File> _generatePdfFromHtml(String html, String languageName, String sessionId) async {
    final font = await _loadFont();
    final widgets = _parseHtmlToPdfWidgets(html, font);

    if (widgets.isEmpty) {
      throw Exception('No content to display in PDF.');
    }

    final pdf = pw.Document();

    // Add a cover/title page or include header on first page.
    // We'll use MultiPage to add all widgets with a header.
    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        header: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                'Lecture Translation - $languageName',
                style: pw.TextStyle(fontSize: 20, fontWeight: pw.FontWeight.bold, font: font),
              ),
              pw.SizedBox(height: 6),
              pw.Text(
                'Session ID: $sessionId',
                style: pw.TextStyle(fontSize: 10, color: PdfColors.grey, font: font),
              ),
              pw.Text(
                'Generated: ${DateTime.now().toLocal()}',
                style: pw.TextStyle(fontSize: 10, color: PdfColors.grey, font: font),
              ),
              pw.Divider(),
              pw.SizedBox(height: 10),
            ],
          );
        },
        // The body is the list of widgets (paragraphs, headings, etc.)
        build: (pw.Context context) => widgets,
      ),
    );

    final directory = await getTemporaryDirectory();
    final fileName = 'lecture_${sessionId.substring(0, 8)}_$languageName.pdf';
    final file = File('${directory.path}/$fileName');
    await file.writeAsBytes(await pdf.save());
    return file;
  }

  // ---------- Main fetch & share method ----------
  Future<void> _fetchAndSharePdf(String sessionId, String languageName) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(child: CircularProgressIndicator()),
    );

    try {
      final uri = Uri.parse('https://lecture-translator.kit.edu/get_cached_text/$sessionId')
          .replace(queryParameters: {'window': languageName});

      final response = await http.get(uri);
      developer.log('📡 URL: ${uri.toString()}');
      developer.log('📄 Status: ${response.statusCode}');
      developer.log('📄 Body length: ${response.body.length}');

      if (response.statusCode != 200) {
        throw Exception('Failed to fetch text: HTTP ${response.statusCode}');
      }

      final htmlContent = response.body.trim();
      if (htmlContent.isEmpty) {
        if (mounted) {
          Navigator.pop(context);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No cached text available for this language yet.'),
              backgroundColor: Colors.orange,
            ),
          );
        }
        return;
      }

      if (kDebugMode) {
        print('📄 Raw HTML first 500 chars: ${htmlContent.substring(0, htmlContent.length > 500 ? 500 : htmlContent.length)}');
      }

      // Generate PDF from HTML with formatting
      final pdfFile = await _generatePdfFromHtml(htmlContent, languageName, sessionId);

      if (mounted) {
        Navigator.pop(context); // dismiss loading

        final action = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('PDF Ready'),
            content: const Text('What would you like to do with the PDF?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'share'),
                child: const Text('Share'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'save'),
                child: const Text('Save to Device'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'cancel'),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );

        if (action == 'share') {
          await _sharePdf(pdfFile, languageName);
        } else if (action == 'save') {
          await _savePdfToDownloads(pdfFile, languageName);
        }
      }
    } catch (e) {
      if (mounted) {
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _sharePdf(File pdfFile, String languageName) async {
    await Share.shareXFiles(
      [XFile(pdfFile.path)],
      text: 'Lecture translation in $languageName',
      subject: 'Lecture Translation PDF',
    );
  }

  Future<void> _savePdfToDownloads(File pdfFile, String languageName) async {
    try {
      final downloadsDir = await getDownloadsDirectory();
      final fileName = 'lecture_${DateTime.now().millisecondsSinceEpoch}_$languageName.pdf';
      if (downloadsDir != null) {
        await pdfFile.copy('${downloadsDir.path}/$fileName');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('PDF saved to Downloads folder')),
          );
        }
      } else {
        final tempDir = await getTemporaryDirectory();
        await pdfFile.copy('${tempDir.path}/$fileName');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('PDF saved to ${tempDir.path}')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to save PDF: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  // ---------- Build ----------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.qr_code_scanner),
          onPressed: () => Navigator.pushNamed(context, '/scan'),
          tooltip: 'Scan New QR',
        ),
        title: _selectedIndices.isNotEmpty
            ? Text('${_selectedIndices.length} selected')
            : const Text('Select Session'),
        actions: [
          if (_selectedIndices.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: _deleteSelected,
              tooltip: 'Delete selected',
            ),
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: _showSettingsDialog,
            tooltip: 'Settings',
          ),
        ],
        bottom: _selectedIndices.isNotEmpty
            ? PreferredSize(
                preferredSize: const Size.fromHeight(48.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16.0),
                  alignment: Alignment.centerRight,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete),
                        onPressed: _deleteSelected,
                        tooltip: 'Delete selected',
                      ),
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert),
                        onSelected: (value) {
                          if (value == 'delete_all') _deleteAll();
                        },
                        itemBuilder: (context) => [
                          const PopupMenuItem<String>(
                            value: 'delete_all',
                            child: Text('Delete All'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final item = _history[index];
                    final isSelected = _selectedIndices.contains(index);
                    return ListTile(
                      leading: Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggleSelection(index),
                      ),
                      title: Text(
                        item.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(item.url, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 12)),
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
                            icon: const Icon(Icons.share, size: 20),
                            onPressed: () => _showLanguageDialog(item.url),
                            tooltip: 'Share as PDF',
                          ),
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
    );
  }

  Widget _buildEmptyState() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.history, size: 80, color: Colors.grey),
          SizedBox(height: 16),
          Text('No previous sessions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          SizedBox(height: 8),
          Text('Tap the QR scan icon in the top left to add a session.', style: TextStyle(color: Colors.grey)),
        ],
      ),
    );
  }
}

// ========== Settings Dialog Widget (unchanged) ==========
class _SettingsDialog extends StatefulWidget {
  final String initialTheme;
  final bool initialKeepOn;
  final Future<void> Function(String theme, bool keepOn) onSave;

  const _SettingsDialog({
    required this.initialTheme,
    required this.initialKeepOn,
    required this.onSave,
  });

  @override
  State<_SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<_SettingsDialog> {
  late String _tempTheme;
  late bool _tempKeepOn;
  String _appVersion = 'loading...';

  @override
  void initState() {
    super.initState();
    _tempTheme = widget.initialTheme;
    _tempKeepOn = widget.initialKeepOn;
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _appVersion = info.version);
    } catch (_) {
      if (mounted) setState(() => _appVersion = 'unknown');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Settings'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Theme', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'light', label: Text('Light')),
                ButtonSegment(value: 'dark', label: Text('Dark')),
                ButtonSegment(value: 'system', label: Text('System')),
              ],
              selected: {_tempTheme},
              onSelectionChanged: (Set<String> newSelection) {
                setState(() => _tempTheme = newSelection.first);
              },
            ),
            const SizedBox(height: 16),
            const Divider(),
            const Text('Device', style: TextStyle(fontWeight: FontWeight.bold)),
            SwitchListTile(
              title: const Text('Keep Screen On'),
              value: _tempKeepOn,
              onChanged: (value) => setState(() => _tempKeepOn = value),
            ),
            const Divider(),
            const SizedBox(height: 8),
            Center(
              child: Text('Version $_appVersion', style: const TextStyle(color: Colors.grey)),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ElevatedButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  Future<void> _save() async {
    await widget.onSave(_tempTheme, _tempKeepOn);
    if (mounted) Navigator.pop(context);
  }
}