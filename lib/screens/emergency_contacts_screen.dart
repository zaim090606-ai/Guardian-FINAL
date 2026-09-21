import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

class EmergencyContactsScreen extends StatefulWidget {
  const EmergencyContactsScreen({super.key});

  @override
  State<EmergencyContactsScreen> createState() => _EmergencyContactsScreenState();
}

class _EmergencyContactsScreenState extends State<EmergencyContactsScreen> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  
  List<Map<String, String>> _contacts = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    setState(() => _isLoading = true);
    List<Map<String, String>> loadedContacts = [];

    final user = FirebaseAuth.instance.currentUser;

    // 1. Fetch from Firestore if logged in
    if (user != null) {
      try {
        final snapshot = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('contacts')
            .get();

        for (var doc in snapshot.docs) {
          final data = doc.data();
          loadedContacts.add({
            'id': doc.id,
            'name': data['name']?.toString() ?? 'Contact',
            'phone': data['phone']?.toString() ?? '',
          });
        }
      } catch (e) {
        debugPrint("❌ Failed to fetch contacts from Firestore: $e");
      }
    }

    // 2. Fallback / Sync with SharedPreferences
    if (loadedContacts.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      List<String> rawList = prefs.getStringList('emergency_contacts') ?? [];
      for (String item in rawList) {
        // Parse "Name (Phone)" format
        RegExp regExp = RegExp(r'^(.*?)\s*\((.*?)\)$');
        Match? match = regExp.firstMatch(item);
        if (match != null) {
          loadedContacts.add({
            'id': DateTime.now().millisecondsSinceEpoch.toString(),
            'name': match.group(1)?.trim() ?? 'Contact',
            'phone': match.group(2)?.trim() ?? item,
          });
        } else {
          loadedContacts.add({
            'id': DateTime.now().millisecondsSinceEpoch.toString(),
            'name': 'Contact',
            'phone': item,
          });
        }
      }
    }

    setState(() {
      _contacts = loadedContacts;
      _isLoading = false;
    });

    _syncToLocalStorage();
  }

  Future<void> _addContact() async {
    final name = _nameController.text.trim();
    final phone = _phoneController.text.trim();

    if (phone.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a phone number')),
      );
      return;
    }

    final user = FirebaseAuth.instance.currentUser;
    String docId = DateTime.now().millisecondsSinceEpoch.toString();

    // 1. Sync to Firestore if authenticated
    if (user != null) {
      try {
        DocumentReference ref = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('contacts')
            .add({
          'name': name.isEmpty ? 'Trusted Contact' : name,
          'phone': phone,
          'createdAt': FieldValue.serverTimestamp(),
        });
        docId = ref.id;
      } catch (e) {
        debugPrint("❌ Failed to save contact to Firestore: $e");
      }
    }

    // 2. Update UI
    setState(() {
      _contacts.add({
        'id': docId,
        'name': name.isEmpty ? 'Trusted Contact' : name,
        'phone': phone,
      });
    });

    // 3. Sync to SharedPreferences for offline backup
    await _syncToLocalStorage();

    _nameController.clear();
    _phoneController.clear();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Emergency contact saved successfully!')),
      );
    }
  }

  Future<void> _deleteContact(int index) async {
    final contact = _contacts[index];
    final user = FirebaseAuth.instance.currentUser;

    // Delete from Firestore
    if (user != null && contact['id'] != null) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('contacts')
            .doc(contact['id'])
            .delete();
      } catch (e) {
        debugPrint("❌ Failed to delete contact from Firestore: $e");
      }
    }

    // Update UI & Local storage
    setState(() {
      _contacts.removeAt(index);
    });

    await _syncToLocalStorage();
  }

  Future<void> _syncToLocalStorage() async {
    final prefs = await SharedPreferences.getInstance();
    List<String> formattedList = _contacts.map((c) => "${c['name']} (${c['phone']})").toList();
    List<String> rawPhoneList = _contacts.map((c) => c['phone']!).toList();

    await prefs.setStringList('emergency_contacts', formattedList);
    if (rawPhoneList.isNotEmpty) {
      await prefs.setString("emergency_contact_number", rawPhoneList.first);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Emergency Contacts'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        elevation: 0,
      ),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Add trusted contacts who will receive your automated SOS alerts and live GPS location.',
              style: TextStyle(color: Colors.grey, fontSize: 14),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Contact Name (e.g., Mom)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _phoneController,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'Phone Number (with country code)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.black,
                  foregroundColor: Colors.white,
                ),
                onPressed: _addContact,
                child: const Text('Add Contact'),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Saved Contacts',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _contacts.isEmpty
                      ? const Center(
                          child: Text(
                            'No emergency contacts added yet.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          itemCount: _contacts.length,
                          itemBuilder: (context, index) {
                            final item = _contacts[index];
                            return Card(
                              child: ListTile(
                                leading: const CircleAvatar(
                                  backgroundColor: Colors.black12,
                                  child: Icon(Icons.person, color: Colors.black),
                                ),
                                title: Text(item['name'] ?? 'Contact'),
                                subtitle: Text(item['phone'] ?? ''),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete, color: Colors.red),
                                  onPressed: () => _deleteContact(index),
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}