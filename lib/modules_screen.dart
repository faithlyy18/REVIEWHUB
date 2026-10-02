import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'google_drive_service.dart';
import 'curriculum_repo.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MODULE SUBJECTS (clusters)
//
// Module subjects (CRIM, CLJ, CDI, FORENSIC, LEA, CA, ENG …) live in their
// OWN Firestore collection: `moduleSubjects`
//   {code, label, createdAt, archived, archivedAt}
//
// The curriculum (CurriculumRepo, numbered subjects such as "CRIM 1") stays in
// the `subjects` collection. The two features are completely separate:
//   • Manage Curriculum      -> `subjects`        (curriculum_repo.dart)
//   • Add Module > Add / manage subjects -> `moduleSubjects` (this file)
//
// Modules keep referencing their subject through `cluster: <code>`.
//
// Each module can ALSO be linked to one curriculum subject, e.g. a CDI
// module is linked to "CDI 3". This is stored on the module as
//   subject        (e.g. 'CDI 3')
//   subjectLabel   (e.g. 'Specialized Crime Investigation 2 …')
// A curriculum subject belongs to a cluster when its code starts with the
// cluster code followed by a space ("CDI 3" belongs to "CDI").
//
// STUDENT SIDE: StudentModulesScreen now navigates
//   Year Level -> Semester -> Subject -> Modules -> Read Module
//
// ARCHIVE MODEL: module subjects are never hard-deleted from the active list.
// Archiving sets `archived: true` and cascade-archives every active module
// under it.
// ─────────────────────────────────────────────────────────────────────────────

const String _kModuleSubjectsCol = 'moduleSubjects';

class _Cluster {
  final String id; // Firestore doc id
  final String code;
  final String label;
  final Color color;
  final IconData icon;
  final DateTime? createdAt;
  final bool isArchived;
  final DateTime? archivedAt;

  /// True for the built-in default module subjects. These are protected:
  /// they can never be archived or deleted.
  final bool isDefault;

  const _Cluster({
    required this.id,
    required this.code,
    required this.label,
    required this.color,
    required this.icon,
    this.createdAt,
    this.isArchived = false,
    this.archivedAt,
    this.isDefault = false,
  });
}

const List<Color> _palette = [
  Color(0xFF1A237E),
  Color(0xFF00695C),
  Color(0xFF4A148C),
  Color(0xFFBF360C),
  Color(0xFF1565C0),
  Color(0xFF558B2F),
  Color(0xFF880E4F),
  Color(0xFF37474F),
  Color(0xFFEF6C00),
  Color(0xFF283593),
];

const List<IconData> _iconPalette = [
  Icons.policy_rounded,
  Icons.gavel_rounded,
  Icons.search_rounded,
  Icons.biotech_rounded,
  Icons.local_police_rounded,
  Icons.account_balance_rounded,
  Icons.fingerprint_rounded,
  Icons.shield_rounded,
  Icons.balance_rounded,
  Icons.security_rounded,
];

Color _colorForCode(String code) =>
    _palette[code.hashCode.abs() % _palette.length];

IconData _iconForCode(String code) =>
    _iconPalette[code.hashCode.abs() % _iconPalette.length];

/// True when the curriculum subject [subjectCode] (e.g. "CDI 3") belongs to
/// the module cluster [clusterCode] (e.g. "CDI").
bool _subjectBelongsToCluster(String subjectCode, String clusterCode) {
  final s = subjectCode.trim().toUpperCase();
  final c = clusterCode.trim().toUpperCase();
  if (c.isEmpty) return false;
  return s.startsWith('$c ');
}

// ─────────────────────────────────────────────────────────────────────────────
// DEFAULT MODULE SUBJECTS (protected)
//
// The 7 original subject clusters. They are built into the app, so they are
// ALWAYS available in the module subject picker, never depend on Firestore,
// and can never be archived or deleted.
// ─────────────────────────────────────────────────────────────────────────────

const List<List<String>> _kDefaultModuleSubjects = [
  ['CRIM', 'Criminology'],
  ['CLJ', 'Criminal Law and Jurisprudence'],
  ['CDI', 'Criminal Detection and Investigation'],
  ['FORENSIC', 'Forensic Science'],
  ['LEA', 'Law Enforcement Administration'],
  ['CA', 'Correctional Administration'],
  ['ENG', 'English'],
];

bool _isDefaultCode(String code) => _kDefaultModuleSubjects
    .any((d) => d[0].toUpperCase() == code.trim().toUpperCase());

final List<_Cluster> _defaultClusters = [
  for (final d in _kDefaultModuleSubjects)
    _Cluster(
      id: 'default_${d[0]}',
      code: d[0],
      label: d[1],
      color: _colorForCode(d[0]),
      icon: _iconForCode(d[0]),
      isDefault: true,
    ),
];

_Cluster _clusterFromDoc(QueryDocumentSnapshot doc) {
  final data = doc.data() as Map<String, dynamic>;
  final code = data['code'] as String? ?? '';
  final label = data['label'] as String? ?? code;
  final rawCreatedAt = data['createdAt'];
  final rawArchivedAt = data['archivedAt'];
  return _Cluster(
    id: doc.id,
    code: code,
    label: label,
    color: _colorForCode(code),
    icon: _iconForCode(code),
    createdAt: rawCreatedAt is Timestamp ? rawCreatedAt.toDate() : null,
    isArchived: data['archived'] as bool? ?? false,
    archivedAt: rawArchivedAt is Timestamp ? rawArchivedAt.toDate() : null,
  );
}

/// Live stream of every ACTIVE (non-archived) module subject, ordered by
/// creation time. Sorted client-side so a pending serverTimestamp() write
/// (createdAt == null) is placed last instead of being hidden by Firestore.
Stream<List<_Cluster>> _subjectsStream() {
  return FirebaseFirestore.instance
      .collection(_kModuleSubjectsCol)
      .snapshots()
      .map((snap) {
    // Subjects added later (a stored doc that reuses a default code is ignored).
    final added = snap.docs
        .map(_clusterFromDoc)
        .where((c) => !c.isArchived && !_isDefaultCode(c.code))
        .toList();
    added.sort((a, b) {
      if (a.createdAt == null && b.createdAt == null) return 0;
      if (a.createdAt == null) return 1;
      if (b.createdAt == null) return -1;
      return a.createdAt!.compareTo(b.createdAt!);
    });
    // The 7 defaults always come first and are always present.
    return [..._defaultClusters, ...added];
  });
}

