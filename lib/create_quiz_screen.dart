import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:archive/archive_io.dart';
import 'package:xml/xml.dart';
import 'dart:convert';

// ─────────────────────────────────────────────────────────────────────────────
// Bold-option marker
// ─────────────────────────────────────────────────────────────────────────────
// When we read a DOCX, we prefix any paragraph whose text is mostly bold with
// this control character before handing it to the parser. It's used to tell
// _BulkParser "the instructor marked this option as the correct answer by
// bolding it" — the character is invisible, never typed by a person, and is
// stripped back out before the text is shown anywhere.
const String _kBoldMarker = '\u0007';

// ─────────────────────────────────────────────────────────────────────────────
// Curriculum data
// ─────────────────────────────────────────────────────────────────────────────

class _Subject {
  final String code;
  final String description;
  const _Subject(this.code, this.description);
}

class _YearCurriculum {
  final String yearLabel;
  final List<_Subject> sem1;
  final List<_Subject> sem2;
  const _YearCurriculum({
    required this.yearLabel,
    required this.sem1,
    required this.sem2,
  });
}

const _curriculum = [
  _YearCurriculum(
    yearLabel: '1st Year',
    sem1: [
      _Subject('CRIM 1', 'Introduction to Criminology'),
    ],
    sem2: [
      _Subject('CLJ 1', 'Introduction to Phil. Criminal Justice System'),
      _Subject('LEA 1', 'Law Enforcement Organization and Administration'),
    ],
  ),
  _YearCurriculum(
    yearLabel: '2nd Year',
    sem1: [
      _Subject('ADGE', 'General Chemistry (Organic)'),
      _Subject('CA 1', 'Institutional Corrections'),
      _Subject('CDI 1', 'Fundamentals of Investigation and Intelligence'),
      _Subject('CLJ 2', 'Human Rights Education'),
      _Subject('CRIM 2', 'Theories of Crime Causation'),
      _Subject('LEA 2', 'Comparative Models in Policing'),
    ],
    sem2: [
      _Subject('CDI 2', 'Specialized Crime Investigation 1 with Legal Medicine'),
      _Subject('CFLM 1', 'Character Formation, Nationalism and Patriotism'),
      _Subject('CLJ 3', 'Criminal Law (Book 1)'),
      _Subject('CRIM 3', 'Human Behavior and Victimology'),
      _Subject('FORENSIC 1', 'Forensic Photography'),
      _Subject('FORENSIC 2', 'Personal Identification Techniques'),
      _Subject('LEA 3', 'Introduction to Industrial Security Concepts'),
    ],
  ),
  _YearCurriculum(
    yearLabel: '3rd Year',
    sem1: [
      _Subject('CA 2', 'Non-Institutional Corrections'),
      _Subject('CDI 3', 'Specialized Crime Investigation 2 with Simulation on Interrogation and Interview'),
      _Subject('CDI 4', 'Traffic Management and Accident Investigation with Driving'),
      _Subject('CDI 5', 'Technical English 1 (Technical Report Writing and Presentation)'),
      _Subject('CFLM 2', 'Character Formation with Leadership, Decision Making, Management and Administration'),
      _Subject('CLJ 4', 'Criminal Law (Book 2)'),
      _Subject('FORENSIC 3', 'Forensic Chemistry and Toxicology'),
      _Subject('FORENSIC 4', 'Questioned Documents Examination'),
      _Subject('LEA 4', 'Law Enforcement Operations and Planning with Crime Mapping'),
    ],
    sem2: [
      _Subject('CA 3', 'Therapeutic Modalities'),
      _Subject('CDI 6', 'Fire Protection and Arson Investigation'),
      _Subject('CDI 7', 'Vice and Drug Education and Control'),
      _Subject('CLJ 5', 'Evidence'),
      _Subject('CRIM 4', 'Professional Conduct and Ethical Standards'),
      _Subject('CRIM 5', 'Juvenile Delinquency and Juvenile Justice System'),
      _Subject('CRIM 6', 'Dispute Resolution and Crises/Incidents Management'),
      _Subject('CRIM 7', 'Criminological Research 1 (Research Methods with Applied Statistics)'),
      _Subject('FORENSIC 5', 'Lie Detection Techniques'),
      _Subject('FORENSIC 6', 'Forensic Ballistics'),
    ],
  ),
  _YearCurriculum(
    yearLabel: '4th Year',
    sem1: [
      _Subject('CDI 8', 'Technical English 2 (Legal Forms)'),
      _Subject('CDI 9', 'Introduction to Cybercrime and Environmental Laws and Protection'),
      _Subject('CLJ 6', 'Criminal Procedure and Court Testimony'),
      _Subject('CP 1', 'Internship (On-the-Job Training 1)'),
      _Subject('CRIM 8', 'Criminological Research 2 (Thesis Writing and Presentation)'),
    ],
    sem2: [
      _Subject('CP 2', 'Internship (On-the-Job Training 2)'),
      _Subject('ICRIM RC', 'Criminology Refresher Course'),
    ],
  ),
];

// ─────────────────────────────────────────────────────────────────────────────
// _QuestionData — Multiple Choice only
// ─────────────────────────────────────────────────────────────────────────────

class _QuestionData {
  final TextEditingController questionController;
  final List<TextEditingController> optionControllers;
  int correctIndex; // -1 = not yet answered

  _QuestionData({
    String questionText = '',
    List<String>? options,
    this.correctIndex = -1,
  })  : questionController = TextEditingController(text: questionText),
        optionControllers = (options ?? ['', '', '', ''])
            .map((o) => TextEditingController(text: o))
            .toList();

  void dispose() {
    questionController.dispose();
    for (final c in optionControllers) {
      c.dispose();
    }
  }

  bool get isAnswerSet => correctIndex >= 0 && correctIndex <= 3;

  bool get isComplete {
    if (questionController.text.trim().isEmpty) return false;
    return optionControllers.every((c) => c.text.trim().isNotEmpty);
  }

  Map<String, dynamic> toMap() => {
        'type': 'multiple_choice',
        'question': questionController.text.trim(),
        'options': optionControllers.map((c) => c.text.trim()).toList(),
        'correctIndex': correctIndex,
      };
}

// ─────────────────────────────────────────────────────────────────────────────
// BULK PARSER
// ─────────────────────────────────────────────────────────────────────────────

class _BulkParser {
  /// Strips the leading bold marker (if any) from a line, returning clean
  /// text safe to run regexes against.
  static String _stripBold(String line) =>
      line.startsWith(_kBoldMarker) ? line.substring(_kBoldMarker.length) : line;

  static List<_QuestionData> parse(String raw) {
    final results = <_QuestionData>[];
    final lines = raw
        .replaceAll('\r\n', '\n')
        .replaceAll('\r', '\n')
        .split('\n')
        .map((l) => l.trim())
        .toList();

    final blocks = <List<String>>[];
    List<String> current = [];

    for (final line in lines) {
      if (line.isEmpty) continue;
      if (_isQuestionStart(_stripBold(line)) && current.isNotEmpty) {
        blocks.add(List.from(current));
        current = [];
      }
      current.add(line);
    }
    if (current.isNotEmpty) blocks.add(current);

    if (blocks.length == 1 && !_isQuestionStart(_stripBold(blocks.first.first))) {
      for (final l in lines.where((l) => l.isNotEmpty)) {
        final cleaned = _stripBold(l);
        final stripped = cleaned.replaceFirst(RegExp(r'^[-•*·]\s+'), '');
        if (stripped.isNotEmpty) {
          results.add(_QuestionData(questionText: stripped));
        }
      }
      return results;
    }

    if (blocks.isEmpty) {
      for (final l in lines.where((l) => l.isNotEmpty)) {
        results.add(_QuestionData(questionText: _stripBold(l)));
      }
      return results;
    }

    for (final block in blocks) {
      final q = _parseBlock(block);
      if (q != null) results.add(q);
    }
    return results;
  }

