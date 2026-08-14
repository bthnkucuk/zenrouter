import 'package:flutter/physics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shits/src/physics/motion.dart';

/// The largest value a simulation reaches in its first two seconds, sampled at
/// 240 Hz — long enough for every motion here to have settled.
double _maximum(Simulation simulation) {
  var peak = double.negativeInfinity;
  for (var t = 0.0; t < 2.0; t += 1 / 240) {
    if (simulation.x(t) > peak) peak = simulation.x(t);
  }
  return peak;
}

/// When [simulation] first reports itself finished, or two seconds.
double _settleTime(Simulation simulation) {
  for (var t = 0.0; t < 2.0; t += 1 / 240) {
    if (simulation.isDone(t)) return t;
  }
  return 2.0;
}

/// A motion built the way a `build` method builds one — from values that were
/// not canonicalised — so that equality is doing real work and an invalid
/// argument reaches the runtime assert instead of failing to compile.
PanelMotion _rebuilt(int milliseconds, double bounce) => PanelMotion(
  duration: Duration(milliseconds: milliseconds),
  bounce: bounce,
);

void main() {
  const motions = <String, PanelMotion>{
    'smooth': PanelMotion.smooth(),
    'snappy': PanelMotion.snappy(),
    'bouncy': PanelMotion.bouncy(),
    'interactive': PanelMotion.interactive(),
  };

  group('the pinned constants', () {
    test('are motor\'s Cupertino presets', () {
      expect(const PanelMotion.smooth().duration.inMilliseconds, 500);
      expect(const PanelMotion.smooth().bounce, 0.0);
      expect(const PanelMotion.snappy().duration.inMilliseconds, 500);
      expect(const PanelMotion.snappy().bounce, 0.15);
      expect(const PanelMotion.bouncy().duration.inMilliseconds, 500);
      expect(const PanelMotion.bouncy().bounce, 0.3);
      expect(const PanelMotion.interactive().duration.inMilliseconds, 150);
      expect(const PanelMotion.interactive().bounce, 0.14);
    });

    test('there is exactly one default, unlike the package they came from', () {
      // motor-1.1.0 ships `CupertinoMotion()` at 550 ms (`lib/src/motion.dart:378`)
      // and `CupertinoMotion.smooth()` at 500 ms (`:423`), both documented as the
      // standard iOS spring, so which one a panel got depended on which
      // constructor the call site reached for. This is what stops that being
      // reintroduced by anyone "restoring" the original numbers.
      expect(const PanelMotion(), const PanelMotion.smooth());
      expect(kPanelMotionDuration.inMilliseconds, 500);
      expect(kPanelInteractiveDuration.inMilliseconds, 150);
    });

    test('a duration override keeps the character', () {
      const slow = PanelMotion.bouncy(duration: Duration(seconds: 1));
      expect(slow.bounce, const PanelMotion.bouncy().bounce);
      expect(slow.duration.inMilliseconds, 1000);
    });
  });

  group('the spring underneath', () {
    test('is the SDK factory, and round-trips both parameters', () {
      for (final MapEntry(key: name, value: motion) in motions.entries) {
        final spring = motion.spring;
        expect(
          spring.duration.inMilliseconds,
          motion.duration.inMilliseconds,
          reason: name,
        );
        expect(
          spring.bounce,
          moreOrLessEquals(motion.bounce, epsilon: 1e-12),
          reason: name,
        );
        final expected = SpringDescription.withDurationAndBounce(
          duration: motion.duration,
          bounce: motion.bounce,
        );
        expect(spring.mass, expected.mass, reason: name);
        expect(spring.stiffness, expected.stiffness, reason: name);
        expect(spring.damping, expected.damping, reason: name);
      }
    });

    test('bounce is overshoot, in the order the names promise', () {
      final peaks = <String, double>{
        for (final MapEntry(key: name, value: motion) in motions.entries)
          name: _maximum(motion.createSimulation(start: 0, end: 100)),
      };
      // A resize is a destination, not a gesture: overshooting a height the
      // content was laid out against shows the gap behind the panel. That is why
      // the zero-bounce spring is the default, and this asserts it really is
      // zero-bounce rather than nearly.
      expect(peaks['smooth'], lessThanOrEqualTo(100 + 1e-6));
      expect(peaks['snappy'], greaterThan(100.1));
      expect(peaks['bouncy'], greaterThan(peaks['snappy']!));
      expect(peaks['bouncy'], lessThan(110));
    });

    test('a negative bounce is overdamped, and still arrives', () {
      const thick = PanelMotion(bounce: -0.6);
      final simulation = thick.createSimulation(start: 0, end: 100);
      expect(_maximum(simulation), lessThanOrEqualTo(100 + 1e-6));
      expect(simulation.x(3.0), moreOrLessEquals(100, epsilon: 0.5));
    });

    test('interactive settles before smooth does', () {
      expect(
        _settleTime(
          const PanelMotion.interactive().createSimulation(start: 0, end: 100),
        ),
        lessThan(
          _settleTime(
            const PanelMotion.smooth().createSimulation(start: 0, end: 100),
          ),
        ),
      );
    });
  });

  group('velocity is never discarded', () {
    test('the simulation starts at exactly the velocity it was given', () {
      for (final MapEntry(key: name, value: motion) in motions.entries) {
        for (final v in const [0.0, 200.0, -900.0, 4800.0]) {
          final simulation = motion.createSimulation(
            start: 450,
            end: 435.68,
            velocity: v,
          );
          expect(
            simulation.dx(0),
            moreOrLessEquals(v, epsilon: 1e-9),
            reason: '$name at $v px/s',
          );
          expect(simulation.x(0), moreOrLessEquals(450, epsilon: 1e-9));
        }
      }
    });

    test('including when it points away from the destination', () {
      // The case `smooth_sheets` substitutes zero for
      // (`lib/src/physics.dart:114-118`): the panel is travelling up and the
      // snap decision is downward. Zeroing it starts the spring from rest at the
      // one moment the finger was moving fastest.
      final away = const PanelMotion.smooth().createSimulation(
        start: 450,
        end: 200,
        velocity: 1200,
      );
      expect(away.dx(0), moreOrLessEquals(1200, epsilon: 1e-9));
      // And what comes out is the motion a hand expects: carry on past where it
      // let go, then turn and come back.
      expect(_maximum(away), greaterThan(460));
      expect(away.x(1.5), moreOrLessEquals(200, epsilon: 0.5));
    });
  });

  group('tolerance', () {
    test('defaults to the SDK\'s, which is a 0..1 tolerance', () {
      final simulation = const PanelMotion.smooth().createSimulation(
        start: 0,
        end: 1,
      );
      expect(simulation.tolerance, same(Tolerance.defaultTolerance));
    });

    test('a pixel tolerance settles sooner than a unit-interval one', () {
      // Over an extent in logical pixels the default settles about a thousand
      // times tighter than a 3x screen can show, and every one of those frames
      // is a layout.
      const motion = PanelMotion.smooth();
      final defaulted = motion.createSimulation(start: 0, end: 400);
      final perPixel = motion.createSimulation(
        start: 0,
        end: 400,
        tolerance: const Tolerance(distance: 0.5 / 3, velocity: 0.5 / 3),
      );
      expect(_settleTime(perPixel), lessThan(_settleTime(defaulted)));
    });
  });

  group('refusals and value semantics', () {
    test('a bounce that never comes to rest is refused', () {
      expect(() => _rebuilt(500, 1), throwsAssertionError);
      expect(() => _rebuilt(500, -1), throwsAssertionError);
      expect(() => _rebuilt(500, 2), throwsAssertionError);
      expect(() => _rebuilt(500, double.nan), throwsAssertionError);
      expect(_rebuilt(500, 0.999).bounce, 0.999);
    });

    test('a zero duration is refused by the SDK factory', () {
      // Not asserted at construction: Dart cannot evaluate `Duration` members in
      // a constant expression, and the const constructor is what keeps
      // `const PanelMotion.snappy()` usable at a const call site.
      expect(() => _rebuilt(0, 0).spring, throwsAssertionError);
    });

    test('two motions with the same numbers are the same motion', () {
      const a = PanelMotion(duration: Duration(milliseconds: 320), bounce: 0.2);
      final b = _rebuilt(320, 0.1 + 0.1);
      expect(identical(a, b), isFalse);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, a);
      expect(
        a,
        isNot(const PanelMotion(duration: Duration(milliseconds: 320))),
      );
      expect(a, isNot(const PanelMotion(bounce: 0.2)));
      expect(a, isNot(const Object()));
    });

    test('a motion says what it is', () {
      expect(
        const PanelMotion.snappy().toString(),
        'PanelMotion(500ms, bounce: 0.15)',
      );
    });
  });

  test('the overshoot helper can actually see an overshoot', () {
    // Without this, every no-overshoot claim above would be vacuous.
    final oscillating = SpringSimulation(
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 500),
        bounce: 0.9,
      ),
      0,
      100,
      0,
    );
    expect(_maximum(oscillating), greaterThan(150));
  });
}
