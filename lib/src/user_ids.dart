import 'dart:async';

/// Provides the current userId.  A provider can cache, stream, store in local storage, generate a uuid, etc
abstract class UserIdProvider {
  String get userId;

  Future dispose();

  factory UserIdProvider.ofGetter(String getUserId()) => UserIdGetter(getUserId);

  factory UserIdProvider.ofStream(Stream<String> userIds) => StreamUserIds(userIds);
}

class UserIdGetter implements UserIdProvider {
  final String Function() getter;

  UserIdGetter(this.getter) : assert(getter != null);

  @override
  Future dispose() async {}

  @override
  String get userId => getter();
}

class StreamUserIds implements UserIdProvider {
  String _userId;

  @override
  String get userId => _userId;

  StreamSubscription _subscription;

  StreamUserIds(Stream<String> userId$) : assert(userId$ != null) {
    _subscription = userId$.listen((_) => _userId = _, cancelOnError: false);
  }

  @override
  Future dispose() {
    return _subscription.cancel();
  }
}
