import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// ReportsScreen — admin-only report of every review and every exam attempt.
///
/// Sections:
///  1. Summary cards (examinees, pass %, fail %, average, highest, lowest)
///  2. Top performer
///  3. Reviews uploaded by instructors (ALL reviews, even with no takers),
///     each with its taker count, pass/fail %, average and top scorer
///  4. Board-exam statistics by subject
///  5. Examinee results table (rank, name, subject, score, remarks, date...)
///
/// Reads `quizzes` + `quiz_results` (+ `users` once, for instructor names).
/// Pass/fail uses the passing % saved on the result (if present), else the
/// quiz's `passingPercent`, else 75.
///
/// Use as a tab body:   const ReportsScreen()
/// Or as its own page:  const ReportsScreen(standalone: true)
class ReportsScreen extends StatefulWidget {
  final bool standalone;
  const ReportsScreen({super.key, this.standalone = false});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

class _ReportsScreenState extends State<ReportsScreen> {
  static const _brand = Color(0xFF1A237E);
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const _border = Color(0xFFE8EAF6);
  static const _muted = Color(0xFF9096B4);
  static const double _defaultPassing = 75;
  static const double _maxWidth = 1100;

  late final Future<bool> _isAdminFuture;
  Map<String, String> _names = {}; // uid -> display name
  late final Stream<QuerySnapshot> _quizStream;
  late final Stream<QuerySnapshot> _resultStream;

  String? _subject;
  String? _quizId;
  String? _year;
  String? _instructor;
  DateTimeRange? _range;

  @override
  void initState() {
    super.initState();
    final db = FirebaseFirestore.instance;
    _quizStream = db.collection('quizzes').snapshots();
    _resultStream = db.collection('quiz_results').snapshots();
    _isAdminFuture = _checkAdmin();
  }

  Future<bool> _checkAdmin() async {
    final u = FirebaseAuth.instance.currentUser;
    if (u == null) return false;
    final d =
        await FirebaseFirestore.instance.collection('users').doc(u.uid).get();
    final isAdmin = d.data()?['accountType'] == 'admin';
    if (isAdmin) {
      try {
        final users =
            await FirebaseFirestore.instance.collection('users').get();
        _names = {for (final x in users.docs) x.id: _nameOf(x.data())};
      } catch (_) {}
    }
    return isAdmin;
  }

  static String _nameOf(Map<String, dynamic> d) {
    final name = _s(d['name']);
    if (name.isNotEmpty) return name;
    final full = '${_s(d['firstName'])} ${_s(d['lastName'])}'.trim();
    if (full.isNotEmpty) return full;
    final email = _s(d['email']);
    return email.isEmpty ? '' : email.split('@').first;
  }

  // ── Helpers ──────────────────────────────────────────────────────────────
  static String _s(dynamic v) => v is String ? v.trim() : '';

  static String _first(List<dynamic> vs) {
    for (final v in vs) {
      final s = _s(v);
      if (s.isNotEmpty) return s;
    }
    return '';
  }

  static String _date(Timestamp? ts) {
    if (ts == null) return '—';
    const m = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final d = ts.toDate();
    return '${m[d.month - 1]} ${d.day}, ${d.year}';
  }

