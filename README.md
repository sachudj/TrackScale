# TrackScale (macOS)

Minimal native macOS app that uses OpenMultitouchSupport for low-level trackpad pressure data and shows grams-like output in auto mode.

## What this app does

- Reads pressure from the trackpad touch stream.
- Auto-selects the built-in trackpad device when available.
- Automatically captures a fixed baseline (no calibration prompts).
- Uses a quick baseline fallback so it does not stay stuck on startup.
- Uses a stabilized pressure window for less jitter.
- Holds the recent value briefly during short signal dropouts.
- Shows live grams-like output as pressure minus baseline.
- Includes a Reset Baseline button.

## Important limitation

- No-finger measurement is best effort only.
- Passive non-conductive objects may not produce a trackpad signal.
- Values are not certified scale measurements.

## Build and run

```bash
cd TrackScale
swift run
```

## How to use

1. Start the app.
2. Place object on trackpad and observe output.
3. If the resting value is off, click Reset Baseline.
4. If no signal appears, try conductive contact conditions.
