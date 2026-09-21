import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Subject Cluster model
//
// Subjects now live in Firestore (`subjects` collection: {code, label,
// createdAt, archived, archivedAt}) instead of a hardcoded list, so admin
// can add/archive/restore/permanently delete them and both the Admin and
// Instructor dashboards (which share this same screen) stay in sync
// automatically via the streams below.
//
// Color/icon are NOT stored — they're derived deterministically from the
// subject's `code` using the fixed palette below, so adding a subject only
// ever needs a code + a name.
//
// ARCHIVE MODEL: subjects are never hard-deleted from the "Manage Subjects"
// list anymore. Tapping the delete icon there now archives the subject
// (sets `archived: true`) and cascade-archives every non-archived module
// under it, exactly mirroring how Reviews/Modules archiving already works
// elsewhere in the app. Archived subjects show up in a separate
// "Archived Subjects" list (see ArchivedSubjectsList below) with Restore
// and Delete Permanently actions.
// ─────────────────────────────────────────────────────────────────────────────

class _Cluster {
  final String id; // Firestore doc id ('' for the synthetic "All" cluster)
  final String code;
  final String label;
  final Color color;
  final IconData icon;
  // Null while the doc's serverTimestamp() write is still pending
  // acknowledgement from the server. Kept so we can sort newly-added
  // subjects to the end client-side instead of relying on Firestore's
  // own orderBy() (see _subjectsStream below for why).
  final DateTime? createdAt;
  // Whether this subject has been archived (soft-deleted) by an admin.
  final bool isArchived;
  // When the subject was archived. Null if it isn't archived, or if the
  // archivedAt serverTimestamp() write is still pending.
  final DateTime? archivedAt;