  static bool _isQuestionStart(String line) => RegExp(
        r'^(\d+[\.\)\:]|Q\.?\s*\d+[\.\)\:]?|Question\s+\d+[\.\)\:]?)\s*',
        caseSensitive: false,
      ).hasMatch(line);

  static String _stripQuestionPrefix(String line) => line
      .replaceFirst(
        RegExp(
          r'^(\d+[\.\)\:]|Q\.?\s*\d+[\.\)\:]?|Question\s+\d+[\.\)\:]?)\s*',
          caseSensitive: false,
        ),
        '',
      )
      .trim();

  static _QuestionData? _parseBlock(List<String> rawLines) {
    if (rawLines.isEmpty) return null;

    // Separate the bold marker from each line's text so the regexes below
    // keep working on clean text, while boldFlags[i] remembers whether that
    // particular line was bold in the source DOCX — i.e. the option the
    // instructor marked as correct by bolding it.
    final lines = <String>[];
    final boldFlags = <bool>[];
    for (final l in rawLines) {
      if (l.startsWith(_kBoldMarker)) {
        boldFlags.add(true);
        lines.add(l.substring(_kBoldMarker.length));
      } else {
        boldFlags.add(false);
        lines.add(l);
      }
    }

    final questionBuffer = StringBuffer();
    int optionStart = lines.length;

    for (int i = 0; i < lines.length; i++) {
      final l = lines[i];
      if (_isOptionLine(l) || _isAnswerLine(l)) {
        optionStart = i;
        break;
      }
      questionBuffer.write(i == 0 ? _stripQuestionPrefix(l) : ' $l');
    }

    final questionRaw = questionBuffer.toString().trim();
    if (questionRaw.isEmpty) return null;

    final options = <String>['', '', '', ''];
    String? answerRaw;
    int boldIndex = -1;

    for (int i = optionStart; i < lines.length; i++) {
      final l = lines[i];
      if (_isAnswerLine(l)) {
        answerRaw = l
            .replaceFirst(
              RegExp(r'^(answer|ans|key|correct)\s*[\:\-]\s*', caseSensitive: false),
              '',
            )
            .trim();
        continue;
      }
      final m = RegExp(r'^\(?([A-Da-d])[\.\)\s]\)?\s*(.+)').firstMatch(l);
      if (m != null) {
        final idx = m.group(1)!.toUpperCase().codeUnitAt(0) - 65;
        if (idx >= 0 && idx < 4) {
          options[idx] = m.group(2)!.trim();
          if (boldFlags[i]) boldIndex = idx;
        }
      }
    }

    // Bold formatting from the DOCX (the instructor's marked answer) always
    // wins over a separate "Answer:" line when both are present.
    int correctIndex = -1;
    if (boldIndex >= 0) {
      correctIndex = boldIndex;
    } else if (answerRaw != null) {
      final letter = answerRaw.toUpperCase().replaceAll(RegExp(r'[^A-D]'), '');
      if (letter.isNotEmpty) {
        correctIndex = (letter.codeUnitAt(0) - 65).clamp(0, 3);
      } else {
        final num = int.tryParse(answerRaw.replaceAll(RegExp(r'[^\d]'), ''));
        if (num != null && num >= 1 && num <= 4) correctIndex = num - 1;
      }
    }

    return _QuestionData(
      questionText: questionRaw,
      options: options,
      correctIndex: correctIndex,
    );
  }

  static bool _isOptionLine(String line) =>
      RegExp(r'^\(?[A-Da-d][\.\)\s]\)?\s*.+').hasMatch(line);

  static bool _isAnswerLine(String line) =>
      RegExp(r'^(answer|ans|key|correct)\s*[\:\-]', caseSensitive: false)
          .hasMatch(line);
}

// ─────────────────────────────────────────────────────────────────────────────
// ADD QUESTIONS DIALOG (paste text / upload DOCX)
// ─────────────────────────────────────────────────────────────────────────────

class _BulkImportDialog extends StatefulWidget {
  const _BulkImportDialog();

  @override
  State<_BulkImportDialog> createState() => _BulkImportDialogState();
}

