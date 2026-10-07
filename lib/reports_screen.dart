import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

/// ReportsScreen — admin-only report of REAL completed reviews.
///
/// Data sources (all live Firestore streams, nothing static):
///   • quiz_results  → every submission a student completes (written by
///                     TakeQuizScreen: studentName, quizId, quizTitle,
///                     score, totalQuestions, submittedAt, ...)
///   • quizzes       → subject + optional `passingPercent` per review, and
///                     the uploader (`createdBy` uid / `createdByName`).
///                     A result is ONLY counted if its review still exists,
///                     so Reports always matches the instructor
///                     Quiz Results screens (no orphaned/old results).
///   • users         → fallback for a student's full name and year level
///                     if a result doesn't have them saved, and the live
///                     name of the instructor who uploaded a review.
///
/// New submissions appear automatically (snapshots), no refresh needed.
///
/// DAILY REVIEW REPORT (sales-inventory style)
///   The results are no longer one long list. They are grouped PER DAY, like
///   a daily sales report:
///     Date | Students Who Took | Submissions | Passed | Failed |
///     Pass Rate | Average | Highest
///   • Newest day first. Tap a day to open its individual records (time,
///     student, review / subject, uploaded by, score, status). "Expand all"
///     / "Collapse all" opens or closes every day at once.
///   • A TOTAL row at the bottom sums everything currently shown.
///   • Period chips: All time, Today, Last 7 days, This month, Custom range.
///   • The Print button prints (or saves as PDF) the daily summary, the
///     TOTAL row and the per-day records of whatever is currently shown, so
///     it always matches the subject / review / search / period / status
///     filters on screen.
///   • "Students Who Took" counts UNIQUE students for that day. The TOTAL row
///     counts each student once overall, so it can be lower than the sum of
///     the days.
///
/// All statistics (top cards + Board Exam Statistics + Subject Summary) are
/// computed from the actual results — nothing is hardcoded — and they also
/// follow the selected period.
///
/// SUBJECT FILTER / SEARCH
///   • The "All subjects" dropdown lists every subject that has results (it
///     is built from the results themselves, so it works for every subject,
///     including ones added later).
///   • Typing a subject in the search box (e.g. "FORENSIC 1" or
///     "Forensic Photography") narrows the report the same way.
///   • The top cards, Board Exam Statistics, the Subject Summary and the
///     daily report all follow the selected subject / search text. The
///     Subject Summary shows, per subject: students who took it, passed,
///     failed and the pass percentage.
///   • The subject dropdown and the review dropdown are SYNCHRONIZED:
///     choosing a subject auto-selects its review (or "All reviews" when the
///     subject has several), and choosing a review auto-selects its subject.
///     The instructor only has to choose once; the two can never contradict
///     each other.
///   • Counting rule (same as the top cards): "Passed" / "Failed" count each
///     student's latest attempt per review, and the pass percentage is
///     passed ÷ (passed + failed). "Students who took it" counts unique
///     students.
///
/// Pass mark: each quiz's `passingPercent` if set, otherwise
/// [kDefaultPassingPercent] below (75, same as the other result screens).
///
/// "Uploaded By": always taken from the REVIEW document (the quiz the
/// result belongs to), never from the student's attempt, so it is the
/// instructor who uploaded that specific review.
///
/// Requires the `pdf` and `printing` packages (see pubspec.yaml).
///
/// Opened from the drawer as: ReportsScreen(standalone: true)
const double kDefaultPassingPercent = 75;

class ReportsScreen extends StatefulWidget {
  /// true  → returns its own Scaffold + AppBar (own page).
  /// false → returns just the body (for embedding in a tab).
  final bool standalone;
  const ReportsScreen({super.key, this.standalone = false});

  @override
  State<ReportsScreen> createState() => _ReportsScreenState();
}

enum _StatusFilter { all, passed, failed }

enum _RangePreset { all, today, week, month, custom }

class _ReportsScreenState extends State<ReportsScreen> {
  static const _brand = Color(0xFF1A237E);
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const _border = Color(0xFFE8EAF6);
  static const _muted = Color(0xFF9096B4);
  static const double _maxWidth = 1100;
  // The daily table has 8 columns + an expand arrow. Below this width the
  // report switches to compact day cards.
  static const double _tableBreakpoint = 820;

  late final Stream<QuerySnapshot> _resultsStream;
  late final Stream<QuerySnapshot> _quizzesStream;
  late final Stream<QuerySnapshot> _usersStream;

  String? _subjectFilter; // null = all subjects
  String? _quizFilter; // null = all reviews
  _StatusFilter _status = _StatusFilter.all;
  String _search = '';

  // Period filter for the daily report.
  _RangePreset _range = _RangePreset.all;
  DateTimeRange? _customRange;

  // Days (by key) whose individual records are currently open.
  final Set<String> _openDays = <String>{};

  // Subject Summary is collapsed by default while no subject filter / search
  // is active (so a long subject list doesn't push the results down). It opens
  // automatically as soon as a subject is selected or something is searched.
  bool _summaryOpen = false;

  @override
  void initState() {
    super.initState();
    final db = FirebaseFirestore.instance;
    _resultsStream = db.collection('quiz_results').snapshots();
    _quizzesStream = db.collection('quizzes').snapshots();
    _usersStream = db.collection('users').snapshots();
  }

