import 'package:flutter/material.dart';
import 'login_screen.dart';

class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with TickerProviderStateMixin {
  late final AnimationController _tickerController;
  final ScrollController _tickerScroll = ScrollController();

  late final AnimationController _fadeController;
  late final List<Animation<double>> _fadeAnims;
  late final List<Animation<Offset>> _slideAnims;

  static const _navy  = Color(0xFF0D1B4B);
  static const _brand = Color(0xFF3D4FC5);
  static const _accent = Color(0xFFA8A0F0);
  // Muted warm gold used sparingly for the formal letterhead accents —
  // reads as "official seal" rather than "app UI".
  static const _seal = Color(0xFFC9A24B);

  static const _subjects = [
    'Criminal Law', 'Criminalistics', 'Penology',
    'Ethics', 'Evidence', 'Forensic Chemistry', 'Police Organization',
  ];

  static const _tickerItems = [
    'Criminal Law', 'Evidence', 'Criminalistics', 'Penology', 'Ethics',
    'Forensic Chemistry', 'Ballistics', 'Police Organization',
    'Criminal Sociology', 'Victimology', 'R.A. 6975', 'R.A. 9708',
    'P.D. 1606', 'B.P. 881', 'R.A. 10591', 'Art. 11 RPC', 'Art. 12 RPC',
  ];

