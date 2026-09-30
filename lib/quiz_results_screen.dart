import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// QuizResultsScreen — all student submissions for a review (quiz).
///
/// LAYOUT
/// - A compact row of four stat tiles (Submissions, Average, Highest, Lowest)
///   visible to everyone. Highest/Lowest are tappable and show the names.
/// - ADMIN ONLY ([isAdmin] == true): one "Examination statistics" card with
///   the overall passing rate, passers / non-passers counts, and the average
///   score and percentage of each group. The Admin can edit the required
///   passing rate (saved on the quiz doc as `passingPercent`, default 75).
/// - Filter chips: All / Passed / Failed.
/// - Results sorted by score, highest first (ties: earlier submission first,
///   tied scores share a rank).
///   * Wide screens  → a six-column table (Rank, Student, Subject/Review,
///     Score, Date & Time, Status) that fits without horizontal scrolling.
///   * Narrow screens (phones) → one compact card per student.
class QuizResultsScreen extends StatefulWidget {
  final String quizId;
  final String quizTitle;

  /// Pass `true` only for Admin accounts. Students/instructors leave it false.
  final bool isAdmin;

  const QuizResultsScreen({
    super.key,
    required this.quizId,
    required this.quizTitle,
    this.isAdmin = false,
  });

  @override
  State<QuizResultsScreen> createState() => _QuizResultsScreenState();
}

enum _ResultFilter { all, passed, failed }

class _QuizResultsScreenState extends State<QuizResultsScreen> {
  static const _brand = Color(0xFF1A237E);
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const _greenBg = Color(0xFFE8F5E9);
  static const _redBg = Color(0xFFFFEBEE);
  static const _border = Color(0xFFE8EAF6);
  static const _muted = Color(0xFF9096B4);
  static const double _defaultPassing = 75;
  static const double _maxWidth = 1000;
  static const double _tableBreakpoint = 700;

  _ResultFilter _filter = _ResultFilter.all;