  // ── Formatting ───────────────────────────────────────────────────────────
  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];
  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  String _fmtTime(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate();
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '$h12:$mm ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _fmtDay(DateTime d) => '${_months[d.month - 1]} ${d.day}, ${d.year}';

  String _fmtDayTime(DateTime d) {
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '${_fmtDay(d)} $h12:$mm ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _pct(double v) =>
      v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  DateTime _dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  String _dayKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // Label shown in the review dropdown. It always carries the subject label
  // (e.g. "CDI 1 — Fundamentals ...") so it visibly matches the subject
  // dropdown when the two are synchronized.
  String _reviewLabel(_Rep r) {
    final sl = r.subjectLabel;
    if (sl == 'No subject') return r.quizTitle;
    if (sl.toLowerCase().startsWith(r.quizTitle.toLowerCase())) return sl;
    return '${r.quizTitle} · $sl';
  }

  // ── Period filter ────────────────────────────────────────────────────────
  DateTimeRange? _activeRange() {
    final today = _dayOnly(DateTime.now());
    switch (_range) {
      case _RangePreset.all:
        return null;
      case _RangePreset.today:
        return DateTimeRange(start: today, end: today);
      case _RangePreset.week:
        return DateTimeRange(
            start: today.subtract(const Duration(days: 6)), end: today);
      case _RangePreset.month:
        return DateTimeRange(
            start: DateTime(today.year, today.month, 1), end: today);
      case _RangePreset.custom:
        return _customRange;
    }
  }

  bool _inRange(_Rep r, DateTimeRange? range) {
    if (range == null) return true;
    final ts = r.submittedAt;
    if (ts == null) return false;
    final d = _dayOnly(ts.toDate());
    return !d.isBefore(range.start) && !d.isAfter(range.end);
  }

  String _rangeLabel(DateTimeRange? range) {
    if (range == null) return 'All dates';
    if (range.start == range.end) return _fmtDay(range.start);
    return '${_fmtDay(range.start)} – ${_fmtDay(range.end)}';
  }

  Future<void> _pickRange() async {
    final today = _dayOnly(DateTime.now());
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: today,
      initialDateRange: _customRange,
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: Theme.of(context).colorScheme.copyWith(primary: _brand),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      _customRange = DateTimeRange(
          start: _dayOnly(picked.start), end: _dayOnly(picked.end));
      _range = _RangePreset.custom;
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final body = _buildBody();
    if (!widget.standalone) return body;
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        title: const Text('Reports',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
      ),
      body: body,
    );
  }

  Widget _buildBody() {
    return StreamBuilder<QuerySnapshot>(
      stream: _resultsStream,
      builder: (context, resSnap) {
        return StreamBuilder<QuerySnapshot>(
          stream: _quizzesStream,
          builder: (context, quizSnap) {
            return StreamBuilder<QuerySnapshot>(
              stream: _usersStream,
              builder: (context, userSnap) {
                if (resSnap.hasError) return _buildError(resSnap.error);
                if (!resSnap.hasData || !quizSnap.hasData) {
                  if (quizSnap.hasError) return _buildError(quizSnap.error);
                  return const Center(
                      child: CircularProgressIndicator(color: _brand));
                }

                // quizId -> quiz data (only reviews that currently exist)
                final quizzes = <String, Map<String, dynamic>>{
                  for (final d in quizSnap.data!.docs)
                    d.id: d.data() as Map<String, dynamic>,
                };

                // uid -> full name / year level (fallbacks only; the users
                // read may be denied or still loading, which is fine).
                // Also used to turn a review's `createdBy` uid into the
                // instructor's current name.
                final names = <String, String>{};
                final years = <String, String>{};
                for (final d in userSnap.data?.docs ?? const []) {
                  final m = d.data() as Map<String, dynamic>;
                  // Full name: `fullName` if present, otherwise first (+middle)
                  // + last when a last name exists, otherwise `name`.
                  final fn = (m['fullName'] as String?)?.trim() ?? '';
                  final n = (m['name'] as String?)?.trim() ?? '';
                  final f = (m['firstName'] as String?)?.trim() ?? '';
                  final mid = (m['middleName'] as String?)?.trim() ?? '';
                  final l = (m['lastName'] as String?)?.trim() ?? '';
                  final composed =
                      l.isNotEmpty ? [f, mid, l].where((s) => s.isNotEmpty).join(' ') : '';
                  final full = fn.isNotEmpty
                      ? fn
                      : (composed.isNotEmpty ? composed : n);
                  if (full.isNotEmpty) names[d.id] = full;
                  final y = (m['yearLevel'] as String?)?.trim() ?? '';
                  if (y.isNotEmpty) years[d.id] = y;
                }

                final all =
                    _normalise(resSnap.data!.docs, quizzes, names, years);
                if (all.isEmpty) return _buildEmpty();

                // Subject dropdown options: every subject that has results.
                final subjectOptions = all.map((r) => r.subjectLabel).toSet().toList()
                  ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

                // Every review that has results: its label and the subject it
                // belongs to.
                final allReviewLabels = <String, String>{};
                final reviewSubject = <String, String>{};
                for (final r in all) {
                  allReviewLabels[r.quizId] = _reviewLabel(r);
                  reviewSubject.putIfAbsent(r.quizId, () => r.subjectLabel);
                }

                // The two selectors are kept in sync: a selected review always
                // decides the subject shown, so they can never contradict each
                // other. If the selected review / subject vanished, fall back
                // to all.
                final activeQuiz =
                    allReviewLabels.containsKey(_quizFilter) ? _quizFilter : null;
                final activeSubject = activeQuiz != null
                    ? reviewSubject[activeQuiz]
                    : (subjectOptions.contains(_subjectFilter)
                        ? _subjectFilter
                        : null);

                // Review dropdown lists only the reviews of the chosen subject
                // (all reviews while no subject is chosen).
                final reviewOptions = <String, String>{
                  for (final e in allReviewLabels.entries)
                    if (activeSubject == null ||
                        reviewSubject[e.key] == activeSubject)
                      e.key: e.value,
                };

                final q = _search.trim().toLowerCase();
                // Subject filter + review filter + search.
                final subjectScoped = all.where((r) {
                  // A chosen review decides on its own (its subject is synced
                  // automatically); otherwise filter by the chosen subject.
                  if (activeQuiz != null) {
                    if (r.quizId != activeQuiz) return false;
                  } else if (activeSubject != null &&
                      r.subjectLabel != activeSubject) {
                    return false;
                  }
                  if (q.isNotEmpty &&
                      !r.name.toLowerCase().contains(q) &&
                      !r.quizTitle.toLowerCase().contains(q) &&
                      !r.subject.toLowerCase().contains(q) &&
                      !r.subjectCode.toLowerCase().contains(q) &&
                      !r.subjectLabel.toLowerCase().contains(q) &&
                      !r.uploadedBy.toLowerCase().contains(q)) {
                    return false;
                  }
                  return true;
                }).toList();

                // Scope = subject filter + review filter + search + period.
                // Stats use this scope so the passed/failed counts always add
                // up to the total.
                final range = _activeRange();
                final scoped =
                    subjectScoped.where((r) => _inRange(r, range)).toList();

                final visible = scoped.where((r) {
                  switch (_status) {
                    case _StatusFilter.passed:
                      return r.passed;
                    case _StatusFilter.failed:
                      return !r.passed;
                    case _StatusFilter.all:
                      return true;
                  }
                }).toList();

                return LayoutBuilder(builder: (context, c) {
                  final w = c.maxWidth > _maxWidth ? _maxWidth : c.maxWidth;
                  return SingleChildScrollView(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: _maxWidth),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildStats(scoped, narrow: w < 560),
                              const SizedBox(height: 12),
                              _buildBoardExamStats(scoped),
                              const SizedBox(height: 12),
                              _buildFilters(subjectOptions, activeSubject,
                                  reviewOptions, activeQuiz, reviewSubject),
                              const SizedBox(height: 12),
                              _buildSubjectSummary(
                                scoped,
                                autoOpen: activeSubject != null || q.isNotEmpty,
                              ),
                              _buildDailyReport(
                                scoped: scoped,
                                visible: visible,
                                useTable: w - 28 >= _tableBreakpoint,
                                subjectText: activeSubject ?? 'All subjects',
                                reviewText: activeQuiz == null
                                    ? 'All reviews'
                                    : (allReviewLabels[activeQuiz] ??
                                        'All reviews'),
                                searchText: _search.trim(),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                });
              },
            );
          },
        );
      },
    );
  }

  // ── Data ─────────────────────────────────────────────────────────────────
  List<_Rep> _normalise(
    List<QueryDocumentSnapshot> docs,
    Map<String, Map<String, dynamic>> quizzes,
    Map<String, String> names,
    Map<String, String> years,
  ) {
    final rows = <_Rep>[];
    for (final d in docs) {
      final m = d.data() as Map<String, dynamic>;
      final quizId = (m['quizId'] as String?) ?? '';

      // Only count results whose review still exists. This is what makes
      // Reports match the instructor Quiz Results screens and removes old /
      // orphaned results from deleted reviews.
      final quiz = quizzes[quizId];
      if (quizId.isEmpty || quiz == null) continue;

      final uid = ((m['studentUid'] ?? m['studentId']) as String?) ?? '';
      // Full name: the student's account (users) is the source of truth,
      // because the name saved on a result may be only a first name.
      // The saved name is used only when no account name can be found.
      final savedName = ((m['studentName'] as String?) ?? '').trim();
      var name = names[uid] ?? '';
      if (name.isEmpty) name = savedName;
      if (name.isEmpty || name.toLowerCase() == 'unknown student') {
        name = 'Unknown Student';
      }

      var year = ((m['yearLevel'] as String?) ?? '').trim();
      if (year.isEmpty) year = years[uid] ?? '';

      final score = (m['score'] as num?)?.toInt() ?? 0;
      final total = (m['totalQuestions'] as num?)?.toInt() ?? 0;
      final percent = total == 0 ? 0.0 : score / total * 100;
      final passMark = (quiz['passingPercent'] as num?)?.toDouble() ??
          kDefaultPassingPercent;

      final subjectFromResult = ((m['subject'] as String?) ?? '').trim();
      final subject = subjectFromResult.isNotEmpty
          ? subjectFromResult
          : ((quiz['subject'] as String?) ?? '').trim();

      // Optional curriculum code (e.g. "FORENSIC 1") if the review or the
      // result happens to store one. Used only for searching / labelling.
      final rawCode = m['subjectCode'] ?? quiz['subjectCode'];
      final subjectCode = rawCode is String ? rawCode.trim() : '';

      final titleFromResult = ((m['quizTitle'] as String?) ?? '').trim();
      final quizTitle = ((quiz['title'] as String?) ?? '').trim();
      final title = titleFromResult.isNotEmpty
          ? titleFromResult
          : (quizTitle.isNotEmpty ? quizTitle : 'Untitled Review');

      // Uploader comes ONLY from the review document (`quiz`), never from
      // the student's result. Order of preference:
      //   1. the uploader's current name from `users` (via createdBy uid)
      //   2. the name saved on the review (`createdByName`)
      //   3. 'Unknown' (older reviews with neither)
      final creatorUid = ((quiz['createdBy'] as String?) ?? '').trim();
      final savedCreatorName =
          ((quiz['createdByName'] as String?) ?? '').trim();
      var uploadedBy = '';
      if (creatorUid.isNotEmpty) uploadedBy = names[creatorUid] ?? '';
      if (uploadedBy.isEmpty) uploadedBy = savedCreatorName;
      if (uploadedBy.isEmpty) uploadedBy = 'Unknown';

      rows.add(_Rep(
        studentKey: uid.isNotEmpty ? uid : name.toLowerCase(),
        name: name,
        year: year,
        quizId: quizId,
        quizTitle: title,
        subject: subject,
        subjectCode: subjectCode,
        uploadedBy: uploadedBy,
        score: score,
        total: total,
        percent: percent,
        submittedAt: m['submittedAt'] as Timestamp?,
        passed: percent >= passMark,
      ));
    }

    // Retakes: keep ONLY each student's latest attempt per review. Earlier
    // attempts are dropped here, so they are not displayed and are not
    // counted in any statistic (totals, passed/failed, Board Exam
    // Statistics, highest score, Subject Summary, Daily Report).
    final latest = <String, _Rep>{};
    for (final r in rows) {
      final key = '${r.studentKey}|${r.quizId}';
      final existing = latest[key];
      if (existing == null) {
        latest[key] = r;
        continue;
      }
      final a = r.submittedAt, b = existing.submittedAt;
      final isNewer = a != null && (b == null || a.compareTo(b) > 0);
      if (isNewer) latest[key] = r;
    }
    rows
      ..clear()
      ..addAll(latest.values);

    // Highest score -> lowest, based on each student's latest attempt.
    // Percentage first (reviews have different totals), then raw score,
    // then newest submission as the tie-breaker.
    rows.sort((a, b) {
      final byPct = b.percent.compareTo(a.percent);
      if (byPct != 0) return byPct;
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final aT = a.submittedAt, bT = b.submittedAt;
      if (aT == null && bT == null) return 0;
      if (aT == null) return 1;
      if (bT == null) return -1;
      return bT.compareTo(aT);
    });
    return rows;
  }

  // Groups rows per calendar day (newest day first). Inside a day the
  // records are in the order they were taken (earliest first), like the
  // line items of a daily sales ledger.
  List<_Day> _groupByDay(List<_Rep> rows) {
    final map = <String, _Day>{};
    for (final r in rows) {
      final dt = r.submittedAt?.toDate();
      final date = dt == null ? null : _dayOnly(dt);
      final key = date == null ? 'nodate' : _dayKey(date);
      map.putIfAbsent(key, () => _Day(key, date)).rows.add(r);
    }
    final list = map.values.toList();
    for (final d in list) {
      d.rows.sort((a, b) {
        final aT = a.submittedAt, bT = b.submittedAt;
        if (aT == null && bT == null) return 0;
        if (aT == null) return 1;
        if (bT == null) return -1;
        return aT.compareTo(bT);
      });
    }
    list.sort((a, b) {
      if (a.date == null && b.date == null) return 0;
      if (a.date == null) return 1;
      if (b.date == null) return -1;
      return b.date!.compareTo(a.date!);
    });
    return list;
  }

  String _dayTitle(_Day d) => d.date == null ? 'No date' : _fmtDay(d.date!);

  String _dayWeekday(_Day d) =>
      d.date == null ? '' : _weekdays[d.date!.weekday - 1];

  // ── Statistics ───────────────────────────────────────────────────────────
  Widget _buildStats(List<_Rep> rows, {required bool narrow}) {
    final submissions = rows.length;
    final students = rows.map((r) => r.studentKey).toSet().length;
    final passed = rows.where((r) => r.passed).length;
    final failed = submissions - passed;
    final passPct = submissions == 0 ? 0.0 : passed / submissions * 100;
    final failPct = submissions == 0 ? 0.0 : failed / submissions * 100;

    _Rep? best;
    for (final r in rows) {
      if (best == null || r.percent > best.percent) best = r;
    }

    final tiles = <Widget>[
      _StatTile(
        icon: Icons.people_alt_outlined,
        label: 'Students Who Took',
        value: '$students',
        sub: '$submissions submission${submissions == 1 ? '' : 's'}',
      ),
      _StatTile(
        icon: Icons.check_circle_outline_rounded,
        label: 'Passed',
        value: '$passed',
        sub: '${_pct(passPct)}%',
        color: _green,
      ),
      _StatTile(
        icon: Icons.cancel_outlined,
        label: 'Failed',
        value: '$failed',
        sub: '${_pct(failPct)}%',
        color: _red,
      ),
      _StatTile(
        icon: Icons.emoji_events_outlined,
        label: 'Highest Score',
        value: best == null ? '—' : '${best.score}/${best.total}',
        sub: best == null
            ? 'No data'
            : '${_pct(best.percent)}% · ${best.name}',
        color: const Color(0xFFF9A825),
      ),
    ];

    if (!narrow) {
      return Row(children: [
        for (int i = 0; i < tiles.length; i++) ...[
          if (i > 0) const SizedBox(width: 8),
          Expanded(child: tiles[i]),
        ],
      ]);
    }
    return Column(children: [
      Row(children: [
        Expanded(child: tiles[0]),
        const SizedBox(width: 8),
        Expanded(child: tiles[1]),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: tiles[2]),
        const SizedBox(width: 8),
        Expanded(child: tiles[3]),
      ]),
    ]);
  }

  // ── Board Exam Statistics ────────────────────────────────────────────────
  // Overall passing / failing percentage, calculated from the actual
  // results currently in scope (e.g. 3 passed + 1 failed = 75% / 25%).
  Widget _buildBoardExamStats(List<_Rep> rows) {
    final total = rows.length;
    final passed = rows.where((r) => r.passed).length;
    final failed = total - passed;
    final passPct = total == 0 ? 0.0 : passed / total * 100;
    final failPct = total == 0 ? 0.0 : failed / total * 100;

    Widget legend(String label, String value, int count, Color c) => Expanded(
          child: Row(children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(
                          text: '$value% ',
                          style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: c)),
                      TextSpan(
                          text: label,
                          style: TextStyle(
                              fontSize: 13, color: Colors.grey[700])),
                    ]),
                  ),
                  Text('$count of $total',
                      style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
                ],
              ),
            ),
          ]),
        );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.bar_chart_rounded, size: 16, color: _brand),
            const SizedBox(width: 6),
            const Text('Board Exam Statistics',
                style: TextStyle(
                    fontWeight: FontWeight.bold, fontSize: 14, color: _brand)),
            const Spacer(),
            Text('$total submission${total == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            legend('Passed', _pct(passPct), passed, _green),
            legend('Failed', _pct(failPct), failed, _red),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 10,
              child: total == 0
                  ? Container(color: const Color(0xFFE8EAF6))
                  : Row(children: [
                      if (passed > 0)
                        Expanded(flex: passed, child: Container(color: _green)),
                      if (failed > 0)
                        Expanded(flex: failed, child: Container(color: _red)),
                    ]),
            ),
          ),
        ],
      ),
    );
  }

  // ── Filters ──────────────────────────────────────────────────────────────
  Widget _buildFilters(
    List<String> subjectOptions,
    String? activeSubject,
    Map<String, String> reviewOptions,
    String? activeQuiz,
    Map<String, String> reviewSubject,
  ) {
    Widget box(Widget child) => Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: const Color(0xFFD0D5E8)),
          ),
          child: child,
        );

    const ddStyle = TextStyle(
        fontSize: 12.5, color: _brand, fontWeight: FontWeight.w600);
    const ddIcon = Icon(Icons.keyboard_arrow_down_rounded,
        size: 18, color: Color(0xFF3949AB));

    // Subject filter — one entry per subject that has results.
    final subjectDropdown = box(
      DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isExpanded: true,
          value: activeSubject,
          icon: ddIcon,
          style: ddStyle,
          onChanged: (v) => setState(() {
            _subjectFilter = v;
            if (v == null) {
              _quizFilter = null; // "All subjects" resets both selectors
              return;
            }
            // Keep the current review if it belongs to this subject.
            if (_quizFilter != null && reviewSubject[_quizFilter] == v) return;
            // Otherwise auto-select the subject's review (when it has just
            // one) so the review dropdown follows; several -> "All reviews".
            final ids = reviewSubject.entries
                .where((e) => e.value == v)
                .map((e) => e.key)
                .toList();
            _quizFilter = ids.length == 1 ? ids.first : null;
          }),
          items: [
            const DropdownMenuItem<String?>(
                value: null, child: Text('All subjects')),
            for (final s in subjectOptions)
              DropdownMenuItem<String?>(
                value: s,
                child: Text(s, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );

    final dropdown = box(
      DropdownButtonHideUnderline(
        child: DropdownButton<String?>(
          isExpanded: true,
          value: activeQuiz,
          icon: ddIcon,
          style: ddStyle,
          onChanged: (v) => setState(() {
            _quizFilter = v;
            // Choosing a review also selects the subject it belongs to.
            if (v != null) _subjectFilter = reviewSubject[v];
          }),
          items: [
            const DropdownMenuItem<String?>(
                value: null, child: Text('All reviews')),
            for (final e in reviewOptions.entries)
              DropdownMenuItem<String?>(
                value: e.key,
                child: Text(e.value, overflow: TextOverflow.ellipsis),
              ),
          ],
        ),
      ),
    );

    final search = SizedBox(
      height: 42,
      child: TextField(
        onChanged: (v) => setState(() => _search = v),
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search student, review, subject or instructor',
          hintStyle: const TextStyle(fontSize: 12.5),
          prefixIcon: const Icon(Icons.search_rounded, size: 18),
          filled: true,
          fillColor: Colors.white,
          contentPadding: EdgeInsets.zero,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFD0D5E8)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: Color(0xFFD0D5E8)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: _brand),
          ),
        ),
      ),
    );

    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth >= 760) {
        return Row(children: [
          Expanded(child: subjectDropdown),
          const SizedBox(width: 10),
          Expanded(child: dropdown),
          const SizedBox(width: 10),
          Expanded(child: search),
        ]);
      }
      return Column(children: [
        subjectDropdown,
        const SizedBox(height: 8),
        dropdown,
        const SizedBox(height: 8),
        search,
      ]);
    });
  }

  // ── Subject Summary ──────────────────────────────────────────────────────
  // One block per subject in the current scope: students who took it, how
  // many passed, how many failed and the pass percentage. Follows the
  // subject dropdown, the review dropdown, the period and the search box, so
  // searching "FORENSIC 1" shows that subject's numbers straight away.
  List<_SubjStat> _subjectStats(List<_Rep> rows) {
    final map = <String, _SubjStat>{};
    for (final r in rows) {
      final s = map.putIfAbsent(r.subjectLabel, () => _SubjStat(r.subjectLabel));
      s.students.add(r.studentKey);
      if (r.passed) {
        s.passed++;
      } else {
        s.failed++;
      }
    }
    final list = map.values.toList()
      ..sort((a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    return list;
  }

  Widget _buildSubjectSummary(List<_Rep> rows, {required bool autoOpen}) {
    final stats = _subjectStats(rows);
    if (stats.isEmpty) return const SizedBox.shrink();
    final open = autoOpen || _summaryOpen;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              const Icon(Icons.menu_book_rounded, size: 16, color: _brand),
              const SizedBox(width: 6),
              const Text('Subject Summary',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: _brand)),
              const Spacer(),
              Text('${stats.length} subject${stats.length == 1 ? '' : 's'}',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
              if (!autoOpen) ...[
                const SizedBox(width: 6),
                TextButton(
                  onPressed: () => setState(() => _summaryOpen = !_summaryOpen),
                  style: TextButton.styleFrom(
                    foregroundColor: _brand,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(_summaryOpen ? 'Hide' : 'Show',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                ),
              ],
            ]),
            if (open) ...[
              const SizedBox(height: 10),
              for (int i = 0; i < stats.length; i++) ...[
                if (i > 0) const SizedBox(height: 8),
                _subjectRow(stats[i]),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _subjectRow(_SubjStat s) {
    final total = s.passed + s.failed;
    final passPct = total == 0 ? 0.0 : s.passed / total * 100;

    Widget mini(String label, String value, Color c) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value,
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold, color: c)),
              Text(label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey[600])),
            ],
          ),
        );

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F6FB),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Expanded(
              child: Text(s.label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      color: _brand)),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE8EAF6),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text('${_pct(passPct)}% pass rate',
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: _brand)),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            mini('Students took it', '${s.students.length}', _brand),
            mini('Passed', '${s.passed}', _green),
            mini('Failed', '${s.failed}', _red),
            mini('Pass rate', '${_pct(passPct)}%', _brand),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              height: 8,
              child: total == 0
                  ? Container(color: const Color(0xFFE8EAF6))
                  : Row(children: [
                      if (s.passed > 0)
                        Expanded(
                            flex: s.passed, child: Container(color: _green)),
                      if (s.failed > 0)
                        Expanded(
                            flex: s.failed, child: Container(color: _red)),
                    ]),
            ),
          ),
          const SizedBox(height: 4),
          Text(
              '$total submission${total == 1 ? '' : 's'} · latest attempt per student',
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ],
      ),
    );
  }

  // ── Daily Review Report (sales-inventory style) ──────────────────────────
  Widget _chip(String label, bool on, VoidCallback onTap, {IconData? icon}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        decoration: BoxDecoration(
          color: on ? const Color(0xFFE8EAF6) : Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: on ? _brand.withOpacity(0.5) : const Color(0xFFD0D5E8)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: on ? _brand : Colors.grey[600]),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: on ? _brand : Colors.grey[600])),
          ),
        ]),
      ),
    );
  }

  Widget _buildDailyReport({
    required List<_Rep> scoped,
    required List<_Rep> visible,
    required bool useTable,
    required String subjectText,
    required String reviewText,
    required String searchText,
  }) {
    final passedCount = scoped.where((r) => r.passed).length;
    final failedCount = scoped.length - passedCount;
    final days = _groupByDay(visible);
    final tot = _Tot.of(visible);
    final range = _activeRange();
    final allOpen = days.isNotEmpty && days.every((d) => _openDays.contains(d.key));

    String statusText;
    switch (_status) {
      case _StatusFilter.passed:
        statusText = 'Passed only';
        break;
      case _StatusFilter.failed:
        statusText = 'Failed only';
        break;
      case _StatusFilter.all:
        statusText = 'All';
        break;
    }

    final printBtn = ElevatedButton.icon(
      onPressed: days.isEmpty
          ? null
          : () => _printReport(
                days: days,
                tot: tot,
                period: _rangeLabel(range),
                subject: subjectText,
                review: reviewText,
                status: statusText,
                search: searchText,
              ),
      icon: const Icon(Icons.print_rounded, size: 16),
      label: const Text('Print',
          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
      style: ElevatedButton.styleFrom(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        minimumSize: const Size(0, 36),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );

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
          // Title + Print
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 4),
            child: Row(children: [
              const Icon(Icons.event_note_rounded, size: 17, color: _brand),
              const SizedBox(width: 6),
              const Expanded(
                child: Text('Daily Review Report',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14.5,
                        color: _brand)),
              ),
              printBtn,
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            child: Text(
                '${days.length} day${days.length == 1 ? '' : 's'} · '
                '${tot.submissions} submission${tot.submissions == 1 ? '' : 's'} · '
                'newest day first · ${_rangeLabel(range)}',
                style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
          ),
          const Divider(height: 1, color: _border),

          // Period chips
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
            child: Wrap(spacing: 6, runSpacing: 6, children: [
              _chip('All time', _range == _RangePreset.all,
                  () => setState(() => _range = _RangePreset.all)),
              _chip('Today', _range == _RangePreset.today,
                  () => setState(() => _range = _RangePreset.today)),
              _chip('Last 7 days', _range == _RangePreset.week,
                  () => setState(() => _range = _RangePreset.week)),
              _chip('This month', _range == _RangePreset.month,
                  () => setState(() => _range = _RangePreset.month)),
              _chip(
                _range == _RangePreset.custom && _customRange != null
                    ? _rangeLabel(_customRange)
                    : 'Custom range',
                _range == _RangePreset.custom,
                _pickRange,
                icon: Icons.calendar_month_rounded,
              ),
            ]),
          ),

          // Status chips + expand / collapse all
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 10),
            child: Row(children: [
              Expanded(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  _chip('All (${scoped.length})', _status == _StatusFilter.all,
                      () => setState(() => _status = _StatusFilter.all)),
                  _chip('Passed ($passedCount)',
                      _status == _StatusFilter.passed,
                      () => setState(() => _status = _StatusFilter.passed)),
                  _chip('Failed ($failedCount)',
                      _status == _StatusFilter.failed,
                      () => setState(() => _status = _StatusFilter.failed)),
                ]),
              ),
              if (days.isNotEmpty)
                TextButton.icon(
                  onPressed: () => setState(() {
                    if (allOpen) {
                      _openDays.clear();
                    } else {
                      _openDays.addAll(days.map((d) => d.key));
                    }
                  }),
                  icon: Icon(
                      allOpen
                          ? Icons.unfold_less_rounded
                          : Icons.unfold_more_rounded,
                      size: 16),
                  label: Text(allOpen ? 'Collapse all' : 'Expand all',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  style: TextButton.styleFrom(
                    foregroundColor: _brand,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    minimumSize: const Size(0, 30),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ]),
          ),
          const Divider(height: 1, color: _border),

          if (days.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('No results match the current filters.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 13)),
              ),
            )
          else ...[
            if (useTable) _buildDayTable(days) else _buildDayCards(days),
            _buildTotal(tot, days.length, useTable),
          ],
        ],
      ),
    );
  }

  void _toggleDay(_Day d) => setState(() {
        if (!_openDays.remove(d.key)) _openDays.add(d.key);
      });

  Widget _mini(String label, String value, Color c) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: TextStyle(
                    fontSize: 17, fontWeight: FontWeight.bold, color: c)),
            Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: Colors.grey[600])),
          ],
        ),
      );

  // ---- Wide screens: ledger table ------------------------------------------
  // Column flex values shared by the header, the day rows and the TOTAL row so
  // everything lines up.
  static const int _fDate = 22;
  static const int _fStudents = 14;
  static const int _fSubs = 13;
  static const int _fPassed = 10;
  static const int _fFailed = 10;
  static const int _fRate = 12;
  static const int _fAvg = 12;
  static const int _fHigh = 12;

  Widget _numCell(String v, int flex, {Color? color, bool bold = false}) =>
      Expanded(
        flex: flex,
        child: Text(v,
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 13,
                fontWeight: bold ? FontWeight.bold : FontWeight.w500,
                color: color)),
      );

  Widget _buildDayTable(List<_Day> days) {
    const head = TextStyle(
        color: Color(0xFF5C6490), fontWeight: FontWeight.w600, fontSize: 12);
    Widget h(String t, int flex, {TextAlign a = TextAlign.center}) =>
        Expanded(flex: flex, child: Text(t, textAlign: a, style: head));

    return Column(children: [
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: const BoxDecoration(
          color: Color(0xFFF5F6FB),
          border: Border(bottom: BorderSide(color: Color(0xFFD0D5E8))),
        ),
        child: Row(children: [
          const SizedBox(width: 28),
          h('Date', _fDate, a: TextAlign.left),
          h('Students Who Took', _fStudents),
          h('Submissions', _fSubs),
          h('Passed', _fPassed),
          h('Failed', _fFailed),
          h('Pass Rate', _fRate),
          h('Average', _fAvg),
          h('Highest', _fHigh),
        ]),
      ),
      for (final d in days) _dayRowWide(d),
    ]);
  }

  Widget _dayRowWide(_Day d) {
    final open = _openDays.contains(d.key);
    final t = d.t;
    return Column(children: [
      InkWell(
        onTap: () => _toggleDay(d),
        child: Container(
          color: open ? const Color(0xFFF5F6FB) : Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
          child: Row(children: [
            SizedBox(
              width: 28,
              child: Icon(
                  open
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 20,
                  color: _brand),
            ),
            Expanded(
              flex: _fDate,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_dayTitle(d),
                      style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                          color: _brand)),
                  if (_dayWeekday(d).isNotEmpty)
                    Text(_dayWeekday(d),
                        style: const TextStyle(fontSize: 11.5, color: _muted)),
                ],
              ),
            ),
            _numCell('${t.students}', _fStudents, bold: true),
            _numCell('${t.submissions}', _fSubs),
            _numCell('${t.passed}', _fPassed, color: _green, bold: true),
            _numCell('${t.failed}', _fFailed,
                color: t.failed > 0 ? _red : _muted, bold: true),
            _numCell('${_pct(t.passRate)}%', _fRate),
            _numCell('${_pct(t.avg)}%', _fAvg),
            _numCell('${_pct(t.highest)}%', _fHigh),
          ]),
        ),
      ),
      if (open) _detailWide(d),
      const Divider(height: 1, color: _border),
    ]);
  }

  Widget _detailWide(_Day d) {
    const hs = TextStyle(
        fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF5C6490));
    Widget hc(String t, int f) =>
        Expanded(flex: f, child: Text(t, style: hs));

    return Container(
      color: const Color(0xFFFAFBFE),
      padding: const EdgeInsets.fromLTRB(40, 6, 12, 10),
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            hc('Time', 11),
            hc('Student', 24),
            hc('Review / Subject', 28),
            hc('Uploaded By', 20),
            hc('Score', 13),
            hc('Status', 10),
          ]),
        ),
        const Divider(height: 1, color: Color(0xFFD0D5E8)),
        for (int i = 0; i < d.rows.length; i++) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              Expanded(
                flex: 11,
                child: Text(_fmtTime(d.rows[i].submittedAt),
                    style: const TextStyle(fontSize: 12.5)),
              ),
              Expanded(
                flex: 24,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(d.rows[i].name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12.5)),
                    if (d.rows[i].year.isNotEmpty)
                      Text(d.rows[i].year,
                          style:
                              const TextStyle(fontSize: 11, color: _muted)),
                  ],
                ),
              ),
              Expanded(
                flex: 28,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(d.rows[i].quizTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12.5)),
                    if (d.rows[i].subject.isNotEmpty)
                      Text(d.rows[i].subject,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              const TextStyle(fontSize: 11, color: _muted)),
                  ],
                ),
              ),
              Expanded(
                flex: 20,
                child: Text(d.rows[i].uploadedBy,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 12,
                        color: d.rows[i].uploadedBy == 'Unknown'
                            ? _muted
                            : const Color(0xFF2C2C2A))),
              ),
              Expanded(
                flex: 13,
                child: RichText(
                  text: TextSpan(children: [
                    TextSpan(
                        text: '${d.rows[i].score}/${d.rows[i].total}',
                        style: TextStyle(
                            color: d.rows[i].passed ? _green : _red,
                            fontWeight: FontWeight.bold,
                            fontSize: 12.5)),
                    TextSpan(
                        text: ' · ${_pct(d.rows[i].percent)}%',
                        style:
                            const TextStyle(color: _muted, fontSize: 11.5)),
                  ]),
                ),
              ),
              Expanded(
                flex: 10,
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: _StatusPill(passed: d.rows[i].passed)),
              ),
            ]),
          ),
          if (i != d.rows.length - 1)
            const Divider(height: 1, color: _border),
        ],
      ]),
    );
  }

  // ---- Phones: one compact card per day -------------------------------------
  Widget _buildDayCards(List<_Day> days) {
    return Column(children: [for (final d in days) _dayCard(d)]);
  }

  Widget _dayCard(_Day d) {
    final open = _openDays.contains(d.key);
    final t = d.t;
    return Column(children: [
      InkWell(
        onTap: () => _toggleDay(d),
        child: Container(
          color: open ? const Color(0xFFF5F6FB) : Colors.white,
          padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_dayTitle(d),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                              color: _brand)),
                      if (_dayWeekday(d).isNotEmpty)
                        Text(_dayWeekday(d),
                            style: const TextStyle(
                                fontSize: 11.5, color: _muted)),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8EAF6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text('${_pct(t.passRate)}% pass rate',
                      style: const TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.bold,
                          color: _brand)),
                ),
                Icon(
                    open
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: _brand),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                _mini('Students took', '${t.students}', _brand),
                _mini('Submissions', '${t.submissions}', _brand),
                _mini('Passed', '${t.passed}', _green),
                _mini('Failed', '${t.failed}', t.failed > 0 ? _red : _muted),
              ]),
              const SizedBox(height: 6),
              Text('Average ${_pct(t.avg)}% · Highest ${_pct(t.highest)}%',
                  style: const TextStyle(fontSize: 11.5, color: _muted)),
            ],
          ),
        ),
      ),
      if (open)
        Container(
          color: const Color(0xFFFAFBFE),
          child: Column(children: [
            const Divider(height: 1, color: _border),
            for (int i = 0; i < d.rows.length; i++) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                child: Row(children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            d.rows[i].year.isNotEmpty
                                ? '${d.rows[i].name} · ${d.rows[i].year}'
                                : d.rows[i].name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontWeight: FontWeight.w600, fontSize: 13)),
                        const SizedBox(height: 2),
                        Text(
                            d.rows[i].subject.isNotEmpty
                                ? '${d.rows[i].quizTitle} — ${d.rows[i].subject}'
                                : d.rows[i].quizTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5, color: _muted)),
                        Text(
                            'Uploaded by ${d.rows[i].uploadedBy} · ${_fmtTime(d.rows[i].submittedAt)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                fontSize: 11.5, color: _muted)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      RichText(
                        text: TextSpan(children: [
                          TextSpan(
                              text: '${d.rows[i].score}/${d.rows[i].total}',
                              style: TextStyle(
                                  color: d.rows[i].passed ? _green : _red,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 13)),
                          TextSpan(
                              text: ' · ${_pct(d.rows[i].percent)}%',
                              style: const TextStyle(
                                  color: _muted, fontSize: 12)),
                        ]),
                      ),
                      const SizedBox(height: 4),
                      _StatusPill(passed: d.rows[i].passed),
                    ],
                  ),
                ]),
              ),
              if (i != d.rows.length - 1)
                const Divider(height: 1, color: _border),
            ],
          ]),
        ),
      const Divider(height: 1, color: _border),
    ]);
  }

  // ---- TOTAL row -------------------------------------------------------------
  Widget _buildTotal(_Tot t, int dayCount, bool useTable) {
    const bg = Color(0xFFEEF0FA);
    final caption = Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Text(
          'Students Who Took counts unique students per day. The TOTAL counts '
          'each student once, so it can be lower than the sum of the days. '
          'Latest attempt per student per review.',
          style: TextStyle(fontSize: 11, color: Colors.grey[600])),
    );

    if (useTable) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          color: bg,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(children: [
            const SizedBox(width: 28),
            Expanded(
              flex: _fDate,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('TOTAL',
                      style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13.5,
                          color: _brand)),
                  Text('$dayCount day${dayCount == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
                ],
              ),
            ),
            _numCell('${t.students}', _fStudents, bold: true, color: _brand),
            _numCell('${t.submissions}', _fSubs, bold: true, color: _brand),
            _numCell('${t.passed}', _fPassed, bold: true, color: _green),
            _numCell('${t.failed}', _fFailed,
                bold: true, color: t.failed > 0 ? _red : _muted),
            _numCell('${_pct(t.passRate)}%', _fRate, bold: true, color: _brand),
            _numCell('${_pct(t.avg)}%', _fAvg, bold: true, color: _brand),
            _numCell('${_pct(t.highest)}%', _fHigh, bold: true, color: _brand),
          ]),
        ),
        caption,
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        color: bg,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Text('TOTAL · $dayCount day${dayCount == 1 ? '' : 's'}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 13.5,
                      color: _brand)),
              const Spacer(),
              Text('${_pct(t.passRate)}% pass rate',
                  style: const TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                      color: _brand)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              _mini('Students took', '${t.students}', _brand),
              _mini('Submissions', '${t.submissions}', _brand),
              _mini('Passed', '${t.passed}', _green),
              _mini('Failed', '${t.failed}', t.failed > 0 ? _red : _muted),
            ]),
            const SizedBox(height: 6),
            Text('Average ${_pct(t.avg)}% · Highest ${_pct(t.highest)}%',
                style: const TextStyle(fontSize: 11.5, color: _muted)),
          ],
        ),
      ),
      caption,
    ]);
  }

  // ── Print ────────────────────────────────────────────────────────────────
  // PDF built-in fonts only cover Latin characters, so typographic symbols
  // are replaced with plain ones before printing.
  String _a(String s) => s
      .replaceAll('—', '-')
      .replaceAll('–', '-')
      .replaceAll('·', '-')
      .replaceAll('’', "'")
      .replaceAll('‘', "'")
      .replaceAll('“', '"')
      .replaceAll('”', '"');

  Future<void> _printReport({
    required List<_Day> days,
    required _Tot tot,
    required String period,
    required String subject,
    required String review,
    required String status,
    required String search,
  }) async {
    try {
      final bytes = await _buildPdf(
        days: days,
        tot: tot,
        period: period,
        subject: subject,
        review: review,
        status: status,
        search: search,
      );
      await Printing.layoutPdf(
        name: 'Daily_Review_Report',
        onLayout: (_) async => bytes,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open the print preview: $e')),
      );
    }
  }

  Future<Uint8List> _buildPdf({
    required List<_Day> days,
    required _Tot tot,
    required String period,
    required String subject,
    required String review,
    required String status,
    required String search,
  }) async {
    final doc = pw.Document();

    final brand = PdfColor.fromInt(0xFF1A237E);
    final green = PdfColor.fromInt(0xFF2E7D32);
    final red = PdfColor.fromInt(0xFFC62828);
    final grey = PdfColor.fromInt(0xFF5C6490);

    pw.Widget cell(
      String text, {
      bool bold = false,
      PdfColor? color,
      pw.TextAlign align = pw.TextAlign.left,
      double size = 8.5,
    }) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          child: pw.Text(
            _a(text),
            textAlign: align,
            style: pw.TextStyle(
              fontSize: size,
              fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
              color: color,
            ),
          ),
        );

    final printed = _fmtDayTime(DateTime.now());

    // ── Daily summary table ────────────────────────────────────────────────
    const heads = [
      'Date',
      'Students Who Took',
      'Submissions',
      'Passed',
      'Failed',
      'Pass Rate',
      'Average',
      'Highest',
    ];

    final summaryRows = <pw.TableRow>[
      pw.TableRow(
        repeat: true,
        decoration: pw.BoxDecoration(color: brand),
        children: [
          for (int i = 0; i < heads.length; i++)
            cell(heads[i],
                bold: true,
                color: PdfColors.white,
                align: i == 0 ? pw.TextAlign.left : pw.TextAlign.center),
        ],
      ),
      for (final d in days)
        pw.TableRow(children: [
          cell(
              d.date == null
                  ? 'No date'
                  : '${_weekdays[d.date!.weekday - 1]}, ${_fmtDay(d.date!)}',
              bold: true),
          cell('${d.t.students}', align: pw.TextAlign.center),
          cell('${d.t.submissions}', align: pw.TextAlign.center),
          cell('${d.t.passed}', align: pw.TextAlign.center, color: green),
          cell('${d.t.failed}',
              align: pw.TextAlign.center, color: d.t.failed > 0 ? red : null),
          cell('${_pct(d.t.passRate)}%', align: pw.TextAlign.center),
          cell('${_pct(d.t.avg)}%', align: pw.TextAlign.center),
          cell('${_pct(d.t.highest)}%', align: pw.TextAlign.center),
        ]),
      pw.TableRow(
        decoration: pw.BoxDecoration(color: PdfColors.grey300),
        children: [
          cell('TOTAL (${days.length} day${days.length == 1 ? '' : 's'})',
              bold: true),
          cell('${tot.students}', bold: true, align: pw.TextAlign.center),
          cell('${tot.submissions}', bold: true, align: pw.TextAlign.center),
          cell('${tot.passed}',
              bold: true, align: pw.TextAlign.center, color: green),
          cell('${tot.failed}',
              bold: true,
              align: pw.TextAlign.center,
              color: tot.failed > 0 ? red : null),
          cell('${_pct(tot.passRate)}%', bold: true, align: pw.TextAlign.center),
          cell('${_pct(tot.avg)}%', bold: true, align: pw.TextAlign.center),
          cell('${_pct(tot.highest)}%', bold: true, align: pw.TextAlign.center),
        ],
      ),
    ];

    final summaryTable = pw.Table(
      border: pw.TableBorder.all(color: PdfColors.grey500, width: 0.5),
      columnWidths: {
        0: const pw.FlexColumnWidth(2.4),
        1: const pw.FlexColumnWidth(1.5),
        2: const pw.FlexColumnWidth(1.3),
        3: const pw.FlexColumnWidth(1.0),
        4: const pw.FlexColumnWidth(1.0),
        5: const pw.FlexColumnWidth(1.1),
        6: const pw.FlexColumnWidth(1.1),
        7: const pw.FlexColumnWidth(1.1),
      },
      children: summaryRows,
    );

    // ── Per-day records ────────────────────────────────────────────────────
    final detailWidgets = <pw.Widget>[];
    for (final d in days) {
      final t = d.t;
      detailWidgets.add(
        pw.Container(
          width: double.infinity,
          color: PdfColors.grey200,
          padding: const pw.EdgeInsets.symmetric(horizontal: 6, vertical: 5),
          child: pw.Text(
            _a('${d.date == null ? 'No date' : '${_weekdays[d.date!.weekday - 1]}, ${_fmtDay(d.date!)}'}'
                '  -  ${t.students} student${t.students == 1 ? '' : 's'}, '
                '${t.submissions} submission${t.submissions == 1 ? '' : 's'}'),
            style: pw.TextStyle(
                fontSize: 9.5, fontWeight: pw.FontWeight.bold, color: brand),
          ),
        ),
      );

      detailWidgets.add(
        pw.Table(
          border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.4),
          columnWidths: {
            0: const pw.FlexColumnWidth(1.1),
            1: const pw.FlexColumnWidth(2.4),
            2: const pw.FlexColumnWidth(0.9),
            3: const pw.FlexColumnWidth(3.0),
            4: const pw.FlexColumnWidth(2.0),
            5: const pw.FlexColumnWidth(1.0),
            6: const pw.FlexColumnWidth(0.9),
            7: const pw.FlexColumnWidth(1.0),
          },
          children: [
            pw.TableRow(
              repeat: true,
              children: [
                for (final h in const [
                  'Time',
                  'Student',
                  'Year',
                  'Review / Subject',
                  'Uploaded By',
                  'Score',
                  '%',
                  'Status'
                ])
                  cell(h, bold: true, color: grey, size: 8),
              ],
            ),
            for (final r in d.rows)
              pw.TableRow(children: [
                cell(_fmtTime(r.submittedAt), size: 8),
                cell(r.name, bold: true, size: 8),
                cell(r.year, size: 8),
                cell(
                    r.subject.isNotEmpty
                        ? '${r.quizTitle} (${r.subject})'
                        : r.quizTitle,
                    size: 8),
                cell(r.uploadedBy, size: 8),
                cell('${r.score}/${r.total}',
                    bold: true, color: r.passed ? green : red, size: 8),
                cell('${_pct(r.percent)}%', size: 8),
                cell(r.passed ? 'Passed' : 'Failed',
                    bold: true, color: r.passed ? green : red, size: 8),
              ]),
          ],
        ),
      );

      detailWidgets.add(
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 4, bottom: 14),
          child: pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              _a('Day total: ${t.students} student${t.students == 1 ? '' : 's'}, '
                  '${t.passed} passed, ${t.failed} failed, '
                  'pass rate ${_pct(t.passRate)}%, average ${_pct(t.avg)}%'),
              style: pw.TextStyle(
                  fontSize: 8.5, fontWeight: pw.FontWeight.bold, color: grey),
            ),
          ),
        ),
      );
    }

    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4.landscape,
        margin: const pw.EdgeInsets.all(28),
        footer: (ctx) => pw.Container(
          alignment: pw.Alignment.centerRight,
          margin: const pw.EdgeInsets.only(top: 8),
          child: pw.Text('Page ${ctx.pageNumber} of ${ctx.pagesCount}',
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700)),
        ),
        build: (ctx) => [
          pw.Text('ReviewHub',
              style: pw.TextStyle(
                  fontSize: 10,
                  fontWeight: pw.FontWeight.bold,
                  color: PdfColors.grey700)),
          pw.SizedBox(height: 2),
          pw.Text('Daily Review Report',
              style: pw.TextStyle(
                  fontSize: 18, fontWeight: pw.FontWeight.bold, color: brand)),
          pw.SizedBox(height: 6),
          pw.Text(_a('Period: $period'), style: const pw.TextStyle(fontSize: 9)),
          pw.Text(_a('Subject: $subject'),
              style: const pw.TextStyle(fontSize: 9)),
          pw.Text(_a('Review: $review'), style: const pw.TextStyle(fontSize: 9)),
          pw.Text(_a('Status: $status'), style: const pw.TextStyle(fontSize: 9)),
          if (search.isNotEmpty)
            pw.Text(_a('Search: $search'),
                style: const pw.TextStyle(fontSize: 9)),
          pw.Text(_a('Date printed: $printed'),
              style: const pw.TextStyle(fontSize: 9)),
          pw.SizedBox(height: 10),
          pw.Text('Daily Summary',
              style: pw.TextStyle(
                  fontSize: 12, fontWeight: pw.FontWeight.bold, color: brand)),
          pw.SizedBox(height: 4),
          summaryTable,
          pw.SizedBox(height: 4),
          pw.Text(
              'Students Who Took counts unique students per day. The TOTAL counts each student once. Latest attempt per student per review.',
              style: const pw.TextStyle(fontSize: 7.5, color: PdfColors.grey700)),
          pw.NewPage(),
          pw.Text('Daily Records',
              style: pw.TextStyle(
                  fontSize: 12, fontWeight: pw.FontWeight.bold, color: brand)),
          pw.SizedBox(height: 6),
          ...detailWidgets,
        ],
      ),
    );

    return doc.save();
  }

  // ── States ───────────────────────────────────────────────────────────────
  Widget _buildError(Object? error) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded,
                  size: 48, color: Colors.red[300]),
              const SizedBox(height: 10),
              const Text('Could not load reports.',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              const SizedBox(height: 6),
              Text('$error',
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  textAlign: TextAlign.center),
            ],
          ),
        ),
      );

  Widget _buildEmpty() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.assessment_outlined,
                  size: 64, color: Colors.grey[400]),
              const SizedBox(height: 12),
              Text('No completed reviews yet.',
                  style: TextStyle(color: Colors.grey[600], fontSize: 16)),
              const SizedBox(height: 4),
              Text('Results will appear here as soon as students submit.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[400], fontSize: 13)),
            ],
          ),
        ),
      );
}

