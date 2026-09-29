import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'curriculum_repo.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Manage Curriculum (ADMIN ONLY)
// ─────────────────────────────────────────────────────────────────────────────
//
// This file holds everything curriculum-related on the UI side:
//
//   • ManageCurriculumScreen   — admin-only screen: add, edit, archive,
//                                restore and permanently delete subjects.
//   • showSubjectPicker()      — the bottom sheet used by Create Review.
//                                Reads the LIVE curriculum; instructors can
//                                only pick from it. Admins additionally see
//                                "Add Subject" / "Manage Curriculum" buttons.
//   • showCurriculumViewer()   — read-only "All Subjects" list for the
//                                instructor dashboard.
//   • showSubjectEditor()      — the add/edit form (admin only callers).
//   • isCurrentUserAdmin()     — accountType == 'admin' check.
//
// Access control: the screen re-checks the admin flag itself and shows a
// "not allowed" message otherwise. That only protects the UI — also add the
// Firestore rule for the `subjects` collection so instructors can't write
// to it even by calling the API directly.
// ─────────────────────────────────────────────────────────────────────────────

const Color _kIndigo = Color(0xFF1A237E);
const Color _kIndigoSoft = Color(0xFF3949AB);
const Color _kPale = Color(0xFFE8EAF6);
const Color _kPage = Color(0xFFF0F2F8);
const Color _kArchive = Color(0xFFD84315);
const Color _kArchiveBg = Color(0xFFFBE9E7);
const Color _kArchiveBorder = Color(0xFFFFCCBC);

/// True when the signed-in account's Firestore user doc has
/// accountType == 'admin' (same rule TeacherHomeScreen uses).
Future<bool> isCurrentUserAdmin() async {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  if (uid == null) return false;
  try {
    final doc =
        await FirebaseFirestore.instance.collection('users').doc(uid).get();
    return doc.data()?['accountType'] == 'admin';
  } catch (_) {
    return false;
  }
}

Widget _sheetHandle() => Container(
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      width: 40,
      height: 4,
      decoration: BoxDecoration(
          color: Colors.grey[300], borderRadius: BorderRadius.circular(2)),
    );

const RoundedRectangleBorder _kSheetShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(20)));

// ═════════════════════════════════════════════════════════════════════════════
// PUBLIC HELPERS
// ═════════════════════════════════════════════════════════════════════════════

/// Bottom sheet listing the ACTIVE subjects of [yearLevel], grouped by
/// semester. Resolves to the tapped [Subject], or null if dismissed.
///
/// Set [isAdmin] to show the "Add Subject" and "Manage Curriculum" buttons.
Future<Subject?> showSubjectPicker(
  BuildContext context, {
  required String yearLevel,
  String selectedCode = '',
  bool isAdmin = false,
}) {
  return showModalBottomSheet<Subject>(
    context: context,
    isScrollControlled: true,
    shape: _kSheetShape,
    builder: (_) => _SubjectPickerSheet(
      yearLevel: yearLevel,
      selectedCode: selectedCode,
      isAdmin: isAdmin,
    ),
  );
}

/// Read-only list of the live curriculum (active subjects only). Pass a
/// specific year like '2nd Year', or 'All Years'.
void showCurriculumViewer(BuildContext context,
    {String yearFilter = 'All Years'}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: _kSheetShape,
    builder: (_) => _CurriculumViewerSheet(yearFilter: yearFilter),
  );
}

/// Add / edit form. Pass [existing] to edit. Resolves to true when saved.
Future<bool?> showSubjectEditor(
  BuildContext context, {
  Subject? existing,
  String? initialYear,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: _kSheetShape,
    builder: (_) =>
        _SubjectEditorSheet(existing: existing, initialYear: initialYear),
  );
}

// ═════════════════════════════════════════════════════════════════════════════
// SUBJECT PICKER SHEET (used by Create Review)
// ═════════════════════════════════════════════════════════════════════════════

class _SubjectPickerSheet extends StatelessWidget {
  final String yearLevel;
  final String selectedCode;
  final bool isAdmin;

