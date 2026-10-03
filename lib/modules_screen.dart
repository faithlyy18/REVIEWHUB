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
// FILE TYPE: every module card shows a file-type badge (PPTX, DOCX, PDF …).
// New uploads save a `fileType` field (e.g. 'pptx'). Older modules that have no
// `fileType` are detected from their saved `fileName` (or the end of `fileUrl`),
// so they get a badge too. Anything unrecognised shows a neutral "FILE" badge.
//
// ADMIN / INSTRUCTOR SIDE: TeacherModulesScreen now navigates
//   Subject Category (CDI, CLJ …) -> Individual Uploaded Modules
// Modules are grouped AUTOMATICALLY by their `cluster` code (falling back to
// the first word of `subject`, e.g. "CDI 3" -> "CDI"). Uploading a new module
// never creates a new category by itself: it simply joins the existing group.
//
// STUDENT SIDE: StudentModulesScreen now navigates
//   Year Level -> Semester -> Subject -> Modules -> Read Module
//
// ALL subjects (including the 7 starters: CRIM, CLJ, CDI, FORENSIC, LEA, CA,
// ENG) can be edited and archived. Archived subjects stay in the Archived tab
// and are only deleted permanently when an admin chooses "Delete" there.
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

/// True when the curriculum subject [subjectCode] (e.g. "CDI 3") belongs to
/// the module cluster [clusterCode] (e.g. "CDI").
bool _subjectBelongsToCluster(String subjectCode, String clusterCode) {
  final s = subjectCode.trim().toUpperCase();
  final c = clusterCode.trim().toUpperCase();
  if (c.isEmpty) return false;
  return s.startsWith('$c ');
}

// ─────────────────────────────────────────────────────────────────────────────
// FILE TYPE helpers
//
// _extensionOf      : "Lecture 1.PPTX" -> "pptx" ('' when there is none)
// _fileTypeInfoFor  : the badge label / icon / color for a module document.
//                     Order of detection: `fileType` field -> `fileName`
//                     -> the last part of `fileUrl`.
// ─────────────────────────────────────────────────────────────────────────────

/// Lower-case extension of [name] without the dot, or '' when there is none.
String _extensionOf(String name) {
  var n = name.trim();
  // Ignore any query string / fragment (in case a URL is passed in).
  final cut = n.indexOf(RegExp(r'[?#]'));
  if (cut != -1) n = n.substring(0, cut);
  final slash = n.lastIndexOf('/');
  if (slash != -1) n = n.substring(slash + 1);
  final dot = n.lastIndexOf('.');
  if (dot == -1 || dot == n.length - 1) return '';
  return n.substring(dot + 1).toLowerCase();
}

class _FileTypeInfo {
  final String label;
  final IconData icon;
  final Color color;
  const _FileTypeInfo(this.label, this.icon, this.color);
}

const _FileTypeInfo _kUnknownFileType = _FileTypeInfo(
    'FILE', Icons.insert_drive_file_rounded, Color(0xFF607D8B));

_FileTypeInfo _fileTypeInfoFor(Map<String, dynamic> data) {
  var ext = (data['fileType'] as String? ?? '').trim().toLowerCase();
  if (ext.startsWith('.')) ext = ext.substring(1);
  if (ext.isEmpty) ext = _extensionOf(data['fileName'] as String? ?? '');
  if (ext.isEmpty) ext = _extensionOf(data['fileUrl'] as String? ?? '');

  switch (ext) {
    case 'pptx':
    case 'ppt':
      return _FileTypeInfo(
          ext.toUpperCase(), Icons.slideshow_rounded, const Color(0xFFE65100));
    case 'docx':
    case 'doc':
      return _FileTypeInfo(
          ext.toUpperCase(), Icons.description_rounded, const Color(0xFF1565C0));
    case 'pdf':
      return const _FileTypeInfo(
          'PDF', Icons.picture_as_pdf_rounded, Color(0xFFC62828));
    case 'xlsx':
    case 'xls':
      return _FileTypeInfo(
          ext.toUpperCase(), Icons.table_chart_rounded, const Color(0xFF2E7D32));
    case 'txt':
      return const _FileTypeInfo(
          'TXT', Icons.text_snippet_rounded, Color(0xFF607D8B));
    default:
      return _kUnknownFileType;
  }
}

/// Solid, clearly visible badge showing the module's file type.
Widget _fileTypeBadge(Map<String, dynamic> data) {
  final info = _fileTypeInfoFor(data);
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: info.color,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(info.icon, size: 11, color: Colors.white),
        const SizedBox(width: 4),
        Text(info.label,
            style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
                color: Colors.white)),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// STARTER MODULE SUBJECTS (fully editable)
//
// The 7 starting subject clusters. They are only a STARTING LIST: the first
// time the app runs, they are copied into Firestore (`moduleSubjects`) once
// (see _seedDefaultModuleSubjects). After that they are ordinary subjects —
// they can be edited (code / name), archived, restored, and permanently
// deleted by an admin, exactly like subjects added manually. They are never
// re-created once the seed marker exists.
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