/// Live stream of every ARCHIVED module subject, newest archived first.
Stream<List<_Cluster>> _archivedSubjectsStream() {
  return FirebaseFirestore.instance
      .collection(_kModuleSubjectsCol)
      .snapshots()
      .map((snap) {
    final clusters = snap.docs
        .map(_clusterFromDoc)
        .where((c) => c.isArchived && !_isDefaultCode(c.code))
        .toList();
    clusters.sort((a, b) {
      if (a.archivedAt == null && b.archivedAt == null) return 0;
      if (a.archivedAt == null) return 1;
      if (b.archivedAt == null) return -1;
      return b.archivedAt!.compareTo(a.archivedAt!);
    });
    return clusters;
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Public helper: open the Add Subject sheet from anywhere.
// ─────────────────────────────────────────────────────────────────────────────

void showAddSubjectSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const AddSubjectSheet(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Archive a module subject — auto-archives its modules.
// ─────────────────────────────────────────────────────────────────────────────

Future<void> archiveSubject(BuildContext context, _Cluster cluster) async {
  if (cluster.isDefault) {
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Default subjects cannot be archived or deleted.')));
    return;
  }
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Archive Subject',
          style: TextStyle(
              color: Color(0xFFD84315), fontWeight: FontWeight.bold)),
      content: Text(
          'This will archive "${cluster.label}" (${cluster.code}) and automatically archive any modules under it. You can restore both later from the Archived tab.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.grey))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFD84315),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Archive'),
        ),
      ],
    ),
  );
  if (confirm != true) return;

  try {
    final firestore = FirebaseFirestore.instance;
    final modulesSnap = await firestore
        .collection('modules')
        .where('cluster', isEqualTo: cluster.code)
        .where('archived', isEqualTo: false)
        .get();

    final batch = firestore.batch();
    for (final doc in modulesSnap.docs) {
      batch.update(doc.reference, {
        'archived': true,
        'archivedAt': FieldValue.serverTimestamp(),
      });
    }
    batch.update(firestore.collection(_kModuleSubjectsCol).doc(cluster.id), {
      'archived': true,
      'archivedAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '"${cluster.label}" archived. ${modulesSnap.docs.length} module(s) archived.')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to archive subject: $e')));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Restore an archived module subject — also restores its archived modules.
// ─────────────────────────────────────────────────────────────────────────────

Future<void> restoreSubject(BuildContext context, _Cluster cluster) async {
  try {
    final firestore = FirebaseFirestore.instance;
    final modulesSnap = await firestore
        .collection('modules')
        .where('cluster', isEqualTo: cluster.code)
        .where('archived', isEqualTo: true)
        .get();

    final batch = firestore.batch();
    for (final doc in modulesSnap.docs) {
      batch.update(doc.reference, {
        'archived': false,
        'archivedAt': FieldValue.delete(),
      });
    }
    batch.update(firestore.collection(_kModuleSubjectsCol).doc(cluster.id), {
      'archived': false,
      'archivedAt': FieldValue.delete(),
    });
    await batch.commit();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '"${cluster.label}" restored. ${modulesSnap.docs.length} module(s) restored.')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to restore subject: $e')));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Permanently delete an already-archived module subject (admin only) and all
// of its modules. Cannot be undone.
// ─────────────────────────────────────────────────────────────────────────────

Future<void> permanentlyDeleteSubject(
    BuildContext context, _Cluster cluster) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Delete Permanently',
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
      content: Text(
          'This will permanently delete "${cluster.label}" (${cluster.code}) and all of its archived modules. This cannot be undone.'),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child:
                const Text('Cancel', style: TextStyle(color: Colors.grey))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Delete Forever'),
        ),
      ],
    ),
  );
  if (confirm != true) return;

  try {
    final firestore = FirebaseFirestore.instance;
    final modulesSnap = await firestore
        .collection('modules')
        .where('cluster', isEqualTo: cluster.code)
        .get();

    final batch = firestore.batch();
    for (final doc in modulesSnap.docs) {
      batch.delete(doc.reference);
    }
    batch.delete(firestore.collection(_kModuleSubjectsCol).doc(cluster.id));
    await batch.commit();

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              '"${cluster.label}" permanently deleted along with ${modulesSnap.docs.length} module(s).')));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to delete subject: $e')));
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TeacherModulesScreen (shared by Instructor + Admin accountTypes)
// ─────────────────────────────────────────────────────────────────────────────

class TeacherModulesScreen extends StatefulWidget {
  const TeacherModulesScreen({super.key});

  @override
  State<TeacherModulesScreen> createState() => _TeacherModulesScreenState();
}

class _TeacherModulesScreenState extends State<TeacherModulesScreen> {
  final _user = FirebaseAuth.instance.currentUser;
  bool _isAdmin = false;

  StreamSubscription<List<_Cluster>>? _subjectsSub;
  List<String>? _prevCodes;

  @override
  void initState() {
    super.initState();
    _loadAccountType();
    _subjectsSub = _subjectsStream().listen(_onSubjectsChanged);
  }

  @override
  void dispose() {
    _subjectsSub?.cancel();
    super.dispose();
  }

  Future<void> _loadAccountType() async {
    if (_user == null) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(_user.uid)
          .get();
      final accountType = doc.data()?['accountType'] as String?;
      if (mounted) setState(() => _isAdmin = accountType == 'admin');
    } catch (_) {
      // Default stays non-admin on failure — the safer fallback.
    }
  }

  void _onSubjectsChanged(List<_Cluster> clusters) {
    final codes = clusters.map((c) => c.code).toList();
    if (_prevCodes != null && !_isAdmin && mounted) {
      final added = codes.where((c) => !_prevCodes!.contains(c)).toList();
      final removed = _prevCodes!.where((c) => !codes.contains(c)).toList();
      if (added.isNotEmpty) {
        _snack('New subject added: ${added.join(", ")}');
      }
      if (removed.isNotEmpty) {
        _snack('Subject removed: ${removed.join(", ")}');
      }
    }
    _prevCodes = codes;
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ── Archive a module (sets archived: true) ──────────────────────────────
  Future<void> _archiveModule(String docId) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Archive Module',
            style: TextStyle(
                color: Color(0xFF1A237E), fontWeight: FontWeight.bold)),
        content: const Text(
            'This module will be moved to the Archive. You can restore it anytime.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child:
                  const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE65100),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Archive'),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await FirebaseFirestore.instance
        .collection('modules')
        .doc(docId)
        .update({'archived': true, 'archivedAt': FieldValue.serverTimestamp()});

    if (mounted) _snack('Module archived.');
  }

  void _onModuleSaved(String title, _Cluster cluster) {
    _showSuccessDialog(context, title, cluster);
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<_Cluster>>(
      stream: _subjectsStream(),
      builder: (context, subjSnap) {
        final clusters = subjSnap.data ?? [];

        return Scaffold(
          backgroundColor: const Color(0xFFF4F6FB),
          floatingActionButton: FloatingActionButton.extended(
            heroTag: 'addModule',
            backgroundColor: const Color(0xFF1A237E),
            foregroundColor: Colors.white,
            icon: const Icon(Icons.add_link_rounded),
            label: const Text('Add Module',
                style: TextStyle(fontWeight: FontWeight.bold)),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => _UploadModuleSheet(
                teacherUid: _user?.uid ?? '',
                clusters: clusters,
                isAdmin: _isAdmin,
                onSaved: _onModuleSaved,
              ),
            ),
          ),
          // Subject management lives only inside the Add Module flow
          // ("Add / manage subjects").
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('modules')
                .where('uploadedBy', isEqualTo: _user?.uid)
                .where('archived', isEqualTo: false)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(
                    child:
                        CircularProgressIndicator(color: Color(0xFF1A237E)));
              }

              final docs = snapshot.data?.docs ?? [];

              docs.sort((a, b) {
                final aTime = (a.data() as Map<String, dynamic>)['uploadedAt']
                    as Timestamp?;
                final bTime = (b.data() as Map<String, dynamic>)['uploadedAt']
                    as Timestamp?;
                if (aTime == null && bTime == null) return 0;
                if (aTime == null) return 1;
                if (bTime == null) return -1;
                return bTime.compareTo(aTime);
              });

              if (docs.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.folder_open_rounded,
                          size: 72, color: Colors.grey[300]),
                      const SizedBox(height: 14),
                      Text('No modules added yet.',
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 15)),
                      const SizedBox(height: 6),
                      Text('Tap "Add Module" to get started.',
                          style: TextStyle(
                              color: Colors.grey[400], fontSize: 13)),
                    ],
                  ),
                );
              }

              return ListView.separated(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
                itemCount: docs.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final doc = docs[index];
                  final data = doc.data() as Map<String, dynamic>;
                  return _ModuleCard(
                    data: data,
                    isTeacher: true,
                    onArchive: () => _archiveModule(doc.id),
                  );
                },
              );
            },
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ManageModuleSubjectsScreen
//
// Opened from Add Module > "Add / manage subjects". Separate from Manage
// Curriculum.
//   Active tab   : list of module subjects with an Archive button
//   Archived tab : archived subjects with Restore (and Delete Permanently for
//                  admins)
//   "Add Subject": adds a subject that instantly appears in the Add Module
//                  subject picker.
// ─────────────────────────────────────────────────────────────────────────────

