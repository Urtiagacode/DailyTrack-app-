import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'python_bridge.dart';



void main() {
  runApp(const FinanceSportApp());
}

class FinanceSportApp extends StatelessWidget {
  const FinanceSportApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Finance + Sport',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        primaryColor: Colors.blue,
        useMaterial3: true,
        textTheme: const TextTheme(
          bodyLarge: TextStyle(color: Colors.black87),
          bodyMedium: TextStyle(color: Colors.black87),
        ),
      ),
      home: const FinanceSportHomePage(),
    );
  }
}

class FinanceSportHomePage extends StatefulWidget {
  const FinanceSportHomePage({super.key});

  @override
  State<FinanceSportHomePage> createState() => _FinanceSportHomePageState();
}

class _FinanceSportHomePageState extends State<FinanceSportHomePage> {
  static const _backendUrl = 'http://127.0.0.1:5000/data';

  final PageController _pageController = PageController(viewportFraction: 0.78);
  int _activeIndex = 0;
  FinanceData? _backendData;
  bool _loading = true;
  String? _error;
  bool _askedInitialBalance = false;
  int _budgetGoal = 0;
  String _budgetGoalName = 'Objectif';
  bool _budgetGoalConfigured = false;
  bool _backendProcessStarted = false;

  @override
  void initState() {
    super.initState();
    _ensureBackendIsRunning();
    _fetchBackendData();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_budgetGoalConfigured && mounted) {
        _promptBudgetGoalIfNeeded();
      }
    });
  }

  Future<void> _ensureBackendIsRunning() async {
    if (_backendProcessStarted || kIsWeb) return;

    final script = File('${Directory.current.path}/../python_backend.py');
    if (!script.existsSync()) return;

    try {
      final executable = Platform.isWindows ? 'py' : 'python3';
      final args = Platform.isWindows ? ['python_backend.py'] : ['python_backend.py'];
      final process = await Process.start(executable, args, workingDirectory: script.parent.path);
      _backendProcessStarted = true;
      process.stdout.transform(utf8.decoder).listen((output) {
        if (output.isNotEmpty) debugPrint(output);
      });
      process.stderr.transform(utf8.decoder).listen((output) {
        if (output.isNotEmpty) debugPrint(output);
      });
    } catch (_) {
      // Ignore and fall back to local mode if the backend cannot be launched automatically.
    }
  }

  Future<void> _fetchBackendData() async {
    await _ensureBackendIsRunning();
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final response = await http.get(Uri.parse(_backendUrl)).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final jsonBody = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _backendData = FinanceData.fromJson(jsonBody);
        });
        return;
      }

      setState(() {
        _error = 'Erreur serveur ${response.statusCode}';
      });
    } catch (e) {
      if (_backendData == null) {
        setState(() {
          _error = 'Impossible de joindre le backend (mode dégradé)';
          _backendData = FinanceData(
            solde: 0,
            historique: [],
            sport: [],
          );
        });
      } else {
        setState(() {
          _error = 'Impossible de joindre le backend, données locales conservées';
        });
      }
    } finally {
      setState(() {
        _loading = false;
      });
    }

    // Prompt for initial balance once after data fetched
    if (!_askedInitialBalance && !_loading) {
      _askedInitialBalance = true;
      if (_backendData == null || (_backendData != null && _backendData!.solde == 0)) {
        // show dialog to ask current account balance
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          final controller = TextEditingController();
          final ok = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Solde actuel du compte'),
              content: TextField(controller: controller, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Entrez le solde actuel (ex: 100)')),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Ignorer')),
                TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK')),
              ],
            ),
          );
          if (ok == true) {
            final v = int.tryParse(controller.text) ?? 0;
            if (v != 0) {
              await _addFinance(v, 'Solde initial');
            }
          }
        });
      }
    }
  }

  Future<void> _promptBudgetGoalIfNeeded() async {
    if (_budgetGoalConfigured || !mounted) return;
    _budgetGoalConfigured = true;

    final nameCtrl = TextEditingController(text: _budgetGoalName);
    final amountCtrl = TextEditingController(text: _budgetGoal > 0 ? _budgetGoal.toString() : '');

    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Définir votre objectif de budget'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nom de l’objectif')),
            TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Montant de l’objectif')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Plus tard')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Enregistrer')),
        ],
      ),
    );

    if (ok == true) {
      final amount = int.tryParse(amountCtrl.text) ?? 0;
      final name = nameCtrl.text.trim();
      setState(() {
        if (amount > 0) {
          _budgetGoal = amount;
        }
        if (name.isNotEmpty) {
          _budgetGoalName = name;
        }
      });
    }
  }

  Future<void> _addFinance(int montant, String raison) async {
    final payload = {'montant': montant, 'raison': raison};
    try {
      final response = await http
          .post(Uri.parse('http://127.0.0.1:5000/finance'), body: jsonEncode(payload), headers: {'Content-Type': 'application/json'}).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final jsonBody = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _backendData = FinanceData.fromJson(jsonBody);
          _error = null;
        });
        return;
      }
    } catch (e) {
      // ignore, fall back to local update
    }
    // fallback: update local state so UI reflects change even without backend
    setState(() {
      final current = _backendData;
      final curSolde = current?.solde ?? 0;
      final curHistorique = current != null ? List<String>.from(current.historique) : <String>[];
      final curSport = current != null ? current.sport.map((s) => {'type': s.type, 'duree': s.duree}).toList() : <Map<String, dynamic>>[];
      curHistorique.add('${montant >= 0 ? '+' : ''}$montant€ - $raison');
      final updated = {'solde': curSolde + montant, 'historique': curHistorique, 'sport': curSport};
      _backendData = FinanceData.fromJson(updated);
      _error = 'Mode dégradé : changement appliqué localement';
    });
    // show feedback and switch to Finances card
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Transaction enregistrée: $montant €')));
    final idx = _cards.indexWhere((c) => c.title == 'Finances');
    if (idx != -1) _pageController.animateToPage(idx, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  Future<void> _addSportSession(String type, int duree) async {
    final payload = {'type': type, 'duree': duree};
    try {
      final response = await http
          .post(Uri.parse('http://127.0.0.1:5000/sport'), body: jsonEncode(payload), headers: {'Content-Type': 'application/json'}).timeout(const Duration(seconds: 8));
      if (response.statusCode == 200) {
        final jsonBody = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _backendData = FinanceData.fromJson(jsonBody);
          _error = null;
        });
        return;
      }
    } catch (e) {
      // ignore, fall back to local update
    }
    setState(() {
      final current = _backendData;
      final curSolde = current?.solde ?? 0;
      final curHistorique = current != null ? List<String>.from(current.historique) : <String>[];
      final curSport = current != null ? current.sport.map((s) => {'type': s.type, 'duree': s.duree}).toList() : <Map<String, dynamic>>[];
      curSport.add({'type': type, 'duree': duree});
      final updated = {'solde': curSolde, 'historique': curHistorique, 'sport': curSport};
      _backendData = FinanceData.fromJson(updated);
      _error = 'Mode dégradé : séance ajoutée localement';
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Séance ajoutée')));
    final idx = _cards.indexWhere((c) => c.title == 'Sport');
    if (idx != -1) _pageController.animateToPage(idx, duration: const Duration(milliseconds: 300), curve: Curves.easeOut);
  }

  List<_CardData> get _cards {
    final solde = _backendData?.solde;
    final sportCount = _backendData?.sport.length ?? 0;
    final totalDuration = _backendData?.sport.fold<int>(0, (sum, item) => sum + item.duree) ?? 0;
    final budgetGoal = _budgetGoal;
    final remaining = solde != null && budgetGoal > 0 ? budgetGoal - solde : null;

    return [
      _CardData(
        title: 'Finances',
        subtitle: 'Contrôlez votre solde et dépenses',
        value: solde != null ? '$solde €' : '--',
        detail: 'Solde actuel',
        accent: const Color(0xFF3366FF),
        icon: Icons.account_balance_wallet,
        label: _backendData != null ? 'Historique ${_backendData!.historique.length} entrée(s)' : 'Chargement...',
      ),
      _CardData(
        title: 'Sport',
        subtitle: 'Ajoutez vos séances',
        value: '$sportCount séances',
        detail: 'Total hebdo',
        accent: const Color(0xFF24C1A3),
        icon: Icons.sports_soccer,
        label: 'Total $totalDuration min',
      ),
      _CardData(
        title: 'Budget',
        subtitle: 'Suivez vos objectifs',
        value: budgetGoal > 0 ? (_budgetGoalName.isNotEmpty ? _budgetGoalName : 'Budget') : 'Définir objectif',
        detail: budgetGoal > 0 ? '$budgetGoal €' : 'Montant à définir',
        accent: const Color(0xFFFF7A50),
        icon: Icons.pie_chart,
        label: budgetGoal > 0
            ? 'Objectif : $_budgetGoalName\n${remaining != null && remaining >= 0 ? (remaining > 0 ? '$remaining € restants' : 'Objectif atteint') : '$budgetGoal €'}'
            : 'Définissez votre objectif de budget',
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 20),
            _buildHeader(),
            if (_loading) const LinearProgressIndicator(minHeight: 3),
            const SizedBox(height: 10),
            _buildCarousel(),
            const SizedBox(height: 26),
            _buildCenterWheel(),
            const SizedBox(height: 22),
            Expanded(child: _buildBottomSheet()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('fait part andoni', style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('Swipez pour changer de vue', style: TextStyle(fontSize: 16, color: Colors.black54)),
            ],
          ),
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: _fetchBackendData,
              child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withAlpha((0.05 * 255).round()),
                borderRadius: BorderRadius.circular(16),
              ),
              padding: const EdgeInsets.all(12),
              child: const Icon(Icons.refresh, color: Colors.black87),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCarousel() {
    return SizedBox(
      height: 210,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PageView.builder(
            controller: _pageController,
            // disable swipe gestures; navigation via arrows
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _cards.length,
            onPageChanged: (index) => setState(() => _activeIndex = index),
            itemBuilder: (context, index) {
              final card = _cards[index];
              final bool active = index == _activeIndex;
              return AnimatedScale(
                scale: active ? 1 : 0.94,
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  child: _DashboardCard(data: card),
                ),
              );
            },
          ),
          Positioned(
            left: 6,
            child: IconButton(
              icon: const Icon(Icons.chevron_left, size: 36),
              color: Colors.black54,
              onPressed: () {
                final prev = _activeIndex > 0 ? _activeIndex - 1 : 0;
                _pageController.animateToPage(prev, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
              },
            ),
          ),
          Positioned(
            right: 6,
            child: IconButton(
              icon: const Icon(Icons.chevron_right, size: 36),
              color: Colors.black54,
              onPressed: () {
                final next = _activeIndex < _cards.length - 1 ? _activeIndex + 1 : _cards.length - 1;
                _pageController.animateToPage(next, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCenterWheel() {
    final selected = _cards[_activeIndex];
    // determine wheel color: for Finances use thresholds; otherwise use card accent
    Color wheelBase = selected.accent;
    if (selected.title == 'Finances' && _backendData != null) {
      final solde = _backendData!.solde;
      final ratio = _budgetGoal == 0 ? 0.0 : solde / _budgetGoal;
      if (ratio >= 0.5) {
        wheelBase = Colors.blue;
      } else if (solde >= 50) {
        wheelBase = Colors.orange;
      } else {
        wheelBase = Colors.redAccent;
      }
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Stack(
        alignment: Alignment.center,
        children: [
          GestureDetector(
            onTap: () {
              // tap wheel to cycle to next card
              final next = (_activeIndex + 1) % _cards.length;
              _pageController.animateToPage(next, duration: const Duration(milliseconds: 320), curve: Curves.easeOut);
            },
            child: Container(
            width: 220,
            height: 220,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [wheelBase.withAlpha((0.24 * 255).round()), Colors.white],
                center: const Alignment(-0.2, -0.3),
                radius: 0.9,
              ),
              boxShadow: [
                BoxShadow(color: wheelBase.withAlpha((0.12 * 255).round()), blurRadius: 32, spreadRadius: 5),
              ],
            ),
            ),
          ),
          Container(
            width: 170,
            height: 170,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white,
              border: Border.all(color: Colors.black12, width: 1.6),
              boxShadow: const [BoxShadow(color: Color(0x11000000), blurRadius: 20, offset: Offset(0, 12))],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(selected.icon, size: 40, color: selected.accent),
                const SizedBox(height: 14),
                Text(selected.value, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(selected.title, style: const TextStyle(color: Colors.black54)),
                if (selected.title == 'Budget') ...[
                  const SizedBox(height: 6),
                  Text(selected.detail, style: const TextStyle(color: Colors.black87, fontWeight: FontWeight.w700, fontSize: 14)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomSheet() {
    final selected = _cards[_activeIndex];
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFFF8F9FB),
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
            Container(
              width: 64,
              height: 6,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(color: Colors.black12, borderRadius: BorderRadius.circular(10)),
            ),
            const SizedBox.shrink(),
            const SizedBox(height: 18),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
              ),
            if (selected.title == 'Finances') ...[
              _infoTile('Solde disponible', selected.detail, selected.accent),
              const SizedBox(height: 12),
              // Balance graph (spent vs remaining)
              _financeBalanceGraph(_backendData),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Ajouter transaction'),
                    onPressed: () async {
                      final montantCtrl = TextEditingController();
                      final raisonCtrl = TextEditingController();
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Ajouter transaction'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(controller: montantCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Montant')), 
                              TextField(controller: raisonCtrl, decoration: const InputDecoration(labelText: 'Raison')),
                            ],
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ajouter')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        final montant = int.tryParse(montantCtrl.text) ?? 0;
                        await _addFinance(montant, raisonCtrl.text);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sectionTitle('Historique financier'),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_backendData != null && _backendData!.historique.isNotEmpty)
                ..._backendData!.historique.asMap().entries.map((e) => _historyCard(e.value, e.key)).toList()
              else
                const Text('Aucun historique disponible.', style: TextStyle(color: Colors.black54)),
            ] else if (selected.title == 'Sport') ...[
              _infoTile('Séances cette semaine', selected.detail, selected.accent),
              const SizedBox(height: 12),
              Row(
                children: [
                  ElevatedButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Ajouter séance'),
                    onPressed: () async {
                      final typeCtrl = TextEditingController();
                      final dureeCtrl = TextEditingController();
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Ajouter séance'),
                          content: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              TextField(controller: typeCtrl, decoration: const InputDecoration(labelText: 'Type (ex: Course)')),
                              TextField(controller: dureeCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Durée (min)')),
                            ],
                          ),
                          actions: [
                            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                            TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ajouter')),
                          ],
                        ),
                      );
                      if (ok == true) {
                        final duree = int.tryParse(dureeCtrl.text) ?? 0;
                        await _addSportSession(typeCtrl.text, duree);
                      }
                    },
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _sectionTitle('Sessions sportives'),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else if (_backendData != null && _backendData!.sport.isNotEmpty)
                ..._backendData!.sport.asMap().entries.map((e) => _sessionCard(e.value, e.key)).toList()
              else
                const Text('Aucune séance enregistrée.', style: TextStyle(color: Colors.black54)),
            ] else ...[
              // Budget: no generic objective tile here; controls shown below
              const SizedBox.shrink(),
              const SizedBox(height: 16),
              _sectionTitle('Suivi budgétaire'),
              _budgetGoalCard(),
            ],
            const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _financeBalanceGraph(FinanceData? data) {
    final remaining = data?.solde ?? 0;
    // parse historique entries to sum negative amounts (withdrawals)
    int lost = 0;
    if (data != null && data.historique.isNotEmpty) {
      for (final entry in data.historique) {
        // expect entries like "+100€ - raison" or "-50€ - raison"
        final match = RegExp(r'^([+-]?\d+)').firstMatch(entry.trim());
        if (match != null) {
          final v = int.tryParse(match.group(1) ?? '0') ?? 0;
          if (v < 0) lost += v.abs();
        }
      }
    }

    final total = (lost + (remaining > 0 ? remaining : 0));
    if (total == 0) {
      return Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
        child: const Center(child: Text('Pas d\'historique')), 
      );
    }

    final lostFlex = lost;
    final remFlex = remaining > 0 ? remaining : 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Répartition dépenses / solde', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Container(
          height: 18,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: Colors.grey.shade200),
          child: Row(
            children: [
              if (lostFlex > 0)
                Flexible(flex: lostFlex, child: Container(decoration: BoxDecoration(color: Colors.redAccent, borderRadius: const BorderRadius.only(topLeft: Radius.circular(12), bottomLeft: Radius.circular(12))))),
              if (remFlex > 0)
                Flexible(flex: remFlex, child: Container(decoration: BoxDecoration(color: Colors.blueAccent, borderRadius: BorderRadius.horizontal(right: Radius.circular(12))))),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Dépensé: ${lost} €', style: const TextStyle(color: Colors.redAccent)),
            Text('Solde: ${remaining} €', style: const TextStyle(color: Colors.blueAccent)),
          ],
        ),
      ],
    );
  }

  Widget _historyCard(String text, int index) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(text, style: const TextStyle(color: Colors.black87))),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Supprimer la transaction'),
                  content: const Text('Confirmez-vous la suppression de cette transaction ?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
                  ],
                ),
              );
              if (confirm == true) {
                _removeFinanceEntry(index);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _infoTile(String label, String value, Color accent) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 18, offset: Offset(0, 10))],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(label, style: const TextStyle(color: Colors.black54)),
            ],
          ),
          const SizedBox.shrink(),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
    );
  }

  void _removeFinanceEntry(int index) {
    setState(() {
      final current = _backendData;
      if (current == null) return;
      final curHistorique = List<String>.from(current.historique);
      if (index < 0 || index >= curHistorique.length) return;
      final entry = curHistorique.removeAt(index);
      final match = RegExp(r'^([+-]?\d+)').firstMatch(entry.trim());
      final amount = match != null ? int.tryParse(match.group(1) ?? '0') ?? 0 : 0;
      final curSolde = current.solde;
      final newSolde = curSolde - amount;
      final curSport = current.sport.map((s) => {'type': s.type, 'duree': s.duree}).toList();
      final updated = {'solde': newSolde, 'historique': curHistorique, 'sport': curSport};
      _backendData = FinanceData.fromJson(updated);
      _error = 'Mode dégradé : transaction supprimée localement';
    });
  }

  void _removeSportSession(int index) {
    setState(() {
      final current = _backendData;
      if (current == null) return;
      final curSport = current.sport.map((s) => {'type': s.type, 'duree': s.duree}).toList();
      if (index < 0 || index >= curSport.length) return;
      curSport.removeAt(index);
      final curHistorique = List<String>.from(current.historique);
      final updated = {'solde': current.solde, 'historique': curHistorique, 'sport': curSport};
      _backendData = FinanceData.fromJson(updated);
      _error = 'Mode dégradé : séance supprimée localement';
    });
  }

  

  Widget _sessionCard(SportSession session, int index) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.black12),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text('${session.type} — ${session.duree} min', style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
          IconButton(
            icon: const Icon(Icons.delete, color: Colors.redAccent),
            onPressed: () async {
              final confirm = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Supprimer la séance'),
                  content: const Text('Confirmez-vous la suppression de cette séance ?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Supprimer')),
                  ],
                ),
              );
              if (confirm == true) {
                _removeSportSession(index);
              }
            },
          ),
        ],
      ),
    );
  }

  Widget _budgetGoalCard() {
    final solde = _backendData?.solde ?? 0;
    final goal = _budgetGoal;
    final progress = goal == 0 ? 0.0 : solde / goal;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        boxShadow: const [BoxShadow(color: Color(0x0F000000), blurRadius: 18, offset: Offset(0, 10))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Progrès vers l’objectif', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: Colors.orange.shade50,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.orange.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_budgetGoalName, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(_budgetGoal > 0 ? '$_budgetGoal €' : 'Montant à définir', style: const TextStyle(color: Colors.black87)),
              ],
            ),
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: LinearProgressIndicator(
              value: progress.clamp(0.0, 1.0),
              color: Colors.blue,
              backgroundColor: Colors.blue.shade50,
              minHeight: 12,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(goal > 0 ? '$solde € sur $goal €' : 'Définissez un objectif', style: const TextStyle(color: Colors.black54)),
              Text(goal > 0 ? '${(progress * 100).clamp(0.0, 100.0).toStringAsFixed(0)} %' : '0 %', style: const TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              ElevatedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('Ajouter somme'),
                onPressed: () async {
                  final ctrl = TextEditingController();
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Ajouter somme'),
                      content: TextField(controller: ctrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Montant')),
                      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')), TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Ajouter'))],
                    ),
                  );
                  if (ok == true) {
                    final v = int.tryParse(ctrl.text) ?? 0;
                    if (v != 0) await _addFinance(v, 'Ajout budget');
                  }
                },
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.remove),
                label: const Text('Enlever somme'),
                onPressed: () async {
                  final ctrl = TextEditingController();
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Enlever somme'),
                      content: TextField(controller: ctrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Montant')),
                      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')), TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Retirer'))],
                    ),
                  );
                  if (ok == true) {
                    final v = int.tryParse(ctrl.text) ?? 0;
                    if (v != 0) await _addFinance(-v, 'Retrait budget');
                  }
                },
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                icon: const Icon(Icons.flag),
                label: const Text('Définir objectif'),
                onPressed: () async {
                  final nameCtrl = TextEditingController(text: _budgetGoalName);
                  final amountCtrl = TextEditingController(text: _budgetGoal.toString());
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Nouvel objectif'),
                      content: Column(mainAxisSize: MainAxisSize.min, children: [
                        TextField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Nom de l\'objectif')),
                        TextField(controller: amountCtrl, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Montant objectif')),
                      ]),
                      actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Annuler')), TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('OK'))],
                    ),
                  );
                  if (ok == true) {
                    final v = int.tryParse(amountCtrl.text) ?? _budgetGoal;
                    setState(() {
                      _budgetGoal = v;
                      _budgetGoalName = nameCtrl.text.isNotEmpty ? nameCtrl.text : _budgetGoalName;
                    });
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardData {
  final String title;
  final String subtitle;
  final String value;
  final String detail;
  final Color accent;
  final IconData icon;
  final String label;

  const _CardData({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.detail,
    required this.accent,
    required this.icon,
    required this.label,
  });
}

  

class _DashboardCard extends StatelessWidget {
  const _DashboardCard({required this.data});

  final _CardData data;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        color: Colors.white,
        boxShadow: const [
          BoxShadow(color: Color(0x11000000), blurRadius: 28, offset: Offset(0, 18)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  height: 46,
                  width: 46,
                  decoration: BoxDecoration(
                    color: data.accent,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(data.icon, color: Colors.white, size: 26),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(data.title, style: const TextStyle(color: Colors.black87, fontSize: 20, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      Text(data.subtitle, style: const TextStyle(color: Colors.black54)),
                    ],
                  ),
                ),
              ],
            ),
            // Use a SizedBox instead of Spacer so the card's content
            // remains bounded and the large value text can shrink.
            const SizedBox(height: 8),
            Flexible(
              child: Text(
                data.value,
                style: const TextStyle(color: Colors.black87, fontSize: 28, fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: data.title == 'Budget' ? Colors.orange.shade50 : data.accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: data.title == 'Budget' ? Colors.orange.shade200 : data.accent.withOpacity(0.25)),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Text(
                data.label,
                style: TextStyle(
                  color: data.title == 'Budget' ? Colors.orange.shade800 : data.accent,
                  fontWeight: FontWeight.w700,
                  height: 1.3,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