/// Fixed creation time for the starter subject at [i], so they always sort
/// before subjects added later and keep their original order.
DateTime _seedTime(int i) => DateTime(2020, 1, 1).add(Duration(seconds: i));

/// Marker document stored in `moduleSubjects` once the starter subjects have
/// been copied to Firestore. It is not a subject and is always skipped.
const String _kSeedDocId = '_seeded_v1';

final List<_Cluster> _defaultClusters = [
  for (var i = 0; i < _kDefaultModuleSubjects.length; i++)
    _Cluster(
      id: 'default_${_kDefaultModuleSubjects[i][0]}',
      code: _kDefaultModuleSubjects[i][0],
      label: _kDefaultModuleSubjects[i][1],
      color: _colorForCode(_kDefaultModuleSubjects[i][0]),
      icon: _iconForCode(_kDefaultModuleSubjects[i][0]),
      createdAt: _seedTime(i),
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
    final stored = _storedClusters(snap);
    final seeded = snap.docs.any((d) => d.id == _kSeedDocId);
    final list = stored.where((c) => !c.isArchived).toList();

    // Until the starter subjects have been copied to Firestore (by a
    // teacher/admin screen), show them from the built-in list so students
    // never see an empty page. Once seeded, Firestore is the only source.
    if (!seeded) {
      final have = stored.map((c) => c.code.trim().toUpperCase()).toSet();
      list.addAll(_defaultClusters
          .where((c) => !have.contains(c.code.trim().toUpperCase())));
    }

    list.sort((a, b) {
      if (a.createdAt == null && b.createdAt == null) return 0;
      if (a.createdAt == null) return 1;
      if (b.createdAt == null) return -1;
      return a.createdAt!.compareTo(b.createdAt!);
    });
    return list;
  });
}

/// Every stored module subject (the seed marker and blank docs are skipped).
List<_Cluster> _storedClusters(QuerySnapshot<Map<String, dynamic>> snap) =>
    snap.docs
        .where((d) => d.id != _kSeedDocId)
        .map(_clusterFromDoc)
        .where((c) => c.code.trim().isNotEmpty)
        .toList();

/// Copies the 7 starter subjects into Firestore ONCE so they become normal,
/// editable and archivable subjects. A marker document records that this has
/// happened, so a subject that is later archived, edited or deleted is never
/// brought back. Safe to call repeatedly; failures are ignored.
Future<void> _seedDefaultModuleSubjects() async {
  try {
    final fs = FirebaseFirestore.instance;
    final col = fs.collection(_kModuleSubjectsCol);

    final marker = await col.doc(_kSeedDocId).get();
    if (marker.exists) return;

    final existing = await col.get();
    final have = existing.docs
        .map((d) => ((d.data()['code'] as String?) ?? '').trim().toUpperCase())
        .toSet();

    final batch = fs.batch();
    for (var i = 0; i < _kDefaultModuleSubjects.length; i++) {
      final code = _kDefaultModuleSubjects[i][0];
      if (have.contains(code.toUpperCase())) continue;
      batch.set(col.doc('default_$code'), {
        'code': code,
        'label': _kDefaultModuleSubjects[i][1],
        'createdAt': Timestamp.fromDate(_seedTime(i)),
        'archived': false,
      });
    }
    batch.set(col.doc(_kSeedDocId), {
      'seededAt': FieldValue.serverTimestamp(),
    });
    await batch.commit();
  } catch (_) {
    // Non-fatal: the built-in fallback keeps the subjects visible.
  }
}