  const _SubjectPickerSheet({
    required this.yearLevel,
    required this.selectedCode,
    required this.isAdmin,
  });

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.93,
      minChildSize: 0.4,
      builder: (_, ctrl) => Column(
        children: [
          _sheetHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Row(children: [
              const Icon(Icons.menu_book_rounded, color: _kIndigo, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('$yearLevel — Select Subject',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: _kIndigo)),
              ),
            ]),
          ),
          // Admin-only shortcuts. Instructors never see these.
          if (isAdmin)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        showSubjectEditor(context, initialYear: yearLevel),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Add Subject'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kIndigo,
                      side: const BorderSide(color: _kIndigo),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      final nav = Navigator.of(context);
                      nav.pop(); // close the sheet first
                      nav.push(MaterialPageRoute(
                          builder: (_) => const ManageCurriculumScreen()));
                    },
                    icon: const Icon(Icons.account_tree_rounded, size: 16),
                    label: const Text('Manage'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _kIndigo,
                      side: const BorderSide(color: _kIndigo),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ]),
            ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<List<Subject>>(
              stream: CurriculumRepo.streamForYear(yearLevel),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Could not load subjects.\n${snap.error}',
                          textAlign: TextAlign.center,
                          style:
                              const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(
                      child: CircularProgressIndicator(color: _kIndigo));
                }

                final subjects = snap.data!;
                if (subjects.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        isAdmin
                            ? 'No subjects for $yearLevel yet.\nTap "Add Subject" to create one.'
                            : 'No subjects for $yearLevel yet.\nPlease ask an administrator to add them.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey[500], fontSize: 13),
                      ),
                    ),
                  );
                }

                final rows = <Widget>[];
                for (final sem in CurriculumRepo.semesters) {
                  final inSem =
                      subjects.where((s) => s.semester == sem).toList();
                  if (inSem.isEmpty) continue;
                  rows.add(_SemHeader(label: sem));
                  for (final s in inSem) {
                    rows.add(_PickerRow(
                      subject: s,
                      isSelected: s.code == selectedCode,
                      onTap: () => Navigator.pop(context, s),
                    ));
                  }
                }
                rows.add(const SizedBox(height: 24));

                return ListView(controller: ctrl, children: rows);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SemHeader extends StatelessWidget {
  final String label;
  const _SemHeader({required this.label});

  @override
  Widget build(BuildContext context) => Container(
        color: _kPage,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
        child: Row(children: [
          const Icon(Icons.calendar_view_month_rounded,
              size: 13, color: _kIndigoSoft),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: _kIndigoSoft,
                  letterSpacing: 0.4)),
        ]),
      );
}

class _PickerRow extends StatelessWidget {
  final Subject subject;
  final bool isSelected;
  final VoidCallback onTap;
  const _PickerRow({
    required this.subject,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          color: isSelected ? _kPale : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
          child: Row(children: [
            _CodeTag(code: subject.code, highlighted: isSelected),
            const SizedBox(width: 12),
            Expanded(
              child: Text(subject.description,
                  style: TextStyle(
                      fontSize: 13,
                      color: isSelected ? _kIndigo : Colors.black87,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.normal)),
            ),
            if (isSelected)
              const Icon(Icons.check_rounded, size: 16, color: _kIndigo),
          ]),
        ),
      );
}

class _CodeTag extends StatelessWidget {
  final String code;
  final bool highlighted;
  final Color? color;
  const _CodeTag({required this.code, this.highlighted = false, this.color});

  @override
  Widget build(BuildContext context) {
    final base = color ?? _kIndigoSoft;
    return Container(
      width: 72,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      decoration: BoxDecoration(
        color: highlighted ? _kIndigo.withOpacity(0.12) : _kPale,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
            color: highlighted ? _kIndigo.withOpacity(0.4) : Colors.transparent),
      ),
      child: Text(code,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: highlighted ? _kIndigo : base)),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// READ-ONLY CURRICULUM VIEWER (instructor dashboard "All Subjects")
// ═════════════════════════════════════════════════════════════════════════════

class _CurriculumViewerSheet extends StatelessWidget {
  final String yearFilter;
  const _CurriculumViewerSheet({required this.yearFilter});

