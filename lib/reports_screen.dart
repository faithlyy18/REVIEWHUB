import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

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
/// Results are sorted from highest score to lowest score.
/// All statistics (top cards + Board Exam Statistics + Subject Summary) are
/// computed from the actual results — nothing is hardcoded.
///
/// SUBJECT FILTER / SEARCH
///   • The "All subjects" dropdown lists every subject that has results (it
///     is built from the results themselves, so it works for every subject,
///     including ones added later).
///   • Typing a subject in the search box (e.g. "FORENSIC 1" or
///     "Forensic Photography") narrows the report the same way.
///   • The top cards, Board Exam Statistics, the Subject Summary and the
///     results table all follow the selected subject / search text. The
///     Subject Summary shows, per subject: students who took it, passed,
///     failed and the pass percentage.
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

class _ReportsScreenState extends State<ReportsScreen> {
  static const _brand = Color(0xFF1A237E);
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const _border = Color(0xFFE8EAF6);
  static const _muted = Color(0xFF9096B4);
  static const double _maxWidth = 1100;
  // Raised from 760 because the table now has 7 columns instead of 6.
  // Below this width the report switches to the compact card list.
  static const double _tableBreakpoint = 860;

  late final Stream<QuerySnapshot> _resultsStream;
  late final Stream<QuerySnapshot> _quizzesStream;
  late final Stream<QuerySnapshot> _usersStream;

  String? _subjectFilter; // null = all subjects
  String? _quizFilter; // null = all reviews
  _StatusFilter _status = _StatusFilter.all;
  String _search = '';

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

  String _fmtDate(Timestamp? ts) {
    if (ts == null) return '—';
    final d = ts.toDate();
    return '${_months[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _fmtTime(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate();
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    return '$h12:$mm ${d.hour >= 12 ? 'PM' : 'AM'}';
  }

  String _pct(double v) =>
      v % 1 == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

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
                // If the selected subject vanished, fall back to all.
                final activeSubject = subjectOptions.contains(_subjectFilter)
                    ? _subjectFilter
                    : null;

                // Review dropdown options (only reviews that have results).
                final reviewOptions = <String, String>{};
                for (final r in all) {
                  reviewOptions[r.quizId] = r.subject.isNotEmpty
                      ? '${r.quizTitle} — ${r.subject}'
                      : r.quizTitle;
                }
                // If the selected review vanished, fall back to all.
                final activeQuiz =
                    reviewOptions.containsKey(_quizFilter) ? _quizFilter : null;

