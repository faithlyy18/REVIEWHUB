import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'dart:async';
import 'dart:math';

/// TakeQuizScreen — supports multiple_choice, true_false, identification, document
class TakeQuizScreen extends StatefulWidget {
  final String quizId;
  final String studentUid;
  final String studentName;
  final String studentYearLevel;
  final int? timeLimitMinutes;

  const TakeQuizScreen({
    super.key,
    required this.quizId,
    required this.studentUid,
    required this.studentName,
    required this.studentYearLevel,
    this.timeLimitMinutes,
  });

  @override
  State<TakeQuizScreen> createState() => _TakeQuizScreenState();
}

class _TakeQuizScreenState extends State<TakeQuizScreen> {
  Map<String, dynamic>? _quizData;
  List<dynamic> _questions = [];

  final Map<int, dynamic> _answers = {};
  final Map<int, TextEditingController> _textControllers = {};

  bool _isLoading    = true;
  bool _isSubmitting = false;
  bool _isSubmitted  = false;
  int  _score        = 0;
  int  _currentPage  = 0;
  Timer? _timer;
  int _remainingSeconds = 0;
  bool _timeLimitEnabled = false;

  // ── Attempt-limit gate ──────────────────────────────────────────────────
  // Students get 2 free attempts (1 take + 1 retake) per review. Beyond
  // that they need an instructor-approved entry in `retake_requests` —
  // created from the Reviews screen — to get back in. This is the
  // server-side enforcement; the Reviews screen already hides the button
  // in this case, but this guards against stale UI state or someone
  // navigating here directly.
  static const int kMaxFreeAttempts = 2;
  bool _accessChecked = false;
  bool _accessDenied = false;
  bool _usingApprovedRetake = false;
  int _attemptCount = 0;

  // "time almost over" notification thresholds (in seconds).
  // These are now computed per-quiz from whatever time limit the instructor
  // set (see _computeWarningThresholds), instead of being fixed values.
  // That way a 3-minute quiz and a 60-minute quiz both get a meaningful
  // "almost over" alert, scaled to their own duration.
  List<int> _warningThresholds = const [];
  final Set<int> _warningsShown = {};

  // NEW: whether the teacher allows students to see the correct answer
  // on the Review Result screen. Defaults to true so quizzes created
  // before this setting existed keep behaving the way they always did.
  bool _showCorrectAnswers = true;

  final PageController _pageController = PageController();

  // ── Max content width ──────────────────────────────────────────────────────
  static const double _maxWidth = 720;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  // Runs the attempt-limit check first; only proceeds to load the quiz
  // (and start any timer) if the student is actually allowed to attempt it.
  Future<void> _initialize() async {
    await _checkAttemptAccess();
    if (!mounted) return;

    if (_accessDenied) {
      setState(() {
        _isLoading = false;
        _accessChecked = true;
      });
      return;
    }

    await _loadQuiz();
    if (widget.timeLimitMinutes != null && widget.timeLimitMinutes! > 0) {
      _timeLimitEnabled = true;
      _remainingSeconds = widget.timeLimitMinutes! * 60;
      _warningThresholds = _computeWarningThresholds(_remainingSeconds);
      _startTimer();
    }
    if (mounted) setState(() => _accessChecked = true);
  }

  // Counts this student's past submissions for this quiz. If they've hit
  // the free-attempt limit, checks `retake_requests` for an approved entry.
  Future<void> _checkAttemptAccess() async {
    try {
      final resultsSnap = await FirebaseFirestore.instance
          .collection('quiz_results')
          .where('quizId', isEqualTo: widget.quizId)
          .where('studentUid', isEqualTo: widget.studentUid)
          .get();
      _attemptCount = resultsSnap.docs.length;

      if (_attemptCount >= kMaxFreeAttempts) {
        final reqDoc = await FirebaseFirestore.instance
            .collection('retake_requests')
            .doc('${widget.quizId}_${widget.studentUid}')
            .get();
        final status = reqDoc.data()?['status'] as String?;
        if (status == 'approved') {
          _usingApprovedRetake = true;
        } else {
          _accessDenied = true;
        }
      }
    } catch (e) {
      // Fail open on a read error rather than locking a student out due to
      // a transient network/Firestore issue.
      _accessDenied = false;
    }
  }