class _BulkImportDialogState extends State<_BulkImportDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabs;
  final _pasteController = TextEditingController();
  bool _loadingFile = false;
  String? _fileContent;
  String? _fileName;
  String? _previewError;
  List<_QuestionData> _previewed = [];
  bool _showPreview = false;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    // Keeps the "How to Upload" instructions in sync if the user swipes
    // between tabs instead of tapping them.
    _tabs.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabs.dispose();
    _pasteController.dispose();
    super.dispose();
  }

  String _autoNumber(String raw) {
    final lines = raw.split('\n');
    final result = <String>[];
    int counter = 1;

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) { result.add(line); continue; }
      final alreadyNumbered = RegExp(r'^\d+[\.\)]').hasMatch(trimmed);
      final isOption = RegExp(r'^[A-Da-d][\.\)]').hasMatch(trimmed);
      final isAnswer = RegExp(r'^answer\s*:', caseSensitive: false).hasMatch(trimmed);

      if (!alreadyNumbered && !isOption && !isAnswer) {
        result.add('$counter. $trimmed');
        counter++;
      } else {
        if (alreadyNumbered) {
          final m = RegExp(r'^(\d+)[\.\)]').firstMatch(trimmed);
          if (m != null) counter = int.parse(m.group(1)!) + 1;
        }
        result.add(line);
      }
    }
    return result.join('\n');
  }

  // ── _pickFile: extracts DOCX text while tracking bold runs, so a bolded
  // option is auto-marked as the correct answer instead of the teacher
  // having to tap A/B/C/D after import. ──────────────────────────────────
  Future<void> _pickFile() async {
    setState(() { _loadingFile = true; _previewError = null; });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['docx'],
        withData: true,
      );
      if (result != null && result.files.single.bytes != null) {
        final bytes = result.files.single.bytes!;
        final archive = ZipDecoder().decodeBytes(bytes);
        final docXml = archive.files.firstWhere(
          (f) => f.name == 'word/document.xml',
          orElse: () => throw Exception('Not a valid DOCX file'),
        );
        final doc = XmlDocument.parse(utf8.decode(docXml.content as List<int>));

        // Walk each paragraph's runs so we can see which text is bold
        // (<w:b/> in the run's <w:rPr>). Importantly, a single Word
        // paragraph can contain MULTIPLE visual lines separated by a
        // manual line break (<w:br/>) rather than a new paragraph — this
        // is exactly how most exam DOCX files lay out "A. ... B. ... C.
        // ... D. ..." as one paragraph with three <w:br/> in between. We
        // treat every <w:br/> as the start of a new line and track bold
        // ratio PER LINE (not per paragraph), so each option's own bold
        // state is captured correctly instead of being averaged away by
        // its non-bold siblings in the same paragraph.
        final lines = <String>[];
        for (final p in doc.findAllElements('w:p')) {
          final lineBuffers = <StringBuffer>[StringBuffer()];
          final lineBoldChars = <int>[0];
          final lineTotalChars = <int>[0];

          for (final run in p.findAllElements('w:r')) {
            bool isBold = false;
            final rPrList = run.findElements('w:rPr');
            if (rPrList.isNotEmpty) {
              final bList = rPrList.first.findElements('w:b');
              if (bList.isNotEmpty) {
                final val = bList.first.getAttribute('w:val');
                // <w:b/> alone (no val) or val="true"/"1" means bold is ON.
                // val="false"/"0" explicitly turns bold OFF.
                isBold = val == null || (val != 'false' && val != '0');
              }
            }

            // A run's children are in document order and can interleave
            // <w:br/> (line break) with <w:t> (text) — e.g. a single <w:r>
            // is often "<w:br/><w:t>C. Aircraft Manual</w:t>". Walk them
            // in order so a break always starts a fresh line.
            for (final child in run.children.whereType<XmlElement>()) {
              final localName = child.name.local;
              if (localName == 'br') {
                lineBuffers.add(StringBuffer());
                lineBoldChars.add(0);
                lineTotalChars.add(0);
              } else if (localName == 't') {
                final text = child.innerText;
                if (text.isEmpty) continue;
                lineBuffers.last.write(text);
                lineTotalChars[lineTotalChars.length - 1] += text.length;
                if (isBold) lineBoldChars[lineBoldChars.length - 1] += text.length;
              }
            }
          }

          for (int i = 0; i < lineBuffers.length; i++) {
            final text = lineBuffers[i].toString();
            if (text.trim().isEmpty) continue;
            final isBoldLine = lineTotalChars[i] > 0 && lineBoldChars[i] / lineTotalChars[i] > 0.5;
            lines.add(isBoldLine ? '$_kBoldMarker$text' : text);
          }
        }

        // Fallback safety net: some DOCX files still cram multiple options
        // onto one line with no <w:br/> between them at all, e.g.
        // "A. Civil Aviation Authority of the Philippines B. Central..."
        // If that happens, split before each A/B/C/D option letter so the
        // parser still sees them as separate lines. With the per-line bold
        // tracking above already correctly assigning the marker, this only
        // needs to fire in that rarer case.
        final splitLines = <String>[];
        for (final line in lines) {
          final hasBoldPrefix = line.startsWith(_kBoldMarker);
          final body = hasBoldPrefix ? line.substring(_kBoldMarker.length) : line;

          // Split before A./B./C./D. even with NO space between options
          // e.g. "...PhilippinesB. Central..." → newline inserted before B.
          final separated = body.replaceAllMapped(
            RegExp(r'(?<=[^\s])([A-Da-d]\.\s)'),
            (m) => '\n${m.group(1)}',
          );
          final parts = separated
              .split('\n')
              .map((l) => l.trim())
              .where((l) => l.isNotEmpty)
              .toList();

          for (int i = 0; i < parts.length; i++) {
            // Only the first split part carries the paragraph's original
            // bold marker forward — merged multi-option paragraphs are rare
            // since each option is normally its own bold/non-bold line now.
            splitLines.add(i == 0 && hasBoldPrefix ? '$_kBoldMarker${parts[i]}' : parts[i]);
          }
        }

        setState(() {
          _fileContent = splitLines.join('\n');
          _fileName = result.files.single.name;
          _showPreview = false;
          _previewed = [];
        });
      }
    } catch (e) {
      setState(() => _previewError = 'Could not read DOCX file: $e');
    } finally {
      setState(() => _loadingFile = false);
    }
  }

  void _runPreview() {
    final text = _tabs.index == 0
        ? _pasteController.text.trim()
        : (_fileContent ?? '').trim();

    if (text.isEmpty) {
      setState(() { _previewError = 'Please enter or upload questions first.'; _showPreview = false; });
      return;
    }

    final parsed = _BulkParser.parse(text);
    if (parsed.isEmpty) {
      setState(() { _previewError = 'No questions detected. Check the format guide below.'; _showPreview = false; });
      return;
    }

    setState(() { _previewed = parsed; _previewError = null; _showPreview = true; });
  }

  void _import() {
    if (_previewed.isEmpty) {
      _runPreview();
      if (_previewed.isEmpty) return;
    }
    Navigator.pop(context, _previewed);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              color: const Color(0xFF1A237E),
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    const Icon(Icons.upload_rounded, color: Colors.white, size: 20),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text('Add Questions',
                          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16)),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                      onPressed: () => Navigator.pop(context),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.list_rounded, color: Colors.white70, size: 12),
                        SizedBox(width: 4),
                        Text('Multiple Choice only', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  TabBar(
                    controller: _tabs,
                    indicatorColor: Colors.white,
                    indicatorWeight: 3,
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white54,
                    labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    onTap: (_) => setState(() { _showPreview = false; _previewed = []; _previewError = null; }),
                    tabs: const [Tab(text: 'Paste Text'), Tab(text: 'Upload DOCX')],
                  ),
                ],
              ),
            ),

            // Body
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.65),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _HowToUploadCard(isDocxTab: _tabs.index == 1),
                    const SizedBox(height: 12),
                    SizedBox(
                      height: 180,
                      child: TabBarView(
                        controller: _tabs,
                        children: [
                          // Paste tab
                          TextField(
                            controller: _pasteController,
                            maxLines: null,
                            expands: true,
                            style: const TextStyle(fontSize: 13, height: 1.5),
                            decoration: InputDecoration(
                              hintText:
                                  '1. What is the capital of the Philippines?\n'
                                  'A. Cebu\nB. Manila\nC. Davao\nD. Baguio\n'
                                  'Answer: B\n\n'
                                  '2. Who is the father of criminology?\n'
                                  'A. Beccaria\nB. Lombroso\nC. Garofalo\nD. Ferri\n'
                                  'Answer: B',
                              hintStyle: TextStyle(color: Colors.grey.shade400, fontSize: 12, fontStyle: FontStyle.italic),
                              filled: true,
                              fillColor: const Color(0xFFF8F9FF),
                              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade200)),
                              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade200)),
                              focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF1A237E), width: 1.5)),
                              contentPadding: const EdgeInsets.all(12),
                            ),
                            onChanged: (_) {
                              setState(() { _showPreview = false; _previewed = []; });
                              final text = _pasteController.text;
                              final numbered = _autoNumber(text);
                              if (numbered != text) {
                                _pasteController.value = TextEditingValue(
                                  text: numbered,
                                  selection: TextSelection.collapsed(offset: numbered.length),
                                );
                              }
                            },
                          ),

                          // Upload DOCX tab
                          GestureDetector(
                            onTap: _loadingFile ? null : _pickFile,
                            child: Container(
                              height: 180,
                              decoration: BoxDecoration(
                                color: const Color(0xFFF8F9FF),
                                border: Border.all(
                                  color: _fileContent != null ? const Color(0xFF1A237E) : Colors.grey.shade300,
                                  width: _fileContent != null ? 1.5 : 1,
                                ),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: _loadingFile
                                  ? const Center(child: CircularProgressIndicator())
                                  : _fileContent != null
                                      ? Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(14),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(Icons.description_rounded, color: Color(0xFF1A237E), size: 36),
                                                const SizedBox(height: 8),
                                                Text(_fileName ?? 'File loaded',
                                                    style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFF1A237E), fontSize: 13),
                                                    textAlign: TextAlign.center),
                                                const SizedBox(height: 4),
                                                Text('${_fileContent!.split('\n').length} lines extracted',
                                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                                                const SizedBox(height: 8),
                                                TextButton(onPressed: _pickFile, child: const Text('Replace file', style: TextStyle(fontSize: 12))),
                                              ],
                                            ),
                                          ),
                                        )
                                      : Center(
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.upload_file_rounded, size: 40, color: Colors.grey.shade400),
                                              const SizedBox(height: 10),
                                              Text('Tap to upload .docx file', style: TextStyle(color: Colors.grey.shade600, fontSize: 13, fontWeight: FontWeight.w500)),
                                              const SizedBox(height: 4),
                                              Text('Bold option = correct answer, auto-detected', style: TextStyle(color: Colors.grey.shade400, fontSize: 11)),
                                              const SizedBox(height: 14),
                                              ElevatedButton.icon(
                                                onPressed: _pickFile,
                                                icon: const Icon(Icons.folder_open_rounded, size: 16),
                                                label: const Text('Browse File', style: TextStyle(fontWeight: FontWeight.bold)),
                                                style: ElevatedButton.styleFrom(
                                                  backgroundColor: const Color(0xFF1A237E),
                                                  foregroundColor: Colors.white,
                                                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),
                    const _FormatGuideCard(),
                    const SizedBox(height: 12),

                    if (_previewError != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.red.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.red.shade200),
                        ),
                        child: Row(children: [
                          Icon(Icons.error_outline_rounded, color: Colors.red.shade400, size: 16),
                          const SizedBox(width: 8),
                          Expanded(child: Text(_previewError!, style: TextStyle(color: Colors.red.shade700, fontSize: 12))),
                        ]),
                      ),

                    if (_showPreview && _previewed.isNotEmpty) ...[
                      Row(children: [
                        const Icon(Icons.preview_rounded, color: Color(0xFF1A237E), size: 14),
                        const SizedBox(width: 6),
                        Text(
                          'Preview — ${_previewed.length} question${_previewed.length == 1 ? '' : 's'}',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF1A237E)),
                        ),
                        const Spacer(),
                        Builder(builder: (_) {
                          final answered = _previewed.where((q) => q.isAnswerSet).length;
                          return Text(
                            '$answered/${_previewed.length} answers detected',
                            style: TextStyle(
                                fontSize: 11,
                                color: answered == _previewed.length ? Colors.green.shade700 : Colors.orange.shade700,
                                fontWeight: FontWeight.w600),
                          );
                        }),
                      ]),
                      const SizedBox(height: 8),
                      for (int i = 0; i < _previewed.length; i++)
                        _PreviewRow(index: i, data: _previewed[i]),
                      const SizedBox(height: 8),
                    ],
                  ],
                ),
              ),
            ),

            // Action buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _runPreview,
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: Color(0xFF1A237E)),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: const Text('Preview', style: TextStyle(color: Color(0xFF1A237E), fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _import,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A237E),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: Text(
                      _previewed.isEmpty ? 'Import' : 'Import ${_previewed.length}',
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
              ]),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// How to Upload — always-visible step instructions (per client request)
