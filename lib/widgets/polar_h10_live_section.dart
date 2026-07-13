import 'dart:math' as math;

import 'package:app_lares/polar_h10/polar_h10_configuration.dart';
import 'package:app_lares/polar_h10/polar_h10_models.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

class PolarH10LiveSection extends StatelessWidget {
  const PolarH10LiveSection({
    super.key,
    required this.configuration,
    required this.status,
    required this.latestHrSample,
    required this.ecgSamples,
    this.batteryPercent,
  });

  final PolarH10Configuration configuration;
  final PolarH10Status status;
  final PolarH10HrSample? latestHrSample;
  final List<PolarH10EcgSample> ecgSamples;
  final int? batteryPercent;

  static const int maxVisibleEcgSamples = 650;
  static const Duration visibleEcgWindow = Duration(seconds: 5);

  @override
  Widget build(BuildContext context) {
    final visibleEcgSamples = _visibleEcgSamples;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PolarStatusRow(
          status: status,
          batteryPercent: batteryPercent,
        ),
        if (configuration.hrEnabled) ...[
          const SizedBox(height: 12),
          _PolarHrCard(sample: latestHrSample),
        ],
        if (configuration.rawEcgEnabled) ...[
          const SizedBox(height: 12),
          _PolarEcgChartCard(samples: visibleEcgSamples),
        ],
      ],
    );
  }

  List<PolarH10EcgSample> get _visibleEcgSamples {
    if (ecgSamples.isEmpty) {
      return const [];
    }

    final indexedSamples = [
      for (var index = 0; index < ecgSamples.length; index += 1)
        MapEntry(index, ecgSamples[index]),
    ]..sort((a, b) {
        final timestampComparison =
            a.value.displayTimestamp.compareTo(b.value.displayTimestamp);
        if (timestampComparison != 0) {
          return timestampComparison;
        }

        return a.key.compareTo(b.key);
      });
    final orderedSamples = [
      for (final entry in indexedSamples) entry.value,
    ];
    final windowEnd = orderedSamples.last.displayTimestamp;
    final cutoff = windowEnd.subtract(visibleEcgWindow);
    final windowSamples = orderedSamples
        .where((sample) => !sample.displayTimestamp.isBefore(cutoff))
        .toList(growable: false);

    return _limitVisibleSamples(windowSamples);
  }

  List<PolarH10EcgSample> _limitVisibleSamples(
    List<PolarH10EcgSample> samples,
  ) {
    if (samples.length <= maxVisibleEcgSamples) {
      return samples;
    }

    return samples.sublist(samples.length - maxVisibleEcgSamples);
  }
}

class _PolarStatusRow extends StatelessWidget {
  const _PolarStatusRow({
    required this.status,
    required this.batteryPercent,
  });

  final PolarH10Status status;
  final int? batteryPercent;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final batteryText =
        batteryPercent == null ? 'Battery: N/A' : 'Battery: $batteryPercent%';

    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _PolarStatusPill(
          icon: Icons.monitor_heart,
          text: status.label,
          iconColor: _statusColor(colorScheme),
        ),
        _PolarStatusPill(
          icon: Icons.battery_std,
          text: batteryText,
          iconColor: colorScheme.primary,
        ),
      ],
    );
  }

  Color _statusColor(ColorScheme colorScheme) {
    return switch (status) {
      PolarH10Status.error => colorScheme.error,
      PolarH10Status.disconnected => colorScheme.error,
      PolarH10Status.reconnecting => colorScheme.primary,
      _ => Colors.green.shade700,
    };
  }
}

class _PolarStatusPill extends StatelessWidget {
  const _PolarStatusPill({
    required this.icon,
    required this.text,
    required this.iconColor,
  });