// ── Data holders ─────────────────────────────────────────────────────────────
class _Rep {
  final String studentKey;
  final String name;
  final String year;
  final String quizId;
  final String quizTitle;
  final String subject;
  final String subjectCode;
  final String uploadedBy;
  final int score;
  final int total;
  final double percent;
  final Timestamp? submittedAt;
  final bool passed;

  _Rep({
    required this.studentKey,
    required this.name,
    required this.year,
    required this.quizId,
    required this.quizTitle,
    required this.subject,
    required this.subjectCode,
    required this.uploadedBy,
    required this.score,
    required this.total,
    required this.percent,
    required this.submittedAt,
    required this.passed,
  });

  /// Name used for grouping / the subject dropdown: "CODE — Subject name"
  /// when a code is stored, otherwise the subject name, otherwise
  /// "No subject".
  String get subjectLabel {
    final parts = [subjectCode, subject].where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? 'No subject' : parts.join(' — ');
  }
}

/// Running totals for one subject in the Subject Summary.
class _SubjStat {
  final String label;
  final Set<String> students = <String>{};
  int passed = 0;
  int failed = 0;
  _SubjStat(this.label);
}

/// Totals for a set of results (one day, or everything currently shown).
class _Tot {
  final int students;
  final int submissions;
  final int passed;
  final int failed;
  final double avg; // average percentage
  final double highest; // highest percentage