class ManageModuleSubjectsScreen extends StatefulWidget {
  final bool isAdmin;
  const ManageModuleSubjectsScreen({super.key, this.isAdmin = false});

  @override
  State<ManageModuleSubjectsScreen> createState() =>
      _ManageModuleSubjectsScreenState();
}

class _ManageModuleSubjectsScreenState
    extends State<ManageModuleSubjectsScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.isAdmin) _migrateOldClusters();
  }

  // One-time move of the old module clusters out of the curriculum's
  // `subjects` collection into `moduleSubjects`. Curriculum documents always
  // have yearLevel/semester, so they are skipped. Safe to run repeatedly.
  Future<void> _migrateOldClusters() async {
    try {
      final fs = FirebaseFirestore.instance;
      final old = await fs.collection('subjects').get();
      final batch = fs.batch();
      var n = 0;
      for (final doc in old.docs) {
        final d = doc.data();
        if (d.containsKey('yearLevel') || d.containsKey('semester')) continue;
        // Defaults are built into the app; no need to move them.
        if (_isDefaultCode((d['code'] as String?) ?? '')) continue;
        batch.set(fs.collection(_kModuleSubjectsCol).doc(doc.id), d);
        batch.delete(doc.reference);
        n++;
      }
      if (n > 0) await batch.commit();
    } catch (_) {
      // Non-fatal.
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: const Color(0xFFF4F6FB),
        appBar: AppBar(
          backgroundColor: const Color(0xFF1A237E),
          foregroundColor: Colors.white,
          title: const Text('Manage Subjects',
              style: TextStyle(fontWeight: FontWeight.bold)),
          bottom: const TabBar(
            indicatorColor: Colors.white,
            indicatorWeight: 3,
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white60,
            labelStyle: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            tabs: [Tab(text: 'Active'), Tab(text: 'Archived')],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'addModuleSubject',
          backgroundColor: const Color(0xFF1A237E),
          foregroundColor: Colors.white,
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add Subject',
              style: TextStyle(fontWeight: FontWeight.bold)),
          onPressed: () => showAddSubjectSheet(context),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: TabBarView(
              children: [
                // ── Active ───────────────────────────────────────────────
                StreamBuilder<List<_Cluster>>(
                  stream: _subjectsStream(),
                  builder: (context, snap) {
                    if (snap.hasError) {
                      return Center(
                        child: Text('Error: ${snap.error}',
                            style: const TextStyle(color: Colors.red)),
                      );
                    }
                    if (!snap.hasData) {
                      return const Center(
                          child: CircularProgressIndicator(
                              color: Color(0xFF1A237E)));
                    }
                    final subjects = snap.data!;
                    if (subjects.isEmpty) {
                      return Center(
                        child: Text(
                          'No subjects yet.\nTap "Add Subject" to create one.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.grey[500], fontSize: 14),
                        ),
                      );
                    }
                    return ListView(
                      padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE8EAF6),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.info_outline_rounded,
                                  color: Color(0xFF1A237E), size: 16),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'These subjects are used when uploading modules. '
                                  'Subjects with a lock are the 7 default subjects '
                                  'and cannot be archived. Subjects you add can be '
                                  'archived (this also archives their modules) and '
                                  'restored later.',
                                  style: TextStyle(
                                      fontSize: 12,
                                      color: Color(0xFF1A237E)),
                                ),
                              ),
                            ],
                          ),
                        ),
                        for (final s in subjects) ...[
                          _ManageSubjectRow(
                            cluster: s,
                            onArchive: () => archiveSubject(context, s),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ],
                    );
                  },
                ),

                // ── Archived ─────────────────────────────────────────────
                ArchivedSubjectsList(canDelete: widget.isAdmin),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// StudentModulesScreen  (REDESIGNED)
//
// Flow: Year Level -> Semester -> Subject -> Modules -> Read Module
//
// Data mapping (uses existing fields, no Firestore changes):
//   Year/Semester/Subject  = curriculum `subjects` (CurriculumRepo.streamAll)
//   Modules of a subject   = `modules` where module.subject == subject.code
//
// Cleanup rules:
//   • Modules with no curriculum `subject` are hidden (no year/semester).
//   • Placeholder titles like "CLJ(0)" or "()" are hidden.
//   • Duplicates (same subject + same title) are shown once.
//   • Modules are sorted by the first number in the title, then A–Z.
// ─────────────────────────────────────────────────────────────────────────────

class StudentModulesScreen extends StatefulWidget {
  /// Optional: pass the student's year (e.g. '4th Year') to tag it "Your year".
  final String? studentYear;
  const StudentModulesScreen({super.key, this.studentYear});

  @override
  State<StudentModulesScreen> createState() => _StudentModulesScreenState();
}

class _StudentModulesScreenState extends State<StudentModulesScreen> {
  static const _navy = Color(0xFF1A237E);

  late final Stream<List<Subject>> _subjectsStream =
      CurriculumRepo.streamAll();
  late final Stream<QuerySnapshot> _modulesStream = FirebaseFirestore.instance
      .collection('modules')
      .where('archived', isEqualTo: false)
      .snapshots();

  String? _year;
  String? _sem;
  Subject? _subject;

  int get _level =>
      _subject != null ? 3 : (_sem != null ? 2 : (_year != null ? 1 : 0));

  void _back() => setState(() {
        if (_subject != null) {
          _subject = null;
        } else if (_sem != null) {
          _sem = null;
        } else {
          _year = null;
        }
      });

  // ── Data cleanup ──────────────────────────────────────────────────────────

  static bool _invalidTitle(String t) =>
      t.isEmpty || RegExp(r'^[A-Za-z ]*\(\s*\d*\s*\)$').hasMatch(t);

  static int _numIn(String t) {
    final m = RegExp(r'\d+').firstMatch(t);
    return m == null ? 9999 : int.parse(m.group(0)!);
  }