// ─────────────────────────────────────────────────────────────────────────────

class _HowToUploadCard extends StatelessWidget {
  final bool isDocxTab;
  const _HowToUploadCard({required this.isDocxTab});

  static const _pasteSteps = [
    'Type or paste your questions into the box below, following the format shown in the Format Guide.',
    'Give every question four options: A, B, C, and D.',
    'Add "Answer: B" (or "Answer: 2") under a question to mark the correct option — or leave it out and tap the answer afterward.',
    'Tap "Preview" to check how your questions were read before importing.',
    'Tap "Import" to add the questions to the Question Sheet below.',
  ];

  static const _docxSteps = [
    'In your Word file, type each question followed by its four options: A, B, C, and D.',
    'Bold the text of the correct option — this marks it as the answer, so you don\'t need to type "Answer:".',
    'Save the file as .docx, then tap the upload area (or "Browse File") to select it.',
    'Tap "Preview" to check the detected questions and answers before importing.',
    'Tap "Import" to add the questions to the Question Sheet below.',
  ];

  @override
  Widget build(BuildContext context) {
    final steps = isDocxTab ? _docxSteps : _pasteSteps;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE8EAF6),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF1A237E).withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.checklist_rounded, color: Color(0xFF1A237E), size: 15),
            const SizedBox(width: 6),
            Text(
              isDocxTab ? 'How to Upload a DOCX Review' : 'How to Add a Review by Pasting Text',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF1A237E)),
            ),
          ]),
          const SizedBox(height: 8),
          for (int i = 0; i < steps.length; i++)
            Padding(
              padding: EdgeInsets.only(bottom: i == steps.length - 1 ? 0 : 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 16,
                    height: 16,
                    margin: const EdgeInsets.only(top: 1),
                    decoration: const BoxDecoration(color: Color(0xFF1A237E), shape: BoxShape.circle),
                    child: Center(
                      child: Text('${i + 1}',
                          style: const TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Colors.white)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(steps[i],
                        style: const TextStyle(fontSize: 11.5, color: Color(0xFF2C2C2A), height: 1.4)),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Format guide card
// ─────────────────────────────────────────────────────────────────────────────

class _FormatGuideCard extends StatefulWidget {
  const _FormatGuideCard();
  @override
  State<_FormatGuideCard> createState() => _FormatGuideCardState();
}

class _FormatGuideCardState extends State<_FormatGuideCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFE082)),
      ),
      child: Column(
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(children: [
                const Icon(Icons.info_outline_rounded, color: Color(0xFFF57F17), size: 15),
                const SizedBox(width: 6),
                const Expanded(
                  child: Text('Format Guide (tap to expand)',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFFF57F17))),
                ),
                Icon(
                  _expanded ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded,
                  color: const Color(0xFFF57F17), size: 16,
                ),
              ]),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Divider(color: Color(0xFFFFE082), height: 1),
                  const SizedBox(height: 8),
                  _guideSection('Multiple Choice (with answer)', [
                    '1. What is the capital of the Philippines?',
                    'A. Cebu', 'B. Manila', 'C. Davao', 'D. Baguio', 'Answer: B',
                  ]),
                  const SizedBox(height: 10),
                  _guideSection('Multiple Choice (answer filled later)', [
                    '2. Who is the father of criminology?',
                    'A. Beccaria', 'B. Lombroso', 'C. Garofalo', 'D. Ferri',
                  ]),
                  const SizedBox(height: 8),
                  Text(
                    '• Each question needs A. B. C. D. options\n'
                    '• "Answer: B" or "Answer: 2" sets the correct answer\n'
                    '• In an uploaded DOCX, bolding an option marks it as correct — no "Answer:" line needed\n'
                    '• Missing answers can be tapped directly on the question card\n'
                    '• Separate questions with a blank line or number\n'
                    '• Also supports: Q1. / Question 1. / Ans: / Key:',
                    style: TextStyle(fontSize: 11, color: Colors.brown.shade600, height: 1.6),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _guideSection(String title, List<String> lines) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF5D4037))),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: const Color(0xFFFFE082)),
          ),
          child: Text(lines.join('\n'),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Color(0xFF37474F), height: 1.5)),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Preview row
// ─────────────────────────────────────────────────────────────────────────────

class _PreviewRow extends StatelessWidget {
  final int index;
  final _QuestionData data;
  const _PreviewRow({required this.index, required this.data});

  @override
  Widget build(BuildContext context) {
    const c = Color(0xFF1A237E);
    final hasAnswer = data.isAnswerSet;
    final answerLabel = hasAnswer ? String.fromCharCode(65 + data.correctIndex) : '?';
    final answerColor = hasAnswer ? Colors.green.shade700 : Colors.orange.shade700;
    final answerBg = hasAnswer ? Colors.green.shade50 : Colors.orange.shade50;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: c.withOpacity(0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withOpacity(0.15)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${index + 1}.', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: c)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(data.questionController.text,
                style: const TextStyle(fontSize: 12, color: Color(0xFF2C2C2A)),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: answerBg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: answerColor.withOpacity(0.4)),
            ),
            child: Text('Ans: $answerLabel',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: answerColor)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BULK ANSWER KEY DIALOG
// ─────────────────────────────────────────────────────────────────────────────

class _BulkAnswerKeyDialog extends StatefulWidget {
  final int questionCount;
  const _BulkAnswerKeyDialog({required this.questionCount});