  // ── Helpers ──────────────────────────────────────────────────────────────
  String _fmtDate(Timestamp? ts) {
    if (ts == null) return '—';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final d = ts.toDate();
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  String _fmtTime(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate();
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    return '$h12:$mm $ampm';
  }

  String _pct(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(1);

  String _rate(double v) => _pct(double.parse(v.toStringAsFixed(1)));

  Future<void> _editPassingPercent(double current) async {
    final controller = TextEditingController(text: _pct(current));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Required passing rate',
            style: TextStyle(color: _brand, fontWeight: FontWeight.bold)),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
          ],
          decoration: const InputDecoration(
            suffixText: '%',
            hintText: 'e.g. 75',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            onPressed: () {
              final v = double.tryParse(controller.text.trim());
              if (v == null || v <= 0 || v > 100) return;
              Navigator.pop(ctx, v);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: _brand, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null) return;
    try {
      await FirebaseFirestore.instance
          .collection('quizzes')
          .doc(widget.quizId)
          .set({'passingPercent': result}, SetOptions(merge: true));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not save passing rate: $e'),
        backgroundColor: Colors.red.shade700,
      ));
    }
  }

  void _showNamesSheet({
    required String title,
    required String names,
    required String scoreLabel,
    required Color accent,
    required IconData icon,
  }) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: accent, size: 18),
                ),
                const SizedBox(width: 10),
                Text(title,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: _brand)),
              ]),
              const SizedBox(height: 14),
              Text(names.isEmpty ? 'No submissions yet.' : names,
                  style: const TextStyle(fontSize: 14, color: Colors.black87)),
              const SizedBox(height: 4),
              Text(scoreLabel,
                  style: TextStyle(fontSize: 12, color: Colors.grey[500])),
            ],
          ),
        ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF0F2F8),
      appBar: AppBar(
        backgroundColor: _brand,
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Review Results',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(widget.quizTitle,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      // Outer stream: the quiz doc (subject + required passing %).
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance
            .collection('quizzes')
            .doc(widget.quizId)
            .snapshots(),
        builder: (context, quizSnap) {
          final quizData =
              (quizSnap.data?.data() as Map<String, dynamic>?) ?? {};
          final passingPercent =
              (quizData['passingPercent'] as num?)?.toDouble() ??
                  _defaultPassing;
          final quizSubject = (quizData['subject'] as String?)?.trim() ?? '';

          // Inner stream: submissions. No orderBy → no composite index
          // needed; sorted client-side below.
          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('quiz_results')
                .where('quizId', isEqualTo: widget.quizId)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(
                    child: CircularProgressIndicator(color: _brand));
              }
              if (snapshot.hasError) return _buildError(snapshot.error);

              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) return _buildEmpty();

              // ── Normalise rows ─────────────────────────────────────────
              final rows = docs.map((d) {
                final m = d.data() as Map<String, dynamic>;
                final score = (m['score'] as num?)?.toInt() ?? 0;
                final total = (m['totalQuestions'] as num?)?.toInt() ?? 1;
                final percent = total == 0 ? 0.0 : score / total * 100;
                final subject =
                    ((m['subject'] as String?)?.trim().isNotEmpty ?? false)
                        ? (m['subject'] as String).trim()
                        : quizSubject;
                final title =
                    ((m['quizTitle'] as String?)?.trim().isNotEmpty ?? false)
                        ? (m['quizTitle'] as String).trim()
                        : widget.quizTitle;
                return _Row(
                  name: (m['studentName'] as String?) ?? 'Unknown Student',
                  year: (m['yearLevel'] as String?) ?? '',
                  subject: subject,
                  quizTitle: title,
                  score: score,
                  total: total,
                  percent: percent,
                  submittedAt: m['submittedAt'] as Timestamp?,
                  passed: percent >= passingPercent,
                );
              }).toList();

              // Highest score first; ties → earlier submission first.
              rows.sort((a, b) {
                final byPct = b.percent.compareTo(a.percent);
                if (byPct != 0) return byPct;
                final aT = a.submittedAt, bT = b.submittedAt;
                if (aT == null && bT == null) return 0;
                if (aT == null) return 1;
                if (bT == null) return -1;
                return aT.compareTo(bT);
              });

              // Ranks (ties share a rank: 1, 2, 2, 4 …)
              for (int i = 0; i < rows.length; i++) {
                rows[i].rank = (i > 0 && rows[i].percent == rows[i - 1].percent)
                    ? rows[i - 1].rank
                    : i + 1;
              }

              // ── Stats (always computed on ALL rows, not the filter) ────
              final total = rows.first.total;
              final avg = rows.map((r) => r.score).reduce((a, b) => a + b) /
                  rows.length;
              final highest = rows.first.score;
              final lowest = rows.last.score;
              final passers =
                  _GroupStats.from(rows.where((r) => r.passed).toList());
              final nonPassers =
                  _GroupStats.from(rows.where((r) => !r.passed).toList());
              final passRate = passers.count / rows.length * 100;
              final failRate = nonPassers.count / rows.length * 100;

              final visible = rows.where((r) {
                switch (_filter) {
                  case _ResultFilter.passed:
                    return r.passed;
                  case _ResultFilter.failed:
                    return !r.passed;
                  case _ResultFilter.all:
                    return true;
                }
              }).toList();

              return LayoutBuilder(builder: (context, constraints) {
                final contentWidth = constraints.maxWidth > _maxWidth
                    ? _maxWidth
                    : constraints.maxWidth;
                final useTable = contentWidth - 28 >= _tableBreakpoint;

                return SingleChildScrollView(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: _maxWidth),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 14, 14, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildKpiStrip(
                              narrow: contentWidth < 480,
                              submissions: rows.length,
                              avg: avg,
                              highest: highest,
                              lowest: lowest,
                              total: total,
                              highestNames: rows
                                  .where((r) => r.score == highest)
                                  .map((r) => r.name)
                                  .toSet()
                                  .join(', '),
                              lowestNames: rows
                                  .where((r) => r.score == lowest)
                                  .map((r) => r.name)
                                  .toSet()
                                  .join(', '),
                            ),
                            // ── ADMIN ONLY ───────────────────────────────
                            if (widget.isAdmin) ...[
                              const SizedBox(height: 12),
                              _buildAdminCard(
                                wide: contentWidth - 28 >= 560,
                                passingPercent: passingPercent,
                                passers: passers,
                                nonPassers: nonPassers,
                                totalStudents: rows.length,
                                totalQuestions: total,
                                passRate: passRate,
                                failRate: failRate,
                              ),
                            ],
                            const SizedBox(height: 12),
                            _buildResultsCard(
                              rows: rows,
                              visible: visible,
                              useTable: useTable,
                              showSortHint: contentWidth >= 520,
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
      ),
    );
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
              const Text('Could not load results.',
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.assignment_outlined, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 12),
            Text('No submissions yet.',
                style: TextStyle(color: Colors.grey[600], fontSize: 16)),
            const SizedBox(height: 4),
            Text("Students haven't taken this review yet.",
                style: TextStyle(color: Colors.grey[400], fontSize: 13)),
          ],
        ),
      );

  // ── 1. KPI strip ─────────────────────────────────────────────────────────
  Widget _buildKpiStrip({
    required bool narrow,
    required int submissions,
    required double avg,
    required int highest,
    required int lowest,
    required int total,
    required String highestNames,
    required String lowestNames,
  }) {
    final tiles = <Widget>[
      _KpiTile(
          icon: Icons.people_alt_outlined,
          label: 'Submissions',
          value: '$submissions'),
      _KpiTile(
          icon: Icons.bar_chart_rounded,
          label: 'Average',
          value: '${avg.toStringAsFixed(1)}/$total'),
      _KpiTile(
        icon: Icons.emoji_events_outlined,
        label: 'Highest',
        value: '$highest/$total',
        onTap: () => _showNamesSheet(
          title: 'Highest score',
          names: highestNames,
          scoreLabel: '$highest out of $total',
          accent: _green,
          icon: Icons.emoji_events_rounded,
        ),
      ),
      _KpiTile(
        icon: Icons.trending_down_rounded,
        label: 'Lowest',
        value: '$lowest/$total',
        onTap: () => _showNamesSheet(
          title: 'Lowest score',
          names: lowestNames,
          scoreLabel: '$lowest out of $total',
          accent: _red,
          icon: Icons.trending_down_rounded,
        ),
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
    // Phones: 2 x 2 grid.
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

  // ── 2. Admin-only examination statistics ─────────────────────────────────
  Widget _buildAdminCard({
    required bool wide,
    required double passingPercent,
    required _GroupStats passers,
    required _GroupStats nonPassers,
    required int totalStudents,
    required int totalQuestions,
    required double passRate,
    required double failRate,
  }) {
    String avgText(_GroupStats g) => g.count == 0
        ? 'No data'
        : 'Avg ${g.avgScore.toStringAsFixed(1)}/$totalQuestions · '
            '${g.avgPercent.toStringAsFixed(1)}%';

    final overall = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Overall passing rate',
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        const SizedBox(height: 2),
        Text('${_rate(passRate)}%',
            style: const TextStyle(
                fontSize: 32,
                height: 1.2,
                fontWeight: FontWeight.bold,
                color: _green)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Container(
            height: 8,
            color: _redBg,
            alignment: Alignment.centerLeft,
            child: FractionallySizedBox(
              widthFactor: (passRate / 100).clamp(0.0, 1.0),
              child: Container(color: _green),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text('${passers.count} of $totalStudents examinees passed',
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
        Text('Failing rate: ${_rate(failRate)}%',
            style: TextStyle(fontSize: 12, color: Colors.grey[600])),
      ],
    );

    final groups = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _GroupBox(
            color: _green,
            bg: _greenBg,
            icon: Icons.check_circle_outline_rounded,
            label: 'Passers',
            count: passers.count,
            detail: avgText(passers),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _GroupBox(
            color: _red,
            bg: _redBg,
            icon: Icons.cancel_outlined,
            label: 'Non-passers',
            count: nonPassers.count,
            detail: avgText(nonPassers),
          ),
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: title + admin badge + editable passing rate
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            runSpacing: 6,
            children: [
              const Icon(Icons.analytics_outlined, size: 18, color: _brand),
              const Text('Examination statistics',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: _brand)),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8EAF6),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Text('Admin only',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: _brand)),
              ),
              InkWell(
                onTap: () => _editPassingPercent(passingPercent),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFFC5CAE9)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.edit_outlined, size: 13, color: _brand),
                    const SizedBox(width: 5),
                    Text('Passing rate: ${_pct(passingPercent)}%',
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: _brand)),
                  ]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (wide)
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 10, child: overall),
                  Container(
                    width: 1,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    color: _border,
                  ),
                  Expanded(flex: 17, child: groups),
                ],
              ),
            )
          else ...[
            overall,
            const SizedBox(height: 14),
            groups,
          ],
        ],
      ),
    );
  }

  // ── 3. Filter chips + table / cards ──────────────────────────────────────
  Widget _buildResultsCard({
    required List<_Row> rows,
    required List<_Row> visible,
    required bool useTable,
    required bool showSortHint,
  }) {
    final passedCount = rows.where((r) => r.passed).length;
    final failedCount = rows.length - passedCount;

    Widget chip(String label, _ResultFilter f) {
      final on = _filter == f;
      return GestureDetector(
        onTap: () => setState(() => _filter = f),
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
                  chip('All (${rows.length})', _ResultFilter.all),
                  chip('Passed ($passedCount)', _ResultFilter.passed),
                  chip('Failed ($failedCount)', _ResultFilter.failed),
                ]),
              ),
              if (showSortHint)
                Text('Sorted by score, highest first',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ]),
          ),
          const Divider(height: 1, color: _border),
          if (visible.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Center(
                child: Text('No students in this category.',
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

  // Wide screens: six columns, flexible widths so it fits with no scrolling.
  Widget _buildTable(List<_Row> rows) {
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
          'Rank',
          'Student',
          'Subject / review',
          'Score',
          'Date and time',
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
            cell(_RankCell(rank: rows[i].rank)),
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
                Text(
                    rows[i].subject.isNotEmpty
                        ? rows[i].subject
                        : rows[i].quizTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 12.5)),
                if (rows[i].subject.isNotEmpty)
                  Text(rows[i].quizTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
              ],
            )),
            cell(_ScoreText(row: rows[i])),
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
        0: FlexColumnWidth(0.9),
        1: FlexColumnWidth(2.0),
        2: FlexColumnWidth(2.8),
        3: FlexColumnWidth(1.6),
        4: FlexColumnWidth(1.6),
        5: FlexColumnWidth(1.2),
      },
      children: [header, ...body],
    );
  }

  // Phones: one compact card per student.
  Widget _buildCardList(List<_Row> rows) {
    return Column(children: [
      for (int i = 0; i < rows.length; i++) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Row(children: [
            SizedBox(width: 44, child: _RankCell(rank: rows[i].rank)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                      rows[i].year.isEmpty
                          ? rows[i].name
                          : '${rows[i].name} · ${rows[i].year}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 13.5)),
                  const SizedBox(height: 2),
                  Text(
                      rows[i].subject.isNotEmpty
                          ? '${rows[i].subject} — ${rows[i].quizTitle}'
                          : rows[i].quizTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
                  Text(
                      '${_fmtDate(rows[i].submittedAt)}, '
                      '${_fmtTime(rows[i].submittedAt)}',
                      style: const TextStyle(fontSize: 11.5, color: _muted)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _ScoreText(row: rows[i]),
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
}

// ── Data holders ─────────────────────────────────────────────────────────────
class _Row {
  final String name;
  final String year;
  final String subject;
  final String quizTitle;
  final int score;
  final int total;
  final double percent;
  final Timestamp? submittedAt;
  final bool passed;
  int rank = 0;

  _Row({
    required this.name,
    required this.year,
    required this.subject,
    required this.quizTitle,
    required this.score,
    required this.total,
    required this.percent,
    required this.submittedAt,
    required this.passed,
  });
}

class _GroupStats {
  final int count;
  final double avgScore;
  final double avgPercent;
  const _GroupStats(this.count, this.avgScore, this.avgPercent);

  factory _GroupStats.from(List<_Row> rows) {
    if (rows.isEmpty) return const _GroupStats(0, 0, 0);
    final n = rows.length;
    final s = rows.fold<int>(0, (a, r) => a + r.score) / n;
    final p = rows.fold<double>(0, (a, r) => a + r.percent) / n;
    return _GroupStats(n, s, p);
  }
}

// ── Small widgets ────────────────────────────────────────────────────────────
class _KpiTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _KpiTile({
    required this.icon,
    required this.label,
    required this.value,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(icon, size: 14, color: Colors.grey[600]),
            const SizedBox(width: 6),
            Flexible(
              child: Text(label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ),
            if (onTap != null) ...[
              const SizedBox(width: 3),
              Icon(Icons.info_outline_rounded,
                  size: 11, color: Colors.grey[500]),
            ],
          ]),
          const SizedBox(height: 3),
          Text(value,
              style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF1A237E))),
        ],
      ),
    );

    return Material(
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: Color(0xFFE8EAF6)),
      ),
      clipBehavior: Clip.antiAlias,
      child: onTap == null ? content : InkWell(onTap: onTap, child: content),
    );
  }
}

