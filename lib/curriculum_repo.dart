import 'package:cloud_firestore/cloud_firestore.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Subject model
// ─────────────────────────────────────────────────────────────────────────────
//
// Firestore collection: 'subjects'
// Each document = one subject, with fields:
//   code        (e.g. 'CRIM 1')
//   description (e.g. 'Introduction to Criminology')
//   yearLevel   (e.g. '1st Year')
//   semester    ('1st Semester' | '2nd Semester')
//   order       (int, keeps subjects in a stable order within their
//                year/semester)
//   archived    (bool, default false — archived subjects are hidden from
//                every picker/viewer but can be restored by an admin)
//   archivedAt  (server timestamp, only present while archived)
//   isCore      (bool — true for the official BS Criminology curriculum.
//                Core subjects can NEVER be edited, archived or deleted.)
//
// A subject is also treated as core when its code matches one of the codes in
// the built-in curriculum (_seedCurriculum), even if the Firestore document
// has no `isCore` flag yet.
// ─────────────────────────────────────────────────────────────────────────────

class Subject {
  final String id; // Firestore document id
  final String code;
  final String description;
  final String yearLevel;
  final String semester;
  final int order;
  final bool archived;

  /// True for the official BS Criminology curriculum (protected).
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
    final core = (data['isCore'] as bool?) == true ||
        CurriculumRepo._isCoreCode(code);
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
// CORE SUBJECTS (official BS Criminology curriculum)
//   • Always present: every stream merges the built-in curriculum with what is
//     in Firestore, so the subjects show up even before any admin has opened
//     Manage Curriculum.
//   • Never removable: edit / archive / delete are blocked for them.
//   • Self-healing: ensureCoreSubjects() re-creates or repairs any core
//     subject that is missing, archived or changed in Firestore.
//
// ADMIN-ADDED SUBJECTS
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
      'This subject is part of the official BS Criminology curriculum '
      'and cannot be edited, archived, or deleted.';

