import 'dart:io';
import 'dart:isolate';
import "package:flutter/material.dart";
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart' show rootBundle;
import 'app_colors.dart';

void main() {
  runApp(const ViennaWasteApp());
}

class ViennaWasteApp extends StatelessWidget {
  const ViennaWasteApp({super.key});
  static const Color darkGreen = Color(0xFF468044);
  static const Color darkGreen2 = Color(0xFF339966);
  static const Color lightGreen = Color(0xFFCCDED0);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GreenLens Wien',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.orange,
        ),
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
      _interpreter = await Interpreter.fromAsset('assets/vienna_waste_model_V2.tflite');
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

  Future<void> pickImage(ImageSource source) async {
    if (_isAnalyzing) return;

    final pickedFile = await picker.pickImage(source: source);
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

    var output = List.filled(1 * 6, 0.0).reshape([1, 6]);

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
        _resultText = 'Nicht sicher (${(probability * 100).toStringAsFixed(0)}%).\nBitte näher fotografieren.';
        _resultColor = Colors.grey;
        return;
      }

      switch (category.trim()) {
        case 'Altpapier':
          _resultText = 'Altpapier / Karton!\n🔴 Rote Tonne\n\n⚠️ AUSNAHMEN:\nTetra Paks ➡️ 🟡 Gelbe Tonne\nSchmutziger Karton (Pizza) ➡️ ⚫ Restmüll';
          _resultColor = Colors.red;
          break;
        case 'Plastik_Rigid':
        case 'Plastik_Soft':
          _resultText = 'Plastik!\n🟡 Gelbe Tonne';
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
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('Tipps & Hinweise', textAlign: TextAlign.center),
        content: const Text.rich(
          TextSpan(
            style: TextStyle(fontSize: 15, height: 1.4),
            children: [
              TextSpan(
                text: '1. Nur ein Objekt pro Bild\n'
                    '2. Das Objekt in die Mitte legen\n'
                    '3. Neutralen Hintergrund wählen\n'
                    '4. Nah genug herangehen\n\n',
              ),
              TextSpan(
                text: 'HINWEIS ZUR KI:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              TextSpan(
                text: '\nGreenLens kann Fehler machen. Im Zweifelsfall gelten die offiziellen Trennregeln der Stadt Wien. Sondermüll- oder Problemstoffe'
                    ' werden nicht von der KI unterstützt!',
              ),
            ],
          ),
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
        title: const Text(
          'GreenLens Wien',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        centerTitle: false,
        backgroundColor: AppColors.darkGreen,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.library_books_outlined, size: 28),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const WasteInfoScreen()),
              );
            },
            tooltip: 'Infoguide: Wiener Tonnen',
            color: Colors.white,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, size: 28),
            onPressed: _showInstructions,
            tooltip: 'Anleitung',
            color: Colors.white,
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
                    ],
                  ),
                  child: _isAnalyzing
                      ? const Center(child: CircularProgressIndicator(color: Colors.green))
                      : Text(
                          _resultText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: _resultColor == Colors.amber
                                ? Colors.orange[800]
                                : _resultColor == Colors.grey
                                    ? Colors.black87
                                    : _resultColor,
                            height: 1.4,
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 120),
            ],
          ),
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            FloatingActionButton.extended(
              heroTag: "camera_btn",
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

class WasteInfoScreen extends StatelessWidget {
  const WasteInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Mülltrennung Info',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.darkGreen,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(20.0),
          child: Text(
            'Mülltrennung info',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
            textAlign: TextAlign.center,
          ),
        ),
      ),
    );
  }
}
