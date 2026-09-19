import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

// NOTE: the Google Drive "connect account" step that used to live on this
// screen (Instructor/Admin only) has been removed. Module uploads now use
// a plain pasted shareable link (see modules_screen.dart's _UploadModuleSheet)
// instead of an in-app Google Drive picker, so there's no longer any reason
// for an applicant to link a Google account before their account exists.
// If google_drive_service.dart isn't used anywhere else in the project,
// it's safe to delete.

// ── Floating text item model ─────────────────────────────────────────────────
class _FloatingItem {
  final String text;
  double x;
  double y;
  final double speed;
  final double fontSize;
  final double opacity;

  _FloatingItem({
    required this.text,
    required this.x,
    required this.y,
    required this.speed,
    required this.fontSize,
    required this.opacity,
  });
}

// ── Animated background painter ───────────────────────────────────────────────
class _BackgroundPainter extends CustomPainter {
  final List<_FloatingItem> items;

  _BackgroundPainter(this.items);

  @override
  void paint(Canvas canvas, Size size) {
    for (final item in items) {
      final textPainter = TextPainter(
        text: TextSpan(
          text: item.text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: item.opacity),
            fontSize: item.fontSize,
            fontWeight: FontWeight.w400,
            letterSpacing: 0.5,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      textPainter.paint(canvas, Offset(item.x, item.y));
    }
  }

  @override
  bool shouldRepaint(_BackgroundPainter old) => true;
}

// ── Animated background widget ────────────────────────────────────────────────
class _AnimatedBackground extends StatefulWidget {
  const _AnimatedBackground();

  @override
  State<_AnimatedBackground> createState() => _AnimatedBackgroundState();
}

class _AnimatedBackgroundState extends State<_AnimatedBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late List<_FloatingItem> _items;
  final _rand = Random();

  static const List<String> _words = [
    'Criminal Law',
    'Evidence',
    'Criminalistics',
    'Penology',
    'Ethics',
    'R.A. 6975',
    'R.A. 9708',
    'P.D. 1606',
    'B.P. 881',
    'R.A. 10591',
    'Forensic Chemistry',
    'Ballistics',
    'Toxicology',
    'Questioned Documents',
    'Police Organization',
    'Law Enforcement Admin',
    'Criminal Sociology',
    'Crime Scene Investigation',
    'Victimology',
    'White-collar Crime',
    'Organized Crime',
    'Juvenile Delinquency',
    'Art. 248 RPC — Murder',
    'Art. 249 — Homicide',
    'Art. 246 — Parricide',
    'Art. 11 RPC — Justifying Circumstances',
    'Art. 12 — Exempting Circumstances',
    'Locard\'s Exchange Principle',
    '1. The study of crime causation is known as...',
    '2. Which agency has primary law enforcement jurisdiction?',
    '3. Every contact leaves a trace.',
    'Modus Operandi',
    'Chain of Custody',
    'Corpus Delicti',
    'Reasonable Doubt',
    'Circumstantial Evidence',
    'Inquest Proceedings',
    'Autopsy Report',
    'DNA Analysis',
    'Fingerprint Classification',
  ];

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..addListener(_tick)..repeat();
    _items = [];
    WidgetsBinding.instance.addPostFrameCallback((_) => _initItems());
  }

  void _initItems() {
    if (!mounted) return;
    final size = MediaQuery.of(context).size;
    _items = List.generate(38, (i) {
      return _FloatingItem(
        text: _words[i % _words.length],
        x: _rand.nextDouble() * size.width,
        y: _rand.nextDouble() * size.height,
        speed: 0.18 + _rand.nextDouble() * 0.32,
        fontSize: 11.0 + _rand.nextDouble() * 4,
        opacity: 0.08 + _rand.nextDouble() * 0.12,
      );
    });
  }

  void _tick() {
    if (!mounted || _items.isEmpty) return;
    final size = MediaQuery.of(context).size;
    for (final item in _items) {
      item.y -= item.speed;
      if (item.y < -30) {
        item.y = size.height + 10;
        item.x = _rand.nextDouble() * size.width;
      }
    }
    setState(() {});
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _BackgroundPainter(_items),
      size: Size.infinite,
    );
  }
}