  /// Throws if the document [id] is a core subject.
  static Future<void> _assertNotCore(String id) async {
    if (id.startsWith('core_')) throw const CurriculumException(_coreMessage);
    final doc = await _col.doc(id).get();
    final data = doc.data();
    if (data == null) return;
    final code = (data['code'] as String?) ?? '';
    if (data['isCore'] == true || _isCoreCode(code)) {
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

  /// Permanently removes an admin subject. Core subjects are rejected.
  static Future<void> deleteSubject(String id) async {
    await _assertNotCore(id);
    await _col.doc(id).delete();
  }

  /// Kept for older callers. Overwrites every field from [subject].
  /// Core subjects are rejected.
  static Future<void> updateSubject(Subject subject) async {
    await _assertNotCore(subject.id);
    await _col.doc(subject.id).update(subject.toMap());
  }

  // ── Core curriculum maintenance ────────────────────────────────────────────
  //
  // Makes sure every official BS Criminology subject exists in Firestore,
  // flagged isCore, not archived, and with its original details. Safe to call
  // as often as you like (only writes when something is actually wrong).
  // Admin only — wrap in try/catch for other accounts.
  // ─────────────────────────────────────────────────────────────────────────

  static Future<void> ensureCoreSubjects() async {
    final snap = await _col.get();

    final byCode = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final d in snap.docs) {
      final code = (d.data()['code'] as String?) ?? '';
      byCode.putIfAbsent(_key(code), () => d);
    }

    final batch = FirebaseFirestore.instance.batch();
    var changed = false;

    for (final seed in _coreSeeds) {
      final existing = byCode[_key(seed.code)];
      final fresh = <String, dynamic>{
        'code': seed.code,
        'description': seed.description,
        'yearLevel': seed.yearLevel,
        'semester': seed.semester,
        'order': seed.order,
        'archived': false,
        'isCore': true,
      };

      if (existing == null) {
        // Fixed id, so it can never be duplicated.
        batch.set(_col.doc(seed.id), fresh);
        changed = true;
        continue;
      }

      final d = existing.data();
      final intact = d['isCore'] == true &&
          d['archived'] != true &&
          d['description'] == seed.description &&
          d['yearLevel'] == seed.yearLevel &&
          d['semester'] == seed.semester &&
          (d['order'] as num?)?.toInt() == seed.order;

      if (!intact) {
        batch.update(existing.reference, {
          ...fresh,
          'archivedAt': FieldValue.delete(),
        });
        changed = true;
      }
    }

    if (changed) await batch.commit();
  }

  /// Old name, kept so existing callers still compile.
  static Future<void> migrateIfEmpty() => ensureCoreSubjects();
}

// ─────────────────────────────────────────────────────────────────────────────
// Core curriculum — the official BS Criminology subjects. These are
// permanent: they are always shown and can never be edited, archived or
// deleted. To add more official subjects, add them here (admins can also add
// extra subjects from the app; those stay removable).
// ─────────────────────────────────────────────────────────────────────────────

class _SeedSubject {
  final String code;
  final String description;
  const _SeedSubject(this.code, this.description);
}

class _SeedYear {
  final String yearLabel;
  final List<_SeedSubject> sem1;
  final List<_SeedSubject> sem2;
  const _SeedYear({
    required this.yearLabel,
    required this.sem1,
    required this.sem2,
  });
}

const List<_SeedYear> _seedCurriculum = [
  _SeedYear(
    yearLabel: '1st Year',
    sem1: [
      _SeedSubject('CRIM 1', 'Introduction to Criminology'),
    ],
    sem2: [
      _SeedSubject('CLJ 1', 'Introduction to Phil. Criminal Justice System'),
      _SeedSubject('LEA 1', 'Law Enforcement Organization and Administration'),
    ],
  ),
  _SeedYear(
    yearLabel: '2nd Year',
    sem1: [
      _SeedSubject('CA 1', 'Institutional Corrections'),
      _SeedSubject('CDI 1', 'Fundamentals of Investigation and Intelligence'),
      _SeedSubject('CLJ 2', 'Human Rights Education'),
      _SeedSubject('CRIM 2', 'Theories of Crime Causation'),
      _SeedSubject('LEA 2', 'Comparative Models in Policing'),
    ],
    sem2: [
      _SeedSubject('CDI 2', 'Specialized Crime Investigation 1 with Legal Medicine'),
      _SeedSubject('CFLM 1', 'Character Formation, Nationalism and Patriotism'),
      _SeedSubject('CLJ 3', 'Criminal Law (Book 1)'),
      _SeedSubject('CRIM 3', 'Human Behavior and Victimology'),
      _SeedSubject('FORENSIC 1', 'Forensic Photography'),
      _SeedSubject('FORENSIC 2', 'Personal Identification Techniques'),
      _SeedSubject('LEA 3', 'Introduction to Industrial Security Concepts'),
    ],
  ),
  _SeedYear(
    yearLabel: '3rd Year',
    sem1: [
      _SeedSubject('CA 2', 'Non-Institutional Corrections'),
      _SeedSubject('CDI 3',
          'Specialized Crime Investigation 2 with Simulation on Interrogation and Interview'),
      _SeedSubject('CDI 4',
          'Traffic Management and Accident Investigation with Driving'),
      _SeedSubject(
          'CDI 5', 'Technical English 1 (Technical Report Writing and Presentation)'),
      _SeedSubject('CFLM 2',
          'Character Formation with Leadership, Decision Making, Management and Administration'),
      _SeedSubject('CLJ 4', 'Criminal Law (Book 2)'),
      _SeedSubject('FORENSIC 3', 'Forensic Chemistry and Toxicology'),
      _SeedSubject('FORENSIC 4', 'Questioned Documents Examination'),
      _SeedSubject(
          'LEA 4', 'Law Enforcement Operations and Planning with Crime Mapping'),
    ],
    sem2: [
      _SeedSubject('CA 3', 'Therapeutic Modalities'),
      _SeedSubject('CDI 6', 'Fire Protection and Arson Investigation'),
      _SeedSubject('CDI 7', 'Vice and Drug Education and Control'),
      _SeedSubject('CLJ 5', 'Evidence'),
      _SeedSubject('CRIM 4', 'Professional Conduct and Ethical Standards'),
      _SeedSubject('CRIM 5', 'Juvenile Delinquency and Juvenile Justice System'),
      _SeedSubject('CRIM 6', 'Dispute Resolution and Crises/Incidents Management'),
      _SeedSubject('CRIM 7',
          'Criminological Research 1 (Research Methods with Applied Statistics)'),
      _SeedSubject('FORENSIC 5', 'Lie Detection Techniques'),
      _SeedSubject('FORENSIC 6', 'Forensic Ballistics'),
    ],
  ),
  _SeedYear(
    yearLabel: '4th Year',
    sem1: [
      _SeedSubject('CDI 8', 'Technical English 2 (Legal Forms)'),
      _SeedSubject(
          'CDI 9', 'Introduction to Cybercrime and Environmental Laws and Protection'),
      _SeedSubject('CLJ 6', 'Criminal Procedure and Court Testimony'),
      _SeedSubject('CP 1', 'Internship (On-the-Job Training 1)'),
      _SeedSubject(
          'CRIM 8', 'Criminological Research 2 (Thesis Writing and Presentation)'),
    ],
    sem2: [
      _SeedSubject('CP 2', 'Internship (On-the-Job Training 2)'),
      _SeedSubject('ICRIM RC', 'Criminology Refresher Course'),
    ],
  ),
];