  const _Cluster({
    required this.id,
    required this.code,
    required this.label,
    required this.color,
    required this.icon,
    this.createdAt,
    this.isArchived = false,
    this.archivedAt,
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
    // Will be null for a split second right after a subject is added,
    // while the serverTimestamp() write is still in flight.
    createdAt: rawCreatedAt is Timestamp ? rawCreatedAt.toDate() : null,
    isArchived: data['archived'] as bool? ?? false,
    archivedAt: rawArchivedAt is Timestamp ? rawArchivedAt.toDate() : null,
  );
}

/// Live stream of every ACTIVE (non-archived) subject, ordered by creation
/// time. Shared by the teacher/admin screen and the student screen so both
/// stay in sync. Archived subjects are intentionally excluded here — they
/// should never appear in subject pickers/filters, only in
/// ArchivedSubjectsList below.
///
/// IMPORTANT: this intentionally does NOT use Firestore's `.orderBy('createdAt')`
/// on the query itself. `createdAt` is written with `FieldValue.serverTimestamp()`,
/// and Firestore excludes documents from query results entirely while a
/// serverTimestamp() field used in orderBy() is still pending server
/// acknowledgement. In practice that meant a subject an admin just added
/// could vanish from this list — sometimes for a second, sometimes longer
/// on a slow connection — instead of showing up immediately. Sorting
/// client-side avoids that: a pending subject (createdAt == null) is simply
/// placed at the end of the list rather than being hidden.
Stream<List<_Cluster>> _subjectsStream() {
  return FirebaseFirestore.instance
      .collection('subjects')
      .snapshots()
      .map((snap) {
    final clusters = snap.docs
        .map(_clusterFromDoc)
        .where((c) => !c.isArchived)
        .toList();
    clusters.sort((a, b) {
      if (a.createdAt == null && b.createdAt == null) return 0;
      if (a.createdAt == null) return 1; // pending write -> goes last
      if (b.createdAt == null) return -1;
      return a.createdAt!.compareTo(b.createdAt!);
    });
    return clusters;
  });
}

/// Live stream of every ARCHIVED subject, most-recently-archived first.
/// Backs ArchivedSubjectsList below.
Stream<List<_Cluster>> _archivedSubjectsStream() {
  return FirebaseFirestore.instance
      .collection('subjects')
      .snapshots()
      .map((snap) {
    final clusters = snap.docs
        .map(_clusterFromDoc)
        .where((c) => c.isArchived)
        .toList();
    clusters.sort((a, b) {
      if (a.archivedAt == null && b.archivedAt == null) return 0;
      if (a.archivedAt == null) return 1; // pending write -> goes last
      if (b.archivedAt == null) return -1;
      return b.archivedAt!.compareTo(a.archivedAt!); // newest first
    });
    return clusters;
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Public helper: open the Add Subject sheet from anywhere (e.g. the
// hamburger drawer in teacher_home_screen.dart), not just from this screen.
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
// Shared "archive subject" action (admin only) — auto-archives its modules.
//
// This used to hard-delete the subject document. It now soft-deletes it
// (sets `archived: true`) so the subject and its cascade-archived modules
// can both be restored later from ArchivedSubjectsList, instead of being
// gone forever.
//
// This used to be a private method on _TeacherModulesScreenState, triggered
// by the "x" on a chip in _ClusterChipsRow. That chip row was removed from
// the Teacher/Admin Modules screen (subjects are already listed inside "Add
// Module", so showing them again up top was redundant/confusing per the
// client). Pulled out to a top-level function so it can be called from
// AddSubjectSheet's "Manage Subjects" list instead — the single place
// admins add AND remove subjects.
// ─────────────────────────────────────────────────────────────────────────────

Future<void> archiveSubject(BuildContext context, _Cluster cluster) async {
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Delete Subject',
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
      content: Text(
          'This will archive "${cluster.label}" (${cluster.code}) and automatically archive any modules under it. You can restore both later from Archived Subjects.'),
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
          child: const Text('Archive & Archive Modules'),
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
    batch.update(firestore.collection('subjects').doc(cluster.id), {
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
// Restore an archived subject (admin only) — un-archives the subject and
// every module currently archived under its code, putting both back in
// active use. Called from ArchivedSubjectsList below.
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
    batch.update(firestore.collection('subjects').doc(cluster.id), {
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
// Permanently delete an already-archived subject (admin only) — hard-deletes
// the subject document and every module under its code (archived or not,
// as a safety net). This cannot be undone. Called from
// ArchivedSubjectsList below.
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
    batch.delete(firestore.collection('subjects').doc(cluster.id));
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
//
// NOTE: the subject filter (originally a chip row, now a hamburger-menu
// filter — see _ClusterFilterBar below) that used to sit at the top of this
// screen has been intentionally removed. The client felt it was
// redundant/confusing here, since subjects are already shown and selectable
// inside the "Add Module" sheet. The filter bar is still used on the
// Student side (see StudentModulesScreen below), where it's the only way
// students can filter modules by subject.
//
// Archiving a subject now happens from the "Manage Subjects" list inside
// AddSubjectSheet (see archiveSubject() above and AddSubjectSheet below),
// not from this screen.
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
    // Separate subscription (outside the build-time StreamBuilder) purely to
    // detect subject changes and toast a notification for non-admin users.
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
          // "Add Subject" now lives in the hamburger drawer (admin only) —
          // see teacher_home_screen.dart's drawer, which calls
          // showAddSubjectSheet() from this file. Only "Add Module" stays
          // here as a FAB.
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
                onSaved: _onModuleSaved,
              ),
            ),
          ),
          // ── Module list ─────────────────────────────────────────────
          // No subject filter here anymore — this screen now always shows
          // every one of the teacher's own non-archived modules. Subject
          // selection still happens inside "Add Module".
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('modules')
                .where('uploadedBy', isEqualTo: _user?.uid)
                // Only show non-archived modules
                .where('archived', isEqualTo: false)
                .snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(
                    child: CircularProgressIndicator(
                        color: Color(0xFF1A237E)));
              }

              final docs = snapshot.data?.docs ?? [];

              // Manually sort by uploadedAt descending
              docs.sort((a, b) {
                final aTime =
                    (a.data() as Map<String, dynamic>)['uploadedAt']
                        as Timestamp?;
                final bTime =
                    (b.data() as Map<String, dynamic>)['uploadedAt']
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
// StudentModulesScreen
// ─────────────────────────────────────────────────────────────────────────────

class StudentModulesScreen extends StatefulWidget {
  const StudentModulesScreen({super.key});

  @override
  State<StudentModulesScreen> createState() => _StudentModulesScreenState();
}

class _StudentModulesScreenState extends State<StudentModulesScreen> {
  String _selectedCluster = 'All';

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<_Cluster>>(
      stream: _subjectsStream(),
      builder: (context, subjSnap) {
        final clusters = subjSnap.data ?? [];

        return Column(
          children: [
            // ── Subject filter (hamburger menu) ───────────────────────
            _ClusterFilterBar(
              clusters: clusters,
              selected: _selectedCluster,
              onSelect: (v) => setState(() => _selectedCluster = v),
            ),
            const Divider(height: 1),

            // ── Module list ───────────────────────────────────────────
            Expanded(
              child: StreamBuilder<QuerySnapshot>(
                stream: FirebaseFirestore.instance
                    .collection('modules')
                    .where('archived', isEqualTo: false)
                    .snapshots(),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      !snapshot.hasData) {
                    return const Center(
                        child: CircularProgressIndicator(
                            color: Color(0xFF1A237E)));
                  }

                  final allDocs = snapshot.data?.docs ?? [];
                  final docs = _selectedCluster == 'All'
                      ? allDocs
                      : allDocs.where((d) {
                          final data = d.data() as Map<String, dynamic>;
                          return (data['cluster'] as String? ?? '') ==
                              _selectedCluster;
                        }).toList();

                  if (allDocs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.folder_open_rounded,
                              size: 72, color: Colors.grey[300]),
                          const SizedBox(height: 14),
                          Text('No modules available yet.',
                              style: TextStyle(
                                  color: Colors.grey[500], fontSize: 15)),
                          const SizedBox(height: 6),
                          Text("Your teacher hasn't added any modules yet.",
                              style: TextStyle(
                                  color: Colors.grey[400], fontSize: 13)),
                        ],
                      ),
                    );
                  }

                  if (docs.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.folder_off_rounded,
                              size: 64, color: Colors.grey[300]),
                          const SizedBox(height: 12),
                          Text(
                            'No modules for $_selectedCluster yet.',
                            style: TextStyle(
                                color: Colors.grey[500], fontSize: 15),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.separated(
                    padding: const EdgeInsets.all(14),
                    itemCount: docs.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final data = docs[index].data() as Map<String, dynamic>;
                      return _ModuleCard(data: data, isTeacher: false);
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Subject Filter Bar (hamburger menu) — used by the Student screen only.
//
// FIX: previously this was a horizontally-scrolling row of subject chips
// (_ClusterChipsRow). Per the client, it's now a single hamburger (☰)
// button showing the current selection; tapping it opens a bottom sheet
// listing "All" plus every subject as a tappable row, with a checkmark on
// whichever one is currently selected. Filtering logic is unchanged — only
// the way the subject is picked changed.
// ─────────────────────────────────────────────────────────────────────────────

class _ClusterFilterBar extends StatelessWidget {
  final List<_Cluster> clusters;
  final String selected;
  final ValueChanged<String> onSelect;

  const _ClusterFilterBar({
    required this.clusters,
    required this.selected,
    required this.onSelect,
  });

  _Cluster? _selectedCluster() {
    if (selected == 'All') return null;
    for (final c in clusters) {
      if (c.code == selected) return c;
    }
    return null;
  }

  Future<void> _openMenu(BuildContext context) async {
    final result = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _SubjectMenuSheet(
        clusters: clusters,
        selected: selected,
      ),
    );
    if (result != null) onSelect(result);
  }

  @override
  Widget build(BuildContext context) {
    final activeCluster = _selectedCluster();
    final color = activeCluster?.color ?? const Color(0xFF1A237E);
    final icon = activeCluster?.icon ?? Icons.apps_rounded;
    final label = activeCluster != null ? activeCluster.code : 'All Subjects';

    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: InkWell(
        onTap: () => _openMenu(context),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withOpacity(0.3)),
          ),
          child: Row(
            children: [
              Icon(Icons.menu_rounded, size: 18, color: color),
              const SizedBox(width: 10),
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: color,
                  ),
                ),
              ),
              Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: color),
            ],
          ),
        ),
      ),
    );
  }
}

// The bottom sheet opened by the hamburger icon: "All" plus one row per
// subject, each tappable, with a checkmark on whichever is selected.
class _SubjectMenuSheet extends StatelessWidget {
  final List<_Cluster> clusters;
  final String selected;

  const _SubjectMenuSheet({required this.clusters, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7),
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
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
              const Icon(Icons.menu_rounded,
                  color: Color(0xFF1A237E), size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Filter by Subject',
                    style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A237E))),
              ),
              IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded,
                    color: Color(0xFF1A237E), size: 20),
                splashRadius: 20,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 32, minHeight: 32),
                tooltip: 'Close',
              ),
            ],
          ),
          const SizedBox(height: 10),
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  _SubjectMenuRow(
                    label: 'All Subjects',
                    icon: Icons.apps_rounded,
                    color: const Color(0xFF1A237E),
                    isSelected: selected == 'All',
                    onTap: () => Navigator.pop(context, 'All'),
                  ),
                  const SizedBox(height: 8),
                  if (clusters.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'No subjects yet.',
                        style:
                            TextStyle(color: Colors.grey[500], fontSize: 12),
                      ),
                    ),
                  for (final c in clusters) ...[
                    _SubjectMenuRow(
                      label: '${c.code} — ${c.label}',
                      icon: c.icon,
                      color: c.color,
                      isSelected: selected == c.code,
                      onTap: () => Navigator.pop(context, c.code),
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SubjectMenuRow extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  const _SubjectMenuRow({
    required this.label,
    required this.icon,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected ? color.withOpacity(0.1) : color.withOpacity(0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: isSelected ? color : color.withOpacity(0.2),
              width: isSelected ? 1.5 : 1),
        ),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color.withOpacity(0.12),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(icon, color: color, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ),
            if (isSelected)
              Icon(Icons.check_circle_rounded, color: color, size: 20),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared Module Card
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
  // Instructor who uploaded this module — looked up once from `users` via
  // the module's `uploadedBy` uid. Null while loading or if unavailable
  // (e.g. an older module saved before this lookup existed, or a missing
  // user doc), in which case the chip is simply omitted.
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
      // Silently skip — a missing/unreadable instructor name shouldn't
      // block the rest of the card from displaying.
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

  @override
  Widget build(BuildContext context) {
    final title = widget.data['title'] as String? ?? 'Untitled Module';
    final clusterCode = widget.data['cluster'] as String? ?? '';
    // clusterLabel is stored on the module itself at creation time, and
    // color/icon are derived from the code — so this card never needs to
    // look anything up in a separate subjects list.
    final clusterLabel = widget.data['clusterLabel'] as String? ?? clusterCode;
    final fileUrl = widget.data['fileUrl'] as String? ?? '';
    final hasCluster = clusterCode.isNotEmpty;
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
            color: const Color(0xFF1A237E).withOpacity(0.05),
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
                // ── Module icon ───────────────────────────────────
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: clusterColor.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: clusterColor.withOpacity(0.25)),
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
                            _chip(clusterIcon, clusterCode, color: clusterColor),
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
                // ── Archive button (teacher only) ────────────────
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
          // ── Preview / Read button ─────────────────────────────
          InkWell(
            onTap: fileUrl.isNotEmpty ? () => _open(context, fileUrl) : null,
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
        color: (color ?? const Color(0xFF3949AB)).withOpacity(0.1),
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
                  color: cluster.color.withOpacity(0.2),
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
                      color: cluster.color.withOpacity(0.1),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: cluster.color.withOpacity(0.35),
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
                    color: cluster.color.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border:
                        Border.all(color: cluster.color.withOpacity(0.3)),
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
// Add Subject Bottom Sheet (admin only)
//
// Public so it can be launched from anywhere via showAddSubjectSheet() above
// — e.g. the "Add Subject" item in the hamburger drawer in
// teacher_home_screen.dart, not just from this screen's own UI.
//
// Now doubles as "Manage Subjects": below the add form is a live list of
// every existing ACTIVE subject with a delete button, so admins have one
// place to both add and archive subjects (archiveSubject() auto-archives
// that subject's modules too — see above). Archived subjects (and their
// Restore / Delete Permanently actions) live in ArchivedSubjectsList,
// surfaced separately (e.g. inside the Archive tab of
// teacher_home_screen.dart).
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
      final existing = await FirebaseFirestore.instance
          .collection('subjects')
          .where('code', isEqualTo: code)
          .limit(1)
          .get();

      if (existing.docs.isNotEmpty) {
        _snack('A subject with code "$code" already exists.');
        return;
      }

      await FirebaseFirestore.instance.collection('subjects').add({
        'code': code,
        'label': label,
        'createdAt': FieldValue.serverTimestamp(),
        'archived': false,
      });

      // Clear the form instead of closing the sheet — admins can keep
      // adding subjects, and the Manage Subjects list below updates live
      // so they can see (and archive) what they just added without
      // reopening the sheet.
      _codeController.clear();
      _labelController.clear();
      if (mounted) _snack('Subject added.');
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
      // Cap the sheet's height so a long subject list still scrolls nicely
      // instead of pushing the add form off-screen.
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
                      'New subjects appear instantly on both the Admin and Instructor dashboards, and can be picked when adding a module.',
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
                      const Color(0xFF1A237E).withOpacity(0.7),
                  disabledForegroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            // ── Manage Subjects ──────────────────────────────────────
            const SizedBox(height: 28),
            const Divider(height: 1),
            const SizedBox(height: 18),
            Row(
              children: [
                const Icon(Icons.tune_rounded,
                    color: Color(0xFF1A237E), size: 18),
                const SizedBox(width: 8),
                const Text('Manage Subjects',
                    style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF1A237E))),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Archiving a subject also archives any modules under it. '
              'Find archived subjects (with Restore / Delete Permanently) '
              'in the Archive tab.',
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
            const SizedBox(height: 12),
            StreamBuilder<List<_Cluster>>(
              stream: _subjectsStream(),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 20),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Color(0xFF1A237E)),
                      ),
                    ),
                  );
                }

                final subjects = snap.data!;
                if (subjects.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      'No subjects yet — add one above.',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  );
                }

                return Column(
                  children: [
                    for (final subject in subjects) ...[
                      _ManageSubjectRow(
                        cluster: subject,
                        onDelete: () => archiveSubject(context, subject),
                      ),
                      const SizedBox(height: 8),
                    ],
                  ],
                );
              },
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
// A single row in the "Manage Subjects" list inside AddSubjectSheet.
// ─────────────────────────────────────────────────────────────────────────────

