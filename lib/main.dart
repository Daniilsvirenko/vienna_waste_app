import 'dart:io';
import 'dart:isolate';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart' show rootBundle;

void main() {
  runApp(const ViennaWasteApp());
}

class ViennaWasteApp extends StatelessWidget {
  const ViennaWasteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mülltrennung Wien',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        useMaterial3: true,
      ),
      home: const TrashSorterScreen(),
    );
  }
}

class TrashSorterScreen extends StatefulWidget {
  const TrashSorterScreen({super.key});

  @override
  State<TrashSorterScreen> createState() => _TrashSorterScreenState();
}

class _TrashSorterScreenState extends State<TrashSorterScreen> {
  File? _image;
  final picker = ImagePicker();
  Interpreter? _interpreter;
  List<String> _labels = [];
  
  String _resultText = 'Müll fotografieren\noder aus Galerie wählen'; 
  Color _resultColor = Colors.grey;
  bool _isAnalyzing = false;

  @override
  void initState() {
    super.initState();
    _loadModel();
    _loadLabels();
  }

  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/vienna_waste_model_PRO.tflite');
    } catch (e) {
      debugPrint("Error loading model: $e");
    }
  }

  Future<void> _loadLabels() async {
    try {
      final labelData = await rootBundle.loadString('assets/labels.txt');
      _labels = labelData.split('\n').where((s) => s.isNotEmpty).toList();
    } catch (e) {
      debugPrint("Error loading labels: $e");
    }
  }

  // ИЗМЕНЕНИЕ 1: Теперь функция принимает источник (Камера или Галерея)
  Future<void> pickImage(ImageSource source) async {
    if (_isAnalyzing) return;

    final pickedFile = await picker.pickImage(
      source: source,
      maxWidth: 400, // Модели нужно 224, поэтому 400 будет более чем достаточно
      maxHeight: 400,
    );
    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _resultText = 'Foto wird analysiert...'; 
        _resultColor = Colors.grey;
        _isAnalyzing = true;
      });
      
      await Future.delayed(const Duration(milliseconds: 100)); 
      _classifyImage(_image!);
    }
  }

  Future<void> _classifyImage(File imageFile) async {
    if (_interpreter == null || _labels.isEmpty) return;

    var imageBytes = await imageFile.readAsBytes();

    var input = await Isolate.run(() {
      img.Image? oriImage = img.decodeImage(imageBytes);
      img.Image resizedImage = img.copyResize(oriImage!, width: 224, height: 224);

      var tensorInput = List.generate(1, (i) => List.generate(224, (j) => List.generate(224, (k) => List.generate(3, (l) => 0.0))));
      for (int y = 0; y < 224; y++) {
        for (int x = 0; x < 224; x++) {
          var pixel = resizedImage.getPixel(x, y);
          tensorInput[0][y][x][0] = pixel.r.toDouble();
          tensorInput[0][y][x][1] = pixel.g.toDouble();
          tensorInput[0][y][x][2] = pixel.b.toDouble();
        }
      }
      return tensorInput;
    });

    var output = List.filled(1 * 5, 0.0).reshape([1, 5]);

    _interpreter!.run(input, output);

    List<double> probabilities = (output[0] as List).cast<double>();
    int maxIndex = 0;
    double maxProb = probabilities[0];
    for (int i = 1; i < probabilities.length; i++) {
      if (probabilities[i] > maxProb) {
        maxProb = probabilities[i];
        maxIndex = i;
      }
    }

    _applyViennaRules(_labels[maxIndex], maxProb);
  }

  void _applyViennaRules(String category, double probability) {
    setState(() {
      _isAnalyzing = false;

      if (probability < 0.6) {
        _resultText = 'Nicht sicher (${(probability*100).toStringAsFixed(0)}%).\nBitte näher fotografieren.';
        _resultColor = Colors.grey;
        return;
      }

      switch (category.trim()) {
        case 'Altpapier':
          // ИЗМЕНЕНИЕ 2: Добавили подсказки про Тетра Пак и грязный картон
          _resultText = 'Altpapier / Karton!\n🔴 Rote Tonne\n\n⚠️ AUSNAHMEN:\nTetra Paks ➡️ 🟡 Gelbe Tonne\nSchmutziger Karton (Pizza) ➡️ ⚫ Restmüll';
          _resultColor = Colors.red;
          break;
        case 'Plastik_Dosen':
          _resultText = 'Plastik / Metall!\n🟡 Gelbe Tonne';
          _resultColor = Colors.amber;
          break;
        case 'Biomuell':
          _resultText = 'Biomüll!\n🟤 Braune Tonne';
          _resultColor = Colors.brown;
          break;
        case 'Restmuell':
          _resultText = 'Restmüll!\n⚫ Schwarze Tonne';
          _resultColor = Colors.black87;
          break;
        case 'Glas':
          _resultText = 'Glas!\n🟢 Buntglas - Grüne Tonne\n⚪ Weißglas - Weiße Tonne';
          _resultColor = Colors.teal;
          break;
        default:
          _resultText = 'Nicht erkannt';
          _resultColor = Colors.grey;
      }
    });
  }

  void _showInstructions() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('💡 Tipps & Wien Regeln', textAlign: TextAlign.center),
        content: const Text(
          '1. Das Objekt in die Mitte legen.\n'
          '2. Neutralen Hintergrund wählen.\n'
          '3. Nah genug herangehen.\n\n'
          '⚠️ HINWEIS ZUR KI:\n'
          'Die KI kann weiche Folien (z.B. Chipstüten) oder Tetra Paks manchmal mit Papier verwechseln. Beachte immer die Warnhinweise!',
          style: TextStyle(fontSize: 15, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Verstanden', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50], 
      appBar: AppBar(
        title: const Text('Mülltrennung Wien', style: TextStyle(fontWeight: FontWeight.bold)),
        centerTitle: true,
        backgroundColor: Colors.green.shade200,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline, size: 28),
            onPressed: _showInstructions,
            tooltip: 'Anleitung',
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Card(
                elevation: 10,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: _image != null
                      ? Image.file(_image!, height: 320, width: 320, fit: BoxFit.cover)
                      : Container(
                          height: 320, width: 320,
                          color: Colors.white,
                          child: const Icon(Icons.delete_outline, size: 100, color: Colors.grey),
                        ),
                ),
              ),
              const SizedBox(height: 30),
              
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.all(25),
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: _resultColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _resultColor.withValues(alpha: 0.5), width: 2),
                    boxShadow: [
                      BoxShadow(color: Colors.white.withValues(alpha: 0.8), blurRadius: 10, spreadRadius: 2)
                    ]
                  ),
                  child: _isAnalyzing 
                    ? const Center(child: CircularProgressIndicator(color: Colors.green))
                    : Text(
                        _resultText,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 20, // Чуть уменьшили шрифт, чтобы влез длинный текст
                          fontWeight: FontWeight.bold, 
                          color: _resultColor == Colors.amber ? Colors.orange[800] : 
                                 _resultColor == Colors.grey ? Colors.black87 : _resultColor,
                          height: 1.4,
                        ),
                      ),
                ),
              ),
              const SizedBox(height: 120), // Сделали отступ побольше для двух кнопок
            ],
          ),
        ),
      ),
      // ИЗМЕНЕНИЕ 3: Две кнопки (Камера и Галерея) в ряд
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            FloatingActionButton.extended(
              heroTag: "camera_btn", // Важно для Flutter, чтобы анимации кнопок не конфликтовали
              onPressed: _isAnalyzing ? null : () => pickImage(ImageSource.camera),
              elevation: _isAnalyzing ? 0 : 6,
              icon: const Icon(Icons.camera_alt),
              label: const Text('Kamera', style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: _isAnalyzing ? Colors.grey.shade400 : Colors.green.shade600,
              foregroundColor: Colors.white,
            ),
            FloatingActionButton.extended(
              heroTag: "gallery_btn",
              onPressed: _isAnalyzing ? null : () => pickImage(ImageSource.gallery),
              elevation: _isAnalyzing ? 0 : 6,
              icon: const Icon(Icons.photo_library),
              label: const Text('Galerie', style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: _isAnalyzing ? Colors.grey.shade400 : Colors.blue.shade600,
              foregroundColor: Colors.white,
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}