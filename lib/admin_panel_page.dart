import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AdminPanelPage extends StatelessWidget {
  const AdminPanelPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF455A64),
      appBar: AppBar(
        backgroundColor: const Color(0xFF455A64),
        elevation: 0,
        iconTheme: const IconThemeData(color: Colors.white),
        title: const Text(
          'Kontrol Paneli',
          style: TextStyle(color: Colors.white),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance.collection('users').snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(
              child: CircularProgressIndicator(color: Colors.white),
            );
          }

          final users = snapshot.data!.docs;

          int totalUsers = users.length;
          double totalBalance = 0;
          int totalRecycled = 0;

          for (var doc in users) {
            final data = doc.data() as Map<String, dynamic>;
            totalBalance += (data['balance'] ?? 0).toDouble();
            totalRecycled += (data['recycledItems'] ?? 0) as int;
          }

          return Column(
            children: [
              // 🔹 DASHBOARD
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    _dashboardCard(
                      title: 'Kullanıcı',
                      value: totalUsers.toString(),
                      icon: Icons.people,
                    ),
                    _dashboardCard(
                      title: 'Toplam ₺',
                      value: totalBalance.toStringAsFixed(2),
                      icon: Icons.account_balance_wallet,
                    ),
                    _dashboardCard(
                      title: 'Geri Dönüşüm',
                      value: totalRecycled.toString(),
                      icon: Icons.recycling,
                    ),
                  ],
                ),
              ),

              // 🔹 KULLANICI LİSTESİ
              Expanded(
                child: ListView.builder(
                  itemCount: users.length,
                  itemBuilder: (context, index) {
                    final data = users[index].data() as Map<String, dynamic>;

                    return Card(
                      color: const Color(0xFF546E7A),
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: Colors.white24,
                          child: Icon(Icons.person, color: Colors.white),
                        ),
                        title: Text(
                          data['name'] ?? 'İsimsiz',
                          style: const TextStyle(color: Colors.white),
                        ),
                        trailing: const Icon(Icons.arrow_forward_ios,
                            color: Colors.white70, size: 16),
                        onTap: () => _showUserDetail(context, data),
                      ),
                    );
                  },
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // 🔹 DASHBOARD KARTI
  Widget _dashboardCard({
    required String title,
    required String value,
    required IconData icon,
  }) {
    return Expanded(
      child: Card(
        color: const Color(0xFF546E7A),
        margin: const EdgeInsets.symmetric(horizontal: 6),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            children: [
              Icon(icon, color: Colors.white),
              const SizedBox(height: 8),
              Text(value,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              Text(title,
                  style: const TextStyle(color: Colors.white70, fontSize: 12)),
            ],
          ),
        ),
      ),
    );
  }

  // 🔹 ALT PANEL (DETAY)
  void _showUserDetail(BuildContext context, Map<String, dynamic> data) {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF455A64),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              data['name'] ?? '',
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 20),
            _detailRow('💰 Bakiye', '${data['balance']} ₺'),
            _detailRow('⭐ Puan', data['points'].toString()),
            _detailRow('♻️ Geri Dönüşüm', data['recycledItems'].toString()),
          ],
        ),
      ),
    );
  }

  Widget _detailRow(String title, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(title, style: const TextStyle(color: Colors.white70)),
          Text(value,
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}