  static String _time(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate();
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '$h:$mm ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  static String _pct(double v) => '${v.toStringAsFixed(1)}%';

  _Rev _toRev(String id, Map<String, dynamic> q) {
    final subject = _first([q['subject']]);
    final title = _first([q['title']]);
    final qs = q['questions'];
    return _Rev(
      id: id,
      title: title.isEmpty ? '(untitled)' : title,
      subject: subject.isEmpty ? 'Unassigned' : subject,
      year: _s(q['yearLevel']),
      instructor: _first([q['instructorName'], _names[_s(q['createdBy'])]]),
      questions: qs is List ? qs.length : 0,
      passing: (q['passingPercent'] as num?)?.toDouble() ?? _defaultPassing,
      archived: q['archived'] as bool? ?? false,
      createdAt: q['createdAt'] as Timestamp?,
    );
  }

  _R _toRow(Map<String, dynamic> m, Map<String, Map<String, dynamic>> quizzes) {
    final quizId = _s(m['quizId']);
    final Map<String, dynamic> q = quizzes[quizId] ?? const {};
    final score = (m['score'] as num?)?.toInt() ?? 0;
    final total = (m['totalQuestions'] as num?)?.toInt() ?? 0;
    final percent = total == 0 ? 0.0 : score / total * 100;
    final passing = ((m['passingPercent'] ?? q['passingPercent']) as num?)
            ?.toDouble() ??
        _defaultPassing;
    final subject = _first([m['subject'], q['subject']]);
    final name = _s(m['studentName']);
    return _R(
      quizId: quizId,
      quizTitle: _first([m['quizTitle'], q['title']]),
      subject: subject.isEmpty ? 'Unassigned' : subject,
      name: name.isEmpty ? 'Unknown Student' : name,
      year: _s(m['yearLevel']),
      instructor: _first([
        m['instructorName'],
        q['instructorName'],
        _names[_s(q['createdBy'])],
      ]),
      score: score,
      total: total,
      percent: percent,
      passing: passing,
      passed: percent >= passing,
      submittedAt: m['submittedAt'] as Timestamp?,
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final content = FutureBuilder<bool>(
      future: _isAdminFuture,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator(color: _brand));
        }
        if (snap.data != true) {
          return _msg(Icons.lock_outline_rounded,
              'Reports are available to administrators only.');
        }
        return _buildReports();
      },
    );

    if (!widget.standalone) return content;
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        title: const Text('Reports',
            style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: content,
    );
  }