  @override
  State<_BulkAnswerKeyDialog> createState() => _BulkAnswerKeyDialogState();
}

class _BulkAnswerKeyDialogState extends State<_BulkAnswerKeyDialog> {
  final _controller = TextEditingController();
  String? _error;
  List<int>? _parsed;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _parse() {
    final raw = _controller.text.trim();
    if (raw.isEmpty) {
      setState(() => _error = 'Please enter the answer sequence.');
      return;
    }

    final tokens = raw
        .toUpperCase()
        .replaceAll(RegExp(r'[^A-D1-4\s,\.\n]'), ' ')
        .trim()
        .split(RegExp(r'[\s,\.\n]+'))
        .where((t) => t.isNotEmpty)
        .toList();

    final indices = <int>[];
    for (final t in tokens) {
      if (RegExp(r'^[A-D]$').hasMatch(t)) {
        indices.add(t.codeUnitAt(0) - 65);
      } else if (RegExp(r'^[1-4]$').hasMatch(t)) {
        indices.add(int.parse(t) - 1);
      }
    }

    if (indices.isEmpty) {
      setState(() => _error = 'No valid answers found. Use A B C D or 1 2 3 4.');
      return;
    }

    if (indices.length < widget.questionCount) {
      setState(() => _error =
          'Only ${indices.length} answers entered — need ${widget.questionCount}. Missing answers will be left blank.');
    } else {
      setState(() => _error = null);
    }

    setState(() => _parsed = indices);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(18),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              color: const Color(0xFF1A237E),
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 16),
              child: Row(children: [
                const Icon(Icons.key_rounded, color: Colors.white, size: 18),
                const SizedBox(width: 8),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Bulk Answer Key', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 15)),
                      Text('Paste all answers at once', style: TextStyle(color: Colors.white60, fontSize: 11)),
                    ],
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                  onPressed: () => Navigator.pop(context),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
              ]),
            ),

            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(color: const Color(0xFFE8EAF6), borderRadius: BorderRadius.circular(8)),
                    child: Text(
                      'Enter answers for all ${widget.questionCount} questions separated by spaces or commas.\n\n'
                      'Example:  A B C D A  or  A,B,C,D,A  or  1 2 3 4 1',
                      style: const TextStyle(fontSize: 12, color: Color(0xFF1A237E), height: 1.5),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _controller,
                    maxLines: 4,
                    style: const TextStyle(fontSize: 14, letterSpacing: 1.5, fontWeight: FontWeight.w600),
                    textCapitalization: TextCapitalization.characters,
                    decoration: InputDecoration(
                      hintText: 'A B C D A B C D A B...',
                      hintStyle: TextStyle(color: Colors.grey.shade400, letterSpacing: 1.5, fontWeight: FontWeight.normal),
                      filled: true,
                      fillColor: const Color(0xFFF8F9FF),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
                      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF1A237E), width: 1.5)),
                      contentPadding: const EdgeInsets.all(12),
                    ),
                    onChanged: (_) => setState(() { _error = null; _parsed = null; }),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade50,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: Colors.orange.shade200),
                      ),
                      child: Row(children: [
                        Icon(Icons.warning_amber_rounded, color: Colors.orange.shade700, size: 14),
                        const SizedBox(width: 6),
                        Expanded(child: Text(_error!, style: TextStyle(fontSize: 11, color: Colors.orange.shade800))),
                      ]),
                    ),
                  ],

                  if (_parsed != null && _parsed!.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (int i = 0; i < _parsed!.length && i < 20; i++)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                            decoration: BoxDecoration(color: const Color(0xFF1A237E), borderRadius: BorderRadius.circular(6)),
                            child: Text(
                              '${i + 1}:${String.fromCharCode(65 + _parsed![i])}',
                              style: const TextStyle(fontSize: 10, color: Colors.white, fontWeight: FontWeight.bold),
                            ),
                          ),
                        if (_parsed!.length > 20)
                          Text('+${_parsed!.length - 20} more', style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                      ],
                    ),
                  ],

                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _parse,
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFF1A237E)),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Preview', style: TextStyle(color: Color(0xFF1A237E), fontWeight: FontWeight.bold)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () {
                          if (_parsed == null) { _parse(); if (_parsed == null) return; }
                          Navigator.pop(context, _parsed);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A237E),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text('Apply', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CreateQuizScreen
// ─────────────────────────────────────────────────────────────────────────────

class CreateQuizScreen extends StatefulWidget {
  final String? quizId;
  final Map<String, dynamic>? existingQuiz;

  const CreateQuizScreen({super.key, this.quizId, this.existingQuiz});

  bool get isEditing => quizId != null && existingQuiz != null;

  @override
  State<CreateQuizScreen> createState() => _CreateQuizScreenState();
}

class _CreateQuizScreenState extends State<CreateQuizScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _timeLimitController = TextEditingController();

  String _selectedYearLevel = '';
  String _selectedSemester = '';
  String _selectedSubject = '';
  String _selectedSubjectCode = '';

  // NEW: teacher-controlled toggle for whether students see the correct
  // answer on their Review Result screen after submitting.
  bool _showCorrectAnswers = true;

  final List<_QuestionData> _questions = [];
  bool _saving = false;

  static const _yearLevels = ['1st Year', '2nd Year', '3rd Year', '4th Year'];

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    if (widget.isEditing) {
      final q = widget.existingQuiz!;
      _titleController.text = q['title'] ?? '';
      _selectedYearLevel = q['yearLevel'] ?? '';
      _selectedSemester = q['semester'] ?? '';
      _selectedSubject = q['subject'] ?? '';
      _selectedSubjectCode = q['subjectCode'] ?? '';

      final savedMins = (q['timeLimitMinutes'] as num?)?.toInt();
      if (savedMins != null) {
        _timeLimitController.text = savedMins.toString();
      }

      // NEW: load the saved toggle. Defaults to true so quizzes created
      // before this feature existed keep showing correct answers as before.
      _showCorrectAnswers = q['showCorrectAnswer'] as bool? ?? true;

      for (final rq in (q['questions'] as List? ?? [])) {
        _questions.add(_questionDataFromMap(rq as Map<String, dynamic>));
      }
    }

    if (_questions.isEmpty) _questions.add(_QuestionData());
  }

  _QuestionData _questionDataFromMap(Map<String, dynamic> map) {
    final opts = (map['options'] as List?)?.cast<String>() ?? ['', '', '', ''];
    while (opts.length < 4) opts.add('');
    return _QuestionData(
      questionText: map['question'] as String? ?? '',
      options: opts,
      correctIndex: map['correctIndex'] as int? ?? -1,
    );
  }

  @override
  void dispose() {
    _titleController.dispose();
    _timeLimitController.dispose();
    for (final q in _questions) {
      q.dispose();
    }
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _snack(String msg, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
    ));
  }

  int get _answeredCount => _questions.where((q) => q.isAnswerSet).length;

  // ── Selection handlers ─────────────────────────────────────────────────────

  void _onYearChanged(String? v) => setState(() {
        _selectedYearLevel = v ?? '';
        _selectedSemester = '';
        _selectedSubject = '';
        _selectedSubjectCode = '';
      });

  void _onSubjectSelected(_Subject s, String semester) {
    setState(() {
      _selectedSubject = s.description;
      _selectedSubjectCode = s.code;
      _selectedSemester = semester;
    });
    Navigator.pop(context);
  }

  // ── Question management ────────────────────────────────────────────────────

  void _addQuestion() => setState(() => _questions.add(_QuestionData()));

  void _removeQuestion(int index) {
    _questions[index].dispose();
    setState(() => _questions.removeAt(index));
  }

  // ── Add Questions (paste / DOCX) ────────────────────────────────────────────

  Future<void> _openBulkImport() async {
    final imported = await showDialog<List<_QuestionData>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _BulkImportDialog(),
    );
    if (imported == null || imported.isEmpty) return;

    setState(() {
      if (_questions.length == 1 && _questions.first.questionController.text.isEmpty) {
        _questions.first.dispose();
        _questions.clear();
      }
      _questions.addAll(imported);
    });
    final autoAnswered = imported.where((q) => q.isAnswerSet).length;
    _snack(
      '${imported.length} question${imported.length == 1 ? '' : 's'} imported'
      '${autoAnswered > 0 ? ' — $autoAnswered answer${autoAnswered == 1 ? '' : 's'} auto-detected' : ''}!',
    );
  }

  // ── Bulk answer key ────────────────────────────────────────────────────────

  Future<void> _openBulkAnswerKey() async {
    if (_questions.isEmpty) {
      _snack('Add questions first.', error: true);
      return;
    }
    final result = await showDialog<List<int>>(
      context: context,
      builder: (_) => _BulkAnswerKeyDialog(questionCount: _questions.length),
    );
    if (result == null) return;

    setState(() {
      for (int i = 0; i < result.length && i < _questions.length; i++) {
        _questions[i].correctIndex = result[i];
      }
    });
    final filled = result.length.clamp(0, _questions.length);
    _snack('$filled answer${filled == 1 ? '' : 's'} applied!');
  }

  // ── Bottom-sheet pickers ───────────────────────────────────────────────────

  void _openSubjectPicker() {
    if (_selectedYearLevel.isEmpty) {
      _snack('Please select a Year Level first.');
      return;
    }
    final year = _curriculum.firstWhere(
      (y) => y.yearLabel == _selectedYearLevel,
      orElse: () => const _YearCurriculum(yearLabel: '', sem1: [], sem2: []),
    );

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.75,
        maxChildSize: 0.93,
        minChildSize: 0.4,
        builder: (_, ctrl) => Column(
          children: [
            _sheetHandle(),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(children: [
                const Icon(Icons.menu_book_rounded, color: Color(0xFF1A237E), size: 18),
                const SizedBox(width: 8),
                Text('$_selectedYearLevel — Select Subject',
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: Color(0xFF1A237E))),
              ]),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView(
                controller: ctrl,
                children: [
                  if (year.sem1.isNotEmpty) const _SemHeader(label: '1st Semester'),
                  for (final s in year.sem1)
                    _SubjectRow(
                      subject: s,
                      isSelected: _selectedSubject == s.description,
                      onTap: () => _onSubjectSelected(s, '1st Semester'),
                    ),
                  if (year.sem2.isNotEmpty) const _SemHeader(label: '2nd Semester'),
                  for (final s in year.sem2)
                    _SubjectRow(
                      subject: s,
                      isSelected: _selectedSubject == s.description,
                      onTap: () => _onSubjectSelected(s, '2nd Semester'),
                    ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Validation ─────────────────────────────────────────────────────────────

  bool _validateQuestions() {
    for (int i = 0; i < _questions.length; i++) {
      final q = _questions[i];
      final n = i + 1;

      if (q.questionController.text.trim().isEmpty) {
        _snack('Question $n is empty.', error: true);
        return false;
      }
      for (int j = 0; j < 4; j++) {
        if (q.optionControllers[j].text.trim().isEmpty) {
          _snack('Option ${String.fromCharCode(65 + j)} in Q$n is empty.', error: true);
          return false;
        }
      }
      if (!q.isAnswerSet) {
        _snack('Answer for Q$n is not set. Tap A, B, C, or D on that question.', error: true);
        return false;
      }
    }
    return true;
  }

  // ── Save ───────────────────────────────────────────────────────────────────

  Future<void> _saveQuiz() async {
    if (!_formKey.currentState!.validate()) return;
    if (_selectedYearLevel.isEmpty) { _snack('Please select a Year Level.', error: true); return; }
    if (_selectedSubject.isEmpty) { _snack('Please select a Subject.', error: true); return; }

    final timeLimitMinutes = int.tryParse(_timeLimitController.text.trim());
    if (timeLimitMinutes == null || timeLimitMinutes <= 0) {
      _snack('Please enter a valid time limit in minutes.', error: true);
      return;
    }

    if (_questions.isEmpty) { _snack('Add at least one question.', error: true); return; }
    if (!_validateQuestions()) return;

    setState(() => _saving = true);
    try {
      final data = <String, dynamic>{
        'title': _titleController.text.trim(),
        'yearLevel': _selectedYearLevel,
        'semester': _selectedSemester,
        'subject': _selectedSubject,
        'subjectCode': _selectedSubjectCode,
        'timeLimitMinutes': timeLimitMinutes,
        // NEW: saved so TakeQuizScreen knows whether to reveal correct
        // answers on the student's Review Result screen.
        'showCorrectAnswer': _showCorrectAnswers,
        'questions': _questions.map((q) => q.toMap()).toList(),
        'createdBy': FirebaseAuth.instance.currentUser?.uid,
      };

      if (widget.isEditing) {
        await FirebaseFirestore.instance
            .collection('quizzes')
            .doc(widget.quizId)
            .update({...data, 'updatedAt': FieldValue.serverTimestamp()});
        if (mounted) { _snack('Review updated!'); Navigator.pop(context); }
      } else {
        await FirebaseFirestore.instance
            .collection('quizzes')
            .add({...data, 'createdAt': FieldValue.serverTimestamp()});
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      _snack('Error saving review: $e', error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final answered = _answeredCount;
    final total = _questions.length;
    final allDone = answered == total && total > 0;

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
        title: Text(
          widget.isEditing ? 'Edit Review' : 'Create Review',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_saving)
            const Center(
              child: Padding(
                padding: EdgeInsets.only(right: 16),
                child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
              ),
            )
          else
            TextButton(
              onPressed: _saveQuiz,
              child: Text(
                widget.isEditing ? 'Update' : 'Save',
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Review Details ─────────────────────────────────────────
            _SectionCard(
              title: 'Review Details',
              icon: Icons.info_outline_rounded,
              children: [
                TextFormField(
                  controller: _titleController,
                  decoration: _inputDeco('Review Title', Icons.title_rounded),
                  textCapitalization: TextCapitalization.sentences,
                  validator: (v) => (v == null || v.trim().isEmpty) ? 'Required' : null,
                ),
                const SizedBox(height: 14),
                _LabeledField(
                  label: 'Year Level',
                  child: DropdownButtonFormField<String>(
                    value: _selectedYearLevel.isEmpty ? null : _selectedYearLevel,
                    decoration: _inputDeco('Select Year Level', Icons.school_rounded),
                    items: _yearLevels.map((y) => DropdownMenuItem(value: y, child: Text(y))).toList(),
                    onChanged: _onYearChanged,
                    validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
                  ),
                ),
                const SizedBox(height: 14),
                _LabeledField(
                  label: 'Subject',
                  child: _PickerField(
                    icon: Icons.menu_book_rounded,
                    placeholder: 'Select Subject',
                    isSelected: _selectedSubject.isNotEmpty,
                    onTap: _openSubjectPicker,
                    child: _selectedSubject.isEmpty
                        ? null
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(children: [
                                _MiniTag(label: _selectedSemester),
                                const SizedBox(width: 6),
                                _MiniTag(label: _selectedSubjectCode),
                              ]),
                              const SizedBox(height: 2),
                              Text(_selectedSubject,
                                  style: const TextStyle(fontSize: 13, color: Color(0xFF1A237E), fontWeight: FontWeight.w600)),
                            ],
                          ),
                  ),
                ),
                const SizedBox(height: 14),
                // ── Time Limit — free-text minutes, instructor's choice ──
                _LabeledField(
                  label: 'Time Limit',
                  child: TextFormField(
                    controller: _timeLimitController,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF1A237E)),
                    decoration: _inputDeco('Enter time limit', Icons.timer_outlined).copyWith(
                      suffixText: 'minutes',
                      suffixStyle: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                    ),
                    validator: (v) {
                      if (v == null || v.trim().isEmpty) return 'Required';
                      final n = int.tryParse(v.trim());
                      if (n == null || n <= 0) return 'Enter a valid number of minutes';
                      return null;
                    },
                  ),
                ),

                // ── NEW: Show Correct Answers toggle ───────────────────
                const SizedBox(height: 14),
                _LabeledField(
                  label: 'Answer Key Visibility',
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.shade300),
                      borderRadius: BorderRadius.circular(10),
                      color: Colors.white,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          _showCorrectAnswers ? Icons.visibility_rounded : Icons.visibility_off_rounded,
                          size: 18,
                          color: const Color(0xFF3949AB),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Show Correct Answers to Students',
                                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Color(0xFF1A237E)),
                              ),
                              Text(
                                _showCorrectAnswers
                                    ? 'Students will see the correct answer after submitting'
                                    : 'Students will only see if their answer was right or wrong',
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                              ),
                            ],
                          ),
                        ),
                        Switch(
                          value: _showCorrectAnswers,
                          activeColor: const Color(0xFF1A237E),
                          onChanged: (v) => setState(() => _showCorrectAnswers = v),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 16),

            // ── Add Questions banner ─────────────────────────────────────
            GestureDetector(
              onTap: _openBulkImport,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF283593), Color(0xFF1A237E)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [BoxShadow(color: const Color(0xFF1A237E).withOpacity(0.3), blurRadius: 8, offset: const Offset(0, 3))],
                ),
                child: Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.white.withOpacity(0.15), borderRadius: BorderRadius.circular(8)),
                    child: const Icon(Icons.upload_rounded, color: Colors.white, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Add Questions', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                        SizedBox(height: 2),
                        Text('Paste text or upload a DOCX file', style: TextStyle(color: Colors.white70, fontSize: 11)),
                      ],
                    ),
                  ),
                  const Icon(Icons.arrow_forward_ios_rounded, color: Colors.white54, size: 14),
                ]),
              ),
            ),

            const SizedBox(height: 16),

            // ── Unified Question + Answer Sheet ────────────────────────
            Card(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 1,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  Container(
                    color: const Color(0xFF1A237E),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: Row(children: [
                      const Icon(Icons.article_outlined, color: Colors.white, size: 16),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text('Question Sheet',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14)),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: allDone
                              ? Colors.green.withOpacity(0.25)
                              : Colors.white.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            allDone ? Icons.check_circle_rounded : Icons.key_rounded,
                            size: 12,
                            color: allDone ? Colors.greenAccent : Colors.white70,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$answered / $total answered',
                            style: TextStyle(
                                fontSize: 11,
                                color: allDone ? Colors.greenAccent : Colors.white70,
                                fontWeight: FontWeight.w600),
                          ),
                        ]),
                      ),
                    ]),
                  ),

                  GestureDetector(
                    onTap: _openBulkAnswerKey,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8EAF6),
                        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
                      ),
                      child: Row(children: [
                        Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: const Color(0xFF1A237E),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: const Icon(Icons.bolt_rounded, color: Colors.white, size: 13),
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Text(
                            'Bulk Fill Answers — paste all at once (e.g. A B C D A...)',
                            style: TextStyle(fontSize: 12, color: Color(0xFF1A237E)),
                          ),
                        ),
                        const Icon(Icons.arrow_forward_ios_rounded, color: Color(0xFF1A237E), size: 11),
                      ]),
                    ),
                  ),

                  _UnifiedQuestionSheet(
                    questions: _questions,
                    onAddQuestion: _addQuestion,
                    onRemoveQuestion: _removeQuestion,
                    onCorrectChanged: (i, idx) => setState(() => _questions[i].correctIndex = idx),
                    onRebuild: () => setState(() {}),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 80),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDeco(String hint, IconData icon) => InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, color: const Color(0xFF3949AB), size: 20),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide(color: Colors.grey.shade300)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: const BorderSide(color: Color(0xFF1A237E), width: 1.5)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared bottom-sheet drag handle