  _Tot({
    required this.students,
    required this.submissions,
    required this.passed,
    required this.failed,
    required this.avg,
    required this.highest,
  });

  double get passRate => submissions == 0 ? 0.0 : passed / submissions * 100;

  factory _Tot.of(List<_Rep> rows) {
    final students = rows.map((r) => r.studentKey).toSet().length;
    final passed = rows.where((r) => r.passed).length;
    var sum = 0.0;
    var hi = 0.0;
    for (final r in rows) {
      sum += r.percent;
      if (r.percent > hi) hi = r.percent;
    }
    return _Tot(
      students: students,
      submissions: rows.length,
      passed: passed,
      failed: rows.length - passed,
      avg: rows.isEmpty ? 0.0 : sum / rows.length,
      highest: hi,
    );
  }
}

/// One calendar day in the Daily Review Report.
class _Day {
  final String key; // yyyy-MM-dd, or 'nodate'
  final DateTime? date;
  final List<_Rep> rows = <_Rep>[];
  _Day(this.key, this.date);

  // Computed once, after the rows have been added.
  late final _Tot t = _Tot.of(rows);
}

// ── Small widgets ────────────────────────────────────────────────────────────
class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String sub;
  final Color color;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    required this.sub,
    this.color = const Color(0xFF1A237E),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFE8EAF6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: color),
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
                  fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 1),
          Text(sub,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
        ],
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  final bool passed;
  const _StatusPill({required this.passed});

  @override
  Widget build(BuildContext context) {
    final color = passed ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    final bg = passed ? const Color(0xFFE8F5E9) : const Color(0xFFFFEBEE);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(passed ? 'Passed' : 'Failed',
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 11.5)),
    );
  }
}