  // Once an instructor-approved retake has actually been used (i.e. the
  // student submitted this attempt), close it out so any attempt after
  // this one requires a brand-new approval.
  Future<void> _consumeApprovedRetakeIfNeeded() async {
    if (!_usingApprovedRetake) return;
    try {
      await FirebaseFirestore.instance
          .collection('retake_requests')
          .doc('${widget.quizId}_${widget.studentUid}')
          .set({
        'status': 'used',
        'usedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {
      // Non-critical — worst case the student could ask for permission
      // again sooner than intended; instructors can still see full history
      // in Firestore directly.
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pageController.dispose();
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  // Picks "almost over" checkpoints relative to the instructor's own time
  // limit, so every quiz gets at least one meaningful warning regardless of
  // how long or short it is. Longer quizzes keep the familiar 5-min/1-min
  // heads-up; shorter ones scale down proportionally instead of silently
  // never crossing a fixed cutoff.
  List<int> _computeWarningThresholds(int totalSeconds) {
    if (totalSeconds > 600) {
      // > 10 minutes: warn at 5 minutes and 1 minute left.
      return const [300, 60];
    } else if (totalSeconds > 120) {
      // 2–10 minutes: warn at 1 minute and 30 seconds left.
      return const [60, 30];
    } else if (totalSeconds > 30) {
      // 30s–2 minutes: warn at halfway and 10 seconds left.
      final half = (totalSeconds / 2).round();
      return [half, 10];
    } else if (totalSeconds > 10) {
      // Very short quiz: a single halfway warning.
      return [(totalSeconds / 2).round()];
    }
    // Too short to meaningfully warn (10s or less).
    return const [];
  }

  Future<void> _loadQuiz() async {
    final doc = await FirebaseFirestore.instance
        .collection('quizzes')
        .doc(widget.quizId)
        .get();
    if (mounted) {
      final data = doc.data();
      final questions = List<dynamic>.from(data?['questions'] ?? []);

// Shuffle so each retake has a different order
questions.shuffle(Random());

for (int i = 0; i < questions.length; i++) {
  final type = questions[i]['type'] as String? ?? 'multiple_choice';
  if (type == 'identification' || type == 'document') {
    _textControllers[i] = TextEditingController();
  }
}

setState(() {
  _quizData  = data;
  _questions = questions;
  // NEW: read the teacher's toggle from the quiz document.
  _showCorrectAnswers = data?['showCorrectAnswer'] as bool? ?? true;
  _isLoading = false;
});
    }
  }


  String _questionType(int index) =>
      _questions[index]['type'] as String? ?? 'multiple_choice';

  void _startTimer() {
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingSeconds <= 0) {
        timer.cancel();
        _autoSubmit();
      } else {
        setState(() => _remainingSeconds--);
        _maybeShowTimeWarning();
      }
    });
  }

  // Checks the countdown against the (per-quiz) warning thresholds and pops
  // a floating SnackBar the first time it crosses one, so the student gets
  // an explicit notification (not just a color change in the AppBar chip).
  void _maybeShowTimeWarning() {
    for (final threshold in _warningThresholds) {
      if (_remainingSeconds == threshold &&
          !_warningsShown.contains(threshold)) {
        _warningsShown.add(threshold);
        if (!mounted) return;

        final minutes = threshold ~/ 60;
        final label = minutes >= 1
            ? '$minutes minute${minutes > 1 ? 's' : ''}'
            : '$threshold seconds';

        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.timer_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '⏳ Only $label left! Please finish up.',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            backgroundColor: threshold <= 60
                ? Colors.red.shade700
                : Colors.orange.shade800,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
        break; // only one threshold can match per tick
      }
    }
  }

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Future<void> _autoSubmit() async {
    if (_isSubmitted || _isSubmitting) return;
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
      content: Text('⏰ Time is up! Submitting your answers...'),
      backgroundColor: Colors.red,
      behavior: SnackBarBehavior.floating,
    ));
    for (final entry in _textControllers.entries) {
      _answers[entry.key] = entry.value.text.trim();
    }
    setState(() => _isSubmitting = true);
    final score = _calculateScore();
    final answersMap = <String, dynamic>{};
    for (int i = 0; i < _questions.length; i++) {
      final type = _questionType(i);
      if (type == 'identification' || type == 'document') {
        answersMap[i.toString()] = _textControllers[i]?.text.trim() ?? '';
      } else {
        answersMap[i.toString()] = _answers[i];
      }
    }
    try {
      await FirebaseFirestore.instance.collection('quiz_results').add({
        'quizId':         widget.quizId,
        'quizTitle':      _quizData?['title'] ?? '',
        'studentUid':     widget.studentUid,
        'studentId':      widget.studentUid,
        'studentName':    widget.studentName,
        'yearLevel':      widget.studentYearLevel,
        'score':          score,
        'totalQuestions': _questions.length,
        'answers':        answersMap,
        'submittedAt':    FieldValue.serverTimestamp(),
      });
      await _consumeApprovedRetakeIfNeeded();
      if (mounted) {
        setState(() {
          _score        = score;
          _isSubmitted  = true;
          _isSubmitting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to submit. Please try again.'),
          backgroundColor: Colors.red.shade700,
        ));
      }
    }
  }

  bool _isAnswered(int index) {
    final type = _questionType(index);
    if (type == 'multiple_choice') return _answers[index] is int;
    if (type == 'true_false')      return _answers[index] is bool;
    if (type == 'identification' || type == 'document') {
      final ctrl = _textControllers[index];
      return ctrl != null && ctrl.text.trim().isNotEmpty;
    }
    return false;
  }

  int get _answeredCount =>
      List.generate(_questions.length, (i) => i)
          .where(_isAnswered)
          .length;

  int _calculateScore() {
    int score = 0;
    for (int i = 0; i < _questions.length; i++) {
      final q    = _questions[i];
      final type = q['type'] as String? ?? 'multiple_choice';

      switch (type) {
        case 'multiple_choice':
          if (_answers[i] == (q['correctIndex'] as int?)) score++;
          break;
        case 'true_false':
          if (_answers[i] == (q['correctAnswer'] as bool?)) score++;
          break;
        case 'identification':
        case 'document':
          final correct = (q['answer'] as String? ?? '').trim().toLowerCase();
          final student = (_textControllers[i]?.text ?? '').trim().toLowerCase();
          if (student.isNotEmpty && student == correct) score++;
          break;
      }
    }
    return score;
  }

  Future<void> _submitQuiz() async {
    for (final entry in _textControllers.entries) {
      _answers[entry.key] = entry.value.text.trim();
    }

    if (_answeredCount < _questions.length) {
      final left = _questions.length - _answeredCount;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$left question(s) still unanswered.'),
        backgroundColor: Colors.orange.shade700,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Submit Review',
            style: TextStyle(
                color: Color(0xFF1A237E), fontWeight: FontWeight.bold)),
        content: const Text(
            'Are you sure you want to submit? You cannot change your answers after submitting.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel',
                  style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1A237E),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            child: const Text('Submit'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isSubmitting = true);

    final score = _calculateScore();

    final answersMap = <String, dynamic>{};
    for (int i = 0; i < _questions.length; i++) {
      final type = _questionType(i);
      if (type == 'identification' || type == 'document') {
        answersMap[i.toString()] = _textControllers[i]?.text.trim() ?? '';
      } else {
        answersMap[i.toString()] = _answers[i];
      }
    }

    try {
      await FirebaseFirestore.instance.collection('quiz_results').add({
        'quizId':         widget.quizId,
        'quizTitle':      _quizData?['title'] ?? '',
        'studentUid':     widget.studentUid,
        'studentId':      widget.studentUid,
        'studentName':    widget.studentName,
        'yearLevel':      widget.studentYearLevel,
        'score':          score,
        'totalQuestions': _questions.length,
        'answers':        answersMap,
        'submittedAt':    FieldValue.serverTimestamp(),
      });
      await _consumeApprovedRetakeIfNeeded();

      if (mounted) {
        setState(() {
          _score        = score;
          _isSubmitted  = true;
          _isSubmitting = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Failed to submit. Please try again.'),
          backgroundColor: Colors.red.shade700,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_accessChecked || _isLoading) {
      return const Scaffold(
        backgroundColor: Color(0xFFF0F2F8),
        body: Center(
            child: CircularProgressIndicator(color: Color(0xFF1A237E))),
      );
    }
    if (_accessDenied) return _buildAccessDeniedScreen();
    if (_isSubmitted) return _buildResultScreen();

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_quizData?['title'] ?? 'Review',
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 16)),
            Text(
              'Question ${_currentPage + 1} of ${_questions.length}',
              style: const TextStyle(fontSize: 12, color: Colors.white70),
            ),
          ],
        ),
        actions: [
          if (_timeLimitEnabled)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: _remainingSeconds <= 60
                        ? Colors.red.shade700
                        : _remainingSeconds <= 300
                            ? Colors.orange.shade800
                            : Colors.white.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.timer_rounded,
                          size: 16,
                          color: _remainingSeconds <= 300
                              ? Colors.white
                              : Colors.amber),
                      const SizedBox(width: 4),
                      Text(
                        _formatTime(_remainingSeconds),
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Colors.white),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: Text(
                '$_answeredCount/${_questions.length} answered',
                style:
                    const TextStyle(fontSize: 12, color: Colors.white70),
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Progress bar (full width intentionally) ──────────────────────
          LinearProgressIndicator(
            value: _questions.isEmpty
                ? 0
                : (_currentPage + 1) / _questions.length,
            backgroundColor: Colors.white24,
            valueColor:
                const AlwaysStoppedAnimation<Color>(Colors.amber),
            minHeight: 4,
          ),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              onPageChanged: (p) => setState(() => _currentPage = p),
              itemCount: _questions.length,
              itemBuilder: (context, index) {
                final q    = _questions[index] as Map<String, dynamic>;
                final type = q['type'] as String? ?? 'multiple_choice';
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  // ── FIX: constrain content width ─────────────────────────
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _maxWidth),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: const Color(0xFF1A237E),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text('Question ${index + 1}',
                                style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 13)),
                          ),
                          const SizedBox(height: 16),
                          Card(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14)),
                            elevation: 2,
                            child: Padding(
                              padding: const EdgeInsets.all(18),
                              child: Text(
                                q['question'] as String? ?? '',
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                  color: Color(0xFF1A237E),
                                  height: 1.5,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (type == 'multiple_choice')
                            _buildMultipleChoice(index, q)
                          else if (type == 'true_false')
                            _buildTrueFalse(index)
                          else if (type == 'identification')
                            _buildIdentification(index)
                          else if (type == 'document')
                            _buildDocument(index, q)
                          else
                            _buildMultipleChoice(index, q),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          _buildNavBar(),
        ],
      ),
    );
  }

  // Shown instead of the quiz when a student has hit the 2-attempt limit
  // and doesn't have instructor approval yet.
  Widget _buildAccessDeniedScreen() {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
        title: const Text('Attempt Limit Reached',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Card(
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
            elevation: 3,
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_clock_rounded,
                      size: 56, color: Color(0xFF6A1B9A)),
                  const SizedBox(height: 16),
                  const Text(
                    'You\'ve used both attempts for this review.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A237E)),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'To try again, request permission from your instructor '
                    'on the Reviews screen. You\'ll be able to retake it '
                    'once they approve your request.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, color: Colors.black54, height: 1.5),
                  ),
                  const SizedBox(height: 22),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('Back to Reviews'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A237E),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 22, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMultipleChoice(int index, Map<String, dynamic> q) {
    final options = List<String>.from(q['options'] ?? q['choices'] ?? []);

    if (options.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text('No options found for this question.',
              style: TextStyle(color: Colors.grey)),
        ),
      );
    }

    const labels = ['A', 'B', 'C', 'D', 'E', 'F'];

    return Column(
      children: List.generate(options.length, (ci) {
        final isSelected = _answers[index] == ci;
        return GestureDetector(
          onTap: () => setState(() => _answers[index] = ci),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isSelected ? const Color(0xFF1A237E) : Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF1A237E)
                    : Colors.grey.shade300,
                width: isSelected ? 2 : 1,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: const Color(0xFF1A237E).withOpacity(0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      )
                    ]
                  : [],
            ),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? Colors.white.withOpacity(0.2)
                        : const Color(0xFFE8EAF6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    ci < labels.length ? labels[ci] : '${ci + 1}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: isSelected
                          ? Colors.white
                          : const Color(0xFF1A237E),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    options[ci],
                    style: TextStyle(
                      fontSize: 14,
                      color: isSelected ? Colors.white : Colors.black87,
                      fontWeight: isSelected
                          ? FontWeight.w600
                          : FontWeight.normal,
                    ),
                  ),
                ),
                if (isSelected)
                  const Icon(Icons.check_circle_rounded,
                      color: Colors.white, size: 20),
              ],
            ),
          ),
        );
      }),
    );
  }

  Widget _buildTrueFalse(int index) {
    final selected = _answers[index];

    return Row(
      children: [
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _answers[index] = true),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                color: selected == true
                    ? const Color(0xFF00695C)
                    : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected == true
                      ? const Color(0xFF00695C)
                      : Colors.grey.shade300,
                  width: selected == true ? 2 : 1,
                ),
              ),
              child: Column(
                children: [
                  Icon(Icons.check_circle_outline_rounded,
                      size: 32,
                      color:
                          selected == true ? Colors.white : Colors.grey),
                  const SizedBox(height: 6),
                  Text('TRUE',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: selected == true
                            ? Colors.white
                            : Colors.grey.shade700,
                      )),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: GestureDetector(
            onTap: () => setState(() => _answers[index] = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              padding: const EdgeInsets.symmetric(vertical: 18),
              decoration: BoxDecoration(
                color: selected == false
                    ? Colors.red.shade700
                    : Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: selected == false
                      ? Colors.red.shade700
                      : Colors.grey.shade300,
                  width: selected == false ? 2 : 1,
                ),
              ),
              child: Column(
                children: [
                  Icon(Icons.cancel_outlined,
                      size: 32,
                      color:
                          selected == false ? Colors.white : Colors.grey),
                  const SizedBox(height: 6),
                  Text('FALSE',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: selected == false
                            ? Colors.white
                            : Colors.grey.shade700,
                      )),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildIdentification(int index) {
    _textControllers.putIfAbsent(index, () => TextEditingController());

    return TextField(
      controller: _textControllers[index],
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(
        hintText: 'Type your answer here…',
        filled: true,
        fillColor: Colors.white,
        prefixIcon: const Icon(Icons.edit_rounded,
            color: Color(0xFF4A148C), size: 20),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide:
              const BorderSide(color: Color(0xFF4A148C), width: 1.5),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  Widget _buildDocument(int index, Map<String, dynamic> q) {
    final docUrl  = q['documentUrl'] as String? ?? '';
    final docName = q['documentName'] as String? ?? 'Document';
    _textControllers.putIfAbsent(index, () => TextEditingController());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (docUrl.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(12),
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: const Color(0xFFFBE9E7),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: const Color(0xFFBF360C).withOpacity(0.4)),
            ),
            child: Row(children: [
              const Icon(Icons.insert_drive_file_rounded,
                  color: Color(0xFFBF360C), size: 28),
              const SizedBox(width: 10),
              Expanded(
                child: Text(docName,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFBF360C)),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
            ]),
          ),
        const Text('Your answer:',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Color(0xFF1A237E))),
        const SizedBox(height: 8),
        TextField(
          controller: _textControllers[index],
          maxLines: 3,
          onChanged: (_) => setState(() {}),
          decoration: InputDecoration(
            hintText: 'Write your answer here…',
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide:
                  const BorderSide(color: Color(0xFF1A237E), width: 1.5),
            ),
            contentPadding: const EdgeInsets.all(14),
          ),
        ),
      ],
    );
  }

  Widget _buildNavBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      // ── FIX: constrain nav bar content width ─────────────────────────────
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: Row(
            children: [
              if (_currentPage > 0) ...[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () => _pageController.previousPage(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                    ),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('Previous'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1A237E),
                      side: const BorderSide(color: Color(0xFF1A237E)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: _currentPage < _questions.length - 1
                    ? ElevatedButton.icon(
                        onPressed: () => _pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        ),
                        icon: const Icon(Icons.arrow_forward_rounded),
                        label: const Text('Next'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF1A237E),
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      )
                    : ElevatedButton.icon(
                        onPressed: _isSubmitting ? null : _submitQuiz,
                        icon: _isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            : const Icon(Icons.send_rounded),
                        label: Text(
                            _isSubmitting ? 'Submitting…' : 'Submit Review'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultScreen() {
    final total   = _questions.length;
    final percent = total == 0 ? 0 : (_score / total * 100).round();
    final passed  = percent >= 75;
    final color   = passed ? Colors.green : Colors.red;
    final label   = percent >= 90
        ? 'Excellent!'
        : percent >= 75
            ? 'Passed!'
            : percent >= 50
                ? 'Almost there!'
                : 'Keep practicing!';

    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A237E),
        foregroundColor: Colors.white,
        title: const Text('Review Result',
            style: TextStyle(fontWeight: FontWeight.bold)),
        automaticallyImplyLeading: false,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        // ── FIX: constrain result screen content width ────────────────────
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _maxWidth),
            child: Column(
              children: [
                Card(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20)),
                  elevation: 4,
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      children: [
                        Icon(
                            passed
                                ? Icons.emoji_events_rounded
                                : Icons.school_rounded,
                            size: 64,
                            color: color),
                        const SizedBox(height: 12),
                        Text(label,
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                                color: color)),
                        const SizedBox(height: 20),
                        Text('$_score / $total',
                            style: const TextStyle(
                                fontSize: 52,
                                fontWeight: FontWeight.bold,
                                color: Color(0xFF1A237E))),
                        Text('$percent%',
                            style: TextStyle(
                                fontSize: 20,
                                color: color,
                                fontWeight: FontWeight.w600)),
                        const SizedBox(height: 16),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: LinearProgressIndicator(
                            value: total == 0 ? 0 : _score / total,
                            backgroundColor: Colors.grey.shade200,
                            valueColor:
                                AlwaysStoppedAnimation<Color>(color),
                            minHeight: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                Card(
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14)),
                  elevation: 2,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Row(children: [
                          Icon(Icons.rate_review_rounded,
                              color: Color(0xFF1A237E), size: 20),
                          SizedBox(width: 8),
                          Text('Answer Review',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: Color(0xFF1A237E))),
                        ]),
                        const Divider(height: 20),
                        ...List.generate(_questions.length, (i) {
                          final q    = _questions[i] as Map<String, dynamic>;
                          final type =
                              q['type'] as String? ?? 'multiple_choice';
                          final opts = List<String>.from(
                              q['options'] ?? q['choices'] ?? []);
                          const labels = ['A', 'B', 'C', 'D', 'E', 'F'];

                          bool isCorrect       = false;
                          String yourAnswer    = '—';
                          String correctAnswer = '—';

                          switch (type) {
                            case 'multiple_choice':
                              final sel = _answers[i];
                              final cor = q['correctIndex'] as int?;
                              isCorrect = sel == cor;
                              if (sel is int && sel < opts.length) {
                                yourAnswer = '${labels[sel]}. ${opts[sel]}';
                              }
                              if (cor != null && cor < opts.length) {
                                correctAnswer =
                                    '${labels[cor]}. ${opts[cor]}';
                              }
                              break;

                            case 'true_false':
                              final sel = _answers[i];
                              final cor = q['correctAnswer'] as bool?;
                              isCorrect = sel == cor;
                              yourAnswer = sel == true
                                  ? 'TRUE'
                                  : sel == false
                                      ? 'FALSE'
                                      : '—';
                              correctAnswer =
                                  cor == true ? 'TRUE' : 'FALSE';
                              break;

                            case 'identification':
                            case 'document':
                              final sel =
                                  (_textControllers[i]?.text ?? '').trim();
                              final cor =
                                  (q['answer'] as String? ?? '').trim();
                              isCorrect =
                                  sel.toLowerCase() == cor.toLowerCase();
                              yourAnswer    = sel.isEmpty ? '—' : sel;
                              correctAnswer = cor.isEmpty ? '—' : cor;
                              break;
                          }

                          return Container(
                            margin: const EdgeInsets.only(bottom: 12),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isCorrect
                                  ? Colors.green.shade50
                                  : Colors.red.shade50,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isCorrect
                                    ? Colors.green.shade200
                                    : Colors.red.shade200,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(children: [
                                  Icon(
                                    isCorrect
                                        ? Icons.check_circle
                                        : Icons.cancel,
                                    color: isCorrect
                                        ? Colors.green
                                        : Colors.red,
                                    size: 18,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Q${i + 1}: ${q['question'] ?? ''}',
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13),
                                    ),
                                  ),
                                ]),
                                const SizedBox(height: 6),
                                Text(
                                  'Your answer: $yourAnswer',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isCorrect
                                        ? Colors.green.shade700
                                        : Colors.red.shade700,
                                  ),
                                ),
                                // NEW: only reveal the correct answer text
                                // when the teacher has allowed it AND the
                                // student got the question wrong. If the
                                // student's own answer was already correct,
                                // there's nothing extra to reveal — their
                                // answer line above already shows it in green.
                                if (!isCorrect && _showCorrectAnswers)
                                  Text(
                                    'Correct answer: $correctAnswer',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.green.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  )
                                else if (!isCorrect && !_showCorrectAnswers)
                                  Text(
                                    'Incorrect',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Colors.red.shade700,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.arrow_back_rounded),
                    label: const Text('Back to Reviews'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1A237E),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}