// ─────────────────────────────────────────────────────────────────────────────

Widget _sheetHandle() => Container(
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      width: 40,
      height: 4,
      decoration: BoxDecoration(color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
    );

// ─────────────────────────────────────────────────────────────────────────────
// _PickerField
// ─────────────────────────────────────────────────────────────────────────────

class _PickerField extends StatelessWidget {
  final IconData icon;
  final String placeholder;
  final bool isSelected;
  final VoidCallback onTap;
  final Widget? child;

  const _PickerField({
    required this.icon,
    required this.placeholder,
    required this.isSelected,
    required this.onTap,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final ic = isSelected ? const Color(0xFF1A237E) : Colors.grey;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          border: Border.all(
            color: isSelected ? const Color(0xFF1A237E) : Colors.grey.shade400,
            width: isSelected ? 1.5 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
          color: Colors.white,
        ),
        child: Row(children: [
          Icon(icon, size: 18, color: ic),
          const SizedBox(width: 10),
          Expanded(
            child: child ?? Text(placeholder, style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
          ),
          Icon(Icons.keyboard_arrow_down_rounded, color: isSelected ? const Color(0xFF1A237E) : Colors.grey),
        ]),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unified Question Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _UnifiedQuestionSheet extends StatefulWidget {
  final List<_QuestionData> questions;
  final VoidCallback onAddQuestion;
  final ValueChanged<int> onRemoveQuestion;
  final void Function(int, int) onCorrectChanged;
  final VoidCallback onRebuild;

  const _UnifiedQuestionSheet({
    required this.questions,
    required this.onAddQuestion,
    required this.onRemoveQuestion,
    required this.onCorrectChanged,
    required this.onRebuild,
  });

  @override
  State<_UnifiedQuestionSheet> createState() => _UnifiedQuestionSheetState();
}

class _UnifiedQuestionSheetState extends State<_UnifiedQuestionSheet> {
  final List<FocusNode> _focusNodes = [];

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < widget.questions.length; i++) {
      _focusNodes.add(FocusNode());
    }
  }

  @override
  void didUpdateWidget(_UnifiedQuestionSheet old) {
    super.didUpdateWidget(old);
    while (_focusNodes.length < widget.questions.length) {
      _focusNodes.add(FocusNode());
    }
    while (_focusNodes.length > widget.questions.length) {
      _focusNodes.removeLast().dispose();
    }
    if (widget.questions.length > old.questions.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_focusNodes.isNotEmpty) _focusNodes.last.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    for (final f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _ExamSectionHeader(
            roman: 'I.',
            instruction: 'Multiple Choice — Write your question, fill in the options, then tap the correct answer letter.',
          ),
          const SizedBox(height: 16),

          for (int i = 0; i < widget.questions.length; i++)
            _UnifiedQuestionRow(
              index: i,
              data: widget.questions[i],
              focusNode: _focusNodes[i],
              canRemove: widget.questions.length > 1,
              onRemove: () => widget.onRemoveQuestion(i),
              onEnterPressed: widget.onAddQuestion,
              onCorrectChanged: (idx) => widget.onCorrectChanged(i, idx),
              onRebuild: widget.onRebuild,
            ),

          const SizedBox(height: 8),
          InkWell(
            onTap: widget.onAddQuestion,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(children: [
                const SizedBox(width: 32),
                Icon(Icons.add_circle_outline_rounded, size: 15, color: Colors.grey.shade400),
                const SizedBox(width: 6),
                Text('Add question...', style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic, color: Colors.grey.shade400)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Unified Question Row
// ─────────────────────────────────────────────────────────────────────────────

class _UnifiedQuestionRow extends StatelessWidget {
  final int index;
  final _QuestionData data;
  final FocusNode focusNode;
  final bool canRemove;
  final VoidCallback onRemove;
  final VoidCallback onEnterPressed;
  final ValueChanged<int> onCorrectChanged;
  final VoidCallback onRebuild;

  const _UnifiedQuestionRow({
    required this.index,
    required this.data,
    required this.focusNode,
    required this.canRemove,
    required this.onRemove,
    required this.onEnterPressed,
    required this.onCorrectChanged,
    required this.onRebuild,
  });

  @override
  Widget build(BuildContext context) {
    final isAnswered = data.isAnswerSet;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F9FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isAnswered ? const Color(0xFF1A237E).withOpacity(0.25) : Colors.grey.shade200,
          width: isAnswered ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: isAnswered ? const Color(0xFF1A237E) : Colors.grey.shade400,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Center(
                    child: Text('${index + 1}',
                        style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: data.questionController,
                    focusNode: focusNode,
                    style: const TextStyle(fontSize: 14, color: Color(0xFF1A1A18), height: 1.5),
                    decoration: InputDecoration(
                      hintText: 'Type question ${index + 1} here...',
                      hintStyle: TextStyle(color: Colors.grey.shade400, fontStyle: FontStyle.italic, fontSize: 14),
                      isDense: true,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                    ),
                    maxLines: null,
                    textInputAction: TextInputAction.next,
                    onSubmitted: (_) => onEnterPressed(),
                    onChanged: (_) => onRebuild(),
                  ),
                ),
                if (canRemove)
                  GestureDetector(
                    onTap: onRemove,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 4),
                      child: Icon(Icons.close_rounded, size: 16, color: Colors.grey.shade400),
                    ),
                  ),
              ],
            ),
          ),

          const SizedBox(height: 10),
          Divider(color: Colors.grey.shade200, height: 1, indent: 12, endIndent: 12),
          const SizedBox(height: 10),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Column(
              children: List.generate(4, (i) {
                final isCorrect = data.correctIndex == i;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 7),
                  child: Row(children: [
                    GestureDetector(
                      onTap: () => onCorrectChanged(i),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 28,
                        height: 28,
                        margin: const EdgeInsets.only(right: 8),
                        decoration: BoxDecoration(
                          color: isCorrect ? const Color(0xFF1A237E) : const Color(0xFFE8EAF6),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Center(
                          child: Text(
                            String.fromCharCode(65 + i),
                            style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isCorrect ? Colors.white : const Color(0xFF1A237E)),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: TextField(
                        controller: data.optionControllers[i],
                        style: TextStyle(
                          fontFamily: 'Georgia',
                          fontSize: 13,
                          color: isCorrect ? const Color(0xFF1A237E) : const Color(0xFF1A1A18),
                          fontWeight: isCorrect ? FontWeight.w600 : FontWeight.normal,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Option ${String.fromCharCode(65 + i)}',
                          hintStyle: const TextStyle(color: Color(0xFFC9C0AA), fontStyle: FontStyle.italic, fontSize: 13),
                          isDense: true,
                          filled: true,
                          fillColor: isCorrect ? const Color(0xFFE8EAF6) : Colors.white,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(7),
                              borderSide: BorderSide(color: isCorrect ? const Color(0xFF1A237E) : Colors.grey.shade200, width: isCorrect ? 1.5 : 1)),
                          enabledBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(7),
                              borderSide: BorderSide(color: isCorrect ? const Color(0xFF1A237E) : Colors.grey.shade200, width: isCorrect ? 1.5 : 1)),
                          focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(7),
                              borderSide: const BorderSide(color: Color(0xFF1A237E), width: 1.5)),
                          suffixIcon: isCorrect
                              ? const Icon(Icons.check_circle_rounded, color: Color(0xFF1A237E), size: 16)
                              : null,
                        ),
                        onChanged: (_) => onRebuild(),
                      ),
                    ),
                  ]),
                );
              }),
            ),
          ),

          Container(
            margin: const EdgeInsets.fromLTRB(12, 4, 12, 12),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isAnswered ? Colors.green.shade50 : Colors.orange.shade50,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Row(children: [
              Icon(
                isAnswered ? Icons.check_circle_rounded : Icons.touch_app_rounded,
                size: 13,
                color: isAnswered ? Colors.green.shade600 : Colors.orange.shade600,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: isAnswered
                    ? Text(
                        'Answer: ${String.fromCharCode(65 + data.correctIndex)}'
                        '${data.optionControllers[data.correctIndex].text.trim().isNotEmpty ? ' — ${data.optionControllers[data.correctIndex].text.trim()}' : ''}',
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.green.shade700),
                        overflow: TextOverflow.ellipsis,
                      )
                    : Text(
                        'Tap A, B, C, or D above to mark the correct answer',
                        style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
                      ),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Bond-paper surface
// ─────────────────────────────────────────────────────────────────────────────

class BondPaperSurface extends StatelessWidget {
  final Widget child;
  const BondPaperSurface({required this.child});

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Container(
          width: double.infinity,
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
          child: child,
        ),
      );
}

class _ExamSectionHeader extends StatelessWidget {
  final String roman;
  final String instruction;
  const _ExamSectionHeader({required this.roman, required this.instruction});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(roman,
            style: const TextStyle(fontFamily: 'Georgia', fontSize: 13, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2A))),
        const SizedBox(width: 6),
        Expanded(
          child: Text(instruction,
              style: const TextStyle(fontFamily: 'Georgia', fontSize: 12, fontWeight: FontWeight.bold, color: Color(0xFF2C2C2A), letterSpacing: 0.3)),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared small widgets
// ─────────────────────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;
  const _SectionCard({required this.title, required this.icon, required this.children});

  @override
  Widget build(BuildContext context) => Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        elevation: 1,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(icon, size: 16, color: const Color(0xFF1A237E)),
                const SizedBox(width: 8),
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Color(0xFF1A237E))),
              ]),
              const SizedBox(height: 14),
              ...children,
            ],
          ),
        ),
      );
}

