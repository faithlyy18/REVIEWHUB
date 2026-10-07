import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

/// Instructor-facing tab for approving/denying students' requests to retake
/// a review after they've used both free attempts.
///
/// OWNERSHIP: every request stores `instructorId` = the uid of the instructor
/// who created the review (the quiz's `createdBy`). This tab only queries
/// requests where `instructorId` equals the logged-in instructor's uid, so an
/// instructor never sees requests for another instructor's reviews.
///
/// DATA MODEL (`retake_requests/{quizId}_{studentUid}`):
///   quizId, quizTitle, subject, yearLevel,
///   instructorId  (owner of the review),
///   studentUid, studentName, studentYearLevel,
///   attemptCount, status ('pending' | 'approved' | 'denied' | 'used'),
///   requestedAt, respondedAt, respondedBy, usedAt
///
/// GROUPING (inside the already-filtered data):
///   Category (e.g. "CDI") -> Level / review -> pending student requests
class RetakeRequestsTab extends StatefulWidget {
  const RetakeRequestsTab({super.key});

  @override
  State<RetakeRequestsTab> createState() => _RetakeRequestsTabState();
}

// One level (review) inside a category.
class _Level {
  final String code;
  final String subject;
  final List<QueryDocumentSnapshot> docs = [];
  _Level(this.code, this.subject);

  String get title => code.isEmpty ? subject : '$code – $subject';
}

class _RetakeRequestsTabState extends State<RetakeRequestsTab> {
  static const int _batchLimit = 400;
  static const String _noSubjectLabel = 'Other';

  // The logged-in instructor. Every query below is scoped to this uid.
  late final String? _uid = FirebaseAuth.instance.currentUser?.uid;

  // Created once so the tab doesn't resubscribe on every rebuild.
  // FILTER ORDER: instructor first, then status.
  late final Stream<QuerySnapshot>? _pendingStream = _uid == null
      ? null
      : FirebaseFirestore.instance
          .collection('retake_requests')
          .where('instructorId', isEqualTo: _uid)
          .where('status', isEqualTo: 'pending')
          .snapshots();

  // quizId -> subjectCode ('' when the quiz has none or can't be read).
  final Map<String, String> _codeCache = {};

  void _showSnack(BuildContext context, String message, Color color) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: color,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── Single request ──────────────────────────────────────────────────────
  Future<void> _respond(
      BuildContext context, DocumentReference ref, String status) async {
    try {
      await ref.set({
        'status': status,
        'respondedAt': FieldValue.serverTimestamp(),
        'respondedBy': _uid,
      }, SetOptions(merge: true));
      _showSnack(
        context,
        status == 'approved' ? 'Retake approved.' : 'Request denied.',
        status == 'approved' ? Colors.green : Colors.red.shade700,
      );
    } catch (e) {
      debugPrint('retake respond failed: $e');
      _showSnack(context, 'Something went wrong. Please try again.',
          Colors.red.shade700);
    }
  }

  // ── Bulk: every pending request of one level ────────────────────────────
  Future<void> _respondAll(
    BuildContext context,
    String subject,
    List<QueryDocumentSnapshot> docs,
    String status,
  ) async {
    if (docs.isEmpty) return;
    final approve = status == 'approved';
    final count = docs.length;
    final noun = count == 1 ? 'request' : 'requests';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(approve ? 'Approve all requests?' : 'Deny all requests?'),
        content: Text(
          approve
              ? 'Approve $count retake $noun for "$subject"? '
                  'Each student will get one more attempt.'
              : 'Deny $count retake $noun for "$subject"?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor:
                  approve ? Colors.green.shade700 : Colors.red.shade700,
              foregroundColor: Colors.white,
            ),
            child: Text(approve ? 'Approve All' : 'Deny All'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final db = FirebaseFirestore.instance;
      for (var i = 0; i < docs.length; i += _batchLimit) {
        final batch = db.batch();
        for (final d in docs.skip(i).take(_batchLimit)) {
          batch.set(
            d.reference,
            {
              'status': status,
              'respondedAt': FieldValue.serverTimestamp(),
              'respondedBy': _uid,
            },
            SetOptions(merge: true),
          );
        }
        await batch.commit();
      }
      _showSnack(
        context,
        approve
            ? 'Approved $count $noun for $subject.'
            : 'Denied $count $noun for $subject.',
        approve ? Colors.green : Colors.red.shade700,
      );
    } catch (e) {
      debugPrint('retake bulk respond failed: $e');
      _showSnack(context, 'Something went wrong. Please try again.',
          Colors.red.shade700);
    }
  }