/// Live stream of every ARCHIVED module subject, newest archived first.
Stream<List<_Cluster>> _archivedSubjectsStream() {
  return FirebaseFirestore.instance
      .collection(_kModuleSubjectsCol)
      .snapshots()
      .map((snap) {
    final clusters = _storedClusters(snap).where((c) => c.isArchived).toList();
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
    batch.set(
        firestore.collection(_kModuleSubjectsCol).doc(cluster.id),
        {
          'code': cluster.code,
          'label': cluster.label,
          'archived': true,
          'archivedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true));
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
// Edit a module subject (code and/or name).
//
// Modules point to their subject through `cluster` (the code) and
// `clusterLabel` (the name), so when either changes, every module under this
// subject (active AND archived) is updated in the same operation. Nothing is
// orphaned and no module is lost.
// ─────────────────────────────────────────────────────────────────────────────

Future<void> editSubject(BuildContext context, _Cluster cluster) async {
  final res = await showDialog<List<String>>(
    context: context,
    builder: (_) => _EditSubjectDialog(cluster: cluster),
  );
  if (res == null) return;

  final newCode = res[0];
  final newLabel = res[1];
  if (newCode == cluster.code && newLabel == cluster.label) return;

  void snack(String msg) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  try {
    final fs = FirebaseFirestore.instance;
    final col = fs.collection(_kModuleSubjectsCol);

    // The new code must not already belong to another subject
    // (active or archived).
    if (newCode.toUpperCase() != cluster.code.trim().toUpperCase()) {
      final dup = await col.where('code', isEqualTo: newCode).get();
      final taken =
          dup.docs.any((d) => d.id != cluster.id && d.id != _kSeedDocId);
      if (taken) {
        snack('A subject with code "$newCode" already exists '
            '(check the Archived tab too).');
        return;
      }
    }

    final modulesSnap = await fs
        .collection('modules')
        .where('cluster', isEqualTo: cluster.code)
        .get();

    var batch = fs.batch();
    var n = 0;
    batch.set(
        col.doc(cluster.id),
        {'code': newCode, 'label': newLabel},
        SetOptions(merge: true));
    n++;
    for (final doc in modulesSnap.docs) {
      batch.update(doc.reference, {
        'cluster': newCode,
        'clusterLabel': newLabel,
      });
      n++;
      if (n >= 400) {
        await batch.commit();
        batch = fs.batch();
        n = 0;
      }
    }
    if (n > 0) await batch.commit();

    snack('Subject updated. ${modulesSnap.docs.length} module(s) updated.');
  } catch (e) {
    snack('Failed to update subject: $e');
  }
}

class _EditSubjectDialog extends StatefulWidget {
  final _Cluster cluster;
  const _EditSubjectDialog({required this.cluster});

  @override
  State<_EditSubjectDialog> createState() => _EditSubjectDialogState();
}

class _EditSubjectDialogState extends State<_EditSubjectDialog> {
  late final TextEditingController _code =
      TextEditingController(text: widget.cluster.code);
  late final TextEditingController _label =
      TextEditingController(text: widget.cluster.label);
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    _label.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _code.text.trim().toUpperCase();
    final label = _label.text.trim();
    if (code.isEmpty) {
      setState(() => _error = 'Please enter a subject code.');
      return;
    }
    if (code.contains(RegExp(r'\s'))) {
      setState(() => _error = 'The code cannot contain spaces (e.g. CRIM).');
      return;
    }
    if (label.isEmpty) {
      setState(() => _error = 'Please enter the subject name.');
      return;
    }
    Navigator.pop(context, [code, label]);
  }

  InputDecoration _deco(String hint, IconData icon) => InputDecoration(
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Edit Subject',
          style: TextStyle(
              color: Color(0xFF1A237E), fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Subject Code',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3949AB))),
            const SizedBox(height: 6),
            TextField(
              controller: _code,
              textCapitalization: TextCapitalization.characters,
              decoration: _deco('e.g. CRIM', Icons.label_rounded),
            ),
            const SizedBox(height: 14),
            const Text('Subject Name',
                style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3949AB))),
            const SizedBox(height: 6),
            TextField(
              controller: _label,
              decoration:
                  _deco('e.g. Criminology', Icons.menu_book_rounded),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFFE8EAF6),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'Modules already uploaded under this subject are updated '
                'automatically. Curriculum subjects (e.g. "CDI 3") are '
                'matched to a subject by the code at the start of their '
                'name, so keep the code in step with the curriculum.',
                style: TextStyle(fontSize: 11, color: Color(0xFF1A237E)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(fontSize: 12, color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF1A237E),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8))),
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TeacherModulesScreen (shared by Instructor + Admin accountTypes)
//
// Flow:  Subject categories (CDI, CLJ, CRIM …)  ->  that subject's modules
//
//   • Categories are built automatically from each module's `cluster` code
//     (fallback: first word of its `subject`, e.g. "CDI 3" -> "CDI").
//   • Only categories that currently have modules are listed, each with its
//     module count. A new upload joins its existing category automatically.
//   • Inside a category the modules are sorted numerically
//     (CDI 1 -> CDI 2 -> … -> CDI 10), then by title.
//   • Every module card keeps Preview Module + Archive.
// ─────────────────────────────────────────────────────────────────────────────

class TeacherModulesScreen extends StatefulWidget {
  const TeacherModulesScreen({super.key});

  @override
  State<TeacherModulesScreen> createState() => _TeacherModulesScreenState();
}

class _TeacherModulesScreenState extends State<TeacherModulesScreen> {
  static const _navy = Color(0xFF1A237E);

  final _user = FirebaseAuth.instance.currentUser;
  bool _isAdmin = false;

  StreamSubscription<List<_Cluster>>? _subjectsSub;
  List<String>? _prevCodes;

  late final Stream<List<_Cluster>> _clustersStream = _subjectsStream();
  late final Stream<QuerySnapshot> _modulesStream = FirebaseFirestore.instance
      .collection('modules')
      .where('uploadedBy', isEqualTo: _user?.uid)
      .where('archived', isEqualTo: false)
      .snapshots();

  /// The subject category currently opened (e.g. 'CDI'), or null when the
  /// category list is showing.
  String? _categoryCode;

  @override
  void initState() {
    super.initState();
    _loadAccountType();
    _seedDefaultModuleSubjects();
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

  // ── Automatic grouping helpers ──────────────────────────────────────────

  /// The category a module belongs to, decided automatically:
  ///   1. its `cluster` code (e.g. 'CDI'), else
  ///   2. the first word of its `subject` (e.g. 'CDI 3' -> 'CDI'), else
  ///   3. 'OTHER' for old modules that have neither.
  /// Always upper-cased/trimmed, so "cdi" and "CDI " never split a category.
  static String _groupCode(Map<String, dynamic> m) {
    final cluster = (m['cluster'] as String? ?? '').trim().toUpperCase();
    if (cluster.isNotEmpty) return cluster;
    final subject = (m['subject'] as String? ?? '').trim().toUpperCase();
    if (subject.isNotEmpty) return subject.split(RegExp(r'\s+')).first;
    return 'OTHER';
  }

  /// First whole number inside [s] ("CDI 10" -> 10). Text without a number
  /// returns a huge value so it sorts after the numbered ones.
  static int _firstNumber(String s) {
    final m = RegExp(r'\d+').firstMatch(s);
    if (m == null) return 1 << 30;
    return int.tryParse(m.group(0)!) ?? (1 << 30);
  }

  /// CDI 1 -> CDI 2 -> … -> CDI 10 (numeric, not text order), then by the
  /// number in the title, then A–Z.
  static int _compareModules(Map<String, dynamic> a, Map<String, dynamic> b) {
    final subjA = (a['subject'] as String? ?? '').trim();
    final subjB = (b['subject'] as String? ?? '').trim();
    final n = _firstNumber(subjA).compareTo(_firstNumber(subjB));
    if (n != 0) return n;

    final titleA = (a['title'] as String? ?? '').trim();
    final titleB = (b['title'] as String? ?? '').trim();
    final t = _firstNumber(titleA).compareTo(_firstNumber(titleB));
    if (t != 0) return t;

    return titleA.toLowerCase().compareTo(titleB.toLowerCase());
  }

  /// Full name of a category, e.g. 'Criminal Detection and Investigation'.
  String _labelFor(String code, List<_Cluster> clusters,
      List<QueryDocumentSnapshot> items) {
    for (final c in clusters) {
      if (c.code.trim().toUpperCase() == code) return c.label;
    }
    for (final d in items) {
      final label =
          ((d.data() as Map<String, dynamic>)['clusterLabel'] as String? ?? '')
              .trim();
      if (label.isNotEmpty) return label;
    }
    return code == 'OTHER' ? 'Uncategorized' : code;
  }

  /// Default subjects first (CRIM, CLJ, CDI …), then subjects added later,
  /// then anything unknown A–Z.
  List<String> _sortedCodes(
      Iterable<String> codes, List<_Cluster> clusters) {
    final order = <String, int>{
      for (var i = 0; i < clusters.length; i++)
        clusters[i].code.trim().toUpperCase(): i,
    };
    final list = codes.toList();
    list.sort((a, b) {
      final ia = order[a] ?? clusters.length;
      final ib = order[b] ?? clusters.length;
      if (ia != ib) return ia.compareTo(ib);
      return a.compareTo(b);
    });
    return list;
  }

  String _countLabel(int n) => '$n ${n == 1 ? 'Module' : 'Modules'}';

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // While a category is open, the system Back returns to the category
      // list instead of leaving the screen.
      canPop: _categoryCode == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _categoryCode = null);
      },
      child: StreamBuilder<List<_Cluster>>(
        stream: _clustersStream,
        builder: (context, subjSnap) {
          final clusters = subjSnap.data ?? [];

          return Scaffold(
            backgroundColor: const Color(0xFFF4F6FB),
            floatingActionButton: FloatingActionButton.extended(
              heroTag: 'addModule',
              backgroundColor: _navy,
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
              stream: _modulesStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting &&
                    !snapshot.hasData) {
                  return const Center(
                      child: CircularProgressIndicator(color: _navy));
                }

                final docs = snapshot.data?.docs ?? [];

                if (docs.isEmpty) {
                  _resetCategoryIfGone(const {});
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

                // ── Group every active module by its subject category ───
                final groups = <String, List<QueryDocumentSnapshot>>{};
                for (final d in docs) {
                  final m = d.data() as Map<String, dynamic>;
                  groups.putIfAbsent(_groupCode(m), () => []).add(d);
                }
                _resetCategoryIfGone(groups);

                final open = _categoryCode;
                if (open != null && groups.containsKey(open)) {
                  return _buildCategoryPage(
                      open, groups[open]!, clusters);
                }
                return _buildCategoryList(groups, clusters);
              },
            ),
          );
        },
      ),
    );
  }

  /// If the opened category no longer has any active module (for example its
  /// last module was just archived), go back to the category list.
  void _resetCategoryIfGone(Map<String, List<QueryDocumentSnapshot>> groups) {
    final open = _categoryCode;
    if (open != null && !groups.containsKey(open)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _categoryCode == open) {
          setState(() => _categoryCode = null);
        }
      });
    }
  }

  // ── Page 1: subject categories ──────────────────────────────────────────

  Widget _buildCategoryList(Map<String, List<QueryDocumentSnapshot>> groups,
      List<_Cluster> clusters) {
    final codes = _sortedCodes(groups.keys, clusters);

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
      itemCount: codes.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final code = codes[index];
        final items = groups[code]!;
        final label = _labelFor(code, clusters, items);
        return _NavCard(
          icon: _iconForCode(code),
          color: _colorForCode(code),
          title: label == code ? code : '$code — $label',
          subtitle: _countLabel(items.length),
          onTap: () => setState(() => _categoryCode = code),
        );
      },
    );
  }

  // ── Page 2: the modules inside one category ─────────────────────────────

  Widget _buildCategoryPage(String code, List<QueryDocumentSnapshot> items,
      List<_Cluster> clusters) {
    final color = _colorForCode(code);
    final label = _labelFor(code, clusters, items);

    final sorted = [...items]..sort((a, b) => _compareModules(
        a.data() as Map<String, dynamic>, b.data() as Map<String, dynamic>));

    return Column(
      children: [
        // Header with a clear Back button
        Container(
          color: Colors.white,
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextButton.icon(
                onPressed: () => setState(() => _categoryCode = null),
                icon: const Icon(Icons.arrow_back_rounded, size: 18),
                label: const Text('Back'),
                style: TextButton.styleFrom(
                  foregroundColor: _navy,
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              const SizedBox(height: 4),
              Text(code,
                  style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: color)),
              if (label != code)
                Text(label,
                    style: TextStyle(fontSize: 13, color: Colors.grey[700])),
              const SizedBox(height: 4),
              Text(_countLabel(sorted.length),
                  style: TextStyle(fontSize: 12, color: Colors.grey[600])),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 100),
            itemCount: sorted.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, index) {
              final doc = sorted[index];
              final data = doc.data() as Map<String, dynamic>;
              final subjectCode = (data['subject'] as String? ?? '').trim();

              return Column(
                key: ValueKey(doc.id),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (subjectCode.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.bookmark_rounded,
                                size: 11, color: color),
                            const SizedBox(width: 4),
                            Text(subjectCode,
                                style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: color)),
                          ],
                        ),
                      ),
                    ),
                  _ModuleCard(
                    data: data,
                    isTeacher: true,
                    onArchive: () => _archiveModule(doc.id),
                  ),
                ],
              );
            },
          ),
        ),
      ],
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
    _prepare();
  }

  Future<void> _prepare() async {
    await _seedDefaultModuleSubjects();
    if (widget.isAdmin) await _migrateOldClusters();
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
                                  'Every subject can be edited (code / name) or '
                                  'archived, for example when the curriculum '
                                  'changes. Archiving also archives its modules. '
                                  'Archived subjects stay in the Archived tab and '
                                  'can be restored; they are only deleted forever '
                                  'if an admin chooses Delete there.',
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
                            onEdit: () => editSubject(context, s),
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
// StudentModulesScreen  (REDESIGNED v2)
//
// Flow: Subject category (CLJ, CDI, CRIM …) -> modules grouped by
//       Year Level + Semester -> Read Module
//
// Data mapping (uses existing fields, no Firestore changes):
//   Category          = module.cluster            (e.g. 'CLJ')
//   Year / Semester   = looked up from the module's curriculum subject
//                       (module.subject, e.g. 'CLJ 6' -> 4th Year, 1st Sem)
//
// Cleanup rules:
//   • Modules with no curriculum `subject` are hidden (no year/semester).
//   • Placeholder titles like "CLJ(0)" or "()" are hidden.
//   • Duplicates (same subject + same title) are shown once.
//   • Inside each Year/Semester group, modules are ordered by curriculum
//     subject, then by the first number in the title, then A–Z.
// ─────────────────────────────────────────────────────────────────────────────

class _ModEntry {
  final Map<String, dynamic> data;
  final Subject subject;
  final String cluster;
  const _ModEntry(this.data, this.subject, this.cluster);

  String get title => (data['title'] as String? ?? '').trim();
}

class StudentModulesScreen extends StatefulWidget {
  /// Kept so existing callers still compile. No longer used.
  final String? studentYear;
  const StudentModulesScreen({super.key, this.studentYear});

  @override
  State<StudentModulesScreen> createState() => _StudentModulesScreenState();
}

class _StudentModulesScreenState extends State<StudentModulesScreen> {
  static const _navy = Color(0xFF1A237E);

  late final Stream<List<_Cluster>> _clustersStream = _subjectsStream();
  late final Stream<List<Subject>> _curriculumStream =
      CurriculumRepo.streamAll();
  late final Stream<QuerySnapshot> _modulesStream = FirebaseFirestore.instance
      .collection('modules')
      .where('archived', isEqualTo: false)
      .snapshots();

  String? _categoryCode;

  // ── Data cleanup ──────────────────────────────────────────────────────────

  static bool _invalidTitle(String t) =>
      t.isEmpty || RegExp(r'^[A-Za-z ]*\(\s*\d*\s*\)$').hasMatch(t);

  static int _numIn(String t) {
    final m = RegExp(r'\d+').firstMatch(t);
    return m == null ? 9999 : int.parse(m.group(0)!);
  }

  List<_ModEntry> _clean(
      List<QueryDocumentSnapshot> docs, Map<String, Subject> subjByCode) {
    final seen = <String>{};
    final out = <_ModEntry>[];
    for (final d in docs) {
      final m = d.data() as Map<String, dynamic>;
      final code = (m['subject'] as String? ?? '').trim().toLowerCase();
      final title = (m['title'] as String? ?? '').trim();
      final subject = subjByCode[code];
      if (subject == null || _invalidTitle(title)) continue;
      final key = '$code|${title.toLowerCase().replaceAll(RegExp(r'\s+'), '')}';
      if (!seen.add(key)) continue;
      var cluster = (m['cluster'] as String? ?? '').trim().toUpperCase();
      if (cluster.isEmpty) {
        cluster = subject.code.trim().split(' ').first.toUpperCase();
      }
      out.add(_ModEntry(m, subject, cluster));
    }
    return out;
  }

  static int _cmp(_ModEntry a, _ModEntry b) {
    final y = CurriculumRepo.yearLevels
        .indexOf(a.subject.yearLevel)
        .compareTo(CurriculumRepo.yearLevels.indexOf(b.subject.yearLevel));
    if (y != 0) return y;
    final s = CurriculumRepo.semesters
        .indexOf(a.subject.semester)
        .compareTo(CurriculumRepo.semesters.indexOf(b.subject.semester));
    if (s != 0) return s;
    final o = a.subject.order.compareTo(b.subject.order);
    if (o != 0) return o;
    final c = a.subject.code.compareTo(b.subject.code);
    if (c != 0) return c;
    final n = _numIn(a.title).compareTo(_numIn(b.title));
    return n != 0 ? n : a.title.toLowerCase().compareTo(b.title.toLowerCase());
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _categoryCode == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(() => _categoryCode = null);
      },
      child: StreamBuilder<List<_Cluster>>(
        stream: _clustersStream,
        builder: (context, clusterSnap) => StreamBuilder<List<Subject>>(
          stream: _curriculumStream,
          builder: (context, subjSnap) => StreamBuilder<QuerySnapshot>(
            stream: _modulesStream,
            builder: (context, modSnap) {
              if (!clusterSnap.hasData ||
                  !subjSnap.hasData ||
                  !modSnap.hasData) {
                return const Center(
                    child: CircularProgressIndicator(color: _navy));
              }
              final clusters = clusterSnap.data!;
              final subjByCode = {
                for (final s in subjSnap.data!) s.code.trim().toLowerCase(): s
              };
              final entries = _clean(modSnap.data!.docs, subjByCode);

              _Cluster? selected;
              for (final c in clusters) {
                if (c.code.toUpperCase() == _categoryCode) selected = c;
              }
              final inCategory = selected == null
                  ? <_ModEntry>[]
                  : (entries
                      .where((e) => e.cluster == selected!.code.toUpperCase())
                      .toList()
                    ..sort(_cmp));

              return Column(
                children: [
                  _header(selected, inCategory.length),
                  const Divider(height: 1),
                  Expanded(
                    child: selected == null
                        ? _categories(clusters, entries)
                        : _moduleGroups(inCategory),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ── Header ────────────────────────────────────────────────────────────────

  Widget _header(_Cluster? selected, int count) {
    return Container(
      color: Colors.white,
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selected == null) ...[
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text('Modules',
                  style: TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold, color: _navy)),
            ),
            const SizedBox(height: 6),
            Text('Select a subject category',
                style: TextStyle(fontSize: 13, color: Colors.grey[600])),
          ] else ...[
            TextButton.icon(
              onPressed: () => setState(() => _categoryCode = null),
              icon: const Icon(Icons.arrow_back_rounded, size: 18),
              label: const Text('Back'),
              style: TextButton.styleFrom(
                foregroundColor: _navy,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
            const SizedBox(height: 4),
            Text(selected.code,
                style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: selected.color)),
            Text(selected.label,
                style: TextStyle(fontSize: 13, color: Colors.grey[700])),
            const SizedBox(height: 4),
            Text('$count ${count == 1 ? 'Module' : 'Modules'}',
                style: TextStyle(fontSize: 12, color: Colors.grey[600])),
          ],
        ],
      ),
    );
  }

  // ── Main page: subject categories ─────────────────────────────────────────

  Widget _categories(List<_Cluster> clusters, List<_ModEntry> entries) {
    if (clusters.isEmpty) {
      return _empty(Icons.folder_open_rounded, 'No subjects available yet.');
    }
    return ListView.separated(
      padding: const EdgeInsets.all(14),
      itemCount: clusters.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (_, i) {
        final c = clusters[i];
        final n = entries.where((e) => e.cluster == c.code.toUpperCase()).length;
        return _NavCard(
          icon: c.icon,
          color: c.color,
          title: '${c.code} — ${c.label}',
          subtitle: '$n ${n == 1 ? 'Module' : 'Modules'}',
          onTap: () => setState(() => _categoryCode = c.code.toUpperCase()),
        );
      },
    );
  }

  // ── Category page: modules grouped by Year Level + Semester ──────────────

  Widget _moduleGroups(List<_ModEntry> list) {
    if (list.isEmpty) {
      return _empty(Icons.folder_open_rounded,
          'No modules uploaded for this subject yet.');
    }

    String groupOf(_ModEntry e) =>
        '${e.subject.yearLevel} • ${e.subject.semester}';
    final counts = <String, int>{};
    for (final e in list) {
      counts[groupOf(e)] = (counts[groupOf(e)] ?? 0) + 1;
    }

    final children = <Widget>[];
    String? current;
    for (final e in list) {
      final g = groupOf(e);
      if (g != current) {
        current = g;
        children.add(_groupHeader(g, counts[g]!));
      }
      children.add(Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 2, bottom: 6),
              child: Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  _pill(Icons.school_rounded, e.subject.yearLevel),
                  _pill(Icons.calendar_month_rounded, e.subject.semester),
                  _pill(Icons.bookmark_rounded, e.subject.code),
                ],
              ),
            ),
            _ModuleCard(data: e.data, isTeacher: false), // Read Module kept
          ],
        ),
      ));
    }

    return ListView(
      padding: const EdgeInsets.all(14),
      children: children,
    );
  }

  Widget _groupHeader(String label, int count) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: _navy.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: _navy.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.school_rounded, size: 16, color: _navy),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: _navy)),
              ),
              Text('$count ${count == 1 ? 'Module' : 'Modules'}',
                  style: TextStyle(fontSize: 11, color: Colors.grey[700])),
            ],
          ),
        ),
      );

  Widget _pill(IconData icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _navy.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: _navy),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _navy)),
          ],
        ),
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

