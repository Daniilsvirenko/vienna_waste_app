import 'dart:io';
import 'package:flutter/material.dart';
import 'database_helper.dart';
import 'app_colors.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<Map<String, dynamic>> _history = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    final data = await DatabaseHelper().queryAllScans();
    setState(() {
      _history = data;
      _isLoading = false;
    });
  }

  Future<void> _deleteEntry(int id) async {
    await DatabaseHelper().deleteScan(id);
    _loadHistory();
  }

  void _showImageDialog(String imagePath) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.all(20),
        child: GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Image.file(
                  File(imagePath),
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 15),
              const Text(
                'Tippen zum Schließen',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getCategoryColor(String category) {
    switch (category) {
      case 'Altpapier':
        return Colors.red;
      case 'Gelbe Tonne':
        return AppColors.gelbeTonneGelb;
      case 'Biomüll':
        return Colors.brown;
      case 'Restmüll':
        return Colors.black87;
      case 'Altglas':
        return Colors.teal;
      default:
        return Colors.black87;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text('Scan-Verlauf', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.darkGreen,
        iconTheme: const IconThemeData(color: Colors.white),
        actions: [
          if (_history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep),
              onPressed: () => _showClearDialog(),
              tooltip: 'Verlauf leeren',
            ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? const Center(
                  child: Text(
                    'Noch keine Scans vorhanden.',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _history.length,
                  itemBuilder: (context, index) {
                    final item = _history[index];
                    return Container(
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: Colors.black12, width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(12),
                        leading: GestureDetector(
                          onTap: () => _showImageDialog(item['imagePath']),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: Image.file(
                              File(item['imagePath']),
                              width: 65,
                              height: 65,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) =>
                                  const Icon(Icons.broken_image, size: 60, color: Colors.grey),
                            ),
                          ),
                        ),
                        title: Text(
                          item['category'],
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: _getCategoryColor(item['category']),
                          ),
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 4),
                            Text(
                              'Sicherheit: ${(item['probability'] * 100).toStringAsFixed(1)}%',
                              style: TextStyle(color: Colors.grey[700]),
                            ),
                            Text(
                              item['timestamp'].toString().substring(0, 16).replaceAll('T', ' '),
                              style: const TextStyle(fontSize: 12, color: Colors.grey),
                            ),
                          ],
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, color: Colors.black),
                          onPressed: () => _deleteEntry(item['id']),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  void _showClearDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Verlauf leeren?', textAlign: TextAlign.center),
        content: const Text(
          'Möchten Sie wirklich alle Einträge aus dem Verlauf löschen?',
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Abbrechen', style: TextStyle(color: Colors.grey, fontWeight: FontWeight.bold)),
          ),
          TextButton(
            onPressed: () async {
              await DatabaseHelper().clearHistory();
              Navigator.pop(context);
              _loadHistory();
            },
            child: const Text('Löschen', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }
}
