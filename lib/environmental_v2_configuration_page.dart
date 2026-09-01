import 'package:flutter/material.dart';

import 'environmental_v2_configuration.dart';

class EnvironmentalV2ConfigurationPage extends StatefulWidget {
  const EnvironmentalV2ConfigurationPage({
    super.key,
    this.initialConfiguration,
    required this.onConfigurationConfirmed,
  });

  final EnvironmentalV2Configuration? initialConfiguration;
  final ValueChanged<EnvironmentalV2Configuration> onConfigurationConfirmed;

  @override
  State<EnvironmentalV2ConfigurationPage> createState() =>
      _EnvironmentalV2ConfigurationPageState();
}

class _EnvironmentalV2ConfigurationPageState
    extends State<EnvironmentalV2ConfigurationPage> {
  late final Map<EnvironmentalV2Option, bool> _enabledOptions;

  bool get _allMeasurementsEnabled {
    return EnvironmentalV2Option.values.every(
      (option) => _enabledOptions[option] ?? false,
    );
  }

  @override
  void initState() {
    super.initState();
    final initialConfiguration = widget.initialConfiguration;
    _enabledOptions = <EnvironmentalV2Option, bool>{
      for (final option in EnvironmentalV2Option.values)
        option: initialConfiguration?.isEnabled(option) ?? false,
    };
  }

  void _setAllMeasurements(bool enabled) {
    setState(() {
      for (final option in EnvironmentalV2Option.values) {
        _enabledOptions[option] = enabled;
      }
    });
  }

  void _setOption(EnvironmentalV2Option option, bool enabled) {
    setState(() {
      _enabledOptions[option] = enabled;
    });
  }

  void _confirmConfiguration() {
    widget.onConfigurationConfirmed(
      EnvironmentalV2Configuration(
        enabledOptions: Map<EnvironmentalV2Option, bool>.from(
          _enabledOptions,
        ),
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Configuration'),
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('All Measurements'),
                  value: _allMeasurementsEnabled,
                  onChanged: _setAllMeasurements,
                ),
                const SizedBox(height: 8),
                for (final option in EnvironmentalV2Option.values)
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(option.label),
                    value: _enabledOptions[option] ?? false,
                    onChanged: (enabled) => _setOption(option, enabled),
                  ),
              ],
            ),
          ),
          SafeArea(
            minimum: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _confirmConfiguration,
                child: const Text('Confirm Configuration'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
