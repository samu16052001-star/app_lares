import 'package:flutter/material.dart';

import 'polar_h10_configuration.dart';

class PolarH10ConfigurationPage extends StatefulWidget {
  const PolarH10ConfigurationPage({
    super.key,
    required this.deviceName,
    this.initialConfiguration,
    this.onConfigurationConfirmed,
  });

  final String deviceName;
  final PolarH10Configuration? initialConfiguration;
  final ValueChanged<PolarH10Configuration>? onConfigurationConfirmed;

  @override
  State<PolarH10ConfigurationPage> createState() =>
      _PolarH10ConfigurationPageState();
}

class _PolarH10ConfigurationPageState extends State<PolarH10ConfigurationPage> {
  late PolarH10Configuration _configuration;

  @override
  void initState() {
    super.initState();
    _configuration =
        widget.initialConfiguration ?? const PolarH10Configuration();
  }

  void _setHrEnabled(bool value) {
    setState(() {
      _configuration = _configuration.copyWith(hrEnabled: value);
    });
  }

  void _setRawEcgEnabled(bool value) {
    setState(() {
      _configuration = _configuration.copyWith(rawEcgEnabled: value);
    });
  }

  void _setAccelerometerEnabled(bool value) {
    setState(() {
      _configuration = _configuration.copyWith(accelerometerEnabled: value);
    });
  }

  void _confirm() {
    if (!_configuration.isValid) {
      return;
    }

    widget.onConfigurationConfirmed?.call(_configuration);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Polar H10 Configuration'),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.monitor_heart),
                      title: Text(widget.deviceName),
                      subtitle: const Text('Polar H10'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Column(
                      children: [
                        SwitchListTile(
                          title: const Text('HR'),
                          value: _configuration.hrEnabled,
                          onChanged: _setHrEnabled,
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          title: const Text('Raw ECG'),
                          value: _configuration.rawEcgEnabled,
                          onChanged: _setRawEcgEnabled,
                        ),
                        const Divider(height: 1),
                        SwitchListTile(
                          title: const Text('Accelerometer'),
                          value: _configuration.accelerometerEnabled,
                          onChanged: _setAccelerometerEnabled,
                        ),
                      ],
                    ),
                  ),
                  if (!_configuration.isValid) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Select at least one stream.',
                      style: TextStyle(color: colorScheme.error),
                    ),
                  ],
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: FilledButton(
                  onPressed: _configuration.isValid ? _confirm : null,
                  child: const Text('Confirm'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