  @override
  Widget build(BuildContext context) {
    final years = yearFilter == 'All Years'
        ? CurriculumRepo.yearLevels
        : [yearFilter];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.93,
      minChildSize: 0.4,
      builder: (_, ctrl) => Column(
        children: [
          _sheetHandle(),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Row(children: [
              const Icon(Icons.menu_book_rounded, color: _kIndigo, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  yearFilter == 'All Years'
                      ? 'All Subjects (1st – 4th Year)'
                      : 'Subjects — $yearFilter',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      color: _kIndigo),
                ),
              ),
            ]),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<List<Subject>>(
              stream: CurriculumRepo.streamAll(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text('Could not load subjects.\n${snap.error}',
                          textAlign: TextAlign.center,
                          style:
                              const TextStyle(color: Colors.red, fontSize: 12)),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(
                      child: CircularProgressIndicator(color: _kIndigo));
                }

                final all = snap.data!;
                final rows = <Widget>[];

                for (final year in years) {
                  final inYear =
                      all.where((s) => s.yearLevel == year).toList();
                  if (inYear.isEmpty) continue;

                  rows.add(Container(
                    color: _kPale,
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 5),
                    child: Text(year,
                        style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: _kIndigo,
                            letterSpacing: 0.3)),
                  ));

                  for (final sem in CurriculumRepo.semesters) {
                    final inSem =
                        inYear.where((s) => s.semester == sem).toList();
                    if (inSem.isEmpty) continue;
                    rows.add(Container(
                      color: _kPage,
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(sem,
                          style: const TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.bold,
                              color: _kIndigoSoft,
                              letterSpacing: 0.4)),
                    ));
                    for (final s in inSem) {
                      rows.add(Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20, vertical: 10),
                        child: Row(children: [
                          _CodeTag(code: s.code),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(s.description,
                                style: const TextStyle(
                                    fontSize: 13, color: Colors.black87)),
                          ),
                        ]),
                      ));
                    }
                  }
                }

                if (rows.isEmpty) {
                  return Center(
                    child: Text('No subjects yet.',
                        style: TextStyle(color: Colors.grey[500])),
                  );
                }
                rows.add(const SizedBox(height: 16));
                return ListView(controller: ctrl, children: rows);
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// ADD / EDIT SUBJECT FORM
// ═════════════════════════════════════════════════════════════════════════════

class _SubjectEditorSheet extends StatefulWidget {
  final Subject? existing;
  final String? initialYear;
  const _SubjectEditorSheet({this.existing, this.initialYear});

  @override
  State<_SubjectEditorSheet> createState() => _SubjectEditorSheetState();
}