/// One tappable row used for the subject categories.
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
// StudentSubjectModulesScreen
//
// Opened when a student taps a subject in the Subjects (curriculum) tab.
// Matches modules by the curriculum subject code (module.subject == code),
// so "CDI 1" only ever shows CDI 1 modules.
//   • Has modules  -> Year/Semester header + pills + the usual module cards
//                     (Read Module and the confirmation dialog unchanged).
//   • No modules   -> "This subject has no module yet."
//   • Back button  -> returns to the Subjects tab.
// ─────────────────────────────────────────────────────────────────────────────

class StudentSubjectModulesScreen extends StatefulWidget {
  final Subject subject;
  const StudentSubjectModulesScreen({super.key, required this.subject});

  @override
  State<StudentSubjectModulesScreen> createState() =>
      _StudentSubjectModulesScreenState();
}

class _StudentSubjectModulesScreenState
    extends State<StudentSubjectModulesScreen> {
  static const _navy = Color(0xFF1A237E);

  late final Stream<QuerySnapshot> _stream = FirebaseFirestore.instance
      .collection('modules')
      .where('archived', isEqualTo: false)
      .snapshots();

  /// Modules of this subject only: placeholder titles removed, duplicates
  /// merged, ordered by the first number in the title, then A–Z.
  List<Map<String, dynamic>> _mine(List<QueryDocumentSnapshot> docs) {
    final code = widget.subject.code.trim().toLowerCase();
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final d in docs) {
      final m = d.data() as Map<String, dynamic>;
      if ((m['subject'] as String? ?? '').trim().toLowerCase() != code) {
        continue;
      }
      final title = (m['title'] as String? ?? '').trim();
      if (_StudentModulesScreenState._invalidTitle(title)) continue;
      final key = title.toLowerCase().replaceAll(RegExp(r'\s+'), '');
      if (!seen.add(key)) continue;
      out.add(m);
    }
    out.sort((a, b) {
      final ta = (a['title'] as String? ?? '').trim();
      final tb = (b['title'] as String? ?? '').trim();
      final n = _StudentModulesScreenState._numIn(ta)
          .compareTo(_StudentModulesScreenState._numIn(tb));
      return n != 0 ? n : ta.toLowerCase().compareTo(tb.toLowerCase());
    });
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.subject;
    final color = _colorForCode(s.code.trim().split(' ').first.toUpperCase());

    return Scaffold(
      backgroundColor: const Color(0xFF283593),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Container(
              margin: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  // Header with Back button
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TextButton.icon(
                          onPressed: () => Navigator.pop(context),
                          icon: const Icon(Icons.arrow_back_rounded, size: 18),
                          label: const Text('Back'),
                          style: TextButton.styleFrom(
                            foregroundColor: _navy,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            minimumSize: const Size(0, 32),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(s.code,
                            style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: color)),
                        Text(s.description,
                            style: TextStyle(
                                fontSize: 13, color: Colors.grey[700])),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: StreamBuilder<QuerySnapshot>(
                      stream: _stream,
                      builder: (context, snap) {
                        if (!snap.hasData) {
                          return const Center(
                              child: CircularProgressIndicator(color: _navy));
                        }
                        final mods = _mine(snap.data!.docs);
                        if (mods.isEmpty) return _noModules();
                        return _list(mods);
                      },
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

  Widget _noModules() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.folder_off_rounded, size: 64, color: Colors.grey[300]),
              const SizedBox(height: 12),
              Text('This subject has no module yet.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey[600], fontSize: 15)),
            ],
          ),
        ),
      );

  Widget _list(List<Map<String, dynamic>> mods) {
    final s = widget.subject;
    final n = mods.length;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        // Year Level • Semester group header (same look as the category page)
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 6, 2, 10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            decoration: BoxDecoration(
              color: _navy.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _navy.withValues(alpha: 0.25)),
            ),
            child: Row(
              children: [
                const Icon(Icons.school_rounded, size: 16, color: _navy),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('${s.yearLevel} • ${s.semester}',
                      style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: _navy)),
                ),
                Text('$n ${n == 1 ? 'Module' : 'Modules'}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700])),
              ],
            ),
          ),
        ),
        for (final m in mods)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(left: 2, bottom: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _pill(Icons.school_rounded, s.yearLevel),
                      _pill(Icons.calendar_month_rounded, s.semester),
                      _pill(Icons.bookmark_rounded, s.code),
                    ],
                  ),
                ),
                _ModuleCard(data: m, isTeacher: false), // Read Module kept
              ],
            ),
          ),
      ],
    );
  }

  Widget _pill(IconData icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: _navy.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 11, color: _navy),
            const SizedBox(width: 4),
            Text(label,
                style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: _navy)),
          ],
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared Module Card
//
// Shows the module's file-type badge (PPTX / DOCX / PDF …), its subject group
// (e.g. CDI) and, when set, its curriculum subject (e.g. CDI 3). For STUDENTS,
// tapping "Read Module" first shows a confirmation dialog saying which subject
// the module belongs to; the module only opens after the student taps "Open
// Module". Teachers preview directly.
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

  /// A module is "NEW" for 30 days after it was uploaded. The badge hides
  /// itself automatically once that time has passed.
  /// A null `uploadedAt` that is present on the document means the upload is
  /// still being written to the server, so it counts as brand new.
  bool get _isNew {
    if (!widget.data.containsKey('uploadedAt')) return false;
    final raw = widget.data['uploadedAt'];
    if (raw == null) return true;
    if (raw is! Timestamp) return false;
    final age = DateTime.now().difference(raw.toDate());
    return age < const Duration(days: 30);
  }

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
                    const SizedBox(height: 10),
                    Text('File type',
                        style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey[600])),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _fileTypeBadge(widget.data),
                    ),
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
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Flexible(
                            child: Text(title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 15,
                                  color: Color(0xFF1A237E),
                                )),
                          ),
                          if (_isNew) ...[
                            const SizedBox(width: 8),
                            Container(
                              margin: const EdgeInsets.only(top: 2),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 2),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE53935),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: const Text('NEW',
                                  style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white)),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      // The file-type badge is ALWAYS shown (even for old
                      // modules that have no subject info).
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _fileTypeBadge(widget.data),
                          if (hasCluster) ...[
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
  final VoidCallback onEdit;
  final VoidCallback onArchive;

  const _ManageSubjectRow({
    required this.cluster,
    required this.onEdit,
    required this.onArchive,
  });

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
          Tooltip(
            message: 'Edit',
            child: GestureDetector(
              onTap: onEdit,
              child: Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A237E).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.edit_outlined,
                    size: 18, color: Color(0xFF1A237E)),
              ),
            ),
          ),
          const SizedBox(width: 6),
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
//
// The chosen group is saved as `cluster`, which is exactly what the Modules
// page groups by — so a new CDI upload lands in the existing CDI category.
//
// The chosen file's extension is saved as `fileType` (e.g. 'pptx') and drives
// the file-type badge on the module cards.
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

      // File type (e.g. 'pptx', 'docx', 'pdf'): from the picked file's own
      // name first, then from the name Drive saved it under.
      var fileType = _extensionOf(_deviceFile!.name);
      if (fileType.isEmpty) fileType = _extensionOf(result.fileName);

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
        'fileType': fileType,
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
              // Shows the detected file type right after a file is chosen.
              if (_deviceFile != null) ...[
                const SizedBox(width: 8),
                _fileTypeBadge({'fileName': _deviceFile!.name}),
              ],
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