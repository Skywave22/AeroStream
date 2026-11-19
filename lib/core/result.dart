import 'plugin_error.dart';

/// The outcome of an operation that can fail for reasons the caller must see.
///
/// AeroStream never lets an untrusted plugin throw into UI code, so every
/// plugin-facing boundary returns `Result<T>` instead of throwing:
///
/// ```dart
/// switch (provider.search('dune')) {
///   case Ok(:final value): render(value);
///   case Err(:final error): showError(error.userMessage);
/// }
/// ```
sealed class Result<T> {
  const Result();

  const factory Result.ok(T value) = Ok<T>;
  const factory Result.err(PluginError error) = Err<T>;

  bool get isOk => this is Ok<T>;

  bool get isErr => this is Err<T>;

  /// The success value, or `null`.
  T? get valueOrNull => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>() => null,
  };

  /// The failure, or `null`.
  PluginError? get errorOrNull => switch (this) {
    Ok<T>() => null,
    Err<T>(:final error) => error,
  };

  /// Transforms a success value, leaving a failure untouched.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
    Ok<T>(:final value) => Ok<R>(transform(value)),
    Err<T>(:final error) => Err<R>(error),
  };

  /// Chains another fallible step.
  Result<R> flatMap<R>(Result<R> Function(T value) transform) =>
      switch (this) {
        Ok<T>(:final value) => transform(value),
        Err<T>(:final error) => Err<R>(error),
      };

  /// The success value, or [fallback] computed from the failure.
  T getOrElse(T Function(PluginError error) fallback) => switch (this) {
    Ok<T>(:final value) => value,
    Err<T>(:final error) => fallback(error),
  };
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;

  @override
  bool operator ==(Object other) => other is Ok<T> && other.value == value;

  @override
  int get hashCode => Object.hash('Ok', value);

  @override
  String toString() => 'Ok($value)';
}

final class Err<T> extends Result<T> {
  const Err(this.error);

  final PluginError error;

  @override
  bool operator ==(Object other) => other is Err<T> && other.error == error;

  @override
  int get hashCode => Object.hash('Err', error);

  @override
  String toString() => 'Err($error)';
}