  /// subject code (lowercase) -> clean, de-duplicated, numerically sorted list
  Map<String, List<Map<String, dynamic>>> _group(
      List<QueryDocumentSnapshot> docs) {
    final seen = <String>{};
    final out = <String, List<Map<String, dynamic>>>{};
    for (final d in docs) {
      final m = d.data() as Map<String, dynamic>;
      final code = (m['subject'] as String? ?? '').trim().toLowerCase();
      final title = (m['title'] as String? ?? '').trim();
      if (code.isEmpty || _invalidTitle(title)) continue;
      final key = '$code|${title.toLowerCase().replaceAll(RegExp(r'\s+'), '')}';
      if (!seen.add(key)) continue;
      (out[code] ??= []).add(m);
    }
    for (final list in out.values) {
      list.sort((a, b) {
        final ta = (a['title'] as String? ?? '').trim();
        final tb = (b['title'] as String? ?? '').trim();
        final n = _numIn(ta).compareTo(_numIn(tb));
        return n != 0 ? n : ta.toLowerCase().compareTo(tb.toLowerCase());
      });
    }
    return out;
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _level == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: StreamBuilder<List<Subject>>(
        stream: _subjectsStream,
        builder: (context, subjSnap) => StreamBuilder<QuerySnapshot>(
          stream: _modulesStream,
          builder: (context, modSnap) {
            if (!subjSnap.hasData || !modSnap.hasData) {
              return const Center(
                  child: CircularProgressIndicator(color: _navy));
            }
            final subjects = subjSnap.data!;
            final byCode = _group(modSnap.data!.docs);
            int count(Subject s) => byCode[s.code.trim().toLowerCase()]
                    ?.length ??
                0;

            return Column(
              children: [
                _header(),
                const Divider(height: 1),
                Expanded(child: _body(subjects, byCode, count)),
              ],
            );
          },
        ),
      ),
    );
  }

  // ── Header: Back button + always-visible current selection ───────────────

  Widget _header() {
    final trail = [if (_year != null) _year!, if (_sem != null) _sem!]
        .join(' • ');
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      width: double.infinity,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_level > 0)
            TextButton.icon(
              onPressed: _back,
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Back'),
              style: TextButton.styleFrom(
                foregroundColor: _navy,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          if (_level == 0)
            const Text('Modules',
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: _navy))
          else
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: _navy.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _navy.withValues(alpha: 0.25)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.school_rounded, size: 16, color: _navy),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(trail,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: _navy)),
                  ),
                ],
              ),
            ),
          if (_subject != null) ...[
            const SizedBox(height: 10),
            Text(_subject!.code,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: _colorForCode(_prefix(_subject!.code)))),
            Text(_subject!.description,
                style: TextStyle(fontSize: 13, color: Colors.grey[700])),
          ] else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                const [
                  'Select your year level',
                  'Select a semester',
                  'Select a subject',
                ][_level],
                style: TextStyle(fontSize: 13, color: Colors.grey[600]),
              ),
            ),
        ],
      ),
    );
  }

  String _prefix(String code) => code.trim().split(' ').first.toUpperCase();

  // ── Body: one list per level ──────────────────────────────────────────────

  Widget _body(List<Subject> subjects,
      Map<String, List<Map<String, dynamic>>> byCode, int Function(Subject) count) {
    // Level 3: modules of the chosen subject.
    if (_subject != null) {
      final mods = byCode[_subject!.code.trim().toLowerCase()] ?? [];
      if (mods.isEmpty) {
        return _empty(Icons.folder_open_rounded,
            'No modules for ${_subject!.code} yet.');
      }
      return ListView.builder(
        padding: const EdgeInsets.all(14),
        itemCount: mods.length,
        itemBuilder: (_, i) => Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 4),
                child: Text('Module ${i + 1}',
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey[600])),
              ),
              _ModuleCard(data: mods[i], isTeacher: false), // Read Module kept
            ],
          ),
        ),
      );
    }

    // Level 2: subjects for the chosen year + semester.
    if (_sem != null) {
      final list = subjects
          .where((s) => s.yearLevel == _year && s.semester == _sem)
          .toList();
      if (list.isEmpty) {
        return _empty(Icons.menu_book_rounded,
            'No subjects for $_year • $_sem yet.');
      }
      return _list([
        for (final s in list)
          _NavCard(
            icon: Icons.menu_book_rounded,
            color: _colorForCode(_prefix(s.code)),
            title: '${s.code} — ${s.description}',
            subtitle: '${count(s)} ${count(s) == 1 ? 'Module' : 'Modules'}',
            onTap: () => setState(() => _subject = s),
          ),
      ]);
    }

    // Level 1: semesters of the chosen year.
    if (_year != null) {
      return _list([
        for (final sem in CurriculumRepo.semesters)
          Builder(builder: (_) {
            final inSem = subjects
                .where((s) => s.yearLevel == _year && s.semester == sem)
                .toList();
            final mods = inSem.fold<int>(0, (n, s) => n + count(s));
            return _NavCard(
              icon: Icons.calendar_month_rounded,
              color: _navy,
              title: sem,
              subtitle: '${inSem.length} Subjects • $mods Modules',
              onTap: () => setState(() => _sem = sem),
            );
          }),
      ]);
    }

    // Level 0: year levels.
    return _list([
      for (final y in CurriculumRepo.yearLevels)
        Builder(builder: (_) {
          final inYear = subjects.where((s) => s.yearLevel == y).toList();
          final mods = inYear.fold<int>(0, (n, s) => n + count(s));
          return _NavCard(
            icon: Icons.school_rounded,
            color: _navy,
            title: y,
            tag: widget.studentYear == y ? 'Your year' : null,
            subtitle: '${inYear.length} Subjects • $mods Modules',
            onTap: () => setState(() => _year = y),
          );
        }),
    ]);
  }

  Widget _list(List<Widget> children) => ListView.separated(
        padding: const EdgeInsets.all(14),
        itemCount: children.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (_, i) => children[i],
      );

  Widget _empty(IconData icon, String msg) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text(msg,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey[500], fontSize: 15)),
          ],
        ),
      );
}

/// One tappable row used at the Year, Semester and Subject levels.
class _NavCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final String? tag;
  final VoidCallback onTap;

  const _NavCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.tag,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.25)),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF1A237E).withValues(alpha: 0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: color)),
                  const SizedBox(height: 3),
                  Text(subtitle,
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey[600])),
                ],
              ),
            ),
            if (tag != null)
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(tag!,
                    style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: color)),
              ),
            Icon(Icons.chevron_right_rounded, color: color),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared Module Card
//
// Shows the module's subject group (e.g. CDI) and, when set, its curriculum
// subject (e.g. CDI 3). For STUDENTS, tapping "Read Module" first shows a
// confirmation dialog saying which subject the module belongs to; the module
// only opens after the student taps "Open Module". Teachers preview directly.
// ─────────────────────────────────────────────────────────────────────────────

class _ModuleCard extends StatefulWidget {
  final Map<String, dynamic> data;
  final bool isTeacher;
  final VoidCallback? onArchive;

  const _ModuleCard({
    required this.data,
    required this.isTeacher,
    this.onArchive,
  });

  @override
  State<_ModuleCard> createState() => _ModuleCardState();
}

