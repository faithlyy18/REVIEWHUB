import 'package:cloud_firestore/cloud_firestore.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Subject model
// ─────────────────────────────────────────────────────────────────────────────
//
// Firestore collection: 'subjects'
// Each document = one subject, with fields:
//   code        (e.g. 'CRIM 1', 'ENG 1')
//   description (e.g. 'Introduction to Criminology')
//   yearLevel   (e.g. '1st Year')
//   semester    ('1st Semester' | '2nd Semester')
//   order       (int, keeps subjects in a stable order within their
//                year/semester)
//   archived    (bool, default false — archived subjects are hidden from
//                every picker/viewer but can be restored by an admin)
//   archivedAt  (server timestamp, only present while archived)
//   isCore      (bool — true ONLY for the built-in BS Criminology subjects
//                listed in _seedCurriculum. Core subjects can NEVER be
//                edited, archived or deleted.)
//
// "Core" is decided ONLY by the built-in list (_seedCurriculum). The isCore
// flag stored in Firestore is NOT trusted on its own, so old documents that
// were flagged core by an earlier version (e.g. ENG 1–4) become ordinary,
// fully editable subjects.
//
// ENGLISH (and every other module subject group) IS NOT HARD-CODED.
//   A curriculum subject belongs to a module subject group when its code
//   starts with the group code followed by a space: "CRIM 1" -> CRIM,
//   "ENG 2" -> ENG. That is the ONLY link. English subjects are therefore
//   plain admin-managed data: add / edit / archive / delete them in
//   Manage Curriculum (e.g. ENG 1, ENG 2 … ENG 12 — any number, any year,
//   any semester) and the Add Module dropdown updates live.
// ─────────────────────────────────────────────────────────────────────────────

class Subject {
  final String id; // Firestore document id
  final String code;
  final String description;
  final String yearLevel;
  final String semester;
  final int order;
  final bool archived;

  /// True for the built-in BS Criminology curriculum (protected).
  final bool isCore;

  const Subject({
    required this.id,
    required this.code,
    required this.description,
    required this.yearLevel,
    required this.semester,
    this.order = 0,
    this.archived = false,
    this.isCore = false,
  });

  factory Subject.fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data() ?? {};
    final code = (data['code'] as String?) ?? '';
    // Core is decided ONLY by the built-in list; the stored isCore flag is
    // ignored so stale flags (e.g. on old ENG docs) cannot lock a subject.
    final core = CurriculumRepo._isCoreCode(code);
    final archivedRaw = (data['archived'] as bool?) ?? false;
    return Subject(
      id: doc.id,
      code: code,
      description: (data['description'] as String?) ?? '',
      yearLevel: (data['yearLevel'] as String?) ?? '',
      semester: (data['semester'] as String?) ?? '',
      order: (data['order'] as num?)?.toInt() ?? 0,
      // A core subject can never be archived, whatever the document says.
      archived: core ? false : archivedRaw,
      isCore: core,
    );
  }

  Map<String, dynamic> toMap() => {
        'code': code,
        'description': description,
        'yearLevel': yearLevel,
        'semester': semester,
        'order': order,
        'archived': archived,
        'isCore': isCore,
      };

  /// e.g. "CRIM 1 — Introduction to Criminology"
  String get label => '$code — $description';
}

/// Thrown by [CurriculumRepo] write methods for problems the admin can fix
/// (empty fields, duplicate code, protected subject). The message is safe to
/// show in the UI.
class CurriculumException implements Exception {
  final String message;
  const CurriculumException(this.message);

  @override
  String toString() => message;
}

// ─────────────────────────────────────────────────────────────────────────────
// CurriculumRepo
// ─────────────────────────────────────────────────────────────────────────────
//
// Single shared access point for reading/writing subjects.
//
// CORE SUBJECTS (built-in curriculum: BS Criminology only)
//   • Always present: every stream merges the built-in curriculum with what is
//     in Firestore, so the subjects show up even before any admin has opened
//     Manage Curriculum.
//   • Never removable: edit / archive / delete are blocked for them.
//   • Self-healing: ensureCoreSubjects() re-creates or repairs any core
//     subject that is missing, archived or changed in Firestore.
//
// ADMIN-ADDED SUBJECTS (this includes ALL English subjects)
//   • Stored only in Firestore, fully editable / archivable / deletable.
//
// Sorting is done on the device (year → semester → order → code), so NO
// composite index is needed.
//
// Writes are admin-only. The UI hides them from instructors, and you must
// also enforce it in Firestore security rules.
// ─────────────────────────────────────────────────────────────────────────────