                final q = _search.trim().toLowerCase();
                // Scope = subject filter + review filter + search. Stats use
                // this scope so the passed/failed counts always add up to
                // the total.
                final scoped = all.where((r) {
                  if (activeSubject != null && r.subjectLabel != activeSubject) {
                    return false;
                  }
                  if (activeQuiz != null && r.quizId != activeQuiz) {
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
                                  reviewOptions, activeQuiz),
                              const SizedBox(height: 12),
                              _buildSubjectSummary(
                                scoped,
                                autoOpen: activeSubject != null || q.isNotEmpty,
                              ),
                              _buildResultsCard(
                                scoped: scoped,
                                visible: visible,
                                useTable: w - 28 >= _tableBreakpoint,
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
    // Statistics, highest score, Subject Summary).
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
          onChanged: (v) => setState(() => _subjectFilter = v),
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
          onChanged: (v) => setState(() => _quizFilter = v),
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
  // subject dropdown, the review dropdown and the search box, so searching
  // "FORENSIC 1" shows that subject's numbers straight away.
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

  // ── Results list ─────────────────────────────────────────────────────────
  Widget _buildResultsCard({
    required List<_Rep> scoped,
    required List<_Rep> visible,
    required bool useTable,
  }) {
    final passedCount = scoped.where((r) => r.passed).length;
    final failedCount = scoped.length - passedCount;

    Widget chip(String label, _StatusFilter f) {
      final on = _status == f;
      return GestureDetector(
        onTap: () => setState(() => _status = f),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFE8EAF6) : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: on ? _brand.withOpacity(0.5) : const Color(0xFFD0D5E8)),
          ),
          child: Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: on ? _brand : Colors.grey[600])),
        ),
      );
    }

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
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: Row(children: [
              Expanded(
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  chip('All (${scoped.length})', _StatusFilter.all),
                  chip('Passed ($passedCount)', _StatusFilter.passed),
                  chip('Failed ($failedCount)', _StatusFilter.failed),
                ]),
              ),
              const SizedBox(width: 8),
              Text('Sorted by score, highest first',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey[600])),
            ]),
          ),
          const Divider(height: 1, color: _border),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('No results match the current filters.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 13)),
              ),
            )
          else if (useTable)
            _buildTable(visible)
          else
            _buildCardList(visible),
        ],
      ),
    );
  }

  Widget _buildTable(List<_Rep> rows) {
    const headStyle = TextStyle(
        color: Color(0xFF5C6490), fontWeight: FontWeight.w600, fontSize: 12);

    Widget cell(Widget child, {double v = 10}) => Padding(
          padding: EdgeInsets.symmetric(horizontal: 10, vertical: v),
          child: child,
        );

    final header = TableRow(
      decoration: const BoxDecoration(
        color: Color(0xFFF5F6FB),
        border: Border(bottom: BorderSide(color: Color(0xFFD0D5E8))),
      ),
      children: [
        for (final h in const [
          'Student',
          'Review / Subject',
          'Uploaded By',
          'Score',
          'Percentage',
          'Date taken',
          'Status'
        ])
          cell(Text(h, style: headStyle), v: 9),
      ],
    );

    final body = <TableRow>[
      for (int i = 0; i < rows.length; i++)
        TableRow(
          decoration: BoxDecoration(
            border: i == rows.length - 1
                ? null
                : const Border(bottom: BorderSide(color: _border)),
          ),
          children: [
            cell(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(rows[i].name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 13)),
                if (rows[i].year.isNotEmpty)
                  Text(rows[i].year,
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
              ],
            )),
            cell(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(rows[i].quizTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12.5)),
                if (rows[i].subject.isNotEmpty)
                  Text(rows[i].subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
              ],
            )),
            cell(Text(rows[i].uploadedBy,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                    color: rows[i].uploadedBy == 'Unknown'
                        ? _muted
                        : const Color(0xFF2C2C2A)))),
            cell(Text('${rows[i].score}/${rows[i].total}',
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: rows[i].passed ? _green : _red))),
            cell(Text('${_pct(rows[i].percent)}%',
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13))),
            cell(Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_fmtDate(rows[i].submittedAt),
                    style: const TextStyle(fontSize: 12.5)),
                Text(_fmtTime(rows[i].submittedAt),
                    style: const TextStyle(fontSize: 11.5, color: _muted)),
              ],
            )),
            cell(Align(
                alignment: Alignment.centerLeft,
                child: _StatusPill(passed: rows[i].passed))),
          ],
        ),
    ];

    return Table(
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      columnWidths: const {
        0: FlexColumnWidth(1.9),
        1: FlexColumnWidth(2.6),
        2: FlexColumnWidth(1.8),
        3: FlexColumnWidth(1.0),
        4: FlexColumnWidth(1.1),
        5: FlexColumnWidth(1.5),
        6: FlexColumnWidth(1.1),
      },
      children: [header, ...body],
    );
  }

  Widget _buildCardList(List<_Rep> rows) {
    return Column(children: [
      for (int i = 0; i < rows.length; i++) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      rows[i].year.isNotEmpty
                          ? '${rows[i].name} · ${rows[i].year}'
                          : rows[i].name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(
                      rows[i].subject.isNotEmpty
                          ? '${rows[i].quizTitle} — ${rows[i].subject}'
                          : rows[i].quizTitle,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
                  Text('Uploaded by ${rows[i].uploadedBy}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
                  Text(
                      '${_fmtDate(rows[i].submittedAt)}, ${_fmtTime(rows[i].submittedAt)}',
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
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
                        text: '${rows[i].score}/${rows[i].total}',
                        style: TextStyle(
                            color: rows[i].passed ? _green : _red,
                            fontWeight: FontWeight.bold,
                            fontSize: 13)),
                    TextSpan(
                        text: ' · ${_pct(rows[i].percent)}%',
                        style: const TextStyle(color: _muted, fontSize: 12)),
                  ]),
                ),
                const SizedBox(height: 4),
                _StatusPill(passed: rows[i].passed),
              ],
            ),
          ]),
        ),
        if (i != rows.length - 1) const Divider(height: 1, color: _border),
      ],
    ]);
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