class _ModuleCardState extends State<_ModuleCard> {
  String? _teacherName;

  @override
  void initState() {
    super.initState();
    _loadTeacherName();
  }

  Future<void> _loadTeacherName() async {
    final uploadedBy = widget.data['uploadedBy'] as String? ?? '';
    if (uploadedBy.isEmpty) return;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uploadedBy)
          .get();
      final userData = doc.data();
      if (userData == null) return;
      final first = (userData['firstName'] as String? ?? '').trim();
      final last = (userData['lastName'] as String? ?? '').trim();
      final fullName = [first, last].where((s) => s.isNotEmpty).join(' ');
      if (mounted && fullName.isNotEmpty) {
        setState(() => _teacherName = fullName);
      }
    } catch (_) {
      // Silently skip.
    }
  }

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the module link.')),
        );
      }
    }
  }

  /// Students: confirm which subject the module belongs to, then open.
  /// Teachers: open straight away.
  Future<void> _onOpenPressed(BuildContext context, String fileUrl) async {
    if (widget.isTeacher) {
      await _open(context, fileUrl);
      return;
    }

    final clusterCode = widget.data['cluster'] as String? ?? '';
    // Old modules without any subject info open directly.
    if (clusterCode.isEmpty) {
      await _open(context, fileUrl);
      return;
    }

    final title = widget.data['title'] as String? ?? 'Untitled Module';
    final clusterLabel = widget.data['clusterLabel'] as String? ?? clusterCode;
    final subjectCode = widget.data['subject'] as String? ?? '';
    final subjectLabel = widget.data['subjectLabel'] as String? ?? '';
    final color = _colorForCode(clusterCode);
    final icon = _iconForCode(clusterCode);

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        contentPadding: const EdgeInsets.fromLTRB(22, 22, 22, 8),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.1),
                    shape: BoxShape.circle,
                    border: Border.all(color: color.withValues(alpha: 0.35)),
                  ),
                  child: Icon(icon, color: color, size: 30),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  'This module is from $clusterCode',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  clusterLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                ),
              ),
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.07),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: color.withValues(alpha: 0.25)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (subjectCode.isNotEmpty) ...[
                      Text('Curriculum subject',
                          style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey[600])),
                      const SizedBox(height: 2),
                      Text(
                        subjectLabel.isNotEmpty
                            ? '$subjectCode — $subjectLabel'
                            : subjectCode,
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: color),
                      ),
                      const SizedBox(height: 10),
                    ],
                    Text('Module',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[600])),
                    const SizedBox(height: 2),
                    Text(title,
                        style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF1A237E))),
                  ],
                ),
              ),
            ],
          ),
        ),
        actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 14),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton.icon(
            style: ElevatedButton.styleFrom(
              backgroundColor: color,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.open_in_browser_rounded, size: 16),
            label: const Text('Open Module'),
          ),
        ],
      ),
    );

    if (proceed == true && context.mounted) {
      await _open(context, fileUrl);
    }
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.data['title'] as String? ?? 'Untitled Module';
    final clusterCode = widget.data['cluster'] as String? ?? '';
    final clusterLabel = widget.data['clusterLabel'] as String? ?? clusterCode;
    final subjectCode = widget.data['subject'] as String? ?? '';
    final subjectLabel = widget.data['subjectLabel'] as String? ?? '';
    final fileUrl = widget.data['fileUrl'] as String? ?? '';
    final hasCluster = clusterCode.isNotEmpty;
    final hasSubject = subjectCode.isNotEmpty;
    final clusterColor =
        hasCluster ? _colorForCode(clusterCode) : const Color(0xFF1A237E);
    final clusterIcon =
        hasCluster ? _iconForCode(clusterCode) : Icons.menu_book_rounded;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE8EAF6), width: 1),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1A237E).withValues(alpha: 0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 14, 12, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: clusterColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: clusterColor.withValues(alpha: 0.25)),
                  ),
                  child: Icon(Icons.menu_book_rounded,
                      color: clusterColor, size: 26),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title,
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Color(0xFF1A237E),
                          )),
                      const SizedBox(height: 6),
                      if (hasCluster)
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            _chip(clusterIcon, clusterCode,
                                color: clusterColor),
                            if (hasSubject)
                              _chip(
                                  Icons.bookmark_rounded,
                                  subjectLabel.isNotEmpty
                                      ? '$subjectCode · $subjectLabel'
                                      : subjectCode,
                                  color: clusterColor,
                                  maxWidth: 240)
                            else
                              _chip(Icons.menu_book_rounded, clusterLabel,
                                  color: clusterColor, maxWidth: 200),
                            if (_teacherName != null)
                              _chip(Icons.person_rounded, _teacherName!,
                                  color: clusterColor, maxWidth: 160),
                          ],
                        ),
                    ],
                  ),
                ),
                if (widget.isTeacher && widget.onArchive != null)
                  GestureDetector(
                    onTap: widget.onArchive,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFFF3E0),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: const Color(0xFFFFCC80)),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inventory_2_rounded,
                              size: 13, color: Color(0xFFE65100)),
                          SizedBox(width: 4),
                          Text('Archive',
                              style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFE65100))),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          InkWell(
            onTap: fileUrl.isNotEmpty
                ? () => _onOpenPressed(context, fileUrl)
                : null,
            borderRadius:
                const BorderRadius.vertical(bottom: Radius.circular(14)),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: clusterColor,
                borderRadius: const BorderRadius.vertical(
                    bottom: Radius.circular(14)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(
                    Icons.open_in_browser_rounded,
                    color: Colors.white,
                    size: 16,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.isTeacher ? 'Preview Module' : 'Read Module',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String label,
      {Color? color, double? maxWidth}) {
    return Container(
      constraints:
          maxWidth != null ? BoxConstraints(maxWidth: maxWidth) : null,
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: (color ?? const Color(0xFF3949AB)).withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color ?? const Color(0xFF3949AB)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                color: color ?? const Color(0xFF3949AB),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Success Dialog
// ─────────────────────────────────────────────────────────────────────────────

void _showSuccessDialog(
    BuildContext context, String title, _Cluster cluster) {
  showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Success',
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 450),
    transitionBuilder: (ctx, anim, _, child) {
      final curved = CurvedAnimation(
        parent: anim,
        curve: Curves.elasticOut,
      );
      return ScaleTransition(
        scale: curved,
        child: FadeTransition(opacity: anim, child: child),
      );
    },
    pageBuilder: (ctx, _, __) {
      Future.delayed(const Duration(milliseconds: 2500), () {
        if (ctx.mounted) Navigator.of(ctx).pop();
      });

      return Center(
        child: Material(
          color: Colors.transparent,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 36),
            padding:
                const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(24),
              boxShadow: [
                BoxShadow(
                  color: cluster.color.withValues(alpha: 0.2),
                  blurRadius: 40,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 650),
                  curve: Curves.elasticOut,
                  builder: (_, value, child) =>
                      Transform.scale(scale: value, child: child),
                  child: Container(
                    width: 76,
                    height: 76,
                    decoration: BoxDecoration(
                      color: cluster.color.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: cluster.color.withValues(alpha: 0.35),
                          width: 2.5),
                    ),
                    child: Icon(Icons.check_rounded,
                        color: cluster.color, size: 40),
                  ),
                ),
                const SizedBox(height: 20),
                const Text(
                  'Module Added!',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A237E),
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF5C6BC0),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: cluster.color.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: cluster.color.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(cluster.icon, size: 15, color: cluster.color),
                      const SizedBox(width: 7),
                      Flexible(
                        child: Text(
                          '${cluster.code} · ${cluster.label}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: cluster.color,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                _AutoDismissBar(color: cluster.color),
                const SizedBox(height: 8),
                Text(
                  'Closing automatically…',
                  style: TextStyle(fontSize: 11, color: Colors.grey[400]),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Subject Bottom Sheet
//
// Adds a MODULE subject (collection `moduleSubjects`). It is separate from the
// curriculum. The new subject appears immediately in the Add Module subject
// picker and in Manage Subjects.
// ─────────────────────────────────────────────────────────────────────────────

class AddSubjectSheet extends StatefulWidget {
  const AddSubjectSheet({super.key});

  @override
  State<AddSubjectSheet> createState() => _AddSubjectSheetState();
}

class _AddSubjectSheetState extends State<AddSubjectSheet> {
  final _codeController = TextEditingController();
  final _labelController = TextEditingController();
  bool _saving = false;

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  void dispose() {
    _codeController.dispose();
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final code = _codeController.text.trim().toUpperCase();
    final label = _labelController.text.trim();

    if (code.isEmpty) {
      _snack('Please enter a short subject code (e.g. CRIM).');
      return;
    }
    if (label.isEmpty) {
      _snack('Please enter the full subject name.');
      return;
    }

    setState(() => _saving = true);
    try {
      if (_isDefaultCode(code)) {
        _snack('"$code" is already a default subject.');
        return;
      }

      final existing = await FirebaseFirestore.instance
          .collection(_kModuleSubjectsCol)
          .where('code', isEqualTo: code)
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        final archived = existing.docs.first.data()['archived'] == true;
        _snack(archived
            ? '"$code" is in the Archived tab. Restore it instead.'
            : 'A subject with code "$code" already exists.');
        return;
      }

      await FirebaseFirestore.instance.collection(_kModuleSubjectsCol).add({
        'code': code,
        'label': label,
        'createdAt': FieldValue.serverTimestamp(),
        'archived': false,
      });

      // Clear the form so more subjects can be added right away.
      _codeController.clear();
      _labelController.clear();
      if (mounted) _snack('Subject added. It is now available for modules.');
    } catch (e) {
      _snack('Failed to add subject: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.85),
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.bookmark_add_rounded,
                    color: Color(0xFF1A237E), size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Add Subject',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A237E))),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: Color(0xFF1A237E), size: 20),
                  splashRadius: 20,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFE8EAF6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: Color(0xFF1A237E), size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This adds a subject for uploading modules only. It does not change the curriculum. The new subject appears instantly in the Add Module subject list.',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFF1A237E)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('Subject Code',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3949AB))),
            const SizedBox(height: 6),
            TextField(
              controller: _codeController,
              textCapitalization: TextCapitalization.characters,
              decoration: _inputDeco('e.g. CRIM', Icons.label_rounded),
            ),
            const SizedBox(height: 14),
            const Text('Subject Name',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3949AB))),
            const SizedBox(height: 6),
            TextField(
              controller: _labelController,
              decoration:
                  _inputDeco('e.g. Criminology', Icons.menu_book_rounded),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.save_rounded),
                label: Text(_saving ? 'Saving…' : 'Save Subject'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A237E),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      const Color(0xFF1A237E).withValues(alpha: 0.7),
                  disabledForegroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
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
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: Color(0xFF1A237E), width: 1.5)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// A single row in the Active list of ManageModuleSubjectsScreen.
// The button ARCHIVES the subject (it is not a permanent delete).
// ─────────────────────────────────────────────────────────────────────────────

class _ManageSubjectRow extends StatelessWidget {
  final _Cluster cluster;
  final VoidCallback onArchive;

  const _ManageSubjectRow({required this.cluster, required this.onArchive});

  @override
  Widget build(BuildContext context) {
    const archiveColor = Color(0xFFD84315);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cluster.color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cluster.color.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: cluster.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(9),
            ),
            child: Icon(cluster.icon, color: cluster.color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(cluster.code,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: cluster.color)),
                Text(
                  cluster.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 12,
                      color: cluster.color.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
          if (cluster.isDefault)
            const Tooltip(
              message: 'Default subject: cannot be archived or deleted',
              child: Padding(
                padding: EdgeInsets.all(7),
                child: Icon(Icons.lock_outline_rounded,
                    size: 18, color: Colors.grey),
              ),
            )
          else
            Tooltip(
              message: 'Archive',
              child: GestureDetector(
                onTap: onArchive,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: archiveColor.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.inventory_2_outlined,
                      size: 18, color: archiveColor),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ArchivedSubjectsList — archived module subjects with Restore and (optionally)
// Delete Permanently. Set [canDelete] to false to hide permanent delete
// (e.g. for instructors). Default true keeps old callers working.
// ─────────────────────────────────────────────────────────────────────────────

class ArchivedSubjectsList extends StatelessWidget {
  final bool canDelete;
  const ArchivedSubjectsList({super.key, this.canDelete = true});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<_Cluster>>(
      stream: _archivedSubjectsStream(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Text('Error: ${snap.error}',
                style: const TextStyle(color: Colors.red)),
          );
        }
        if (!snap.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFFD84315)));
        }

        final subjects = snap.data!;
        if (subjects.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.bookmark_remove_rounded,
                    size: 64, color: Colors.grey[300]),
                const SizedBox(height: 14),
                Text('No archived subjects.',
                    style: TextStyle(color: Colors.grey[500], fontSize: 15)),
                const SizedBox(height: 6),
                Text('Archived subjects will appear here.',
                    style: TextStyle(color: Colors.grey[400], fontSize: 13)),
              ],
            ),
          );
        }

        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
          itemCount: subjects.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final cluster = subjects[index];
            return _ArchivedSubjectCard(
              key: ValueKey(cluster.id),
              cluster: cluster,
              onRestore: () => restoreSubject(context, cluster),
              onDeletePermanently: canDelete
                  ? () => permanentlyDeleteSubject(context, cluster)
                  : null,
            );
          },
        );
      },
    );
  }
}

