/// What each runtime permission switches on, and the message shown when the
/// user denies it. Pure, so the wording and the grouping can be tested.
class PermissionFeature {
  final String permission;
  final String feature;
  final String effect;
  const PermissionFeature(this.permission, this.feature, this.effect);
}

const List<PermissionFeature> permissionFeatures = [
  PermissionFeature('location', 'Location',
      'GPS position, dead reckoning and the live tracking link are OFF; SOS is sent without a position.'),
  PermissionFeature('locationAlways', 'Background location',
      'Position updates may stop when the app is not in view.'),
  PermissionFeature('notification', 'Notifications',
      'The cancel notification for automatic SOS is OFF; use the app to cancel.'),
  PermissionFeature('microphone', 'Microphone',
      'Voice and sound triggers and the 30 s audio evidence are OFF.'),
  PermissionFeature('bluetoothScan', 'Bluetooth scan',
      'Offline mesh relay (finding nearby phones) is OFF.'),
  PermissionFeature('bluetoothAdvertise', 'Bluetooth advertise',
      'Offline mesh relay (sending your SOS to nearby phones) is OFF.'),
  PermissionFeature('bluetoothConnect', 'Bluetooth connect',
      'Offline mesh relay is OFF.'),
  PermissionFeature('nearbyWifiDevices', 'Nearby devices (Wi-Fi)',
      'Faster mesh transfer is OFF; Bluetooth relay may still work.'),
  PermissionFeature('sms', 'SMS',
      'Emergency SMS to your contacts is OFF. Cloud and mesh are the only channels.'),
  PermissionFeature('phone', 'Phone state',
      'Choosing a SIM for SMS is limited to the default SIM.'),
];

/// One line per denied permission, in the order the app asks for them.
/// [granted] maps the permission names above to their state; a name that is
/// missing counts as denied, so nothing is claimed active without a grant.
List<String> describeDenied(Map<String, bool> granted) => [
      for (final f in permissionFeatures)
        if (granted[f.permission] != true) '${f.feature} denied: ${f.effect}',
    ];