// ── Register Screen ───────────────────────────────────────────────────────────
class RegisterScreen extends StatefulWidget {
  final String initialRole;
  const RegisterScreen({super.key, this.initialRole = 'student'});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();

  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _accessCodeController = TextEditingController();

  bool _isPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;
  bool _isAccessCodeVisible = false;
  bool _isLoading = false;
  bool _agreedToTerms = false;
  String? _selectedYearLevel;
  late String _selectedRole;

  int _passwordStrength = 0;

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  final List<String> _yearLevels = [
    '1st Year',
    '2nd Year',
    '3rd Year',
    '4th Year',
  ];

  static const Color _brand = Color(0xFF1A237E);

  // ── Access code gates ─────────────────────────────────────────────────────
  // Instructor and Admin each have their own code. Both roles are stored in
  // Firestore as 'teacher' (see _handleRegister) so they land on the exact
  // same TeacherHomeScreen dashboard — 'accountType' just remembers which
  // tab they registered under, in case it's ever needed later.
  // TODO: replace with your real admin code before shipping.
  static const String _instructorAccessCode = 'BISUCCJ2026';
  static const String _adminAccessCode = 'BISUADMIN2026';

  @override
  void initState() {
    super.initState();
    _selectedRole = widget.initialRole;
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _animationController.forward();
    _passwordController.addListener(_updatePasswordStrength);
  }

  @override
  void dispose() {
    _animationController.dispose();
    _firstNameController.dispose();
    _lastNameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _accessCodeController.dispose();
    super.dispose();
  }

  bool get _isStudent => _selectedRole == 'student';
  bool get _isAdmin => _selectedRole == 'admin';

  // The access code that must match for whichever non-student tab is active.
  String get _expectedAccessCode =>
      _isAdmin ? _adminAccessCode : _instructorAccessCode;

  void _updatePasswordStrength() {
    final pw = _passwordController.text;
    int score = 0;
    if (pw.length >= 8) score++;
    if (RegExp(r'[A-Z]').hasMatch(pw)) score++;
    if (RegExp(r'[0-9]').hasMatch(pw)) score++;
    if (RegExp(r'[!@#\$%^&*(),.?":{}|<>]').hasMatch(pw)) score++;

    setState(() {
      if (pw.isEmpty) {
        _passwordStrength = 0;
      } else if (score <= 1) {
        _passwordStrength = 1;
      } else if (score == 2) {
        _passwordStrength = 2;
      } else {
        _passwordStrength = 3;
      }
    });
  }

  Color get _strengthColor {
    switch (_passwordStrength) {
      case 1:
        return Colors.red.shade600;
      case 2:
        return Colors.orange.shade600;
      case 3:
        return Colors.green.shade600;
      default:
        return Colors.transparent;
    }
  }

  String get _strengthLabel {
    switch (_passwordStrength) {
      case 1:
        return 'Weak';
      case 2:
        return 'Fair';
      case 3:
        return 'Strong';
      default:
        return '';
    }
  }

  InputDecoration _inputDecoration({
    required String label,
    required String hint,
    required IconData prefixIcon,
    Widget? suffixIcon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixIcon: Icon(prefixIcon, color: _brand),
      suffixIcon: suffixIcon,
    );
  }