class _ArchivedSubjectCard extends StatelessWidget {
  final _Cluster cluster;
  final VoidCallback onRestore;
  final VoidCallback? onDeletePermanently;

  const _ArchivedSubjectCard({
    super.key,
    required this.cluster,
    required this.onRestore,
    this.onDeletePermanently,
  });

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
  ];

  String? get _archivedDateLabel {
    final dt = cluster.archivedAt;
    if (dt == null) return null;
    return '${_monthNames[dt.month - 1]} ${dt.day}, ${dt.year}';
  }

  @override
  Widget build(BuildContext context) {
    final archivedDate = _archivedDateLabel;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFBE9E7),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFCCBC), width: 1.2),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFD84315).withValues(alpha: 0.07),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: const Color(0xFFFFCCBC),
              borderRadius: BorderRadius.circular(9),
            ),
            child: const Icon(Icons.bookmark_remove_rounded,
                color: Color(0xFFD84315), size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(cluster.code,
                    style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFBF360C))),
                Text(cluster.label,
                    style: TextStyle(
                        fontSize: 13,
                        color: const Color(0xFFBF360C)
                            .withValues(alpha: 0.85))),
                if (archivedDate != null) ...[
                  const SizedBox(height: 3),
                  Text('Archived $archivedDate',
                      style: TextStyle(fontSize: 11, color: Colors.grey[600])),
                ],
              ],
            ),
          ),
          const SizedBox(width: 6),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _SmallActionButton(
                label: 'Restore',
                icon: Icons.restore_rounded,
                color: const Color(0xFF1A237E),
                onTap: onRestore,
              ),
              if (onDeletePermanently != null) ...[
                const SizedBox(height: 4),
                _SmallActionButton(
                  label: 'Delete',
                  icon: Icons.delete_forever_rounded,
                  color: Colors.red.shade600,
                  onTap: onDeletePermanently!,
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _SmallActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _SmallActionButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: color.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 11, color: color),
              const SizedBox(width: 3),
              Text(label,
                  style: TextStyle(
                      fontSize: 10, fontWeight: FontWeight.bold, color: color)),
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Add Module Bottom Sheet
//
// The Subject picker is LIVE: it listens to the active module subjects, so a
// subject added (or archived/restored) while this sheet is open shows up
// right away. The "Add / manage subjects" button opens Manage Subjects.
//
// After choosing a subject group (e.g. CDI), a "Curriculum subject" dropdown
// lists that group's curriculum subjects (CDI 1 … CDI 9) from the LIVE
// curriculum. It is required when the group has curriculum subjects, and
// hidden when it has none (e.g. ENG or a custom subject).
// ─────────────────────────────────────────────────────────────────────────────

class _UploadModuleSheet extends StatefulWidget {
  final String teacherUid;
  final List<_Cluster> clusters;
  final bool isAdmin;
  final void Function(String title, _Cluster cluster) onSaved;

  const _UploadModuleSheet({
    required this.teacherUid,
    required this.clusters,
    required this.onSaved,
    this.isAdmin = false,
  });

  @override
  State<_UploadModuleSheet> createState() => _UploadModuleSheetState();
}

class _UploadModuleSheetState extends State<_UploadModuleSheet> {
  final _titleController = TextEditingController();

  String? _selectedCode;
  String? _selectedSubjectCode; // curriculum subject, e.g. 'CDI 3'
  late List<_Cluster> _clusters;
  List<Subject> _curriculum = const [];
  bool _saving = false;
  bool _connecting = false;
  String? _driveEmail;
  PlatformFile? _deviceFile;

  static const _allowedExt = [
    'pdf', 'doc', 'docx', 'ppt', 'pptx', 'xls', 'xlsx', 'txt'
  ];

  /// The chosen subject, falling back to the first one if the chosen subject
  /// no longer exists (e.g. it was just archived).
  _Cluster? get _selectedCluster {
    for (final c in _clusters) {
      if (c.code == _selectedCode) return c;
    }
    return _clusters.isNotEmpty ? _clusters.first : null;
  }

  /// Curriculum subjects that belong to [cluster] (e.g. CDI 1 … CDI 9).
  List<Subject> _curriculumFor(_Cluster? cluster) {
    if (cluster == null) return const [];
    return _curriculum
        .where((s) => _subjectBelongsToCluster(s.code, cluster.code))
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _clusters = widget.clusters;
    _driveEmail = GoogleDriveService.connectedEmail;
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  String? get _accountEmail => FirebaseAuth.instance.currentUser?.email;

  Future<bool> _ensureConnected() async {
    if (_driveEmail != null) return true;
    setState(() => _connecting = true);
    try {
      final email = await GoogleDriveService.connect();
      if (!mounted) return false;
      setState(() => _driveEmail = email);
      if (email != null &&
          _accountEmail != null &&
          email.toLowerCase() != _accountEmail!.toLowerCase()) {
        _snack('Using $email, which is different from your account '
            'email ($_accountEmail).');
      }
      return email != null;
    } catch (e) {
      if (mounted) _snack('Could not connect to Google Drive: $e');
      return false;
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _switchAccount() async {
    await GoogleDriveService.disconnect();
    if (!mounted) return;
    setState(() => _driveEmail = null);
    await _ensureConnected();
  }

  Future<void> _pickFromDevice() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _allowedExt,
        withData: true,
      );
      if (res == null || res.files.isEmpty) return;
      final f = res.files.first;
      if (f.bytes == null) {
        _snack('Could not read that file. Please try another one.');
        return;
      }
      setState(() => _deviceFile = f);
    } catch (e) {
      _snack('Could not open the file picker: $e');
    }
  }

  Future<void> _openDrive() async {
    final uri = Uri.parse('https://drive.google.com/drive/my-drive');
    try {
      final opened =
          await launchUrl(uri, mode: LaunchMode.externalApplication);
      if (!opened && mounted) _snack('Could not open Google Drive.');
    } catch (e) {
      if (mounted) _snack('Could not open Google Drive: $e');
    }
  }

  void _openManageSubjects() {
    Navigator.push(
      context,
      MaterialPageRoute(
          builder: (_) => ManageModuleSubjectsScreen(isAdmin: widget.isAdmin)),
    );
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final cluster = _selectedCluster;

    if (cluster == null) {
      _snack('No subjects available yet. Tap "Add / manage subjects" first.');
      return;
    }

    // Curriculum subject: required whenever this group has any.
    final options = _curriculumFor(cluster);
    Subject? curriculumSubject;
    for (final s in options) {
      if (s.code == _selectedSubjectCode) curriculumSubject = s;
    }
    if (options.isNotEmpty && curriculumSubject == null) {
      _snack('Please choose which ${cluster.code} subject this module '
          'belongs to (e.g. ${options.first.code}).');
      return;
    }

    if (title.isEmpty) {
      _snack('Please enter a module title.');
      return;
    }
    if (_deviceFile == null) {
      _snack('Please choose a file to upload.');
      return;
    }

    if (!await _ensureConnected() || !mounted) return;

    setState(() => _saving = true);

    try {
      final result = await GoogleDriveService.upload(
        fileName: _deviceFile!.name,
        bytes: _deviceFile!.bytes!,
      );

      await FirebaseFirestore.instance.collection('modules').add({
        'title': title,
        'cluster': cluster.code,
        'clusterLabel': cluster.label,
        if (curriculumSubject != null) 'subject': curriculumSubject.code,
        if (curriculumSubject != null)
          'subjectLabel': curriculumSubject.description,
        'fileUrl': result.viewUrl,
        'driveFileId': result.fileId,
        'fileName': result.fileName,
        'driveOwnerEmail': result.accountEmail,
        'uploadedBy': widget.teacherUid,
        'uploadedAt': FieldValue.serverTimestamp(),
        'archived': false,
      });

      if (mounted) {
        final savedTitle = title;
        Navigator.pop(context);
        Future.delayed(const Duration(milliseconds: 300), () {
          widget.onSaved(savedTitle, cluster);
        });
      }
    } on StateError {
      if (mounted) {
        setState(() => _driveEmail = null);
        _snack('Google Drive session expired. Please connect again.');
      }
    } catch (e) {
      final msg = e.toString();
      final expired = msg.contains('401') || msg.contains('Invalid Credentials');
      if (mounted) {
        if (expired) setState(() => _driveEmail = null);
        _snack(expired
            ? 'Google Drive session expired. Please connect again.'
            : 'Failed to save: $e');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _buildSubjectPicker() {
    return StreamBuilder<List<_Cluster>>(
      stream: _subjectsStream(),
      initialData: _clusters,
      builder: (context, snap) {
        _clusters = snap.data ?? _clusters;
        final selectedCode = _selectedCluster?.code;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_clusters.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFFCC80)),
                ),
                child: const Text(
                  'No subjects exist yet. Tap "Add / manage subjects" below to add one.',
                  style: TextStyle(fontSize: 12, color: Color(0xFFE65100)),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _clusters.map((c) {
                  final isSelected = selectedCode == c.code;
                  return GestureDetector(
                    onTap: _saving
                        ? null
                        : () => setState(() {
                              if (_selectedCode != c.code) {
                                // A different group has different curriculum
                                // subjects, so clear the previous choice.
                                _selectedSubjectCode = null;
                              }
                              _selectedCode = c.code;
                            }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? c.color
                            : c.color.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? c.color
                              : c.color.withValues(alpha: 0.3),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(c.icon,
                              size: 16,
                              color: isSelected ? Colors.white : c.color),
                          const SizedBox(width: 7),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(c.code,
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                      color: isSelected
                                          ? Colors.white
                                          : c.color)),
                              Text(c.label,
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: isSelected
                                          ? Colors.white70
                                          : c.color.withValues(alpha: 0.7))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _saving ? null : _openManageSubjects,
                icon: const Icon(Icons.add_rounded, size: 16),
                label: const Text('Add / manage subjects'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF1A237E),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// Dropdown of the live curriculum subjects (CDI 1 … CDI 9) that belong to
  /// the chosen subject group. Hidden when the group has none.
  Widget _buildCurriculumSubjectPicker() {
    return StreamBuilder<List<Subject>>(
      stream: CurriculumRepo.streamAll(),
      builder: (context, snap) {
        if (snap.hasData) _curriculum = snap.data!;

        final cluster = _selectedCluster;
        final options = _curriculumFor(cluster);
        if (cluster == null || options.isEmpty) {
          return const SizedBox.shrink();
        }

        final value = options.any((s) => s.code == _selectedSubjectCode)
            ? _selectedSubjectCode
            : null;

        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${cluster.code} Subject (Curriculum)',
                  style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFF3949AB))),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: value,
                isExpanded: true,
                decoration: _inputDeco(
                    'Select ${cluster.code} subject', Icons.bookmark_rounded),
                items: options
                    .map((s) => DropdownMenuItem<String>(
                          value: s.code,
                          child: Text(
                            '${s.code} — ${s.description}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 13),
                          ),
                        ))
                    .toList(),
                onChanged: _saving
                    ? null
                    : (v) => setState(() => _selectedSubjectCode = v),
              ),
              const SizedBox(height: 4),
              Text(
                'Students will be told this module is from '
                '${cluster.code} before they open it.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(
          20, 16, 20, MediaQuery.of(context).viewInsets.bottom + 24),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                    color: Colors.grey[300],
                    borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Row(
              children: [
                const Icon(Icons.add_to_drive_rounded,
                    color: Color(0xFF1A237E), size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('Add Module',
                      style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF1A237E))),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.arrow_back_rounded,
                      color: Color(0xFF1A237E), size: 20),
                  splashRadius: 20,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 32, minHeight: 32),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFE8EAF6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline_rounded,
                      color: Color(0xFF1A237E), size: 16),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Choose a file from this device to upload. It is saved '
                      'to your Google Drive (ReviewHub Modules folder) and '
                      'shared with students as view-only. Need to grab it '
                      'from Drive first? Use "Open Google Drive" below.',
                      style:
                          TextStyle(fontSize: 12, color: Color(0xFF1A237E)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const Text('Module Title',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3949AB))),
            const SizedBox(height: 6),
            TextField(
              controller: _titleController,
              decoration: _inputDeco(
                  'e.g. Chapter 1: Introduction to Corrections',
                  Icons.title_rounded),
            ),
            const SizedBox(height: 14),
            const Text('Subject',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3949AB))),
            const SizedBox(height: 10),
            _buildSubjectPicker(),
            _buildCurriculumSubjectPicker(),
            const SizedBox(height: 14),
            ..._buildFileSection(),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Icon(Icons.save_rounded),
                label: Text(_saving ? 'Uploading…' : 'Save Module'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A237E),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      const Color(0xFF1A237E).withValues(alpha: 0.7),
                  disabledForegroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildFileSection() {
    const navy = Color(0xFF1A237E);
    const indigo = Color(0xFF3949AB);
    final connected = _driveEmail != null;
    final busy = _saving || _connecting;

    return [
      SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: busy ? null : _openDrive,
          icon: const Icon(Icons.open_in_new_rounded),
          label: const Text('Open Google Drive'),
          style: OutlinedButton.styleFrom(
            foregroundColor: navy,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
      const SizedBox(height: 14),
      const Text('File from device',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.w600, color: indigo)),
      const SizedBox(height: 6),
      InkWell(
        onTap: busy ? null : _pickFromDevice,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.grey.shade300),
          ),
          child: Row(
            children: [
              _connecting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.attach_file_rounded,
                      color: indigo, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _deviceFile?.name ??
                      'Tap to choose a PDF, DOCX, PPTX… file',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 14,
                      color: _deviceFile == null
                          ? Colors.grey.shade600
                          : Colors.black87),
                ),
              ),
            ],
          ),
        ),
      ),
      if (connected) ...[
        const SizedBox(height: 6),
        Row(
          children: [
            const Icon(Icons.check_circle_rounded,
                color: Color(0xFF2E7D32), size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Google Drive: $_driveEmail',
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            ),
            TextButton(
              onPressed: busy ? null : _switchAccount,
              style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap),
              child: const Text('Switch account',
                  style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ],
    ];
  }

  InputDecoration _inputDeco(String hint, IconData icon) => InputDecoration(
        hintText: hint,
        prefixIcon: Icon(icon, color: const Color(0xFF3949AB), size: 20),
        filled: true,
        fillColor: Colors.white,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300)),
        enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: Colors.grey.shade300)),
        focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide:
                const BorderSide(color: Color(0xFF1A237E), width: 1.5)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Auto-dismiss progress bar widget
// ─────────────────────────────────────────────────────────────────────────────

class _AutoDismissBar extends StatefulWidget {
  final Color color;
  const _AutoDismissBar({required this.color});

  @override
  State<_AutoDismissBar> createState() => _AutoDismissBarState();
}

class _AutoDismissBarState extends State<_AutoDismissBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    )..forward();
    _anim = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.linear),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, __) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 3,
          width: 160,
          child: LinearProgressIndicator(
            value: _anim.value,
            backgroundColor: widget.color.withValues(alpha: 0.15),
            valueColor: AlwaysStoppedAnimation(widget.color),
          ),
        ),
      ),
    );
  }
}