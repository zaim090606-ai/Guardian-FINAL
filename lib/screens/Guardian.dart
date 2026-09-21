import 'package:fast_contacts/fast_contacts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:easy_help/navbar/navbar.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';

class Guardianscreen extends StatelessWidget {
  const Guardianscreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Guardian Setup UI',
      theme: ThemeData(
        scaffoldBackgroundColor: Colors.white,
        fontFamily: 'Roboto',
      ),
      home: const MakeGuardianReadyScreen(),
    );
  }
}

class MakeGuardianReadyScreen extends StatefulWidget {
  const MakeGuardianReadyScreen({super.key});

  @override
  State<MakeGuardianReadyScreen> createState() =>
      _MakeGuardianReadyScreenState();
}

class _MakeGuardianReadyScreenState extends State<MakeGuardianReadyScreen> {
  // ---------- Direct Phone Call Launcher ----------
  Future<void> _makePhoneCall(String phoneNumber) async {
    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);
    try {
      if (await canLaunchUrl(launchUri)) {
        await launchUrl(launchUri);
      } else {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not open dialer for $phoneNumber')),
          );
        }
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Error calling number: $e')));
      }
    }
  }

  // ---------- Location Permission Function ----------
  Future<void> _requestLocationPermission() async {
    bool serviceEnabled;
    LocationPermission permission;

    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location services are disabled.')),
        );
      }
      return;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Location permissions are denied')),
          );
        }
        return;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Location permissions are permanently denied.')),
        );
      }
      return;
    }

    Position position = await Geolocator.getCurrentPosition();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Location allowed! Lat: ${position.latitude}, Lng: ${position.longitude}')),
      );
    }
  }

  // ---------- SMS Permission Function ----------
  Future<void> _requestSmsPermission() async {
    PermissionStatus status = await Permission.sms.request();
    if (status.isGranted) {
      if (context.mounted) {Remove-Item .\gitwork.git
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SMS permission allowed!')),
        );
      }
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('SMS permission denied.')),
        );
      }
    }
  }

  // ---------- Fetch Device Contacts (Helper) ----------
  Future<List<Contact>> fetchDeviceContacts() async {
    PermissionStatus status = await Permission.contacts.request();
    if (status.isGranted) {
      return await FastContacts.getAllContacts();
    } else {
      print("Contact permission denied.");
      return [];
    }
  }

  // ---------- Add Trusted Contact Dialog ----------
  Future<void> _showAddContactDialog() async {
    final nameController = TextEditingController();
    final phoneController = TextEditingController();
    final relationController = TextEditingController();

    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Add trusted contact'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: phoneController,
                decoration: const InputDecoration(labelText: 'Phone number'),
                keyboardType: TextInputType.phone,
              ),
              TextField(
                controller: relationController,
                decoration: const InputDecoration(
                  labelText: 'Relation (e.g. Parent, Friend)',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final phone = phoneController.text.trim();
                final relation = relationController.text.trim();

                if (name.isEmpty || phone.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Name and phone are required'),
                    ),
                  );
                  return;
                }

                try {
                  await FirebaseFirestore.instance
                      .collection('trusted_contacts')
                      .add({
                    'name': name,
                    'phone': phone,
                    'relation': relation,
                    'createdAt': FieldValue.serverTimestamp(),
                  });

                  if (context.mounted) {
                    Navigator.pop(context);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('$name added as a trusted contact'),
                      ),
                    );
                    setState(() {});
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to save contact: $e')),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Set up Guardian',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.black,
                  ),
                ),
                const SizedBox(height: 32),
                const Text(
                  'Make Guardian ready',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.black,
                    letterSpacing: -0.5,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  "We'll only ask for access needed for the features you enable.",
                  style: TextStyle(
                    fontSize: 16,
                    color: Colors.grey.shade700,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 32),
                PermissionCard(
                  title: 'Trusted contacts',
                  description: 'People Guardian can alert, call, and share your emergency location with.',
                  buttonText: 'Add trusted contact',
                  onTap: _showAddContactDialog,
                ),
                const SizedBox(height: 16),
                StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('trusted_contacts')
                      .orderBy('createdAt', descending: true)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      return const SizedBox.shrink();
                    }
                    final docs = snapshot.data!.docs;
                    return Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                            child: Text(
                              'Saved contacts (${docs.length})',
                              style: const TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                color: Colors.black,
                              ),
                            ),
                          ),
                          ...docs.map((doc) {
                            final data = doc.data() as Map<String, dynamic>;
                            final phone = data['phone'] as String? ?? '';
                            return ListTile(
                              title: Text(
                                data['name'] ?? '',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              subtitle: Text(
                                '$phone • ${data['relation'] ?? ''}',
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(
                                      Icons.phone,
                                      color: Colors.green,
                                    ),
                                    onPressed: () {
                                      if (phone.isNotEmpty) {
                                        _makePhoneCall(phone);
                                      }
                                    },
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.delete_outline,
                                      color: Colors.redAccent,
                                    ),
                                    onPressed: () async {
                                      await FirebaseFirestore.instance
                                          .collection('trusted_contacts')
                                          .doc(doc.id)
                                          .delete();
                                    },
                                  ),
                                ],
                              ),
                              onTap: () {
                                if (phone.isNotEmpty) {
                                  _makePhoneCall(phone);
                                }
                              },
                            );
                          }),
                          const SizedBox(height: 4),
                        ],
                      ),
                    );
                  },
                ),
                PermissionCard(
                  title: 'Location',
                  description: 'Used for emergency response and optional location sharing.',
                  buttonText: 'Allow location',
                  onTap: _requestLocationPermission,
                ),
                const SizedBox(height: 16),
                const PermissionCard(
                  title: 'Notifications',
                  description: 'Used for Guardian alerts and status.',
                  buttonText: 'Enabled ✓ notifications',
                ),
                const SizedBox(height: 16),
                const PermissionCard(
                  title: 'Motion & sensors',
                  description: 'Used for possible-emergency detection.',
                  buttonText: 'Allow sensors',
                ),
                const SizedBox(height: 16),
                PermissionCard(
                  title: 'Calls & SMS',
                  description: 'Used to text and call trusted people during an emergency.',
                  buttonText: 'Allow SMS dispatch',
                  onTap: _requestSmsPermission,
                ),
                const SizedBox(height: 32),
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 24.0),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.black,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 48,
                          vertical: 14,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                      ),
                      onPressed: () async {
                        final prefs = await SharedPreferences.getInstance();
                        await prefs.setBool('is_setup_complete', true);

                        if (context.mounted) {
                          Navigator.pushReplacement(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const MainBottomNavBar(),
                            ),
                          );
                        }
                      },
                      child: const Text(
                        'Finish',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class PermissionCard extends StatelessWidget {
  final String title;
  final String description;
  final String buttonText;
  final VoidCallback? onTap;

  const PermissionCard({
    super.key,
    required this.title,
    required this.description,
    required this.buttonText,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade300, width: 1),
      ),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            description,
            style: TextStyle(
              fontSize: 15,
              color: Colors.grey.shade700,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade400, width: 1),
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: onTap ?? () {},
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16.0),
                    child: Text(
                      buttonText,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.black,
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
}