class _GroupBox extends StatelessWidget {
  final Color color;
  final Color bg;
  final IconData icon;
  final String label;
  final int count;
  final String detail;

  const _GroupBox({
    required this.color,
    required this.bg,
    required this.icon,
    required this.label,
    required this.count,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: color)),
          ]),
          const SizedBox(height: 2),
          Text('$count',
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(detail, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }
}

class _RankCell extends StatelessWidget {
  final int rank;
  const _RankCell({required this.rank});

  @override
  Widget build(BuildContext context) {
    Color? medal;
    if (rank == 1) medal = const Color(0xFFF9A825);
    if (rank == 2) medal = const Color(0xFF9E9E9E);
    if (rank == 3) medal = const Color(0xFFBF7B45);

    return Row(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        width: 20,
        child: medal == null
            ? null
            : Icon(Icons.workspace_premium_rounded, size: 17, color: medal),
      ),
      const SizedBox(width: 2),
      Text('$rank',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
    ]);
  }
}

class _ScoreText extends StatelessWidget {
  final _Row row;
  const _ScoreText({required this.row});

  @override
  Widget build(BuildContext context) {
    final color = row.passed ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    return RichText(
      text: TextSpan(children: [
        TextSpan(
            text: '${row.score}/${row.total}',
            style: TextStyle(
                color: color, fontWeight: FontWeight.bold, fontSize: 13)),
        TextSpan(
            text: ' · ${row.percent.round()}%',
            style: const TextStyle(color: Color(0xFF9096B4), fontSize: 12)),
      ]),
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