class _ManageSubjectRow extends StatelessWidget {
  final _Cluster cluster;
  final VoidCallback onDelete;

  const _ManageSubjectRow({required this.cluster, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cluster.color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: cluster.color.withOpacity(0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: cluster.color.withOpacity(0.12),
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
                      fontSize: 12, color: cluster.color.withOpacity(0.75)),
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: onDelete,
            child: Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.delete_outline_rounded,
                  size: 18, color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// ArchivedSubjectsList — public widget showing every archived subject with
// Restore and Delete Permanently actions. Drop this into any tab/screen —
// e.g. as a third sub-tab ("Subjects") alongside Reviews and Modules inside
// the Archive tab of teacher_home_screen.dart.
// ─────────────────────────────────────────────────────────────────────────────

class ArchivedSubjectsList extends StatelessWidget {
  const ArchivedSubjectsList({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<_Cluster>>(
      stream: _archivedSubjectsStream(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: Color(0xFFD84315)));
        }
        if (snap.hasError) {
          return Center(
            child: Text('Error: ${snap.error}',
                style: const TextStyle(color: Colors.red)),
          );
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
              onDeletePermanently: () =>
                  permanentlyDeleteSubject(context, cluster),
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
  final VoidCallback onDeletePermanently;

  const _ArchivedSubjectCard({
    super.key,
    required this.cluster,
    required this.onRestore,
    required this.onDeletePermanently,
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
            color: const Color(0xFFD84315).withOpacity(0.07),
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
                        color: const Color(0xFFBF360C).withOpacity(0.85))),
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
              const SizedBox(height: 4),
              _SmallActionButton(
                label: 'Delete',
                icon: Icons.delete_forever_rounded,
                color: Colors.red.shade600,
                onTap: onDeletePermanently,
              ),
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
            color: color.withOpacity(0.08),
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: color.withOpacity(0.25)),
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
// REVERTED: back to the original pasted-shareable-link flow instead of the
// direct Google Drive picker. The instructor types/pastes a link (Google
// Drive, Google Docs, or any other publicly viewable URL) and it's saved
// straight to Firestore as `fileUrl` — no `google_drive_service.dart`
// dependency, no in-app file picker, no `driveFileId`/`fileName` fields.
// ─────────────────────────────────────────────────────────────────────────────

class _UploadModuleSheet extends StatefulWidget {
  final String teacherUid;
  final List<_Cluster> clusters;
  final void Function(String title, _Cluster cluster) onSaved;

  const _UploadModuleSheet({
    required this.teacherUid,
    required this.clusters,
    required this.onSaved,
  });

  @override
  State<_UploadModuleSheet> createState() => _UploadModuleSheetState();
}

class _UploadModuleSheetState extends State<_UploadModuleSheet> {
  final _titleController = TextEditingController();
  final _linkController = TextEditingController();

  _Cluster? _selectedCluster;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _selectedCluster =
        widget.clusters.isNotEmpty ? widget.clusters.first : null;
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  Future<void> _save() async {
    final title = _titleController.text.trim();
    final link = _linkController.text.trim();

    if (_selectedCluster == null) {
      _snack('No subjects available yet. Ask an admin to add one first.');
      return;
    }
    if (title.isEmpty) {
      _snack('Please enter a module title.');
      return;
    }
    if (link.isEmpty) {
      _snack('Please paste a shareable link to the module file.');
      return;
    }

    final uri = Uri.tryParse(link);
    if (uri == null || !(uri.isScheme('HTTP') || uri.isScheme('HTTPS'))) {
      _snack('That doesn\'t look like a valid link. Please check and try again.');
      return;
    }

    setState(() => _saving = true);

    try {
      await FirebaseFirestore.instance.collection('modules').add({
        'title': title,
        'cluster': _selectedCluster!.code,
        'clusterLabel': _selectedCluster!.label,
        'fileUrl': link,
        'uploadedBy': widget.teacherUid,
        'uploadedAt': FieldValue.serverTimestamp(),
        'archived': false,
      });

      if (mounted) {
        final savedTitle = title;
        final savedCluster = _selectedCluster!;
        Navigator.pop(context);
        Future.delayed(const Duration(milliseconds: 300), () {
          widget.onSaved(savedTitle, savedCluster);
        });
      }
    } catch (e) {
      if (mounted) _snack('Failed to save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _linkController.dispose();
    super.dispose();
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
            // ── Handle bar ────────────────────────────────────────
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

            // ── Header row with close/back icon ─────────────────────
            Row(
              children: [
                const Icon(Icons.add_link_rounded,
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
                  constraints: const BoxConstraints(
                      minWidth: 32, minHeight: 32),
                  tooltip: 'Close',
                ),
              ],
            ),
            const SizedBox(height: 6),

            // ── Instruction banner ────────────────────────────────
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
                      'Upload your file to Google Drive (or another host), set sharing to "Anyone with the link can view," then paste that link below.',
                      style: TextStyle(
                          fontSize: 12, color: Color(0xFF1A237E)),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Module Title ──────────────────────────────────────
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

            // ── Subject Cluster ───────────────────────────────────
            const Text('Subject Cluster',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3949AB))),
            const SizedBox(height: 10),
            if (widget.clusters.isEmpty)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF3E0),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFFCC80)),
                ),
                child: const Text(
                  'No subjects exist yet. Ask an admin to add one first (via "Add Subject" in the menu).',
                  style: TextStyle(fontSize: 12, color: Color(0xFFE65100)),
                ),
              )
            else
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.clusters.map((c) {
                  final isSelected = _selectedCluster?.code == c.code;
                  return GestureDetector(
                    onTap: _saving
                        ? null
                        : () => setState(() => _selectedCluster = c),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color:
                            isSelected ? c.color : c.color.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? c.color
                              : c.color.withOpacity(0.3),
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
                                          : c.color.withOpacity(0.7))),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
              ),
            const SizedBox(height: 14),

            // ── Shareable link input ───────────────────────────────
            const Text('Module Link',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3949AB))),
            const SizedBox(height: 6),
            TextField(
              controller: _linkController,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: _inputDeco(
                  'Paste shareable link (Google Drive, Docs, etc.)',
                  Icons.link_rounded),
            ),
            const SizedBox(height: 24),

            // ── Save button ───────────────────────────────────────
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
                label: Text(_saving ? 'Saving…' : 'Save Module'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1A237E),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor:
                      const Color(0xFF1A237E).withOpacity(0.7),
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
            backgroundColor: widget.color.withOpacity(0.15),
            valueColor: AlwaysStoppedAnimation(widget.color),
          ),
        ),
      ),
    );
  }
}