  @override
  void initState() {
    super.initState();

    _tickerController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 32),
    )..repeat();

    _tickerController.addListener(() {
      if (_tickerScroll.hasClients) {
        final max = _tickerScroll.position.maxScrollExtent;
        _tickerScroll.jumpTo(_tickerController.value * max);
      }
    });

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();

    // Indices 0–5 are the original stagger (logo, badge, title, subtitle,
    // chips, button). Indices 6–7 are the formal letterhead block
    // (Republic/University/College line, then campus address line)
    // inserted right after the logo — kept at the end of this list so the
    // existing animated(...) calls below don't need to change their index
    // arguments.
    final delays = [0.0, 0.12, 0.22, 0.32, 0.42, 0.54, 0.06, 0.09];
    _fadeAnims = delays.map((d) {
      return Tween<double>(begin: 0, end: 1).animate(
        CurvedAnimation(
          parent: _fadeController,
          curve: Interval(d, d + 0.4, curve: Curves.easeOut),
        ),
      );
    }).toList();

    _slideAnims = delays.map((d) {
      return Tween<Offset>(
        begin: const Offset(0, -0.25),
        end: Offset.zero,
      ).animate(
        CurvedAnimation(
          parent: _fadeController,
          curve: Interval(d, d + 0.4, curve: Curves.easeOut),
        ),
      );
    }).toList();
  }

  @override
  void dispose() {
    _tickerController.dispose();
    _tickerScroll.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  Widget _animated(int index, Widget child) {
    return FadeTransition(
      opacity: _fadeAnims[index],
      child: SlideTransition(position: _slideAnims[index], child: child),
    );
  }

  @override
  Widget build(BuildContext context) {
    final doubled = [..._tickerItems, ..._tickerItems];

    // ── Responsive helpers ──────────────────────────────────────
    final screenWidth  = MediaQuery.of(context).size.width;
    final screenHeight = MediaQuery.of(context).size.height;

    // Breakpoints
    final isTablet  = screenWidth >= 600;
    final isDesktop = screenWidth >= 1024;

    // Responsive values
    final double maxContentWidth = isDesktop ? 680 : isTablet ? 560 : double.infinity;
    final double logoSize        = isTablet ? 100 : 80;
    final double logoIconSize    = isTablet ? 46  : 36;
    final double logoRadius      = isTablet ? 28  : 20;
    final double titleFontSize   = isDesktop ? 48 : isTablet ? 42 : 36;
    final double subtitleSize    = isTablet ? 15  : 13;
    final double chipFontSize    = isTablet ? 13  : 12;
    final double buttonFontSize  = isTablet ? 18  : 16;
    final double buttonPadV      = isTablet ? 20  : 16;
    final double hPadding        = isDesktop ? 48 : isTablet ? 36 : 28;
    final double vPadding        = screenHeight * 0.04;
    final double spacingMd       = isTablet ? 28  : 22;
    final double spacingSm       = isTablet ? 14  : 10;
    final double spacingLg       = isTablet ? 44  : 36;

    // Formal letterhead sizing.
    final double republicFontSize  = isTablet ? 12  : 11;
    final double universityFontSize = isDesktop ? 24 : isTablet ? 22 : 19;
    final double collegeFontSize   = isTablet ? 15  : 13;
    final double addressFontSize   = isTablet ? 12.5 : 11.5;
    final double letterheadRuleW   = isTablet ? 120 : 90;

    return Scaffold(
      backgroundColor: _navy,
      body: Stack(
        children: [
          // ── Grid background ───────────────────────────────────
          Positioned.fill(child: CustomPaint(painter: _GridPainter())),

          // ── Glow orb ─────────────────────────────────────────
          Positioned(
            top: -150, left: 0, right: 0,
            child: Center(
              child: Container(
                width: isTablet ? 680 : 520,
                height: isTablet ? 680 : 520,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(colors: [
                    Color(0x2E534AB7),
                    Colors.transparent,
                  ]),
                ),
              ),
            ),
          ),

          SafeArea(
            child: Column(
              children: [
                // ── Ticker ──────────────────────────────────────
                Container(
                  height: isTablet ? 40 : 36,
                  decoration: const BoxDecoration(
                    color: Color(0x0AFFFFFF),
                    border: Border(
                      bottom: BorderSide(color: Color(0x12FFFFFF)),
                    ),
                  ),
                  child: ListView.builder(
                    controller: _tickerScroll,
                    scrollDirection: Axis.horizontal,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: doubled.length,
                    itemBuilder: (_, i) => Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: isTablet ? 10 : 8,
                        vertical: isTablet ? 11 : 9,
                      ),
                      child: Row(children: [
                        Text(
                          doubled[i],
                          style: TextStyle(
                            fontSize: isTablet ? 12 : 11,
                            color: const Color(0x59FFFFFF),
                            letterSpacing: 1.1,
                          ),
                        ),
                        const SizedBox(width: 6),
                        const Text('·',
                            style: TextStyle(
                                color: Color(0x40FFFFFF), fontSize: 11)),
                      ]),
                    ),
                  ),
                ),

                // ── Main content ────────────────────────────────
                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: maxContentWidth),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.symmetric(
                          horizontal: hPadding,
                          vertical: vPadding,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Logo
                            _animated(
                              0,
                              Container(
                                width: logoSize,
                                height: logoSize,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      Color(0xFF2A3A8C),
                                      Color(0xFF3D4FC5),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(logoRadius),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.15),
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x59534AB7),
                                      blurRadius: 32,
                                      offset: Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Icons.menu_book_rounded,
                                  color: Colors.white,
                                  size: logoIconSize,
                                ),
                              ),
                            ),
                            SizedBox(height: spacingSm + 6),

                            // ── Formal letterhead block ─────────────────
                            // Republic → University → thin rule → College
                            // → campus address. Mirrors the layout used on
                            // official PH state-university letterheads.
                            _animated(
                              6,
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    'REPUBLIC OF THE PHILIPPINES',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: _seal,
                                      fontSize: republicFontSize,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 2.2,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    'Bohol Island State University',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: universityFontSize,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 10),
                            _animated(
                              7,
                              Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // hairline divider — the "letterhead rule"
                                  Container(
                                    width: letterheadRuleW,
                                    height: 1,
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        colors: [
                                          Colors.transparent,
                                          _seal.withValues(alpha: 0.65),
                                          Colors.transparent,
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  Text(
                                    'College of Criminal Justice',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: const Color(0xE6FFFFFF),
                                      fontSize: collegeFontSize,
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: 0.6,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.location_on_rounded,
                                        size: addressFontSize + 2,
                                        color: const Color(0x8CFFFFFF),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Magsija, Balilihan, Bohol',
                                        style: TextStyle(
                                          color: const Color(0x8CFFFFFF),
                                          fontSize: addressFontSize,
                                          letterSpacing: 0.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                            SizedBox(height: spacingMd),

                            SizedBox(height: spacingMd),

                            // Title
                            _animated(
                              2,
                              RichText(
                                textAlign: TextAlign.center,
                                text: TextSpan(
                                  style: TextStyle(
                                    fontSize: titleFontSize,
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white,
                                    height: 1.15,
                                  ),
                                  children: const [
                                    TextSpan(text: 'Welcome, '),
                                    TextSpan(
                                      text: 'Reviewers!',
                                      style: TextStyle(color: _accent),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            SizedBox(height: spacingSm),

                            // Subtitle
                            _animated(
                              3,
                              Text(
                                'Bohol Island State University — BISU Exam Reviewer',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: const Color(0x73FFFFFF),
                                  fontSize: subtitleSize,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                            SizedBox(height: spacingMd),

                            // Subject chips
                            _animated(
                              4,
                              Wrap(
                                spacing: isTablet ? 10 : 8,
                                runSpacing: isTablet ? 10 : 8,
                                alignment: WrapAlignment.center,
                                children: _subjects.map((s) {
                                  return Container(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: isTablet ? 18 : 14,
                                      vertical: isTablet ? 9 : 7,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(0x10FFFFFF),
                                      border: Border.all(
                                          color: const Color(0x1AFFFFFF)),
                                      borderRadius:
                                          BorderRadius.circular(100),
                                    ),
                                    child: Text(
                                      s,
                                      style: TextStyle(
                                        color: const Color(0x99FFFFFF),
                                        fontSize: chipFontSize,
                                        letterSpacing: 0.4,
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                            SizedBox(height: spacingLg),

                            // Get Started button
                            _animated(
                              5,
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: () {
                                    Navigator.pushReplacement(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => const LoginScreen(),
                                      ),
                                    );
                                  },
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _brand,
                                    foregroundColor: Colors.white,
                                    padding: EdgeInsets.symmetric(
                                        vertical: buttonPadV),
                                    shape: RoundedRectangleBorder(
                                      borderRadius:
                                          BorderRadius.circular(isTablet ? 16 : 12),
                                    ),
                                    elevation: 10,
                                    shadowColor: const Color(0x663D4FC5),
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      Text(
                                        'Get Started',
                                        style: TextStyle(
                                          fontSize: buttonFontSize,
                                          fontWeight: FontWeight.w600,
                                          letterSpacing: 0.6,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Icon(Icons.arrow_forward_rounded,
                                          size: isTablet ? 22 : 20),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Bottom accent bar ─────────────────────────────────
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: Container(
              height: isTablet ? 5 : 4,
              decoration: const BoxDecoration(
                gradient: LinearGradient(colors: [
                  Color(0xFF3D4FC5),
                  Color(0xFF7C74E0),
                  Color(0xFF3D4FC5),
                ]),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0x08FFFFFF)
      ..strokeWidth = 1;

    const spacing = 48.0;
    for (double x = 0; x < size.width; x += spacing) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += spacing) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}