  String _friendlyRegisterError(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'This email is already registered. Please sign in instead.';
      case 'invalid-email':
        return 'The email address is not valid.';
      case 'weak-password':
        return 'Password is too weak. Use at least 6 characters.';
      case 'network-request-failed':
      case 'channel-error':
        return 'Network error. Please check your internet connection.';
      case 'operation-not-allowed':
        return 'Registration is currently disabled. Contact support.';
      default:
        return 'Registration failed ($code). Please try again.';
    }
  }

  Future<void> _handleRegister() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_agreedToTerms) {
      _showSnackbar(
        'Please agree to the Terms and Conditions.',
        Colors.orange.shade700,
        Icons.warning_amber_rounded,
      );
      return;
    }

    // Extra defensive check on top of the form validator — Instructor and
    // Admin registration cannot proceed without their respective correct
    // access code.
    if (!_isStudent &&
        _accessCodeController.text.trim() != _expectedAccessCode) {
      _showSnackbar(
        _isAdmin ? 'Invalid admin access code.' : 'Invalid instructor access code.',
        Colors.red.shade700,
        Icons.gpp_bad_rounded,
      );
      return;
    }

    setState(() => _isLoading = true);

    User? newUser;

    try {
      final credential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      newUser = credential.user;
      if (newUser == null) throw Exception('account-creation-failed');

      final uid = newUser.uid;
      // Admin registers on its own tab/code, but is stored as 'teacher' so
      // it reuses the existing instructor dashboard (TeacherHomeScreen) —
      // no separate admin dashboard needed. 'accountType' keeps track of
      // which tab was actually used, in case that distinction is needed
      // later (e.g. an admin-only settings screen).
      final firestoreRole = _isStudent ? 'student' : 'teacher';

      await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .set(
        {
          'uid': uid,
          'firstName': _firstNameController.text.trim(),
          'lastName': _lastNameController.text.trim(),
          'fullName':
              '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}',
          'email': _emailController.text.trim().toLowerCase(),
          'role': firestoreRole,
          'accountType': _selectedRole, // 'student' | 'instructor' | 'admin'
          'yearLevel': _isStudent ? _selectedYearLevel : null,
          'createdAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: false),
      );

      await newUser.updateDisplayName(
        '${_firstNameController.text.trim()} ${_lastNameController.text.trim()}',
      );

      newUser = null;
      await FirebaseAuth.instance.signOut();

      if (!mounted) return;

      final roleLabel =
          _isStudent ? 'Student' : (_isAdmin ? 'Admin' : 'Instructor');
      _showSnackbar(
        '$roleLabel account created! Please log in.',
        Colors.green.shade700,
        Icons.check_circle,
      );

      Navigator.pop(context);
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      _showSnackbar(
        _friendlyRegisterError(e.code),
        Colors.red.shade700,
        Icons.error_outline,
      );
    } catch (e) {
      if (newUser != null) {
        try {
          await newUser.delete();
        } catch (_) {}
      }

      if (!mounted) return;

      final errorStr = e.toString();
      final codeMatch =
          RegExp(r'\[firebase_auth/([^\]]+)\]').firstMatch(errorStr) ??
              RegExp(r'firebase_auth/([^\s\]]+)').firstMatch(errorStr);

      final message = codeMatch != null
          ? _friendlyRegisterError(codeMatch.group(1) ?? '')
          : 'Registration failed. Please try again.';

      _showSnackbar(message, Colors.red.shade700, Icons.error_outline);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  void _showSnackbar(String message, Color color, IconData icon) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(icon, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        backgroundColor: color,
        duration: const Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // ── MATCHING DARK NAVY BACKGROUND ──────────────────────────────────
      backgroundColor: const Color(0xFF0D1547),
      appBar: AppBar(
        title: const Text('Create Account'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [
          // ── Layer 1: gradient background ──────────────────────────────
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0D1547), Color(0xFF1A237E), Color(0xFF0D1547)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
          ),

          // ── Layer 2: dot grid overlay (matches login screen) ──────────
          CustomPaint(
            painter: _DotGridPainter(),
            size: Size.infinite,
          ),

          // ── Layer 3: floating criminology text ─────────────────────────
          const Positioned.fill(child: _AnimatedBackground()),

          // ── Layer 4: form content ──────────────────────────────────────
          SafeArea(
            child: Center(
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 24),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        children: [
                          _buildTopBanner(),
                          const SizedBox(height: 20),
                          _buildRoleSelector(),
                          const SizedBox(height: 16),
                          _buildPersonalInfoCard(),
                          const SizedBox(height: 16),
                          _buildTermsAndSubmit(),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopBanner() {
    final title = _isStudent
        ? 'Student Registration'
        : (_isAdmin ? 'Admin Registration' : 'Instructor Registration');
    final icon = _isStudent
        ? Icons.school_rounded
        : (_isAdmin ? Icons.admin_panel_settings_rounded : Icons.person_4_rounded);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1A237E), Color(0xFF3949AB)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 1,
        ),
        boxShadow: [
          BoxShadow(
            color: _brand.withValues(alpha: 0.4),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 40,
            color: Colors.white,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'BS Criminology — BISU Balilihan Campus',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.all(6),
      child: Row(
        children: [
          _roleTab(
              label: 'Student',
              icon: Icons.school_rounded,
              role: 'student'),
          _roleTab(
              label: 'Instructor',
              icon: Icons.person_4_rounded,
              role: 'instructor'),
          _roleTab(
              label: 'Admin',
              icon: Icons.admin_panel_settings_rounded,
              role: 'admin'),
        ],
      ),
    );
  }

  Widget _roleTab({
    required String label,
    required IconData icon,
    required String role,
  }) {
    final isSelected = _selectedRole == role;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() {
          _selectedRole = role;
          _selectedYearLevel = null;
          _accessCodeController.clear();
        }),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? _brand : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: _brand.withValues(alpha: 0.5),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    )
                  ]
                : null,
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.5),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: isSelected
                      ? Colors.white
                      : Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPersonalInfoCard() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(Icons.person_outline, 'Personal Information'),
          const SizedBox(height: 16),

          TextFormField(
            controller: _firstNameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: _inputDecoration(
              label: 'First Name',
              hint: 'e.g. Juan',
              prefixIcon: Icons.badge_outlined,
            ),
            validator: (v) => v == null || v.trim().isEmpty
                ? 'Please enter your first name.'
                : null,
          ),
          const SizedBox(height: 14),

          TextFormField(
            controller: _lastNameController,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.next,
            decoration: _inputDecoration(
              label: 'Last Name',
              hint: 'e.g. Dela Cruz',
              prefixIcon: Icons.badge_outlined,
            ),
            validator: (v) => v == null || v.trim().isEmpty
                ? 'Please enter your last name.'
                : null,
          ),

          if (_isStudent) ...[
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              value: _selectedYearLevel,
              decoration: _inputDecoration(
                label: 'Year Level',
                hint: 'Select year level',
                prefixIcon: Icons.bar_chart_rounded,
              ),
              items: _yearLevels
                  .map((y) => DropdownMenuItem(value: y, child: Text(y)))
                  .toList(),
              onChanged: (val) => setState(() => _selectedYearLevel = val),
              validator: (v) => _isStudent && v == null
                  ? 'Please select your year level.'
                  : null,
            ),
          ],

          // ── Instructor/Admin access code field ─────────────────────────
          // Same field, different label/hint/expected code depending on
          // whether the Admin tab is active (_isAdmin) or not.
          if (!_isStudent) ...[
            const SizedBox(height: 14),
            TextFormField(
              controller: _accessCodeController,
              obscureText: !_isAccessCodeVisible,
              textCapitalization: TextCapitalization.characters,
              textInputAction: TextInputAction.next,
              decoration: _inputDecoration(
                label: _isAdmin ? 'Admin Access Code' : 'Instructor Access Code',
                hint: _isAdmin
                    ? 'Enter the admin code provided by BISU CCJ'
                    : 'Enter the code provided by BISU CCJ',
                prefixIcon: Icons.vpn_key_outlined,
                suffixIcon: IconButton(
                  icon: Icon(
                    _isAccessCodeVisible
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: const Color(0xFF757575),
                  ),
                  onPressed: () => setState(
                      () => _isAccessCodeVisible = !_isAccessCodeVisible),
                ),
              ),
              validator: (v) {
                if (_isStudent) return null;
                if (v == null || v.trim().isEmpty) {
                  return _isAdmin
                      ? 'Please enter the admin access code.'
                      : 'Please enter the instructor access code.';
                }
                if (v.trim() != _expectedAccessCode) {
                  return 'Incorrect access code.';
                }
                return null;
              },
            ),
          ],

          const SizedBox(height: 14),

          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autocorrect: false,
            decoration: _inputDecoration(
              label: 'Email Address',
              hint: 'e.g. user@gmail.com',
              prefixIcon: Icons.email_outlined,
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'Please enter your email address.';
              }
              if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                  .hasMatch(v.trim())) {
                return 'Please enter a valid email address.';
              }
              return null;
            },
          ),
          const SizedBox(height: 14),

          TextFormField(
            controller: _passwordController,
            obscureText: !_isPasswordVisible,
            textInputAction: TextInputAction.next,
            decoration: _inputDecoration(
              label: 'Password',
              hint: 'Minimum 6 characters',
              prefixIcon: Icons.lock_outline,
              suffixIcon: IconButton(
                icon: Icon(
                  _isPasswordVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: const Color(0xFF757575),
                ),
                onPressed: () => setState(
                    () => _isPasswordVisible = !_isPasswordVisible),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) return 'Please create a password.';
              if (v.length < 6) {
                return 'Password must be at least 6 characters.';
              }
              return null;
            },
          ),

          if (_passwordStrength > 0) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _passwordStrength / 3,
                      backgroundColor: Colors.grey.shade200,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(_strengthColor),
                      minHeight: 5,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _strengthLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: _strengthColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],

          const SizedBox(height: 14),

          TextFormField(
            controller: _confirmPasswordController,
            obscureText: !_isConfirmPasswordVisible,
            textInputAction: TextInputAction.done,
            onFieldSubmitted: (_) => _handleRegister(),
            decoration: _inputDecoration(
              label: 'Confirm Password',
              hint: 'Re-enter your password',
              prefixIcon: Icons.lock_reset_outlined,
              suffixIcon: IconButton(
                icon: Icon(
                  _isConfirmPasswordVisible
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  color: const Color(0xFF757575),
                ),
                onPressed: () => setState(() =>
                    _isConfirmPasswordVisible = !_isConfirmPasswordVisible),
              ),
            ),
            validator: (v) {
              if (v == null || v.isEmpty) {
                return 'Please confirm your password.';
              }
              if (v != _passwordController.text) {
                return 'Passwords do not match.';
              }
              return null;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTermsAndSubmit() {
    final submitLabel = _isStudent
        ? 'Register as Student'
        : (_isAdmin ? 'Register as Admin' : 'Register as Instructor');

    return Column(
      children: [
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.2),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Checkbox(
                value: _agreedToTerms,
                activeColor: _brand,
                onChanged: (val) =>
                    setState(() => _agreedToTerms = val ?? false),
              ),
              Expanded(
                child: RichText(
                  text: const TextSpan(
                    text: 'I agree to the ',
                    style: TextStyle(
                        fontSize: 13, color: Color(0xFF616161)),
                    children: [
                      TextSpan(
                        text: 'Terms and Conditions',
                        style: TextStyle(
                          color: _brand,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                      TextSpan(text: ' and '),
                      TextSpan(
                        text: 'Privacy Policy',
                        style: TextStyle(
                          color: _brand,
                          fontWeight: FontWeight.bold,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                      TextSpan(text: ' of BISU Exam Reviewer.')
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _isLoading ? null : _handleRegister,
            icon: _isLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                : const Icon(Icons.how_to_reg_rounded),
            label: Text(
              _isLoading ? 'Creating account…' : submitLabel,
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: _brand,
              foregroundColor: Colors.white,
              disabledBackgroundColor: _brand.withValues(alpha: 0.6),
              disabledForegroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(vertical: 14),
              textStyle: const TextStyle(
                  fontSize: 15, fontWeight: FontWeight.w600),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
              elevation: 6,
              shadowColor: _brand.withValues(alpha: 0.5),
            ),
          ),
        ),
        const SizedBox(height: 12),

        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'Already have an account? ',
              style: TextStyle(color: Colors.white70, fontSize: 14),
            ),
            GestureDetector(
              onTap: () => Navigator.pop(context),
              child: const Text(
                'Sign In',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                  decoration: TextDecoration.underline,
                  decorationColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _sectionTitle(IconData icon, String title) {
    return Row(
      children: [
        Icon(icon, color: _brand, size: 20),
        const SizedBox(width: 8),
        Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: _brand,
          ),
        ),
      ],
    );
  }
}

// ── Dot grid background painter (matches login screen grid lines) ─────────────
class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1;

    const spacing = 40.0;

    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(_DotGridPainter old) => false;
}