class _SubjectEditorSheetState extends State<_SubjectEditorSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _code;
  late final TextEditingController _description;
  String? _year;
  String? _semester;
  bool _saving = false;
  String? _error;

  bool get _isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _code = TextEditingController(text: e?.code ?? '');
    _description = TextEditingController(text: e?.description ?? '');
    _year = e?.yearLevel ?? widget.initialYear;
    _semester = e?.semester ?? CurriculumRepo.semesters.first;
  }

  @override
  void dispose() {
    _code.dispose();
    _description.dispose();
    super.dispose();
  }

  InputDecoration _deco(String label, IconData icon) => InputDecoration(
        labelText: label,
        prefixIcon: Icon(icon, color: _kIndigoSoft, size: 20),
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
            borderSide: const BorderSide(color: _kIndigo, width: 1.5)),
      );

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_isEditing) {
        await CurriculumRepo.editSubject(
          id: widget.existing!.id,
          code: _code.text,
          description: _description.text,
          yearLevel: _year!,
          semester: _semester!,
        );
      } else {
        await CurriculumRepo.addSubject(
          code: _code.text,
          description: _description.text,
          yearLevel: _year!,
          semester: _semester!,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } on CurriculumException catch (e) {
      if (mounted) setState(() { _saving = false; _error = e.message; });
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save the subject: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(child: _sheetHandle()),
              const SizedBox(height: 8),
              Row(children: [
                Icon(_isEditing ? Icons.edit_rounded : Icons.bookmark_add_rounded,
                    color: _kIndigo, size: 20),
                const SizedBox(width: 8),
                Text(_isEditing ? 'Edit Subject' : 'Add Subject',
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                        color: _kIndigo)),
              ]),
              const SizedBox(height: 16),
              TextFormField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                decoration: _deco('Subject Code (e.g. CRIM 9)', Icons.tag_rounded),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _description,
                textCapitalization: TextCapitalization.words,
                maxLines: null,
                decoration:
                    _deco('Description', Icons.menu_book_rounded),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _year,
                decoration: _deco('Year Level', Icons.school_rounded),
                items: CurriculumRepo.yearLevels
                    .map((y) => DropdownMenuItem(value: y, child: Text(y)))
                    .toList(),
                onChanged: (v) => setState(() => _year = v),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: _semester,
                decoration:
                    _deco('Semester', Icons.calendar_view_month_rounded),
                items: CurriculumRepo.semesters
                    .map((s) => DropdownMenuItem(value: s, child: Text(s)))
                    .toList(),
                onChanged: (v) => setState(() => _semester = v),
                validator: (v) => (v == null || v.isEmpty) ? 'Required' : null,
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Text(_error!,
                      style:
                          TextStyle(color: Colors.red.shade700, fontSize: 12)),
                ),
              ],
              const SizedBox(height: 18),
              Row(children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.pop(context, false),
                    style: OutlinedButton.styleFrom(
                      side: const BorderSide(color: _kIndigo),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Cancel',
                        style: TextStyle(
                            color: _kIndigo, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _kIndigo,
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: _saving
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : Text(_isEditing ? 'Save Changes' : 'Add Subject',
                            style: const TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.bold)),
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// MANAGE CURRICULUM SCREEN (ADMIN ONLY)
// ═════════════════════════════════════════════════════════════════════════════

class ManageCurriculumScreen extends StatefulWidget {
  const ManageCurriculumScreen({super.key});

  @override
  State<ManageCurriculumScreen> createState() => _ManageCurriculumScreenState();
}

class _ManageCurriculumScreenState extends State<ManageCurriculumScreen> {
  late final Future<bool> _readyFuture;
  late final Stream<List<Subject>> _stream;
  String _yearFilter = 'All Years';

  @override
  void initState() {
    super.initState();
    _stream = CurriculumRepo.streamEverything();
    _readyFuture = _init();
  }

  // Confirms the account is an admin, then (admin only) fills the
  // `subjects` collection from the original curriculum if it is empty.
  Future<bool> _init() async {
    final admin = await isCurrentUserAdmin();
    if (admin) {
      try {
        await CurriculumRepo.migrateIfEmpty();
      } catch (_) {
        // Non-fatal: the stream below will surface any real problem.
      }
    }
    return admin;
  }

  void _snack(String msg, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: error ? Colors.red.shade700 : null,
      behavior: SnackBarBehavior.floating,
    ));
  }

  PreferredSizeWidget _appBar({PreferredSizeWidget? bottom}) => AppBar(
        backgroundColor: _kIndigo,
        foregroundColor: Colors.white,
        title: const Text('Manage Curriculum',
            style: TextStyle(fontWeight: FontWeight.bold)),
        bottom: bottom,
      );

  Future<bool?> _confirm({
    required String title,
    required String message,
    required String confirmLabel,
    required Color color,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(title,
            style: TextStyle(color: color, fontWeight: FontWeight.bold)),
        content: Text(message),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel', style: TextStyle(color: Colors.grey))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: color,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8))),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  // ── Actions ────────────────────────────────────────────────────────────────

  Future<void> _add() async {
    final saved = await showSubjectEditor(
      context,
      initialYear: _yearFilter == 'All Years' ? null : _yearFilter,
    );
    if (saved == true) _snack('Subject added.');
  }

  Future<void> _edit(Subject s) async {
    final saved = await showSubjectEditor(context, existing: s);
    if (saved == true) _snack('Subject updated.');
  }

  Future<void> _archive(Subject s) async {
    final ok = await _confirm(
      title: 'Archive Subject',
      message:
          '"${s.label}" will be hidden from the subject list when creating '
          'reviews. Existing reviews keep their subject. You can restore it '
          'anytime from the Archived tab.',
      confirmLabel: 'Archive',
      color: _kArchive,
    );
    if (ok != true) return;
    try {
      await CurriculumRepo.archiveSubject(s.id);
      _snack('${s.code} archived.');
    } catch (e) {
      _snack('Could not archive: $e', error: true);
    }
  }

  Future<void> _restore(Subject s) async {
    try {
      await CurriculumRepo.restoreSubject(s.id);
      _snack('${s.code} restored.');
    } catch (e) {
      _snack('Could not restore: $e', error: true);
    }
  }

  Future<void> _deleteForever(Subject s) async {
    final ok = await _confirm(
      title: 'Delete Permanently',
      message:
          'This permanently removes "${s.label}" from the curriculum. '
          'Existing reviews keep their saved subject name. This cannot be undone.',
      confirmLabel: 'Delete Forever',
      color: Colors.red,
    );
    if (ok != true) return;
    try {
      await CurriculumRepo.deleteSubject(s.id);
      _snack('${s.code} permanently deleted.');
    } catch (e) {
      _snack('Could not delete: $e', error: true);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _readyFuture,
      builder: (context, ready) {
        if (!ready.hasData) {
          return Scaffold(
            backgroundColor: _kPage,
            appBar: _appBar(),
            body: const Center(
                child: CircularProgressIndicator(color: _kIndigo)),
          );
        }

        if (ready.data != true) {
          return Scaffold(
            backgroundColor: _kPage,
            appBar: _appBar(),
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline_rounded,
                        size: 56, color: Colors.grey[400]),
                    const SizedBox(height: 14),
                    const Text('Administrators only',
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 16,
                            color: _kIndigo)),
                    const SizedBox(height: 6),
                    Text(
                      'Only an administrator can change the curriculum. '
                      'You can still pick from the existing subjects when '
                      'creating a review.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return StreamBuilder<List<Subject>>(
          stream: _stream,
          builder: (context, snap) {
            final all = snap.data ?? const <Subject>[];
            final active = all.where((s) => !s.archived).toList();
            final archived = all.where((s) => s.archived).toList();

            return DefaultTabController(
              length: 2,
              child: Scaffold(
                backgroundColor: _kPage,
                appBar: _appBar(
                  bottom: TabBar(
                    indicatorColor: Colors.white,
                    indicatorWeight: 3,
                    labelColor: Colors.white,
                    unselectedLabelColor: Colors.white60,
                    labelStyle: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 13),
                    tabs: [
                      Tab(text: 'Active (${active.length})'),
                      Tab(text: 'Archived (${archived.length})'),
                    ],
                  ),
                ),
                floatingActionButton: FloatingActionButton.extended(
                  heroTag: 'addSubject',
                  backgroundColor: _kIndigo,
                  foregroundColor: Colors.white,
                  icon: const Icon(Icons.add_rounded),
                  label: const Text('Add Subject',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  onPressed: _add,
                ),
                body: snap.hasError
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text('Could not load the curriculum.\n${snap.error}',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                  color: Colors.red, fontSize: 12)),
                        ),
                      )
                    : !snap.hasData
                        ? const Center(
                            child: CircularProgressIndicator(color: _kIndigo))
                        : TabBarView(
                            children: [
                              _buildActive(active),
                              _buildArchived(archived),
                            ],
                          ),
              ),
            );
          },
        );
      },
    );
  }

  // ── Active tab ─────────────────────────────────────────────────────────────

  Widget _buildYearChips() {
    final options = ['All Years', ...CurriculumRepo.yearLevels];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 6),
      child: Row(
        children: [
          for (final y in options)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ChoiceChip(
                label: Text(y),
                selected: _yearFilter == y,
                onSelected: (_) => setState(() => _yearFilter = y),
                selectedColor: _kIndigo,
                backgroundColor: Colors.white,
                side: BorderSide(
                    color: _yearFilter == y ? _kIndigo : const Color(0xFFD0D5E8)),
                labelStyle: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _yearFilter == y ? Colors.white : _kIndigoSoft),
                showCheckmark: false,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildActive(List<Subject> active) {
    final years = _yearFilter == 'All Years'
        ? CurriculumRepo.yearLevels
        : [_yearFilter];

    final rows = <Widget>[];
    for (final year in years) {
      final inYear = active.where((s) => s.yearLevel == year).toList();
      if (inYear.isEmpty) continue;

      rows.add(Padding(
        padding: const EdgeInsets.fromLTRB(2, 14, 2, 4),
        child: Row(children: [
          Text(year,
              style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  color: _kIndigo)),
          const SizedBox(width: 8),
          Text('${inYear.length} subject${inYear.length == 1 ? '' : 's'}',
              style: TextStyle(fontSize: 11, color: Colors.grey[600])),
        ]),
      ));

      for (final sem in CurriculumRepo.semesters) {
        final inSem = inYear.where((s) => s.semester == sem).toList();
        if (inSem.isEmpty) continue;
        rows.add(Padding(
          padding: const EdgeInsets.fromLTRB(2, 8, 2, 6),
          child: Text(sem.toUpperCase(),
              style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: _kIndigoSoft,
                  letterSpacing: 0.6)),
        ));
        for (final s in inSem) {
          rows.add(_ActiveTile(
            subject: s,
            onEdit: () => _edit(s),
            onArchive: () => _archive(s),
          ));
        }
      }
    }

    return Column(
      children: [
        _buildYearChips(),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      active.isEmpty
                          ? 'No subjects yet.\nTap "Add Subject" to build the curriculum.'
                          : 'No subjects for $_yearFilter.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.grey[500], fontSize: 14),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 96),
                  children: rows,
                ),
        ),
      ],
    );
  }

  // ── Archived tab ───────────────────────────────────────────────────────────

  Widget _buildArchived(List<Subject> archived) {
    if (archived.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inventory_2_outlined, size: 60, color: Colors.grey[300]),
              const SizedBox(height: 12),
              Text('No archived subjects.',
                  style: TextStyle(color: Colors.grey[500], fontSize: 15)),
              const SizedBox(height: 6),
              Text('Subjects you archive will appear here.',
                  style: TextStyle(color: Colors.grey[400], fontSize: 13)),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 96),
      itemCount: archived.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final s = archived[i];
        return _ArchivedTile(
          subject: s,
          onRestore: () => _restore(s),
          onDelete: () => _deleteForever(s),
        );
      },
    );
  }
}

