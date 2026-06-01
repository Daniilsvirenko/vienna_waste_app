import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:image/image.dart' as img;
import 'package:flutter/services.dart' show rootBundle;
import 'app_colors.dart'; // Твой файл с цветами

// 🚀 МАКСИМАЛЬНАЯ ОПТИМИЗАЦИЯ: Функция вне класса для работы в Isolate
// Используем одномерный Float32List вместо List<List<List<List<double>>>>
// Это в несколько раз быстрее и требует меньше памяти.
Float32List processImageFast(Uint8List imageBytes) {
  img.Image? oriImage = img.decodeImage(imageBytes);
  if (oriImage == null) throw Exception('Failed to decode image');

  // Делаем квадратный кроп и сжимаем до 224x224
  int minLength = oriImage.width < oriImage.height ? oriImage.width : oriImage.height;
  int x = (oriImage.width - minLength) ~/ 2;
  int y = (oriImage.height - minLength) ~/ 2;
  img.Image croppedImage = img.copyCrop(oriImage, x: x, y: y, width: minLength, height: minLength);
  img.Image resizedImage = img.copyResize(croppedImage, width: 224, height: 224);

  // Создаем плоский массив на 150 528 элементов (1 * 224 * 224 * 3)
  var tensorInput = Float32List(1 * 224 * 224 * 3);
  int index = 0;
  for (int y = 0; y < 224; y++) {
    for (int x = 0; x < 224; x++) {
      var pixel = resizedImage.getPixel(x, y);
      tensorInput[index++] = pixel.r.toDouble();
      tensorInput[index++] = pixel.g.toDouble();
      tensorInput[index++] = pixel.b.toDouble();
    }
  }
  return tensorInput;
}

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

  String _resultText = 'Modell wird geladen...';
  String? _resultSubtitle;
  Color _resultColor = Colors.grey;
  String? _resultImage;
  bool _isAnalyzing = false;
  bool _isModelLoaded = false; // Блокировка UI до загрузки модели

  @override
  void initState() {
    super.initState();
    _initAI();
  }

  // ✅ Очистка памяти при закрытии
  @override
  void dispose() {
    _interpreter?.close();
    super.dispose();
  }

  // ✅ Инициализация с обработкой ошибок
  Future<void> _initAI() async {
    await _loadModel();
    await _loadLabels();
    
    if (_interpreter != null && _labels.isNotEmpty) {
      if (mounted) {
        setState(() {
          _isModelLoaded = true;
          _resultText = 'Müll fotografieren\noder aus Galerie wählen';
        });
      }
    } else {
      if (mounted) {
        setState(() {
          _resultText = 'Kritischer Fehler: AI nicht geladen.\nBitte App neu starten.';
          _resultColor = Colors.red;
        });
      }
    }
  }

  // ✅ Загружаем актуальную V3 модель
  Future<void> _loadModel() async {
    try {
      _interpreter = await Interpreter.fromAsset('assets/vienna_waste_model_V3.tflite');
    } catch (e) {
      debugPrint("Error loading model: $e");
    }
  }

  // ✅ Загружаем текстовый файл V3 (8 классов)
  Future<void> _loadLabels() async {
    try {
      final labelData = await rootBundle.loadString('assets/labels_v3.txt');
      _labels = labelData.split('\n').where((s) => s.trim().isNotEmpty).toList();
    } catch (e) {
      debugPrint("Error loading labels: $e");
    }
  }

  Future<void> pickImage(ImageSource source) async {
    // Защита: нельзя нажать, пока идет анализ или не загружена модель
    if (_isAnalyzing || !_isModelLoaded) return;

    // imageQuality: 85 ускорит загрузку тяжелых фото
    final pickedFile = await picker.pickImage(
      source: source,
      maxWidth: 400,
      maxHeight: 400,
      imageQuality: 85,
    );
    
    if (pickedFile != null) {
      setState(() {
        _image = File(pickedFile.path);
        _resultText = 'Foto wird analysiert...';
        _resultSubtitle = null;
        _resultImage = null;
        _resultColor = Colors.grey;
        _isAnalyzing = true;
      });

      await Future.delayed(const Duration(milliseconds: 100)); // Даем UI отрисоваться
      _classifyImage(_image!);
    }
  }

  Future<void> _classifyImage(File imageFile) async {
    if (_interpreter == null || _labels.isEmpty) return;

    try {
      var imageBytes = await imageFile.readAsBytes();

      // Отправляем конвертацию в фон
      var flatInput = await Isolate.run(() => processImageFast(imageBytes));
      // Формируем нужную размерность для TFLite
      var input = flatInput.reshape([1, 224, 224, 3]);

      // ✅ ИСПРАВЛЕНИЕ: Выделяем память ровно под 8 классов модели V3!
      var output = List.generate(1, (_) => List.filled(8, 0.0));

      _interpreter!.run(input, output);

      List<double> probabilities = output[0].cast<double>();
      int maxIndex = 0;
      double maxProb = probabilities[0];
      for (int i = 1; i < probabilities.length; i++) {
        if (probabilities[i] > maxProb) {
          maxProb = probabilities[i];
          maxIndex = i;
        }
      }

      if (!mounted) return;
      _applyViennaRules(_labels[maxIndex], maxProb);
    } catch (e) {
      debugPrint('Error in classification: $e');
      if (!mounted) return;
      setState(() {
        _isAnalyzing = false;
        _resultText = 'Fehler bei Analyse';
        _resultColor = Colors.red;
      });
    }
  }

  void _applyViennaRules(String category, double probability) {
    setState(() {
      _isAnalyzing = false;

      // Улучшенная подсказка при низкой уверенности ИИ
      if (probability < 0.6) {
        String hint = "Bitte näher fotografieren.";
        if (probability > 0.45) {
          hint = "Ziemlich unsicher. Versuchen Sie, das Objekt um 90 Grad zu drehen oder das Licht zu verbessern.";
        }
        _resultText = 'Nicht sicher (${(probability * 100).toStringAsFixed(0)}%).\n$hint';
        _resultSubtitle = null;
        _resultColor = Colors.orange;
        _resultImage = null;
        return;
      }

      // ✅ Добавлены новые классы V3: Papier_Rollen и Metall
      switch (category.trim()) {
        case 'Altpapier':
        case 'Papier_Rollen':
          _resultText = 'Altpapier / Karton!';
          _resultSubtitle = 'AUSNAHMEN:\nTetra Paks -> Gelbe Tonne\nSchmutziger Karton (Pizza) -> Restmüll';
          _resultColor = Colors.red;
          _resultImage = 'assets/images/AltpapierTonne.png';
          
          // Вызов контекстной подсказки (интерактивность)
          Future.delayed(const Duration(milliseconds: 600), () {
            if (mounted) _showDirtyPaperWarning();
          });
          break;
        case 'Plastik_Rigid':
        case 'Plastik_Soft':
        case 'Metall':
          _resultText = 'Gelbe Tonne';
          _resultSubtitle = 'Plastik & Metallverpackungen';
          _resultColor = Colors.amber;
          _resultImage = 'assets/images/gelbeTonne.png';
          break;
        case 'Biomuell':
          _resultText = 'Biomüll!';
          _resultSubtitle = null;
          _resultColor = Colors.brown;
          _resultImage = 'assets/images/Biomuelltonne.png';
          break;
        case 'Restmuell':
          _resultText = 'Restmüll!';
          _resultSubtitle = null;
          _resultColor = Colors.black87;
          _resultImage = 'assets/images/Restmuelltonne.png';
          break;
        case 'Glas':
          _resultText = 'Altglas';
          _resultSubtitle = 'Unterscheidung zwischen Bunt- und Weißglas!';
          _resultColor = Colors.teal;
          _resultImage = 'assets/images/Altglascontainer.png';
          break;
        default:
          _resultText = 'Nicht erkannt';
          _resultSubtitle = null;
          _resultColor = Colors.grey;
          _resultImage = null;
      }
    });
  }

  // Фильтр для предотвращения попадания грязной коробки пиццы в бумагу
  void _showDirtyPaperWarning() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('⚠️ Kurze Frage', textAlign: TextAlign.center),
        content: const Text(
          'Hat das Papier oder der Karton Speisereste, Öl oder starken Schmutz (z.B. benutzte Pizzakartons)?',
          style: TextStyle(fontSize: 16),
          textAlign: TextAlign.center,
        ),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.black87),
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _resultText = 'Restmüll!';
                _resultSubtitle = 'Schmutziges Papier darf nicht recycelt werden.';
                _resultColor = Colors.black87;
                _resultImage = 'assets/images/Restmuelltonne.png';
              });
            },
            child: const Text('Ja (Schmutzig)', style: TextStyle(color: Colors.white)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(context),
            child: const Text('Nein (Sauber)', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
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
                    '2. Das Objekt mittig platzieren\n'
                    '3. Neutralen Hintergrund wählen\n'
                    '4. Nah genug herangehen\n\n',
              ),
              TextSpan(
                text: 'Hinweis zur KI:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              TextSpan(
                text: '\nGreenLens kann Fehler machen. Im Zweifelsfall gelten die offiziellen Trennregeln der Stadt Wien. Sondermüll- oder Problemstoffe werden nicht von der KI unterstützt!',
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

  void _showESBNDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
        title: const Text('ESBN', textAlign: TextAlign.center),
        content: const Text('ESBN (Barcode-Scan wird bald hinzugefügt)', textAlign: TextAlign.center),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK', style: TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
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
                          padding: const EdgeInsets.all(40),
                          child: Image.asset('assets/images/logo_greenlens.png', fit: BoxFit.contain),
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
                      : Column(
                          children: [
                            if (_resultImage != null)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12.0),
                                child: Image.asset(_resultImage!, height: 80, fit: BoxFit.contain),
                              ),
                            Text(
                              _resultText,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                                color: _resultColor == Colors.amber
                                    ? Colors.orange[800]
                                    : _resultColor == Colors.grey
                                        ? Colors.black87
                                        : _resultColor,
                                height: 1.2,
                              ),
                            ),
                            if (_resultSubtitle != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 8.0),
                                child: Text(
                                  _resultSubtitle!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.normal,
                                    color: Colors.black87,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                          ],
                        ),
                ),
              ),
              const SizedBox(height: 120),
            ],
          ),
        ),
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            Expanded(
              child: FloatingActionButton.extended(
                heroTag: "ean_btn",
                onPressed: (_isAnalyzing || !_isModelLoaded) ? null : _showESBNDialog,
                elevation: (_isAnalyzing || !_isModelLoaded) ? 0 : 6,
                icon: const Icon(Icons.qr_code_scanner),
                label: const Text('ESBN', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                backgroundColor: (_isAnalyzing || !_isModelLoaded) ? Colors.grey.shade400 : AppColors.greenLensBlack,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FloatingActionButton.extended(
                heroTag: "camera_btn",
                onPressed: (_isAnalyzing || !_isModelLoaded) ? null : () => pickImage(ImageSource.camera),
                elevation: (_isAnalyzing || !_isModelLoaded) ? 0 : 6,
                icon: const Icon(Icons.camera_alt),
                label: const Text('Kamera', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                backgroundColor: (_isAnalyzing || !_isModelLoaded) ? Colors.grey.shade400 : AppColors.darkGreen,
                foregroundColor: Colors.white,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FloatingActionButton.extended(
                heroTag: "gallery_btn",
                onPressed: (_isAnalyzing || !_isModelLoaded) ? null : () => pickImage(ImageSource.gallery),
                elevation: (_isAnalyzing || !_isModelLoaded) ? 0 : 6,
                icon: const Icon(Icons.photo_library),
                label: const Text('Galerie', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                backgroundColor: (_isAnalyzing || !_isModelLoaded) ? Colors.grey.shade400 : AppColors.greenLensBlack,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
    );
  }
}

// -------------------------------------------------------------
// Дальше идет неизменный код экрана WasteInfoScreen
// -------------------------------------------------------------

class WasteInfoScreen extends StatelessWidget {
  const WasteInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> bins = [
      {
        'title': 'Gelbe Tonne',
        'color': Colors.amber,
        'image': 'assets/images/gelbeTonne.png',
        'info': 'Für die Gelbe Tonne geeignet:\n'
            '• Plastikflaschen (z. B. Speiseöl, Essig, Milchprodukte, Waschmittel, Körperpflege)\n'
            '• Metallverpackungen (z. B. Konservendosen)\n'
            '• Getränkeflaschen und -dosen ohne Pfandlogo\n'
            '• Getränkekartons (Tetra Pak)\n'
            '• Joghurtbecher\n'
            '• Folien bzw. Luftpolsterfolien\n'
            '• (Tiefzieh-)Schalen/Trays (z. B. für Obst, Gemüse, Takeaway)\n'
            '• Einweggeschirr und -besteck\n'
            '• Kaffeebecher\n'
            '• Menüschalen aus Metall (z. B. für Fertiggerichte)\n'
            '• Verschlüsse und Deckel von Gläsern, Flaschen und Tuben\n'
            '• Sonstige Verpackungen (außer Glas/Papier)\n\n'
            'Nicht geeignet:\n'
            '• Spielzeug, Gießkannen\n'
            '• Stark verschmutzte Verpackungen (Restmüll)\n'
            '• Nichtverpackungs-Kunststoffe\n'
            '• Altpapier- und Glasverpackungen\n\n'
            'Auf den Mistplatz gehören:\n'
            '• Große Verpackungen, Kanister, große Folien/Styroporteile\n'
            '• Holz, Textilien, sperrige Metallteile\n'
            '• Haushalts- und Elektrogeräte\n\n'
            'Problemstoffsammlung:\n'
            '• Motorölflaschen, medizinische Kunststoffe\n'
            '• Lack-, Spray- und Öldosen',
      },
      {
        'title': 'Altpapier',
        'color': Colors.red,
        'image': 'assets/images/AltpapierTonne.png',
        'info': 'Für den Altpapier-Behälter geeignet:\n'
            '• Zeitungen, Illustrierte, Kataloge, Prospekte\n'
            '• Schreibpapier, Kuverts (mit und ohne Sichtfenster)\n'
            '• Hefte, Telefonbücher\n'
            '• Unbeschichtete Tiefkühlkartons\n'
            '• Wellpappe\n'
            '• Papiersäcke, Kartonagen, Schachteln (bitte entfalten)\n'
            '• Bücher (Mistplatz-Tipp: 48er-Tandler-Box)\n\n'
            'Nicht geeignet für den Altpapier-Behälter:\n'
            '• Milch- und Getränke-Verbundverpackungen (Tetra Paks) muss in die Gelbe Tonne\n'
            '• Kohle-, Durchschlag- und Thermopapier kommt in den Restmüll\n'
            '• Taschentücher, Papierhandtücher, Feuchttücher und Küchenrolle kommt in den Restmüll\n'
            '• Stark verschmutztes Papier kommt in den Restmüll\n'
            '• Beschichtete Kartonverpackungen kommt in den Restmüll\n'
            '• Große Kartonagen muss zum Mistplatz',
      },
      {
        'title': 'Biomüll',
        'color': Colors.brown,
        'image': 'assets/images/Biomuelltonne.png',
        'info': 'Für die Biotonne geeignet:\n'
            '• Aus dem Garten: Rasenschnitt, Laub, Baum- und Strauchschnitt (bis 8 cm), Ernterückstände, Stauden, Fallobst, Wasserpflanzen\n'
            '• Aus Küche und Haus: ungewürzte und ungekochte Obst- und Gemüseabfälle, Tee- und Kaffeesud\n'
            '• Grundsätzlich gilt: Nur Abfälle, die auch kompostiert werden können.\n'
            '• WICHTIG: Biogene Abfälle bitte OHNE Plastiksackerl (auch kein "Bio-Plastik") einwerfen!\n\n'
            'Nicht geeignet für die Biotonne:\n'
            '• Restmüll: Fleisch, Knochen, Eier, Milchprodukte, Speisereste, Windeln, Staubsaugerbeutel, Katzenstreu, gekochte/gewürzte Speisen\n'
            '• Gelbe Tonne: Verpackungen, Plastiksackerl, Bio-Plastik\n'
            '• Mistplatz: Erde, große Mengen Grünschnitt, Wurzelstöcke, Äste > 8 cm, behandeltes Holz\n'
            '• Problemstoffsammlung: Altöle, Batterien, Chemikalien, Lacke, Medikamente',
      },
      {
        'title': 'Restmüll',
        'color': Colors.black87,
        'image': 'assets/images/Restmuelltonne.png',
        'info': 'Für den Restmüll-Behälter geeignet:\n'
            '• Abfälle ohne gefährliche Inhaltsstoffe, die nicht verwertet werden können\n'
            '• Beispiele: Windeln, Zahnpasta-Tuben, Schwämme, Staubsaugerbeutel, verschmutztes Papier, Zigarettenstummel, Kehricht\n\n'
            'Nicht geeignet für den Restmüll-Behälter:\n'
            '• Mistplatz: Holz, Reifen, Elektrogeräte, Kartonagen, Styropor, Bauschutt, Sperrmüll\n'
            '• Problemstoffsammlung: Farben, Lacke, Batterien, CDs/DVDs, Speiseöle, Elektrokleingeräte (Handys, elektrische Zahnbürsten)\n'
            '• Handel: Mehrwegflaschen und -kisten',
      },
      {
        'title': 'Altglas',
        'color': Colors.teal,
        'image': 'assets/images/Altglascontainer.png',
        'info': ' Die Altglassammlung erfolgt zum Großteil mit lärmgedämmten Behältern. Diese bestehen aus 2 voneinander getrennten Kammern für Weiß- und Buntglas.\n\n'
            'Für den Weißglas-Behälter geeignet:\n'
            '• Ungefärbte Einwegflaschen, Konservengläser\n'
            '• Ungefärbte Kondensmilch- und Limonadenflaschen\n'
            '• Ungefärbte Wein- und Spirituosenflaschen\n'
            '• Ungefärbte Glasflakons\n'
            '• (Zeichen: grauer Kreis, MA 48 Icon)\n\n'
            'Für den Weißglas-Behälter nicht geeignet:\n'
            '• Buntglas: (auch leicht) eingefärbte Verpackungsgläser\n'
            '• Schraubverschlüsse und Korken\n\n'
            'Für den Buntglas-Behälter geeignet:\n'
            '• Gefärbte Einwegflaschen, Konservengläser\n'
            '• Gefärbte Wein-, Spirituosen- und Limonadenflaschen\n'
            '• Auch leicht eingefärbtes Glas ist Buntglas\n'
            '• (Zeichen: grüner Kreis, MA 48 Icon)\n\n'
            'Für den Buntglas-Behälter nicht geeignet:\n'
            '• Weißglas: ungefärbtes Glas\n'
            '• Schraubverschlüsse und Korken\n\n'
            'Für beide Altglas-Behälter nicht geeignet:\n'
            '• Restmüll: Geschirr, Vasen, Porzellan, Keramik, Trinkgläser, Glühbirnen, Korken\n'
            '• Mistplatz: Fenster-, Flach-, Drahtglas, Spiegel, Aquarienglas\n'
            '• Problemstoffsammlung: Glasgebinde mit giftigem Inhalt (Lacke, Lösungsmittel)\n'
            '• Altstoffsammlung: Leichtverpackungen, Schraubverschlüsse, Kapseln',
      },
    ];

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'Infoguide: Wiener Tonnen',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        backgroundColor: AppColors.darkGreen,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          children: [
            Row(
              children: [
                Expanded(child: _buildBinTile(context, bins[0])),
                const SizedBox(width: 16),
                Expanded(child: _buildBinTile(context, bins[1])),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(child: _buildBinTile(context, bins[2])),
                const SizedBox(width: 16),
                Expanded(child: _buildBinTile(context, bins[3])),
              ],
            ),
            const SizedBox(height: 16),
            _buildBinTile(context, bins[4], isWide: true),
          ],
        ),
      ),
    );
  }

  Widget _buildBinTile(BuildContext context, Map<String, dynamic> bin, {bool isWide = false}) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => WasteDetailScreen(
              title: bin['title'],
              color: bin['color'],
              info: bin['info'],
              imagePath: bin['image'],
            ),
          ),
        );
      },
      child: Container(
        height: 150,
        width: isWide ? double.infinity : null,
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            bin.containsKey('image')
                ? Image.asset(bin['image'], height: 60, fit: BoxFit.contain)
                : Icon(bin['icon'], size: 50, color: bin['color']),
            const SizedBox(height: 8),
            Text(
              bin['title'],
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: bin['color'] == Colors.amber ? AppColors.gelbeTonneGelb : bin['color'],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WasteDetailScreen extends StatelessWidget {
  final String title;
  final Color color;
  final String info;
  final String? imagePath;

  const WasteDetailScreen({
    super.key,
    required this.title,
    required this.color,
    required this.info,
    this.imagePath,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        backgroundColor: color,
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (imagePath != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 24.0),
                  child: Image.asset(imagePath!, height: 200, fit: BoxFit.contain),
                ),
              ),
            Text(
              'Was gehört hier hinein?',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: color),
            ),
            const SizedBox(height: 16),
            Text.rich(
              TextSpan(
                children: _buildInfoSpans(info),
                style: const TextStyle(fontSize: 18, height: 1.5, color: Colors.black87),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<TextSpan> _buildInfoSpans(String text) {
    List<TextSpan> spans = [];
    final lines = text.split('\n');
    for (int i = 0; i < lines.length; i++) {
      String line = lines[i];
      bool isHeader = line.trim().endsWith(':');
      spans.add(
        TextSpan(
          text: line + (i < lines.length - 1 ? '\n' : ''),
          style: TextStyle(
            fontWeight: isHeader ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      );
    }
    return spans;
  }
}
