import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'register_screen.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isPasswordVisible = false;
  bool _isLoading = false;
  bool _rememberMe = false;
  String _selectedRole = 'student';

  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;
  late Animation<Offset> _slideAnimation;

  static const Color _brand = Color(0xFF1A237E);

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeIn),
    );
    _slideAnimation = Tween<Offset>(
      begin: const Offset(0, 0.2),
      end: Offset.zero,
    ).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeOut),
    );
    _animationController.forward();
  }

  @override
  void dispose() {
    _animationController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _isStudent => _selectedRole == 'student';
  bool get _isAdmin => _selectedRole == 'admin';

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

  String _friendlyError(String code) {
    switch (code) {
      case 'user-not-found':
        return 'No account found with this email. Please register first.';
      case 'wrong-password':
        return 'Incorrect password. Please try again.';
      case 'invalid-email':
        return 'The email address is not valid.';
      case 'user-disabled':
        return 'This account has been disabled. Contact support.';
      case 'too-many-requests':
        return 'Too many failed attempts. Please try again later.';
      case 'invalid-credential':
        return 'Invalid email or password. Please try again.';
      case 'network-request-failed':
      case 'channel-error':
        return 'Network error. Please check your internet connection.';
      default:
        return 'Login failed ($code). Please check your credentials and try again.';
    }
  }

  void _showErrorSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        backgroundColor: Colors.red.shade700,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showInfoSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.info_outline, color: Colors.white),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 13)),
            ),
          ],
        ),
        backgroundColor: Colors.green.shade700,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    try {
      await FirebaseAuth.instance.setPersistence(
        _rememberMe ? Persistence.LOCAL : Persistence.SESSION,
      );

      final credential = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      final uid = credential.user!.uid;

      final doc = await FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .get();

      if (!mounted) return;

      if (!doc.exists) {
        await FirebaseAuth.instance.signOut();
        _showErrorSnackbar('Account data not found. Please register again.');
        return;
      }

      final storedRole = doc.data()?['role'] ?? '';
      // Instructor and Admin both register with role: 'teacher' (they share
      // the same dashboard) — 'accountType' is what actually distinguishes
      // them, and is only used here for the friendlier mismatch message.
      final storedAccountType = doc.data()?['accountType'] as String?;

      // Student tab expects 'student'; both Instructor and Admin tabs expect
      // 'teacher', since both roles share the same stored role value.
      final expectedRole = _isStudent ? 'student' : 'teacher';

      if (storedRole != expectedRole) {
        await FirebaseAuth.instance.signOut();
        final correctLabel = storedRole == 'teacher'
            ? (storedAccountType == 'admin' ? 'Admin' : 'Instructor')
            : 'Student';
        _showErrorSnackbar(
          'This account is registered as $correctLabel. '
          'Please select the $correctLabel tab and try again.',
        );
        return;
      }

      if (!mounted) return;

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const HomeScreen()),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      _showErrorSnackbar(_friendlyError(e.code));
    } catch (e) {
      if (!mounted) return;
      final errorStr = e.toString();
      final codeMatch =
          RegExp(r'\[firebase_auth/([^\]]+)\]').firstMatch(errorStr) ??
              RegExp(r'firebase_auth/([^\s\]]+)').firstMatch(errorStr);
      if (codeMatch != null) {
        _showErrorSnackbar(_friendlyError(codeMatch.group(1) ?? ''));
      } else {
        _showErrorSnackbar(
            'Login failed. Please check your credentials and try again.');
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleForgotPassword() async {
    final email = _emailController.text.trim();

    if (email.isEmpty ||
        !RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email)) {
      _showErrorSnackbar(
          'Please enter your email address above, then tap Forgot Password.');
      return;
    }

    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      _showInfoSnackbar('Password reset email sent to $email. Check your inbox.');
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      _showErrorSnackbar(_friendlyError(e.code));
    } catch (_) {
      if (!mounted) return;
      _showErrorSnackbar('Could not send reset email. Please try again.');
    }
  }

  void _navigateToRegister() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RegisterScreen(initialRole: _selectedRole),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // Layer 1: Dark navy base
          Container(color: const Color(0xFF0D1B4E)),

          // Layer 2: Subtle grid lines
          CustomPaint(
            size: Size.infinite,
            painter: _GridPainter(),
          ),

          // Layer 3: The actual login UI
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 480),
                  child: FadeTransition(
                    opacity: _fadeAnimation,
                    child: SlideTransition(
                      position: _slideAnimation,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _buildHeader(),
                          const SizedBox(height: 28),
                          _buildRoleSelector(),
                          const SizedBox(height: 20),
                          _buildLoginCard(),
                          const SizedBox(height: 24),
                          _buildRegisterLink(),
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

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 90,
          height: 90,
          decoration: BoxDecoration(
            color: const Color(0xFF1A237E),
            borderRadius: BorderRadius.circular(22),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.2),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.menu_book_rounded,
              size: 52, color: Colors.white),
        ),
        const SizedBox(height: 16),
        const Text(
          'BISU Exam Reviewer',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.bold,
            color: Colors.white,
            letterSpacing: 0.5,
            shadows: [
              Shadow(
                color: Colors.black45,
                blurRadius: 8,
                offset: Offset(0, 2),
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Criminology — Balilihan Campus',
          style: TextStyle(
            fontSize: 13,
            color: Colors.white.withValues(alpha: 0.6),
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildRoleSelector() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.12),
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
        onTap: () => setState(() => _selectedRole = role),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOut,
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? _brand : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
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

  Widget _buildLoginCard() {
    final roleTitle =
        _isStudent ? 'Student' : (_isAdmin ? 'Admin' : 'Instructor');
    final roleIcon = _isStudent
        ? Icons.school_rounded
        : (_isAdmin ? Icons.admin_panel_settings_rounded : Icons.person_4_rounded);
    final roleSubtitle = _isStudent
        ? 'Access your review modules and quizzes'
        : (_isAdmin
            ? 'Manage the platform and monitor all activity'
            : 'Manage review content and monitor students');

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.4),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    roleIcon,
                    color: _brand,
                    size: 22,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$roleTitle Sign In',
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _brand,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                roleSubtitle,
                style: const TextStyle(
                    fontSize: 13, color: Color(0xFF9E9E9E)),
              ),
              const SizedBox(height: 24),

              // Email
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
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your email address.';
                  }
                  if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
                      .hasMatch(value.trim())) {
                    return 'Please enter a valid email address.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Password
              TextFormField(
                controller: _passwordController,
                obscureText: !_isPasswordVisible,
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _handleLogin(),
                decoration: _inputDecoration(
                  label: 'Password',
                  hint: 'Enter your password',
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
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Please enter your password.';
                  }
                  if (value.length < 6) {
                    return 'Password must be at least 6 characters.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 8),

              // Remember me + Forgot password
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: _rememberMe,
                        activeColor: _brand,
                        onChanged: (val) =>
                            setState(() => _rememberMe = val ?? false),
                      ),
                      const Text('Remember me',
                          style: TextStyle(
                              fontSize: 13, color: Color(0xFF616161))),
                    ],
                  ),
                  TextButton(
                    onPressed: _handleForgotPassword,
                    child: const Text(
                      'Forgot Password?',
                      style: TextStyle(
                          fontSize: 13,
                          color: _brand,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Sign In button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isLoading ? null : _handleLogin,
                  icon: _isLoading
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Icon(Icons.login_rounded),
                  label: Text(
                    _isLoading ? 'Signing in…' : 'Sign In as $roleTitle',
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
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRegisterLink() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          "Don't have an account? ",
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.7),
            fontSize: 14,
          ),
        ),
        GestureDetector(
          onTap: _navigateToRegister,
          child: const Text(
            'Register',
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
    );
  }
}

// ── Grid painter for the notebook-style background lines ──────────────────
class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x0FFFFFFF) // ~6% white
      ..strokeWidth = 0.8;

    // Horizontal lines (like ruled paper)
    const spacing = 40.0;
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }

    // Vertical lines (faint)
    paint.color = const Color(0x07FFFFFF); // ~4% white
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }

    // Red margin line (like a notebook)
    final marginPaint = Paint()
      ..color = const Color(0x18FF6B6B)
      ..strokeWidth = 1.5;
    canvas.drawLine(
      const Offset(48, 0),
      Offset(48, size.height),
      marginPaint,
    );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}