class _LabeledField extends StatelessWidget {
  final String label;
  final Widget child;
  const _LabeledField({required this.label, required this.child});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF3949AB))),
          const SizedBox(height: 6),
          child,
        ],
      );
}

class _MiniTag extends StatelessWidget {
  final String label;
  const _MiniTag({required this.label});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF1A237E).withOpacity(0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Color(0xFF3949AB))),
      );
}

class _SemHeader extends StatelessWidget {
  final String label;
  const _SemHeader({required this.label});

  @override
  Widget build(BuildContext context) => Container(
        color: const Color(0xFFF0F2F8),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Row(children: [
          const Icon(Icons.calendar_view_month_rounded, size: 13, color: Color(0xFF3949AB)),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Color(0xFF3949AB), letterSpacing: 0.4)),
        ]),
      );
}

class _SubjectRow extends StatelessWidget {
  final _Subject subject;
  final bool isSelected;
  final VoidCallback onTap;
  const _SubjectRow({required this.subject, required this.isSelected, required this.onTap});

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          color: isSelected ? const Color(0xFFE8EAF6) : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          child: Row(children: [
            Container(
              width: 72,
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
              decoration: BoxDecoration(
                color: isSelected ? const Color(0xFF1A237E).withOpacity(0.12) : const Color(0xFFE8EAF6),
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: isSelected ? const Color(0xFF1A237E).withOpacity(0.4) : Colors.transparent),
              ),
              child: Text(subject.code,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: isSelected ? const Color(0xFF1A237E) : const Color(0xFF3949AB))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(subject.description,
                  style: TextStyle(
                      fontSize: 13,
                      color: isSelected ? const Color(0xFF1A237E) : Colors.black87,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
            ),
            if (isSelected) const Icon(Icons.check_rounded, size: 16, color: Color(0xFF1A237E)),
          ]),
        ),
      );
}