class CurriculumRepo {
  static final CollectionReference<Map<String, dynamic>> _col =
      FirebaseFirestore.instance.collection('subjects');

  static const List<String> yearLevels = [
    '1st Year',
    '2nd Year',
    '3rd Year',
    '4th Year',
  ];

  static const List<String> semesters = [
    '1st Semester',
    '2nd Semester',
  ];

  // ── Core curriculum helpers ───────────────────────────────────────────────

  static String _key(String code) => code.trim().toLowerCase();

  static final Set<String> _coreCodes = {
    for (final y in _seedCurriculum)
      for (final s in [...y.sem1, ...y.sem2]) _key(s.code),
  };

  static bool _isCoreCode(String code) => _coreCodes.contains(_key(code));

  static String _coreId(String code) =>
      'core_${code.trim().replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_')}';

  /// The built-in curriculum as [Subject]s (used when Firestore lacks them).
  static final List<Subject> _coreSeeds = _buildCoreSeeds();

  static List<Subject> _buildCoreSeeds() {
    final out = <Subject>[];
    for (final y in _seedCurriculum) {
      for (var i = 0; i < y.sem1.length; i++) {
        out.add(Subject(
          id: _coreId(y.sem1[i].code),
          code: y.sem1[i].code,
          description: y.sem1[i].description,
          yearLevel: y.yearLabel,
          semester: '1st Semester',
          order: i,
          isCore: true,
        ));
      }
      for (var i = 0; i < y.sem2.length; i++) {
        out.add(Subject(
          id: _coreId(y.sem2[i].code),
          code: y.sem2[i].code,
          description: y.sem2[i].description,
          yearLevel: y.yearLabel,
          semester: '2nd Semester',
          order: i,
          isCore: true,
        ));
      }
    }
    return out;
  }

  // ── Sorting / parsing helpers ─────────────────────────────────────────────

  static int _compare(Subject a, Subject b) {
    final y = yearLevels
        .indexOf(a.yearLevel)
        .compareTo(yearLevels.indexOf(b.yearLevel));
    if (y != 0) return y;
    final s = semesters
        .indexOf(a.semester)
        .compareTo(semesters.indexOf(b.semester));
    if (s != 0) return s;
    final o = a.order.compareTo(b.order);
    if (o != 0) return o;
    return a.code.toLowerCase().compareTo(b.code.toLowerCase());
  }

  /// Firestore subjects merged with the built-in core curriculum.
  /// Core subjects missing from Firestore are supplied from the seed list.
  static List<Subject> _parse(QuerySnapshot<Map<String, dynamic>> snap) {
    final result = <Subject>[];
    final seenCore = <String>{};

    for (final doc in snap.docs) {
      final s = Subject.fromDoc(doc);
      if (s.isCore && !seenCore.add(_key(s.code))) continue; // drop duplicates
      result.add(s);
    }
    for (final seed in _coreSeeds) {
      if (!seenCore.contains(_key(seed.code))) result.add(seed);
    }

    result.sort(_compare);
    return result;
  }

  // ── Live streams ─────────────────────────────────────────────────────────

  /// Every ACTIVE (non-archived) subject, in curriculum order.
  static Stream<List<Subject>> streamAll() {
    return _col.snapshots().map(
        (snap) => _parse(snap).where((s) => !s.archived).toList());
  }

  /// ACTIVE subjects for one year level (both semesters), still live.
  static Stream<List<Subject>> streamForYear(String yearLevel) {
    return _col.snapshots().map((snap) => _parse(snap)
        .where((s) => !s.archived && s.yearLevel == yearLevel)
        .toList());
  }

  /// ACTIVE subjects that belong to one module subject group, e.g.
  /// streamForGroup('ENG') -> ENG 1, ENG 2 … in curriculum order.
  /// Nothing is hard-coded per group.
  static Stream<List<Subject>> streamForGroup(String groupCode) {
    final prefix = '${groupCode.trim().toLowerCase()} ';
    return _col.snapshots().map((snap) => _parse(snap)
        .where((s) => !s.archived && s.code.trim().toLowerCase().startsWith(prefix))
        .toList());
  }

  /// ARCHIVED subjects only (core subjects are never archived).
  static Stream<List<Subject>> streamArchived() {
    return _col
        .snapshots()
        .map((snap) => _parse(snap).where((s) => s.archived).toList());
  }

  /// Active AND archived subjects (for the admin's Manage Curriculum screen).
  static Stream<List<Subject>> streamEverything() {
    return _col.snapshots().map(_parse);
  }

  // ── Writes (admin only — enforce in the UI layer AND Firestore rules) ─────

  static const String _coreMessage =
      'This subject is part of the built-in curriculum '
      'and cannot be edited, archived, or deleted.';

  /// Throws if the document [id] is a core subject. Core is decided by the
  /// subject's CODE against the built-in list (not by the document id or a
  /// stored flag), so old `core_ENG_*` documents are freely editable.
  static Future<void> _assertNotCore(String id) async {
    final doc = await _col.doc(id).get();
    final data = doc.data();
    if (data == null) return;
    final code = (data['code'] as String?) ?? '';
    if (_isCoreCode(code)) {
      throw const CurriculumException(_coreMessage);
    }
  }

  static void _assertCodeFree(List<Subject> all, String code,
      {String? exceptId}) {
    final clash = all.where(
        (s) => s.id != exceptId && _key(s.code) == _key(code));
    if (clash.isNotEmpty) {
      final first = clash.first;
      throw CurriculumException(
        'A subject with the code "$code" already exists'
        '${first.archived ? ' (it is in the Archived list — restore it instead)' : ''}.',
      );
    }
  }

  static int _nextOrder(
      List<Subject> all, String yearLevel, String semester) {
    var highest = -1;
    for (final s in all) {
      if (s.yearLevel == yearLevel &&
          s.semester == semester &&
          s.order > highest) {
        highest = s.order;
      }
    }
    return highest + 1;
  }

  /// Adds an admin subject (never core).
  static Future<void> addSubject({
    required String code,
    required String description,
    required String yearLevel,
    required String semester,
  }) async {
    final c = code.trim();
    final d = description.trim();
    if (c.isEmpty || d.isEmpty) {
      throw const CurriculumException(
          'Subject code and description are required.');
    }

    // Includes the built-in core subjects, so a core code can't be reused.
    final all = _parse(await _col.get());
    _assertCodeFree(all, c);

    await _col.add({
      'code': c,
      'description': d,
      'yearLevel': yearLevel,
      'semester': semester,
      // New subjects go to the end of their year/semester group.
      'order': _nextOrder(all, yearLevel, semester),
      'archived': false,
      'isCore': false,
    });
  }

  /// Edits an admin subject. Core subjects are rejected.
  /// If it moves to another year/semester it is placed at the end of that
  /// group.
  static Future<void> editSubject({
    required String id,
    required String code,
    required String description,
    required String yearLevel,
    required String semester,
  }) async {
    await _assertNotCore(id);

    final c = code.trim();
    final d = description.trim();
    if (c.isEmpty || d.isEmpty) {
      throw const CurriculumException(
          'Subject code and description are required.');
    }

    final all = _parse(await _col.get());
    _assertCodeFree(all, c, exceptId: id);

    final current = all.where((s) => s.id == id);
    final moved = current.isEmpty ||
        current.first.yearLevel != yearLevel ||
        current.first.semester != semester;

    final update = <String, dynamic>{
      'code': c,
      'description': d,
      'yearLevel': yearLevel,
      'semester': semester,
      'isCore': false,
    };
    if (moved) update['order'] = _nextOrder(all, yearLevel, semester);

    await _col.doc(id).update(update);
  }

  /// Hides an admin subject from every picker/viewer without deleting it.
  /// Core subjects are rejected.
  static Future<void> archiveSubject(String id) async {
    await _assertNotCore(id);
    await _col.doc(id).update({
      'archived': true,
      'archivedAt': FieldValue.serverTimestamp(),
    });
  }

  static Future<void> restoreSubject(String id) async {
    await _col.doc(id).update({
      'archived': false,
      'archivedAt': FieldValue.delete(),
    });
  }

  ///