// ═════════════════════════════════════════════════════════════════════════════
// TILES
// ═════════════════════════════════════════════════════════════════════════════

class _ActiveTile extends StatelessWidget {
  final Subject subject;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  const _ActiveTile({
    required this.subject,
    required this.onEdit,
    required this.onArchive,
  });

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kPale),
        ),
        child: Row(children: [
          _CodeTag(code: subject.code),
          const SizedBox(width: 10),
          Expanded(
            child: Text(subject.description,
                style: const TextStyle(fontSize: 13, color: Colors.black87)),
          ),
          IconButton(
            tooltip: 'Edit',
            icon: const Icon(Icons.edit_outlined, size: 19, color: _kIndigo),
            onPressed: onEdit,
          ),
          IconButton(
            tooltip: 'Archive',
            icon: const Icon(Icons.inventory_2_outlined,
                size: 19, color: _kArchive),
            onPressed: onArchive,
          ),
        ]),
      );
}

class _ArchivedTile extends StatelessWidget {
  final Subject subject;
  final VoidCallback onRestore;
  final VoidCallback onDelete;
  const _ArchivedTile({
    required this.subject,
    required this.onRestore,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
        decoration: BoxDecoration(
          color: _kArchiveBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: _kArchiveBorder, width: 1.2),
        ),
        child: Row(children: [
          _CodeTag(code: subject.code, color: _kArchive),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(subject.description,
                    style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFBF360C))),
                const SizedBox(height: 2),
                Text('${subject.yearLevel} · ${subject.semester}',
                    style: TextStyle(fontSize: 11, color: Colors.grey[700])),
              ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _SmallAction(
                  label: 'Restore',
                  icon: Icons.restore_rounded,
                  color: _kIndigo,
                  onTap: onRestore),
              const SizedBox(height: 4),
              _SmallAction(
                  label: 'Delete',
                  icon: Icons.delete_forever_rounded,
                  color: Colors.red.shade600,
                  onTap: onDelete),
            ],
          ),
        ]),
      );
}

class _SmallAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;
  const _SmallAction({
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
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 11, color: color),
            const SizedBox(width: 3),
            Text(label,
                style: TextStyle(
                    fontSize: 10, fontWeight: FontWeight.bold, color: color)),
          ]),
        ),
      );
}