  Widget _msg(IconData icon, String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 52, color: Colors.grey[400]),
              const SizedBox(height: 10),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600], fontSize: 14)),
            ],
          ),
        ),
      );

  Widget _buildReports() {
    return StreamBuilder<QuerySnapshot>(
      stream: _quizStream,
      builder: (context, quizSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: _resultStream,
          builder: (context, resSnap) {
            if (quizSnap.hasError) {
              return _msg(Icons.error_outline_rounded,
                  'Could not load reviews.\n${quizSnap.error}');
            }
            if (resSnap.hasError) {
              return _msg(Icons.error_outline_rounded,
                  'Could not load results.\n${resSnap.error}');
            }
            if (!quizSnap.hasData || !resSnap.hasData) {
              return const Center(
                  child: CircularProgressIndicator(color: _brand));
            }
            final quizzes = <String, Map<String, dynamic>>{
              for (final d in quizSnap.data!.docs)
                d.id: d.data() as Map<String, dynamic>,
            };
            final revs =
                quizzes.entries.map((e) => _toRev(e.key, e.value)).toList();
            final rows = resSnap.data!.docs
                .map((d) => _toRow(d.data() as Map<String, dynamic>, quizzes))
                .toList();
            return _buildBody(revs, rows);
          },
        );
      },
    );
  }

  Widget _buildBody(List<_Rev> allRevs, List<_R> allRows) {
    // ── Filter option lists ────────────────────────────────────────────────
    final subjects = {
      ...allRevs.map((v) => v.subject),
      ...allRows.map((r) => r.subject),
    }.toList()
      ..sort();
    final years = allRows
        .map((r) => r.year)
        .where((y) => y.isNotEmpty)
        .toSet()
        .toList()
      ..sort();
    final instructors = {
      ...allRevs.map((v) => v.instructor),
      ...allRows.map((r) => r.instructor),
    }.where((i) => i.isNotEmpty).toList()
      ..sort();

    final quizOptions = <String, String>{};
    for (final v in allRevs) {
      if (_subject != null && v.subject != _subject) continue;
      if (_instructor != null && v.instructor != _instructor) continue;
      quizOptions[v.id] = v.title;
    }

    // ── Apply filters ──────────────────────────────────────────────────────
    final revs = allRevs.where((v) {
      if (_subject != null && v.subject != _subject) return false;
      if (_quizId != null && v.id != _quizId) return false;
      if (_instructor != null && v.instructor != _instructor) return false;
      return true;
    }).toList()
      ..sort((a, b) {
        final aT = a.createdAt, bT = b.createdAt;
        if (aT == null && bT == null) return 0;
        if (aT == null) return 1;
        if (bT == null) return -1;
        return bT.compareTo(aT); // newest first
      });

    final rows = allRows.where((r) {
      if (_subject != null && r.subject != _subject) return false;
      if (_quizId != null && r.quizId != _quizId) return false;
      if (_year != null && r.year != _year) return false;
      if (_instructor != null && r.instructor != _instructor) return false;
      if (_range != null) {
        final t = r.submittedAt?.toDate();
        if (t == null) return false;
        final s = DateTime(
            _range!.start.year, _range!.start.month, _range!.start.day);
        final e = DateTime(_range!.end.year, _range!.end.month, _range!.end.day)
            .add(const Duration(days: 1));
        if (t.isBefore(s) || !t.isBefore(e)) return false;
      }
      return true;
    }).toList();

    // Highest score first; ties -> earlier submission first; ties share rank.
    rows.sort((a, b) {
      final c = b.percent.compareTo(a.percent);
      if (c != 0) return c;
      final aT = a.submittedAt, bT = b.submittedAt;
      if (aT == null && bT == null) return 0;
      if (aT == null) return 1;
      if (bT == null) return -1;
      return aT.compareTo(bT);
    });
    for (int i = 0; i < rows.length; i++) {
      rows[i].rank = (i > 0 && rows[i].percent == rows[i - 1].percent)
          ? rows[i - 1].rank
          : i + 1;
    }

    // ── Groupings (rows are sorted, so first = top scorer) ────────────────
    final byQuiz = <String, List<_R>>{};
    final bySubject = <String, List<_R>>{};
    for (final r in rows) {
      byQuiz.putIfAbsent(r.quizId, () => []).add(r);
      bySubject.putIfAbsent(r.subject, () => []).add(r);
    }
    final reviewCountBySubject = <String, int>{};
    for (final v in revs) {
      reviewCountBySubject[v.subject] =
          (reviewCountBySubject[v.subject] ?? 0) + 1;
    }
    final subjectKeys = {...bySubject.keys, ...reviewCountBySubject.keys}
        .toList()
      ..sort();

    final passedN = rows.where((r) => r.passed).length;
    final failedN = rows.length - passedN;
    final avg = rows.isEmpty
        ? 0.0
        : rows.fold<double>(0, (a, r) => a + r.percent) / rows.length;

    return SingleChildScrollView(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _header(rows),
                const SizedBox(height: 12),
                _filters(subjects, years, instructors, quizOptions),
                const SizedBox(height: 12),
                if (rows.isNotEmpty) ...[
                  _summary(rows, passedN, failedN, avg),
                  const SizedBox(height: 12),
                  _topPerformer(rows.first),
                  const SizedBox(height: 12),
                ],
                _card(
                  title: 'Reviews uploaded by instructors',
                  icon: Icons.quiz_rounded,
                  trailing: Text(
                      '${revs.length} review${revs.length == 1 ? '' : 's'}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  child: revs.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: Center(
                            child: Text('No reviews match these filters.',
                                style: TextStyle(color: Colors.grey[500])),
                          ),
                        )
                      : Column(children: [
                          for (int i = 0; i < revs.length; i++) ...[
                            _reviewRow(revs[i], byQuiz[revs[i].id] ?? []),
                            if (i != revs.length - 1)
                              const Divider(height: 1, color: _border),
                          ],
                        ]),
                ),
                const SizedBox(height: 12),
                if (subjectKeys.isNotEmpty)
                  _card(
                    title: 'Board-exam statistics by subject',
                    icon: Icons.school_outlined,
                    child: Column(children: [
                      for (int i = 0; i < subjectKeys.length; i++) ...[
                        _subjectRow(
                            subjectKeys[i],
                            bySubject[subjectKeys[i]] ?? [],
                            reviewCountBySubject[subjectKeys[i]] ?? 0),
                        if (i != subjectKeys.length - 1)
                          const Divider(height: 1, color: _border),
                      ],
                    ]),
                  ),
                if (subjectKeys.isNotEmpty) const SizedBox(height: 12),
                _card(
                  title: 'Examinee results',
                  icon: Icons.list_alt_rounded,
                  trailing: Text(
                      '${rows.length} attempt${rows.length == 1 ? '' : 's'}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  child: rows.isEmpty
                      ? Padding(
                          padding: const EdgeInsets.all(20),
                          child: Center(
                            child: Text(
                                'No student has taken an exam that matches these filters.',
                                textAlign: TextAlign.center,
                                style: TextStyle(color: Colors.grey[500])),
                          ),
                        )
                      : _table(rows),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Sections ─────────────────────────────────────────────────────────────
  Widget _header(List<_R> rows) {
    return Row(children: [
      const Icon(Icons.assessment_rounded, color: _brand),
      const SizedBox(width: 8),
      const Expanded(
        child: Text('Exam Reports',
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.bold, color: _brand)),
      ),
      OutlinedButton.icon(
        onPressed: rows.isEmpty
            ? null
            : () async {
                await Clipboard.setData(ClipboardData(text: _csv(rows)));
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                  content:
                      Text('CSV copied. Paste it into Excel or Google Sheets.'),
                  behavior: SnackBarBehavior.floating,
                ));
              },
        icon: const Icon(Icons.copy_rounded, size: 16),
        label: const Text('Copy CSV'),
        style: OutlinedButton.styleFrom(
          foregroundColor: _brand,
          side: const BorderSide(color: _brand),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
    ]);
  }

  Widget _filters(List<String> subjects, List<String> years,
      List<String> instructors, Map<String, String> quizzes) {
    final hasFilter = _subject != null ||
        _quizId != null ||
        _year != null ||
        _instructor != null ||
        _range != null;
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _dropdown(
          label: 'Subject',
          value: _subject,
          options: {for (final s in subjects) s: s},
          onChanged: (v) => setState(() {
            _subject = v;
            _quizId = null;
          }),
        ),
        _dropdown(
          label: 'Instructor',
          value: _instructor,
          options: {for (final i in instructors) i: i},
          onChanged: (v) => setState(() {
            _instructor = v;
            _quizId = null;
          }),
        ),
        _dropdown(
          label: 'Review / exam',
          value: _quizId,
          options: quizzes,
          onChanged: (v) => setState(() => _quizId = v),
        ),
        _dropdown(
          label: 'Student year level',
          value: _year,
          options: {for (final y in years) y: y},
          onChanged: (v) => setState(() => _year = v),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final picked = await showDateRangePicker(
              context: context,
              firstDate: DateTime(2020),
              lastDate: DateTime.now().add(const Duration(days: 1)),
              initialDateRange: _range,
            );
            if (picked != null) setState(() => _range = picked);
          },
          icon: const Icon(Icons.date_range_rounded, size: 18),
          label: Text(_range == null
              ? 'All dates'
              : '${_range!.start.month}/${_range!.start.day}/${_range!.start.year}'
                  ' – ${_range!.end.month}/${_range!.end.day}/${_range!.end.year}'),
          style: OutlinedButton.styleFrom(
            foregroundColor: _brand,
            backgroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
        if (hasFilter)
          TextButton(
            onPressed: () => setState(() {
              _subject = null;
              _quizId = null;
              _year = null;
              _instructor = null;
              _range = null;
            }),
            child: const Text('Clear filters'),
          ),
      ],
    );
  }

  Widget _dropdown({
    required String label,
    required String? value,
    required Map<String, String> options,
    required ValueChanged<String?> onChanged,
  }) {
    final v = options.containsKey(value) ? value : null;
    return SizedBox(
      width: 210,
      child: DropdownButtonFormField<String?>(
        value: v,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: label,
          filled: true,
          fillColor: Colors.white,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
        ),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('All')),
          for (final e in options.entries)
            DropdownMenuItem<String?>(
              value: e.key,
              child: Text(e.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: onChanged,
      ),
    );
  }

  Widget _summary(List<_R> rows, int passedN, int failedN, double avg) {
    final n = rows.length;
    final highest = rows.first; // sorted desc
    final lowest = rows.last;
    final tiles = <Widget Function(double)>[
      (w) => _tile(w, Icons.people_alt_outlined, 'Total examinees', '$n'),
      (w) => _tile(w, Icons.check_circle_outline_rounded, 'Passed',
          _pct(passedN / n * 100),
          color: _green, sub: '$passedN student(s)'),
      (w) => _tile(w, Icons.cancel_outlined, 'Failed', _pct(failedN / n * 100),
          color: _red, sub: '$failedN student(s)'),
      (w) => _tile(w, Icons.bar_chart_rounded, 'Average score', _pct(avg)),
      (w) => _tile(w, Icons.arrow_upward_rounded, 'Highest',
          _pct(highest.percent),
          sub: highest.name),
      (w) => _tile(w, Icons.arrow_downward_rounded, 'Lowest',
          _pct(lowest.percent),
          sub: lowest.name),
    ];
    return LayoutBuilder(builder: (context, c) {
      const gap = 8.0;
      final cols = c.maxWidth >= 900 ? 6 : (c.maxWidth >= 560 ? 3 : 2);
      final w = (c.maxWidth - gap * (cols - 1)) / cols;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [for (final t in tiles) t(w)],
      );
    });
  }

  Widget _tile(double width, IconData icon, String label, String value,
      {Color color = _brand, String? sub}) {
    return Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: Colors.grey[600]),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ),
          ]),
          const SizedBox(height: 3),
          Text(value,
              style: TextStyle(
                  fontSize: 20, fontWeight: FontWeight.bold, color: color)),
          if (sub != null)
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11.5, color: _muted)),
        ],
      ),
    );
  }

  Widget _topPerformer(_R r) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF8E1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFFFE082)),
      ),
      child: Row(children: [
        const Icon(Icons.emoji_events_rounded,
            color: Color(0xFFF9A825), size: 28),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Top performer',
                  style: TextStyle(fontSize: 11.5, color: _muted)),
              Text(r.name,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 15)),
              Text(
                  '${r.score}/${r.total} (${_pct(r.percent)}) · ${r.subject}'
                  '${r.quizTitle.isEmpty ? '' : ' — ${r.quizTitle}'}'
                  ' · ${_date(r.submittedAt)}',
                  style: const TextStyle(fontSize: 12, color: Colors.black54)),
            ],
          ),
        ),
      ]),
    );
  }

  Widget _card({
    required String title,
    required IconData icon,
    required Widget child,
    Widget? trailing,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(children: [
              Icon(icon, size: 18, color: _brand),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: _brand)),
              ),
              if (trailing != null) trailing,
            ]),
          ),
          const Divider(height: 1, color: _border),
          child,
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label, {Color? color}) {
    final c = color ?? const Color(0xFF3949AB);
    return Container(
      constraints: const BoxConstraints(maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: c.withOpacity(0.10),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 11, color: c),
        const SizedBox(width: 4),
        Flexible(
          child: Text(label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 11, color: c, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }

  /// One uploaded review, with its outcome. Tap to filter results to it.
  Widget _reviewRow(_Rev v, List<_R> list) {
    final n = list.length;
    final p = list.where((r) => r.passed).length;
    final f = n - p;
    final avg = n == 0
        ? 0.0
        : list.fold<double>(0, (a, r) => a + r.percent) / n;

    return InkWell(
      onTap: () => setState(() => _quizId = v.id),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(v.title,
                style: const TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14, color: _brand)),
            const SizedBox(height: 6),
            Wrap(spacing: 6, runSpacing: 4, children: [
              _chip(Icons.menu_book_rounded, v.subject),
              _chip(Icons.person_rounded,
                  v.instructor.isEmpty ? 'Unknown instructor' : v.instructor),
              if (v.year.isNotEmpty) _chip(Icons.school_rounded, v.year),
              _chip(Icons.help_outline_rounded,
                  '${v.questions} question${v.questions == 1 ? '' : 's'}'),
              _chip(Icons.flag_rounded, 'Passing ${v.passing.toStringAsFixed(0)}%'),
              _chip(Icons.event_rounded, 'Posted ${_date(v.createdAt)}'),
              if (v.archived)
                _chip(Icons.inventory_2_rounded, 'Archived',
                    color: const Color(0xFFD84315)),
            ]),
            const SizedBox(height: 8),
            if (n == 0)
              const Text('No students have taken this review yet.',
                  style: TextStyle(fontSize: 12.5, color: _muted))
            else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  height: 8,
                  child: Row(children: [
                    if (p > 0)
                      Expanded(flex: p, child: Container(color: _green)),
                    if (f > 0)
                      Expanded(flex: f, child: Container(color: _red)),
                  ]),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(spacing: 16, runSpacing: 4, children: [
                Text('Taken by $n',
                    style: const TextStyle(
                        fontSize: 12.5, fontWeight: FontWeight.w600)),
                Text('Passed ${_pct(p / n * 100)} ($p)',
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: _green,
                        fontWeight: FontWeight.w600)),
                Text('Failed ${_pct(f / n * 100)} ($f)',
                    style: const TextStyle(
                        fontSize: 12.5,
                        color: _red,
                        fontWeight: FontWeight.w600)),
                Text('Average ${_pct(avg)}',
                    style: const TextStyle(fontSize: 12.5)),
                Text(
                    'Top: ${list.first.name} (${_pct(list.first.percent)})',
                    style: const TextStyle(fontSize: 12.5)),
              ]),
            ],
          ],
        ),
      ),
    );
  }

  Widget _subjectRow(String subject, List<_R> list, int reviewCount) {
    final n = list.length;
    final p = list.where((r) => r.passed).length;
    final f = n - p;
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(subject,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 14)),
            ),
            Text(
                '$reviewCount review${reviewCount == 1 ? '' : 's'} · '
                '$n taker${n == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 12, color: _muted)),
          ]),
          const SizedBox(height: 8),
          if (n == 0)
            const Text('No students have taken this subject yet.',
                style: TextStyle(fontSize: 12.5, color: _muted))
          else ...[
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 10,
                child: Row(children: [
                  if (p > 0) Expanded(flex: p, child: Container(color: _green)),
                  if (f > 0) Expanded(flex: f, child: Container(color: _red)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(spacing: 16, runSpacing: 4, children: [
              Text('Passed ${_pct(p / n * 100)} ($p)',
                  style: const TextStyle(
                      fontSize: 12.5,
                      color: _green,
                      fontWeight: FontWeight.w600)),
              Text('Failed ${_pct(f / n * 100)} ($f)',
                  style: const TextStyle(
                      fontSize: 12.5,
                      color: _red,
                      fontWeight: FontWeight.w600)),
              Text(
                  'Average ${_pct(list.fold<double>(0, (a, r) => a + r.percent) / n)}',
                  style: const TextStyle(fontSize: 12.5)),
              Text('Top: ${list.first.name} (${_pct(list.first.percent)})',
                  style: const TextStyle(fontSize: 12.5)),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _table(List<_R> rows) {
    const head = TextStyle(
        color: Color(0xFF5C6490), fontWeight: FontWeight.w600, fontSize: 12);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: DataTable(
        headingRowHeight: 40,
        dataRowMinHeight: 48,
        dataRowMaxHeight: 56,
        columnSpacing: 22,
        headingRowColor: MaterialStateProperty.all(const Color(0xFFF5F6FB)),
        columns: [
          for (final h in const [
            'Rank', 'Student', 'Year', 'Subject', 'Review', 'Instructor',
            'Score', 'Remarks', 'Date & time'
          ])
            DataColumn(label: Text(h, style: head)),
        ],
        rows: [
          for (final r in rows)
            DataRow(
              color: r.rank == 1
                  ? MaterialStateProperty.all(const Color(0xFFFFF8E1))
                  : null,
              cells: [
                DataCell(Row(mainAxisSize: MainAxisSize.min, children: [
                  if (r.rank == 1)
                    const Icon(Icons.workspace_premium_rounded,
                        size: 17, color: Color(0xFFF9A825)),
                  const SizedBox(width: 2),
                  Text('${r.rank}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                ])),
                DataCell(Text(r.name,
                    style: const TextStyle(fontWeight: FontWeight.w600))),
                DataCell(Text(r.year.isEmpty ? '—' : r.year)),
                DataCell(Text(r.subject)),
                DataCell(Text(r.quizTitle.isEmpty ? '—' : r.quizTitle)),
                DataCell(Text(r.instructor.isEmpty ? '—' : r.instructor)),
                DataCell(Text('${r.score}/${r.total} · ${r.percent.round()}%',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: r.passed ? _green : _red))),
                DataCell(_pill(r.passed)),
                DataCell(Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_date(r.submittedAt),
                        style: const TextStyle(fontSize: 12.5)),
                    Text(_time(r.submittedAt),
                        style: const TextStyle(fontSize: 11.5, color: _muted)),
                  ],
                )),
              ],
            ),
        ],
      ),
    );
  }

  Widget _pill(bool passed) {
    final color = passed ? _green : _red;
    final bg = passed ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(passed ? 'Passed' : 'Failed',
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 11.5)),
    );
  }

  // ── CSV ──────────────────────────────────────────────────────────────────
  String _csv(List<_R> rows) {
    String e(String v) => '"${v.replaceAll('"', '""')}"';
    final b = StringBuffer(
        'Rank,Student,Year Level,Subject,Review,Instructor,Score,Total,Percent,Passing %,Remarks,Date,Time\n');
    for (final r in rows) {
      b.writeln([
        r.rank,
        e(r.name),
        e(r.year),
        e(r.subject),
        e(r.quizTitle),
        e(r.instructor),
        r.score,
        r.total,
        r.percent.toStringAsFixed(1),
        r.passing.toStringAsFixed(0),
        r.passed ? 'Passed' : 'Failed',
        e(_date(r.submittedAt)),
        e(_time(r.submittedAt)),
      ].join(','));
    }
    return b.toString();
  }
}

/// One uploaded review (a `quizzes` document).
class _Rev {
  final String id;
  final String title;
  final String subject;
  final String year;
  final String instructor;
  final int questions;
  final double passing;
  final bool archived;
  final Timestamp? createdAt;

  _Rev({
    required this.id,
    required this.title,
    required this.subject,
    required this.year,
    required this.instructor,
    required this.questions,
    required this.passing,
    required this.archived,
    required this.createdAt,
  });
}

/// One exam attempt (a `quiz_results` document).
class _R {
  final String quizId;
  final String quizTitle;
  final String subject;
  final String name;
  final String year;
  final String instructor;
  final int score;
  final int total;
  final double percent;
  final double passing;
  final bool passed;
  final Timestamp? submittedAt;
  int rank = 0;

  _R({
    required this.quizId,
    required this.quizTitle,
    required this.subject,
    required this.name,
    required this.year,
    required this.instructor,
    required this.score,
    required this.total,
    required this.percent,
    required this.passing,
    required this.passed,
    required this.submittedAt,
  });
}