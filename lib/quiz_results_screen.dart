import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// QuizResultsScreen — all student submissions for a quiz, shown as a table.
///
/// - Rows are sorted by score, highest first (ties: earlier submission first).
///   Tied scores share the same rank.
/// - Columns: Rank, Student, Year, Subject/Quiz, Score, %, Date & Time, Status.
/// - Status (Passed / Failed) is shown to everyone, based on the quiz's
///   required passing percentage.
/// - The overall passing/failing report card is shown ONLY when
///   [isAdmin] is true. The Admin can also change the required passing
///   percentage; it is saved on the quiz document as `passingPercent`
///   (defaults to 75 if never set).
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

class _QuizResultsScreenState extends State<QuizResultsScreen> {
  static const _brand = Color(0xFF1A237E);
  static const _green = Color(0xFF2E7D32);
  static const _red = Color(0xFFC62828);
  static const double _defaultPassing = 75;

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

  Future<void> _editPassingPercent(double current) async {
    final controller = TextEditingController(text: _pct(current));
    final result = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Required Passing Rate',
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
            const Text('Quiz Results',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            Text(widget.quizTitle,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
          ],
        ),
      ),
      // Outer stream: the quiz doc (for subject + required passing %).
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
              if (snapshot.hasError) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 48, color: Colors.red[300]),
                        const SizedBox(height: 10),
                        const Text('Could not load results.',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                        const SizedBox(height: 6),
                        Text('${snapshot.error}',
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                            textAlign: TextAlign.center),
                      ],
                    ),
                  ),
                );
              }

              final docs = snapshot.data?.docs ?? [];
              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.assignment_outlined,
                          size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 12),
                      Text('No submissions yet.',
                          style: TextStyle(
                              color: Colors.grey[600], fontSize: 16)),
                      const SizedBox(height: 4),
                      Text("Students haven't taken this quiz yet.",
                          style: TextStyle(
                              color: Colors.grey[400], fontSize: 13)),
                    ],
                  ),
                );
              }

              // ── Normalise rows ─────────────────────────────────────────
              final rows = docs.map((d) {
                final m = d.data() as Map<String, dynamic>;
                final score = (m['score'] as num?)?.toInt() ?? 0;
                final total = (m['totalQuestions'] as num?)?.toInt() ?? 1;
                final percent = total == 0 ? 0.0 : score / total * 100;
                final subject = ((m['subject'] as String?)?.trim().isNotEmpty ??
                        false)
                    ? (m['subject'] as String).trim()
                    : quizSubject;
                final title = (m['quizTitle'] as String?)?.trim().isNotEmpty ==
                        true
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
                if (i > 0 && rows[i].percent == rows[i - 1].percent) {
                  rows[i].rank = rows[i - 1].rank;
                } else {
                  rows[i].rank = i + 1;
                }
              }

              // ── Stats ──────────────────────────────────────────────────
              final total = rows.first.total;
              final avg = rows.map((r) => r.score).reduce((a, b) => a + b) /
                  rows.length;
              final highest = rows.first.score;
              final lowest = rows.last.score;
              final passedCount = rows.where((r) => r.passed).length;
              final failedCount = rows.length - passedCount;
              final passRate = passedCount / rows.length * 100;
              final failRate = failedCount / rows.length * 100;

              return LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    padding: const EdgeInsets.only(bottom: 24),
                    child: Column(
                      children: [
                        // Cards: centered, max 600 wide.
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 600),
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(14, 14, 14, 8),
                              child: Column(
                                children: [
                                  _buildSummaryCard(
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
                                  // ── ADMIN ONLY ──────────────────────────
                                  if (widget.isAdmin) ...[
                                    const SizedBox(height: 12),
                                    _buildAdminReport(
                                      passingPercent: passingPercent,
                                      passedCount: passedCount,
                                      failedCount: failedCount,
                                      passRate: passRate,
                                      failRate: failRate,
                                      totalStudents: rows.length,
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                        ),

                        // Table: full width, scrolls horizontally if needed.
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
                          child: Container(
                            width: double.infinity,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(14),
                              border:
                                  Border.all(color: const Color(0xFFE8EAF6)),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                    minWidth: constraints.maxWidth - 28),
                                child: _buildTable(rows),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }

  // ── Table ────────────────────────────────────────────────────────────────
  Widget _buildTable(List<_Row> rows) {
    const headStyle = TextStyle(
        color: _brand, fontWeight: FontWeight.bold, fontSize: 12.5);

    return DataTable(
      headingRowColor: WidgetStateProperty.all(const Color(0xFFE8EAF6)),
      headingRowHeight: 44,
      dataRowMinHeight: 52,
      dataRowMaxHeight: 60,
      columnSpacing: 22,
      horizontalMargin: 14,
      columns: const [
        DataColumn(label: Text('Rank', style: headStyle)),
        DataColumn(label: Text('Student', style: headStyle)),
        DataColumn(label: Text('Year', style: headStyle)),
        DataColumn(label: Text('Subject / Quiz', style: headStyle)),
        DataColumn(label: Text('Score', style: headStyle), numeric: true),
        DataColumn(label: Text('%', style: headStyle), numeric: true),
        DataColumn(label: Text('Date & Time', style: headStyle)),
        DataColumn(label: Text('Status', style: headStyle)),
      ],
      rows: rows.map((r) {
        final color = r.passed ? _green : _red;
        return DataRow(cells: [
          DataCell(Text(
            r.rank == 1 ? '🥇 1' : r.rank == 2 ? '🥈 2' : r.rank == 3 ? '🥉 3' : '${r.rank}',
            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
          )),
          DataCell(ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(r.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontWeight: FontWeight.w600, fontSize: 13)),
          )),
          DataCell(Text(r.year.isEmpty ? '—' : r.year,
              style: const TextStyle(fontSize: 12.5))),
          DataCell(ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 170),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (r.subject.isNotEmpty)
                  Text(r.subject,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 12.5, fontWeight: FontWeight.w600)),
                Text(r.quizTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: r.subject.isEmpty ? 12.5 : 11,
                        color: r.subject.isEmpty
                            ? Colors.black87
                            : const Color(0xFF9096B4))),
              ],
            ),
          )),
          DataCell(Text('${r.score}/${r.total}',
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 13))),
          DataCell(Text('${r.percent.round()}%',
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 13))),
          DataCell(Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_fmtDate(r.submittedAt),
                  style: const TextStyle(fontSize: 12.5)),
              Text(_fmtTime(r.submittedAt),
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFF9096B4))),
            ],
          )),
          DataCell(_StatusChip(passed: r.passed)),
        ]);
      }).toList(),
    );
  }

  // ── Summary card (visible to everyone) ───────────────────────────────────
  Widget _buildSummaryCard({
    required int submissions,
    required double avg,
    required int highest,
    required int lowest,
    required int total,
    required String highestNames,
    required String lowestNames,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: _brand,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
              color: _brand.withOpacity(0.25),
              blurRadius: 14,
              offset: const Offset(0, 6)),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          IntrinsicHeight(
            child: Row(children: [
              Expanded(
                  child: _StatTile(
                      icon: Icons.people_alt_rounded,
                      value: '$submissions',
                      label: 'Submissions')),
              const VerticalDivider(
                  color: Colors.white24,
                  width: 1,
                  thickness: 1,
                  indent: 14,
                  endIndent: 14),
              Expanded(
                  child: _StatTile(
                      icon: Icons.bar_chart_rounded,
                      value: '${avg.toStringAsFixed(1)}/$total',
                      label: 'Average')),
            ]),
          ),
          const Divider(color: Colors.white24, height: 1, thickness: 1),
          IntrinsicHeight(
            child: Row(children: [
              Expanded(
                child: _StatTile(
                  icon: Icons.emoji_events_rounded,
                  value: '$highest/$total',
                  label: 'Highest',
                  tappable: true,
                  onTap: () => _showNamesSheet(
                    title: 'Highest Score',
                    names: highestNames,
                    scoreLabel: '$highest out of $total',
                    accent: _green,
                    icon: Icons.emoji_events_rounded,
                  ),
                ),
              ),
              const VerticalDivider(
                  color: Colors.white24,
                  width: 1,
                  thickness: 1,
                  indent: 14,
                  endIndent: 14),
              Expanded(
                child: _StatTile(
                  icon: Icons.trending_down_rounded,
                  value: '$lowest/$total',
                  label: 'Lowest',
                  tappable: true,
                  onTap: () => _showNamesSheet(
                    title: 'Lowest Score',
                    names: lowestNames,
                    scoreLabel: '$lowest out of $total',
                    accent: _red,
                    icon: Icons.trending_down_rounded,
                  ),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
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

  // ── Admin-only passing / failing report ──────────────────────────────────
  Widget _buildAdminReport({
    required double passingPercent,
    required int passedCount,
    required int failedCount,
    required double passRate,
    required double failRate,
    required int totalStudents,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8EAF6)),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 8,
              offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.assessment_rounded, color: _brand, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text('Overall Passing Report',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                      color: _brand)),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFFE8EAF6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text('Admin only',
                  style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: _brand)),
            ),
          ]),
          const SizedBox(height: 12),

          // Required passing rate + edit
          InkWell(
            onTap: () => _editPassingPercent(passingPercent),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Text('Required passing rate: ',
                    style: TextStyle(fontSize: 13, color: Colors.grey[700])),
                Text('${_pct(passingPercent)}%',
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: _brand)),
                const SizedBox(width: 6),
                const Icon(Icons.edit_rounded, size: 14, color: _brand),
              ]),
            ),
          ),
          const SizedBox(height: 12),

          // Passed / Failed split bar
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: SizedBox(
              height: 12,
              child: Row(children: [
                if (passedCount > 0)
                  Expanded(flex: passedCount, child: Container(color: _green)),
                if (failedCount > 0)
                  Expanded(flex: failedCount, child: Container(color: _red)),
              ]),
            ),
          ),
          const SizedBox(height: 14),

          Row(children: [
            Expanded(
              child: _ReportBox(
                color: _green,
                icon: Icons.check_circle_rounded,
                label: 'Passing Rate',
                rate: '${_pct(double.parse(passRate.toStringAsFixed(1)))}%',
                detail: '$passedCount of $totalStudents passed',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ReportBox(
                color: _red,
                icon: Icons.cancel_rounded,
                label: 'Failing Rate',
                rate: '${_pct(double.parse(failRate.toStringAsFixed(1)))}%',
                detail: '$failedCount of $totalStudents failed',
              ),
            ),
          ]),
        ],
      ),
    );
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
class _StatusChip extends StatelessWidget {
  final bool passed;
  const _StatusChip({required this.passed});

  @override
  Widget build(BuildContext context) {
    final color = passed ? const Color(0xFF2E7D32) : const Color(0xFFC62828);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(passed ? 'Passed' : 'Failed',
          style: TextStyle(
              color: color, fontWeight: FontWeight.bold, fontSize: 11.5)),
    );
  }
}

class _ReportBox extends StatelessWidget {
  final Color color;
  final IconData icon;
  final String label;
  final String rate;
  final String detail;

  const _ReportBox({
    required this.color,
    required this.icon,
    required this.label,
    required this.rate,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 5),
            Text(label,
                style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: color)),
          ]),
          const SizedBox(height: 6),
          Text(rate,
              style: TextStyle(
                  fontSize: 22, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 2),
          Text(detail,
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ],
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final bool tappable;
  final VoidCallback? onTap;

  const _StatTile({
    required this.icon,
    required this.value,
    required this.label,
    this.tappable = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(height: 6),
          Text(value,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16)),
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 11)),
            if (tappable) ...[
              const SizedBox(width: 2),
              const Icon(Icons.info_outline_rounded,
                  size: 11, color: Colors.white70),
            ],
          ]),
        ],
      ),
    );
    if (!tappable) return content;
    return InkWell(onTap: onTap, child: content);
  }
}