  String _formatDate(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return '${dt.month}/${dt.day}/${dt.year}';
  }

  // ── Subject-code helpers ────────────────────────────────────────────────
  static final RegExp _codePattern = RegExp(r'^(.*?)[\s\-_.]*(\d+)\s*$');

  String _categoryOf(String code) {
    final c = code.trim();
    if (c.isEmpty) return _noSubjectLabel;
    final m = _codePattern.firstMatch(c);
    if (m != null && m.group(1)!.trim().isNotEmpty) {
      return m.group(1)!.trim().toUpperCase();
    }
    return c.toUpperCase();
  }

  int _numberOf(String code) {
    final m = _codePattern.firstMatch(code.trim());
    if (m == null) return 0;
    return int.tryParse(m.group(2)!) ?? 0;
  }

  String _codeFor(QueryDocumentSnapshot d) {
    final data = d.data() as Map<String, dynamic>;
    final own = (data['subjectCode'] as String?)?.trim() ?? '';
    if (own.isNotEmpty) return own;
    final quizId = data['quizId'] as String?;
    if (quizId == null) return '';
    return _codeCache[quizId] ?? '';
  }

  Future<void> _loadCodes(Set<String> quizIds) async {
    await Future.wait(quizIds.map((id) async {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('quizzes')
            .doc(id)
            .get();
        final code =
            ((snap.data() ?? {})['subjectCode'] as String?)?.trim() ?? '';
        _codeCache[id] = code;
      } catch (_) {
        _codeCache[id] = '';
      }
    }));
  }

  Map<String, List<_Level>> _group(List<QueryDocumentSnapshot> docs) {
    final byCategory = <String, Map<String, _Level>>{};

    for (final d in docs) {
      final data = d.data() as Map<String, dynamic>;
      final code = _codeFor(d);
      final rawSubject = (data['subject'] as String?)?.trim() ?? '';
      final subject = rawSubject.isEmpty
          ? ((data['quizTitle'] as String?)?.trim().isNotEmpty == true
              ? (data['quizTitle'] as String).trim()
              : _noSubjectLabel)
          : rawSubject;

      final category = _categoryOf(code);
      final levelKey = '${code.toLowerCase()}|${subject.toLowerCase()}';
      final levels = byCategory.putIfAbsent(category, () => {});
      levels.putIfAbsent(levelKey, () => _Level(code, subject)).docs.add(d);
    }

    for (final levels in byCategory.values) {
      for (final level in levels.values) {
        level.docs.sort((a, b) {
          final at =
              (a.data() as Map<String, dynamic>)['requestedAt'] as Timestamp?;
          final bt =
              (b.data() as Map<String, dynamic>)['requestedAt'] as Timestamp?;
          if (at == null || bt == null) return 0;
          return at.compareTo(bt);
        });
      }
    }

    final categories = byCategory.keys.toList()
      ..sort((a, b) {
        if (a == _noSubjectLabel) return 1;
        if (b == _noSubjectLabel) return -1;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    return {
      for (final c in categories)
        c: (byCategory[c]!.values.toList()
          ..sort((a, b) {
            final n = _numberOf(a.code).compareTo(_numberOf(b.code));
            if (n != 0) return n;
            final cc = a.code.toLowerCase().compareTo(b.code.toLowerCase());
            if (cc != 0) return cc;
            return a.subject.toLowerCase().compareTo(b.subject.toLowerCase());
          })),
    };
  }

  Widget _buildHeader(int? count) {
    return Container(
      width: double.infinity,
      color: const Color(0xFFF0F2F8),
      padding: const EdgeInsets.all(14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Expanded(
            child: Text(
              'Students appear here after using both attempts on one of YOUR '
              'reviews and asking for permission to try again.',
              style: TextStyle(fontSize: 12, color: Colors.black54),
            ),
          ),
          if (count != null && count > 0) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: const Color(0xFF1A237E),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                count == 1 ? '1 pending' : '$count pending',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildList(int totalCount, Map<String, List<_Level>> grouped) {
    final categories = grouped.keys.toList();
    return Column(
      children: [
        _buildHeader(totalCount),
        Expanded(
          child: totalCount == 0
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.mark_email_read_rounded,
                          size: 56, color: Colors.grey[300]),
                      const SizedBox(height: 12),
                      Text('No pending requests.',
                          style:
                              TextStyle(color: Colors.grey[500], fontSize: 15)),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(14),
                  itemCount: categories.length,
                  itemBuilder: (context, index) {
                    final category = categories[index];
                    final levels = grouped[category]!;
                    return _CategoryGroup(
                      key: ValueKey('cat|$category'),
                      category: category,
                      levels: levels,
                      formatDate: _formatDate,
                      onRespondOne: (doc, status) =>
                          _respond(context, doc.reference, status),
                      onRespondAll: (level, status) =>
                          _respondAll(context, level.title, level.docs, status),
                    );
                  },
                ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Not signed in -> nothing to show (and nothing must be queried).
    if (_uid == null || _pendingStream == null) {
      return Column(
        children: [
          _buildHeader(null),
          const Expanded(
            child: Center(
              child: Text('Please sign in again to see your requests.',
                  style: TextStyle(color: Colors.grey)),
            ),
          ),
        ],
      );
    }

    return StreamBuilder<QuerySnapshot>(
      stream: _pendingStream,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return Column(
            children: [
              _buildHeader(null),
              const Expanded(
                child: Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF1A237E))),
              ),
            ],
          );
        }

        // Surface permission-denied / index errors instead of silently
        // showing "No pending requests."
        if (snapshot.hasError) {
          return Column(
            children: [
              _buildHeader(null),
              Expanded(
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 48, color: Colors.red[300]),
                        const SizedBox(height: 10),
                        const Text('Could not load requests.',
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
                ),
              ),
            ],
          );
        }

        final docs = (snapshot.data?.docs ?? []).toList();

        final missing = <String>{};
        for (final d in docs) {
          final data = d.data() as Map<String, dynamic>;
          final own = (data['subjectCode'] as String?)?.trim() ?? '';
          final quizId = data['quizId'] as String?;
          if (own.isEmpty && quizId != null && !_codeCache.containsKey(quizId)) {
            missing.add(quizId);
          }
        }

        if (missing.isEmpty) {
          return _buildList(docs.length, _group(docs));
        }

        return FutureBuilder<void>(
          future: _loadCodes(missing),
          builder: (context, codeSnap) {
            if (codeSnap.connectionState != ConnectionState.done) {
              return Column(
                children: [
                  _buildHeader(docs.length),
                  const Expanded(
                    child: Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF1A237E))),
                  ),
                ],
              );
            }
            return _buildList(docs.length, _group(docs));
          },
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Level 1: one collapsible card per CATEGORY (e.g. "CDI").
// ─────────────────────────────────────────────────────────────────────────
class _CategoryGroup extends StatefulWidget {
  final String category;
  final List<_Level> levels;
  final String Function(DateTime) formatDate;
  final Future<void> Function(QueryDocumentSnapshot doc, String status)
      onRespondOne;
  final Future<void> Function(_Level level, String status) onRespondAll;

  const _CategoryGroup({
    super.key,
    required this.category,
    required this.levels,
    required this.formatDate,
    required this.onRespondOne,
    required this.onRespondAll,
  });

  @override
  State<_CategoryGroup> createState() => _CategoryGroupState();
}

class _CategoryGroupState extends State<_CategoryGroup> {
  bool _expanded = false;

  int get _requestCount =>
      widget.levels.fold<int>(0, (sum, l) => sum + l.docs.length);

  int get _studentCount {
    final ids = <String>{};
    for (final level in widget.levels) {
      for (final d in level.docs) {
        final data = d.data() as Map<String, dynamic>;
        ids.add((data['studentUid'] as String?) ??
            (data['studentName'] as String?) ??
            d.id);
      }
    }
    return ids.length;
  }

  @override
  Widget build(BuildContext context) {
    final count = _requestCount;
    final students = _studentCount;
    final reviews = widget.levels.length;
    final summary = '$reviews ${reviews == 1 ? 'review' : 'reviews'}'
        ' · $count ${count == 1 ? 'request' : 'requests'}'
        ' · $students ${students == 1 ? 'student' : 'students'}';

    return Card(
      margin: const EdgeInsets.only(bottom: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      elevation: 2,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 14, 10, 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8EAF6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.folder_rounded,
                        color: Color(0xFF1A237E), size: 22),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.category,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 15,
                                color: Color(0xFF1A237E))),
                        const SizedBox(height: 2),
                        Text(summary,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.black54)),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A237E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.black45,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            const Divider(height: 1),
            Container(
              color: const Color(0xFFF7F8FC),
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 2),
              child: Column(
                children: [
                  for (final level in widget.levels)
                    _LevelGroup(
                      key: ValueKey(
                          'lvl|${widget.category}|${level.code}|${level.subject}'),
                      title: level.title,
                      docs: level.docs,
                      formatDate: widget.formatDate,
                      onRespondOne: widget.onRespondOne,
                      onRespondAll: (status) =>
                          widget.onRespondAll(level, status),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────
// Level 2: one collapsible section per review level.
// ─────────────────────────────────────────────────────────────────────────
class _LevelGroup extends StatefulWidget {
  final String title;
  final List<QueryDocumentSnapshot> docs;
  final String Function(DateTime) formatDate;
  final Future<void> Function(QueryDocumentSnapshot doc, String status)
      onRespondOne;
  final Future<void> Function(String status) onRespondAll;

  const _LevelGroup({
    super.key,
    required this.title,
    required this.docs,
    required this.formatDate,
    required this.onRespondOne,
    required this.onRespondAll,
  });

  @override
  State<_LevelGroup> createState() => _LevelGroupState();
}

class _LevelGroupState extends State<_LevelGroup> {
  bool _expanded = false;
  bool _busy = false;

  Future<void> _bulk(String status) async {
    setState(() => _busy = true);
    try {
      await widget.onRespondAll(status);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  int get _studentCount {
    final ids = <String>{};
    for (final d in widget.docs) {
      final data = d.data() as Map<String, dynamic>;
      final id = (data['studentUid'] as String?) ??
          (data['studentName'] as String?) ??
          d.id;
      ids.add(id);
    }
    return ids.length;
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.docs.length;
    final students = _studentCount;
    final summary = '$count ${count == 1 ? 'request' : 'requests'}'
        ' · $students ${students == 1 ? 'student' : 'students'}';

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      elevation: 1,
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 8, 10),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8EAF6),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.menu_book_rounded,
                        color: Color(0xFF1A237E), size: 18),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(widget.title,
                            style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 13.5,
                                color: Color(0xFF1A237E))),
                        const SizedBox(height: 2),
                        Text(summary,
                            style: const TextStyle(
                                fontSize: 11, color: Colors.black54)),
                      ],
                    ),
                  ),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A237E),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    color: Colors.black45,
                  ),
                ],
              ),
            ),
          ),

          if (count > 1)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : () => _bulk('denied'),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Deny All'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.red.shade700,
                        side: BorderSide(color: Colors.red.shade200),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: _busy ? null : () => _bulk('approved'),
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.done_all_rounded, size: 16),
                      label: Text('Approve All ($count)'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.green.shade700,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ),
                ],
              ),
            ),

          if (_expanded) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: [
                  for (final doc in widget.docs) _buildRequestTile(doc),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 70,
            child: Text(label,
                style: const TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: valueColor ?? Colors.black87)),
          ),
        ],
      ),
    );
  }

  Widget _buildRequestTile(QueryDocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final quizTitle = data['quizTitle'] as String? ?? 'Review';
    final studentName = data['studentName'] as String? ?? 'Student';
    final yearLevel = data['studentYearLevel'] as String? ?? '';
    final attemptCount = (data['attemptCount'] as num?)?.toInt() ?? 0;
    final requestedAt = data['requestedAt'] as Timestamp?;

    final attemptsLabel =
        attemptCount <= 2 ? '$attemptCount/2' : '$attemptCount';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFC),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE6E8F0)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.person_rounded,
                    color: Colors.orange.shade800, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(studentName,
                        style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color: Color(0xFF1A237E))),
                    if (yearLevel.isNotEmpty)
                      Text(yearLevel,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.black54)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _infoRow('Review', quizTitle),
          _infoRow('Attempts', '$attemptsLabel used'),
          _infoRow('Request', 'Wants to take the review again'),
          _infoRow('Status', 'Pending Instructor Approval',
              valueColor: Colors.orange.shade800),
          if (requestedAt != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Requested ${widget.formatDate(requestedAt.toDate())}',
                style: const TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed:
                      _busy ? null : () => widget.onRespondOne(doc, 'denied'),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Deny'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.red.shade700,
                    side: BorderSide(color: Colors.red.shade200),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _busy
                      ? null
                      : () => widget.onRespondOne(doc, 'approved'),
                  icon: const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Approve'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green.shade700,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}