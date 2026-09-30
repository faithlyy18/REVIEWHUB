import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// ReviewResultsScreen — examination statistics for ONE selected review/quiz.
///
/// Everything here is calculated ONLY from the submissions of [quizId]
/// (e.g. 4 submissions → 4 examinees), never from all quizzes in the system.
///
/// LAYOUT
/// - Four summary tiles: Total Examinees · Overall Average · Passing Average
///   · Non-Passing Average.
/// - Below them, the examinee results those statistics were computed from
///   (ranked, highest score first; ties share a rank).
///   * Wide screens  → a table (Rank, Student, Subject/Quiz, Score,
///     Date and time, Status).
///   * Phones        → one compact card per examinee.
///
/// Passing is judged against the quiz's `passingPercent` (default 75).
/// Averages are mean score percentages.
class ReviewResultsScreen extends StatelessWidget {
  final String quizId;
  final String quizTitle;

  /// Kept only so callers that pass `isAdmin:` still compile.
  final bool isAdmin;

  const ReviewResultsScreen({
    super.key,
    required this.quizId,
    required this.quizTitle,
    this.isAdmin = false,
  });

  static const _brand = Color(0xFF1A237E);
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const _border = Color(0xFFE8EAF6);
  static const _muted = Color(0xFF9096B4);
  static const double _defaultPassing = 75;
  static const double _maxWidth = 1000;
  static const double _tableBreakpoint = 700;

  static String _fmtDate(Timestamp? ts) {
    if (ts == null) return '—';
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final d = ts.toDate();
    return '${months[d.month - 1]} ${d.day}, ${d.year}';
  }

  static String _fmtTime(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate();
    final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final mm = d.minute.toString().padLeft(2, '0');
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    return '$h12:$mm $ampm';
  }

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
            Text(quizTitle,
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
            .doc(quizId)
            .snapshots(),
        builder: (context, quizSnap) {
          final quizData =
              (quizSnap.data?.data() as Map<String, dynamic>?) ?? {};
          final passingPercent =
              (quizData['passingPercent'] as num?)?.toDouble() ??
                  _defaultPassing;
          final quizSubject = (quizData['subject'] as String?)?.trim() ?? '';

          // Inner stream: ONLY this quiz's submissions.
          return StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('quiz_results')
                .where('quizId', isEqualTo: quizId)
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
                        : quizTitle;
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
              for (int i = 0; i < rows.length; i++) {
                rows[i].rank = (i > 0 && rows[i].percent == rows[i - 1].percent)
                    ? rows[i - 1].rank
                    : i + 1;
              }

              // ── The four statistics (this quiz's examinees only) ───────
              final passers = rows.where((r) => r.passed).toList();
              final nonPassers = rows.where((r) => !r.passed).toList();
              double mean(List<_Row> l) => l.isEmpty
                  ? 0
                  : l.fold<double>(0, (a, r) => a + r.percent) / l.length;
              String fmt(List<_Row> l) =>
                  l.isEmpty ? '—' : '${mean(l).toStringAsFixed(1)}%';

              final tiles = <Widget>[
                _StatTile(
                    icon: Icons.people_alt_outlined,
                    label: 'Total Examinees',
                    value: '${rows.length}'),
                _StatTile(
                    icon: Icons.bar_chart_rounded,
                    label: 'Overall Average',
                    value: fmt(rows)),
                _StatTile(
                    icon: Icons.emoji_events_outlined,
                    label: 'Passing Average',
                    value: fmt(passers),
                    valueColor: _green),
                _StatTile(
                    icon: Icons.trending_down_rounded,
                    label: 'Non-Passing Average',
                    value: fmt(nonPassers),
                    valueColor: _red),
              ];

              return LayoutBuilder(builder: (context, constraints) {
                final contentWidth = constraints.maxWidth > _maxWidth
                    ? _maxWidth
                    : constraints.maxWidth;
                final narrow = contentWidth < 480;
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
                            if (narrow) ...[
                              // Phones: 2 x 2 grid.
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
                            ] else
                              Row(children: [
                                for (int i = 0; i < tiles.length; i++) ...[
                                  if (i > 0) const SizedBox(width: 8),
                                  Expanded(child: tiles[i]),
                                ],
                              ]),
                            const SizedBox(height: 12),
                            _buildResultsCard(
                                rows: rows,
                                useTable: useTable,
                                showSortHint: contentWidth >= 520),
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
              const Text('Could not load review results.',
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
            Text('No examinees yet.',
                style: TextStyle(color: Colors.grey[600], fontSize: 16)),
            const SizedBox(height: 4),
            Text("Students haven't taken this review yet.",
                style: TextStyle(color: Colors.grey[400], fontSize: 13)),
          ],
        ),
      );

  // ── Examinee results (below the statistics) ──────────────────────────────
  Widget _buildResultsCard({
    required List<_Row> rows,
    required bool useTable,
    required bool showSortHint,
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
              const Icon(Icons.list_alt_rounded, size: 18, color: _brand),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Examinee results',
                    style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 14,
                        color: _brand)),
              ),
              if (showSortHint)
                Text('Sorted by score, highest first',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ]),
          ),
          const Divider(height: 1, color: _border),
          useTable ? _buildTable(rows) : _buildCardList(rows),
        ],
      ),
    );
  }

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
          'Rank', 'Student', 'Subject / quiz', 'Score', 'Date and time', 'Status'
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

// ── Data holder ──────────────────────────────────────────────────────────────
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

// ── Small widgets ────────────────────────────────────────────────────────────
class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color valueColor;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor = const Color(0xFF1A237E),
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
                  fontSize: 20, fontWeight: FontWeight.bold, color: valueColor)),
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