  final IconData icon;
  final String text;
  final Color iconColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: iconColor),
            const SizedBox(width: 8),
            Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PolarHrCard extends StatelessWidget {
  const _PolarHrCard({
    required this.sample,
  });

  final PolarH10HrSample? sample;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final valueText = sample == null ? '-' : '${sample!.hrBpm} bpm';
    final updateText =
        sample == null ? 'No data received yet' : _formatTime(sample!.receivedAt);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.favorite, color: colorScheme.error, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'HR',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    valueText,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Last update: $updateText',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PolarEcgChartCard extends StatelessWidget {
  const _PolarEcgChartCard({
    required this.samples,
  });

  final List<PolarH10EcgSample> samples;

  static const int _yAxisLabelCount = 3;
  static const String _unit = '\u00B5V';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Raw ECG',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  _unit,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 210,
              child: samples.isEmpty
                  ? _buildEmptyChartPlaceholder(context)
                  : _buildChart(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyChartPlaceholder(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Center(
        child: Text(
          'No data received yet',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: colorScheme.onSurfaceVariant,
              ),
        ),
      ),
    );
  }

  Widget _buildChart(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final firstSampleTime = samples.first.displayTimestamp;
    final lastSampleTime = samples.last.displayTimestamp;
    final maxX = math.max(
      1.0,
      lastSampleTime.difference(firstSampleTime).inMilliseconds / 1000,
    );
    final spots = samples.map((sample) {
      final seconds =
          sample.displayTimestamp.difference(firstSampleTime).inMicroseconds /
              Duration.microsecondsPerSecond;
      return FlSpot(seconds.clamp(0, maxX).toDouble(), sample.ecgMicrovolts.toDouble());
    }).toList(growable: false);

    var minY = samples.first.ecgMicrovolts.toDouble();
    var maxY = samples.first.ecgMicrovolts.toDouble();
    for (final sample in samples.skip(1)) {
      final value = sample.ecgMicrovolts.toDouble();
      minY = math.min(minY, value);
      maxY = math.max(maxY, value);
    }

    final yRange = maxY - minY;
    final yPadding = yRange == 0 ? math.max(10.0, maxY.abs() * 0.1) : yRange * 0.12;
    final chartMinY = minY - yPadding;
    final chartMaxY = maxY + yPadding;
    final yAxisValues = _buildYAxisValues(chartMinY, chartMaxY);
    final yAxisInterval = _yAxisInterval(chartMinY, chartMaxY);
    final xAxisValues = _buildXAxisValues(maxX);
    final labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: colorScheme.onSurfaceVariant,
      fontSize: 11,
    );

    return Padding(
      padding: const EdgeInsets.only(top: 6, right: 4),
      child: LineChart(
        LineChartData(
          minX: 0,
          maxX: maxX,
          minY: chartMinY,
          maxY: chartMaxY,
          gridData: FlGridData(
            show: true,
            horizontalInterval: yAxisInterval,
            verticalInterval: maxX / 2,
            checkToShowHorizontalLine: (value) =>
                _isAxisValue(value, yAxisValues),
            checkToShowVerticalLine: (value) => _isAxisValue(value, xAxisValues),
            getDrawingHorizontalLine: (_) => FlLine(
              color: colorScheme.outlineVariant.withValues(alpha: 0.7),
              strokeWidth: 0.8,
            ),
            getDrawingVerticalLine: (_) => FlLine(
              color: colorScheme.outlineVariant.withValues(alpha: 0.35),
              strokeWidth: 0.6,
            ),
          ),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              axisNameSize: 24,
              axisNameWidget: Text(
                _unit,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 46,
                interval: yAxisInterval,
                getTitlesWidget: (value, meta) {
                  if (!_isAxisValue(value, yAxisValues)) {
                    return const SizedBox.shrink();
                  }

                  return SideTitleWidget(
                    meta: meta,
                    space: 6,
                    child: Text(
                      value.toStringAsFixed(0),
                      style: labelStyle,
                    ),
                  );
                },
              ),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                interval: maxX / 2,
                getTitlesWidget: (value, meta) {
                  if (!_isAxisValue(value, xAxisValues)) {
                    return const SizedBox.shrink();
                  }

                  final labelTime = firstSampleTime.add(
                    Duration(milliseconds: (value * 1000).round()),
                  );
                  return SideTitleWidget(
                    meta: meta,
                    space: 6,
                    child: Text(
                      _formatTime(labelTime),
                      style: labelStyle,
                    ),
                  );
                },
              ),
            ),
          ),
          borderData: FlBorderData(
            show: true,
            border: Border(
              left: BorderSide(color: colorScheme.outlineVariant),
              bottom: BorderSide(color: colorScheme.outlineVariant),
              right: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.35),
              ),
              top: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.35),
              ),
            ),
          ),
          lineTouchData: const LineTouchData(enabled: false),
          lineBarsData: [
            LineChartBarData(
              spots: spots,
              isCurved: false,
              color: colorScheme.primary,
              barWidth: 1.8,
              dotData: FlDotData(show: samples.length == 1),
              belowBarData: BarAreaData(
                show: true,
                color: colorScheme.primary.withValues(alpha: 0.06),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<double> _buildXAxisValues(double maxX) {
    return [0, maxX / 2, maxX];
  }

  List<double> _buildYAxisValues(double minY, double maxY) {
    final interval = _yAxisInterval(minY, maxY);

    return List<double>.generate(
      _yAxisLabelCount,
      (index) => minY + interval * index,
      growable: false,
    );
  }

  double _yAxisInterval(double minY, double maxY) {
    final range = (maxY - minY).abs();
    if (!range.isFinite || range <= 0) {
      return 1;
    }

    return range / (_yAxisLabelCount - 1);
  }

  bool _isAxisValue(double value, List<double> axisValues) {
    const tolerance = 0.000001;

    return axisValues.any((axisValue) {
      final scale = math.max(1.0, axisValue.abs());
      return (value - axisValue).abs() <= tolerance * scale;
    });
  }
}

String _formatTime(DateTime value) {
  final local = value.toLocal();
  final hour = local.hour.toString().padLeft(2, '0');
  final minute = local.minute.toString().padLeft(2, '0');
  final second = local.second.toString().padLeft(2, '0');
  return '$hour:$minute:$second';
}
