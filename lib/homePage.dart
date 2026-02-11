import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:qr_code_scanner/qr_code_scanner.dart';
import 'package:permission_handler/permission_handler.dart';
import 'dart:io'; // Platform kontrolü için eklendi
import 'dart:async'; // StreamSubscription için
import 'main.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription? _userSubscription;
  StreamSubscription? _transactionSubscription;

  double _balance = 0;
  int _points = 0;
  int _recycledItems = 0;
  final List<RecycleTransaction> _transactions = [];

  @override
  void initState() {
    super.initState();
    _listenToUserData();
    _listenToTransactions();
  }

  @override
  void dispose() {
    _userSubscription?.cancel();
    _transactionSubscription?.cancel();
    super.dispose();
  }

  void _listenToUserData() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _userSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .snapshots()
        .listen((doc) {
      if (doc.exists && mounted) {
        setState(() {
          _balance = (doc['balance'] ?? 0).toDouble();
          _points = (doc['points'] ?? 0).toInt();
          _recycledItems = (doc['recycledItems'] ?? 0).toInt();
        });
      }
    }, onError: (e) {
      debugPrint("Kullanıcı verisi dinleme hatası: $e");
    });
  }

  void _listenToTransactions() {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    _transactionSubscription = FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('transactions')
        .orderBy('createdAt', descending: true)
        .limit(5)
        .snapshots()
        .listen((snapshot) {
      if (mounted) {
        setState(() {
          _transactions.clear();
          for (var doc in snapshot.docs) {
            final data = doc.data();
            final type = data['type'] ?? 'Bilinmeyen';
            final amount = (data['amount'] ?? 0).toDouble();
            final createdAt = data['createdAt'] as Timestamp?;

            _transactions.add(RecycleTransaction(
              type,
              amount,
              createdAt?.toDate() ?? DateTime.now(),
              _getIconForType(type),
            ));
          }
        });
      }
    }, onError: (e) {
      debugPrint("İşlem geçmişi dinleme hatası: $e");
    });
  }

  //burada Qr ayarlama işlemi yapılmaktadır.
  void _handleQrResult(String rawQrCode) async {
    debugPrint("GELEN QR KOD: $rawQrCode");

    // 1. Machine ID Temizleme (URL veya boşluk varsa temizle)
    String machineId = rawQrCode;
    if (machineId.contains('/')) {
      machineId = machineId.split('/').last;
    }
    machineId = machineId.trim();

    debugPrint("TEMİZLENMİŞ MACHINE ID: $machineId");

    if (machineId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Geçersiz QR Kod!")),
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Oturum açmış kullanıcı bulunamadı!")),
      );
      return;
    }

    // 2. Kullanıcıya "Bağlanıyor..." de
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(color: Colors.white),
      ),
    );

    try {
      // 3. Makine ile el sıkışma (Handshake)
      // Zaman aşımı ekleyerek ekranın kararıp kalmasını önlüyoruz
      await FirebaseFirestore.instance
          .collection('machines')
          .doc(machineId)
          .set({
        'activeUser': {
          'uid': user.uid,
          'email': user.email,
          'timestamp': FieldValue.serverTimestamp(),
        },
        'status': 'active',
      }, SetOptions(merge: true)).timeout(const Duration(seconds: 10), onTimeout: () {
        throw TimeoutException("Sunucuya bağlanılamadı. Lütfen internetinizi kontrol edin.");
      });

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop(); // Diyaloğu güvenli kapat

      // 4. Başarılı olduğunu söyle
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: const Color(0xFF455A64),
          title: const Text("Makineye Bağlandı! ✅",
              style: TextStyle(color: Colors.white)),
          content: Text(
            "Makine ID: $machineId\n\nLütfen atığınızı **$machineId** numaralı makineye atın.\n\nPuanınız otomatik olarak hesabınıza yansıyacak.",
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Tamam", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      try {
        Navigator.of(context, rootNavigator: true).pop();
      } catch (_) {}
      
      String errorMsg = e.toString();
      if (errorMsg.contains("permission-denied")) {
        errorMsg = "Firebase Firestore yetki hatası! Firestore kurallarınızı kontrol edin.";
      }
      
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text("Hata"),
          content: Text("Makineye bağlanılamadı:\n$e"),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Tamam"),
            ),
          ],
        ),
      );
    }
  }

  void _recycleItem(String type, double amount) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    // Firestore'da atomik güncelleme yapıyoruz (FieldValue.increment)
    // Stream dinleyicisi (listener) sayesinde UI otomatik güncellenecek.
    
    try {
      // 1. Kullanıcı bakiyesini güncelle
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'balance': FieldValue.increment(amount),
        'points': FieldValue.increment((amount * 10).toInt()),
        'recycledItems': FieldValue.increment(1),
      }, SetOptions(merge: true));

      // 2. İşlem geçmişine ekle
      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('transactions')
          .add({
        'type': type,
        'amount': amount,
        'createdAt': FieldValue.serverTimestamp(),
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content:
              Text('$type geri dönüştürüldü! +₺${amount.toStringAsFixed(2)}'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hata oluştu: $e'), backgroundColor: Colors.red),
      );
    }
  }

  IconData _getIconForType(String type) {
    switch (type) {
      case 'Plastik':
        return Icons.local_drink;
      case 'Cam':
        return Icons.wine_bar;
      case 'Kağıt':
        return Icons.description;
      case 'Metal':
        return Icons.settings;
      default:
        return Icons.recycling;
    }
  }

  void _logout() async {
    await FirebaseAuth.instance.signOut();
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const MyApp()),
    );
  }

  void _openCamera() async {
    var status = await Permission.camera.status;
    if (!status.isGranted) {
      await Permission.camera.request();
    }

    if (await Permission.camera.isGranted) {
      final result = await Navigator.push(
        context,
        MaterialPageRoute(builder: (context) => const QRScannerPage()),
      );

      if (result != null) {
        _handleQrResult(result);
      }
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Kamera izni gereklidir'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  // TEST İÇİN: Elle Kod Girme
  void _showManualEntryDialog() {
    final TextEditingController _codeController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("Manuel Kod Girişi"),
        content: TextField(
          controller: _codeController,
          decoration: const InputDecoration(hintText: "Örn: box_01"),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("İptal"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              if (_codeController.text.isNotEmpty) {
                _handleQrResult(_codeController.text.trim());
              }
            },
            child: const Text("Bağlan"),
          ),
        ],
      ),
    );
  }

  void _viewAllTransactions() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    final transactions = await FirebaseFirestore.instance
        .collection('users')
        .doc(user.uid)
        .collection('transactions')
        .orderBy('createdAt', descending: true)
        .get();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF455A64),
        title: const Text(
          'Tüm İşlem Geçmişi',
          style: TextStyle(color: Colors.white),
        ),
        content: Container(
          width: double.maxFinite,
          height: 400,
          child: transactions.docs.isEmpty
              ? Center(
                  child: Text(
                    'Henüz işlem geçmişi bulunmuyor.',
                    style: TextStyle(color: Colors.white.withOpacity(0.7)),
                  ),
                )
              : ListView.builder(
                  itemCount: transactions.docs.length,
                  itemBuilder: (context, index) {
                    final doc = transactions.docs[index];
                    final data = doc.data();
                    final type = data['type'] ?? 'Bilinmeyen';
                    final amount = (data['amount'] ?? 0).toDouble();
                    final createdAt = data['createdAt'] as Timestamp?;
                    final date = createdAt?.toDate() ?? DateTime.now();

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: Colors.white.withOpacity(0.2),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _getIconForType(type),
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  type,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                Text(
                                  '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.white.withOpacity(0.7),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            '+₺${amount.toStringAsFixed(2)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text(
              'Kapat',
              style: TextStyle(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF455A64),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF455A64),
              Color(0xFF37474F),
            ],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12.0), // 16'dan 12'ye düşürüldü
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Hoş Geldiniz Mesajı ve Logout Butonu - KÜÇÜLTÜLDÜ
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      children: [
                        CircleAvatar(
                          radius: 22, // 25'ten 22'ye
                          backgroundColor: Colors.white.withOpacity(0.2),
                          child: Icon(Icons.person,
                              color: Colors.white, size: 22), // size eklendi
                        ),
                        const SizedBox(width: 10), // 12'den 10'a
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Hoş Geldiniz!',
                              style: TextStyle(
                                fontSize: 14, // 16'dan 14'e
                                color: Colors.white.withOpacity(0.8),
                              ),
                            ),
                            Text(
                              'Çevreyi Koruyun, Kazanın!',
                              style: TextStyle(
                                fontSize: 16, // 18'den 16'ya
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        // TEST İÇİN: Elle Kod Girme Butonu
                        IconButton(
                          icon: const Icon(Icons.keyboard, color: Colors.white),
                          onPressed: () {
                             _showManualEntryDialog();
                          },
                        ),
                        IconButton(
                          onPressed: _logout,
                          icon: Icon(Icons.logout,
                              color: Colors.white, size: 22), // size eklendi
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.indigo[700]!.withOpacity(0.8),
                            shape: RoundedRectangleBorder(
                              borderRadius:
                                  BorderRadius.circular(10), // 12'den 10'a
                            ),
                            padding: const EdgeInsets.all(10), // 12'den 10'a
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                const SizedBox(height: 16), // 20'den 16'ya

                // Bakiye ve İstatistikler - KÜÇÜLTÜLDÜ
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(16), // 20'den 16'ya
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius:
                              BorderRadius.circular(14), // 16'dan 14'e
                          border: Border.all(
                            color: Colors.white.withOpacity(0.2),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.2),
                              blurRadius: 8, // 10'dan 8'e
                              offset: const Offset(0, 4), // 5'ten 4'e
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Bakiyeniz',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 13, // 14'ten 13'e
                              ),
                            ),
                            const SizedBox(height: 6), // 8'den 6'ya
                            Text(
                              '₺${_balance.toStringAsFixed(2)}',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 24, // 28'den 24'e
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 6), // 8'den 6'ya
                            Text(
                              '${_points} Puan',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.9),
                                fontSize: 13, // 14'ten 13'e
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 12), // 16'dan 12'ye
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.all(16), // 20'den 16'ya
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.1),
                          borderRadius:
                              BorderRadius.circular(14), // 16'dan 14'e
                          border: Border.all(
                            color: Colors.white.withOpacity(0.2),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.1),
                              blurRadius: 8, // 10'dan 8'e
                              offset: const Offset(0, 4), // 5'ten 4'e
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            Row(
                              children: [
                                Icon(Icons.recycling,
                                    color: Colors.white,
                                    size: 18), // 20'den 18'e
                                const SizedBox(width: 6), // 8'den 6'ya
                                Text(
                                  'Geri Dönüşüm',
                                  style: TextStyle(
                                    fontSize: 11, // 12'den 11'e
                                    color: Colors.white.withOpacity(0.9),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6), // 8'den 6'ya
                            Text(
                              '$_recycledItems',
                              style: TextStyle(
                                fontSize: 22, // 24'ten 22'ye
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            Text(
                              'toplam ürün',
                              style: TextStyle(
                                fontSize: 9, // 10'dan 9'a
                                color: Colors.white.withOpacity(0.7),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 20), // 24'ten 20'ye

                // Çöp Atma Seçenekleri - KÜÇÜLTÜLDÜ
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  childAspectRatio: 0.85, // 0.9'dan 0.85'e - DAHA DAHA KÜÇÜK
                  crossAxisSpacing: 4, // 6'dan 4'e
                  mainAxisSpacing: 4, // 6'dan 4'e
                  children: [
                    _buildRecycleOption('Plastik', Icons.local_drink, 2.50,
                        Colors.indigo[200]!),
                    _buildRecycleOption(
                        'Cam', Icons.wine_bar, 1.75, Colors.indigo[300]!),
                    _buildRecycleOption(
                        'Kağıt', Icons.description, 1.25, Colors.indigo[400]!),
                    _buildRecycleOption(
                        'Metal', Icons.settings, 3.00, Colors.indigo[500]!),
                  ],
                ),

                const SizedBox(height: 20), // 24'ten 20'ye

                // Son İşlemler - KÜÇÜLTÜLDÜ
                Container(
                  padding: const EdgeInsets.all(10), // 16'dan 14'e
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10), // 16'dan 14'e
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Son İşlemler',
                            style: TextStyle(
                              fontSize: 16, // 18'den 16'ya
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          TextButton(
                            onPressed: _viewAllTransactions,
                            child: Text(
                              'Tümünü Gör',
                              style: TextStyle(
                                  fontSize: 14, // eklendi
                                  color: Colors.white.withOpacity(0.8)),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _transactions.isEmpty
                          ? Container(
                              padding: const EdgeInsets.all(16), // 20'den 16'ya
                              child: Text(
                                'Henüz işlem yapılmamış.',
                                style: TextStyle(
                                    color: Colors.white.withOpacity(0.6)),
                                textAlign: TextAlign.center,
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              itemCount: _transactions.length,
                              itemBuilder: (context, index) {
                                final transaction = _transactions[index];
                                return Container(
                                  padding: const EdgeInsets.symmetric(
                                      vertical: 6), // eklendi
                                  decoration: BoxDecoration(
                                    border: Border(
                                      bottom: index < _transactions.length - 1
                                          ? BorderSide(
                                              color:
                                                  Colors.white.withOpacity(0.2))
                                          : BorderSide.none,
                                    ),
                                  ),
                                  child: ListTile(
                                    contentPadding: const EdgeInsets.symmetric(
                                        horizontal: 0), // padding'i sıfırladık
                                    leading: Container(
                                      width: 36, // 40'tan 36'ya
                                      height: 36, // 40'tan 36'ya
                                      decoration: BoxDecoration(
                                        color: Colors.white.withOpacity(0.2),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        transaction.icon,
                                        color: Colors.white,
                                        size: 18, // 20'den 18'e
                                      ),
                                    ),
                                    title: Text(
                                      transaction.type,
                                      style: TextStyle(
                                        fontWeight: FontWeight.w500,
                                        color: Colors.white,
                                        fontSize: 14, // eklendi
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${transaction.date.day}/${transaction.date.month}/${transaction.date.year} ${transaction.date.hour}:${transaction.date.minute.toString().padLeft(2, '0')}',
                                      style: TextStyle(
                                        fontSize: 11, // 12'den 11'e
                                        color: Colors.white.withOpacity(0.7),
                                      ),
                                    ),
                                    trailing: Text(
                                      '+₺${transaction.amount.toStringAsFixed(2)}',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 14, // 16'dan 14'e
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ],
                  ),
                ),

                const SizedBox(height: 16), // 20'den 16'ya

                // Hızlı Erişim Butonları - KÜÇÜLTÜLDÜ
                Container(
                  padding: const EdgeInsets.all(14), // 16'dan 14'e
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(14), // 16'dan 14'e
                    border: Border.all(
                      color: Colors.white.withOpacity(0.2),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildQuickAction(Icons.qr_code, 'QR Tara', Colors.white),
                      _buildQuickAction(Icons.history, 'Geçmiş', Colors.white,
                          onTap: _viewAllTransactions),
                      _buildQuickAction(
                          Icons.credit_card, 'Para Çek', Colors.white),
                      _buildQuickAction(Icons.help, 'Yardım', Colors.white),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecycleOption(
      String type, IconData icon, double amount, Color color) {
    return Card(
      elevation: 3, // 4'ten 3'e düşürüldü
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12), // 14'ten 12'ye
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12), // 14'ten 12'ye
        onTap: () {
          _recycleItem(type, amount);
        },
        child: Container(
          padding: const EdgeInsets.all(10), // 12'den 10'a
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                color.withOpacity(0.6),
                color.withOpacity(0.3),
              ],
            ),
            borderRadius: BorderRadius.circular(12), // 14'ten 12'ye
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 42, // 48'den 42'ye - DAHA KÜÇÜK
                height: 42, // 48'den 42'ye - DAHA KÜÇÜK
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 3, // 4'ten 3'e
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Icon(
                  icon,
                  size: 24, // 28'den 24'e - DAHA KÜÇÜK
                  color: Colors.indigo[900],
                ),
              ),
              const SizedBox(height: 6), // 8'den 6'ya
              Text(
                type,
                style: TextStyle(
                  fontSize: 10, // 11'den 10'a - DAHA KÜÇÜK
                  color: Colors.indigo[900],
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildQuickAction(IconData icon, String label, Color color,
      {VoidCallback? onTap}) {
    return Column(
      children: [
        Container(
          width: 45, // 50'den 45'e
          height: 45, // 50'den 45'e
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.2),
            shape: BoxShape.circle,
          ),
          child: IconButton(
            icon: Icon(icon, color: color, size: 22), // size eklendi
            onPressed: onTap ??
                () {
                  if (label == 'QR Tara') {
                    _openCamera();
                  }
                },
            padding: EdgeInsets.zero, // padding'i sıfırladık
          ),
        ),
        const SizedBox(height: 6), // 8'den 6'ya
        Text(
          label,
          style: TextStyle(
            fontSize: 11, // 12'den 11'e
            color: Colors.white.withOpacity(0.9),
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class RecycleTransaction {
  final String type;
  final double amount;
  final DateTime date;
  final IconData icon;

  RecycleTransaction(this.type, this.amount, this.date, this.icon);
}

// QR Scanner Sayfası
class QRScannerPage extends StatefulWidget {
  const QRScannerPage({super.key});

  @override
  _QRScannerPageState createState() => _QRScannerPageState();
}

class _QRScannerPageState extends State<QRScannerPage> {
  final GlobalKey qrKey = GlobalKey(debugLabel: 'QR');
  QRViewController? controller;

  // Çift okumayı engellemek için kilit
  bool _isScanned = false; 

  @override
  void reassemble() {
    super.reassemble();
    if (Platform.isAndroid) {
      controller!.pauseCamera();
    }
    controller!.resumeCamera();
  }

  @override
  void dispose() {
    controller?.dispose();
    super.dispose();
  }

  void _onQRViewCreated(QRViewController controller) {
    this.controller = controller;

    controller.scannedDataStream.listen((scanData) async {
      // Eğer daha önce okunduysa tekrar işlem yapma
      if (_isScanned) return;

      final qrResult = scanData.code;

      if (qrResult != null && qrResult.isNotEmpty) {
        setState(() {
          _isScanned = true; // Kilitle
        });
        
        await controller.pauseCamera();
        debugPrint("QR OKUNDU: $qrResult");

        if (mounted) {
          Navigator.pop(context, qrResult);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          'QR Kodu Okutun',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: QRView(
        key: qrKey,
        onQRViewCreated: _onQRViewCreated,
        overlay: QrScannerOverlayShape(
          borderColor: Colors.greenAccent, // GÜNCELLEME KONTROLÜ: YEŞİL RENK
          borderRadius: 10,
          borderLength: 30,
          borderWidth: 10,
          cutOutSize: MediaQuery.of(context).size.width * 0.7,
        ),
      ),
    );
  }
}
