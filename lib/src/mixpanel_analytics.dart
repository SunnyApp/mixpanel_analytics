import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart';
import 'package:logging/logging.dart';
import 'package:mixpanel_analytics/src/user_ids.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum MixpanelUpdateOperations { $set, $setOnce, $add, $append, $union, $remove, $unset, $delete }

typedef ShaFn = String Function(String value);

final _log = Logger('mixpanelAnalytics');

/// Strategy for processing new events.  Could be [MixpanelBatchSender] or [MixpanelSyncSender]
abstract class MixpanelSender {
  MixpanelAnalytics get analytics;

  Future<bool> processTrackEvent(Map<String, dynamic> event);

  Future<bool> processEngageEvent(Map<String, dynamic> event);

  Future dispose();
}

class MixpanelAnalytics {
  /// This are the update operations allowed for the 'engage' request.
  static const Map<MixpanelUpdateOperations, String> updateOperations = {
    MixpanelUpdateOperations.$set: '\$set',
    MixpanelUpdateOperations.$setOnce: '\$set_once',
    MixpanelUpdateOperations.$add: '\$add',
    MixpanelUpdateOperations.$append: '\$append',
    MixpanelUpdateOperations.$union: '\$union',
    MixpanelUpdateOperations.$remove: '\$remove',
    MixpanelUpdateOperations.$unset: '\$unset',
    MixpanelUpdateOperations.$delete: '\$delete',
  };

  /// This controls how the mixpanel events are queued and sent to the server
  MixpanelSender _sender;

  // The Mixpanel token associated with your project.
  String _token;

  // If present and equal to true, more detailed information will be printed on error.
  bool _verbose;

  // In case we use [MixpanelAnalytics.batch()] we will send analytics every [uploadInterval]
  // Will be zero by default
  Duration _uploadInterval = Duration.zero;

  // In case we use [MixpanelAnalytics.batch()] we need to provide a storage provider
  // This will be used to save the events not sent
  @visibleForTesting
  SharedPreferences prefs;

  UserIdProvider _userIdProvider;

  /// If true, sensitive information like deviceId or userId will be anonymized prior to being sent.
  bool _shouldAnonymize;

  /// As the fields to be anonymized will be the same with every event log, we can keep a cache of the values already anonymized.
  Map<String, String> _anonymized;

  /// Function used to anonymize the data.
  ShaFn _shaFn;

  // If this is not null, any error will be sent to this function, otherwise `debugPrint` will be used.
  void Function(Object error) _onError;

  /// We can inject the client required, useful for testing
  Client http = Client();

  static const String baseApi = 'https://api.mixpanel.com';

  /// Returns the value of the token in mixpanel.
  String get mixpanelToken => _token;

  /// When in batch mode, events will be added to a queue and send in batch every [_uploadInterval]
  bool get isBatchMode => _uploadInterval.compareTo(Duration.zero) != 0;

  /// Default sha function to be used when none is provided.
  static String _defaultShaFn(value) => value;

  /// Used in case we want to remove the timer to send batched events.
  Future dispose() async {
    await _sender.dispose();
    await _userIdProvider.dispose();
  }

  /// Provides an instance of this class.
  /// The instance of the class created with this constructor will send the events on the fly, which could result on high traffic in case there are many events.
  /// Also, if a request returns an error, this will be logged but the event will be lost.
  /// If you want events to be send in batch and also reliability to the requests use [MixpanelAnalytics.batch] instead.
  /// [token] is the Mixpanel token associated with your project.
  /// [userId$] is a stream which contains the value of the userId that will be used to identify the events for a user.
  /// [userIdProvider] the strategy for calculating the current userId
  /// [shouldAnonymize] will anonymize the sensitive information (userId) sent to mixpanel.
  /// [shaFn] function used to anonymize the data.
  /// [verbose] true will provide a detailed error cause in case the request is not successful.
  /// [onError] is a callback function that will be executed in case there is an error, otherwise `debugPrint` will be used.
  MixpanelAnalytics({
    @required String token,
    Stream<String> userId$,
    UserIdProvider userIdProvider,
    bool shouldAnonymize,
    ShaFn shaFn,
    bool verbose,
    Function onError,
  }) : assert(userIdProvider != null || userId$ != null) {
    _sender = MixpanelSyncSender(this);
    _token = token;
    _verbose = verbose;
    _onError = onError;
    _shouldAnonymize = shouldAnonymize ?? false;
    _shaFn = shaFn ?? _defaultShaFn;

    if (userId$ != null) {
      _userIdProvider = StreamUserIds(userId$);
    } else {
      _userIdProvider = userIdProvider;
    }
  }

  /// Provides an instance of this class.
  /// With this constructor, the instance will send the events in batch, and also if the request can't be sent (connectivity issues) it will be retried until it is successful.
  /// [token] is the Mixpanel token associated with your project.
  /// [userId$] is a stream which contains the value of the userId that will be used to identify the events for a user.
  /// [uploadInterval] is the interval used to batch the events.
  /// [shouldAnonymize] will anonymize the sensitive information (userId) sent to mixpanel.
  /// [shaFn] function used to anonymize the data.
  /// [verbose] true will provide a detailed error cause in case the request is not successful.
  /// [onError] is a callback function that will be executed in case there is an error, otherwise `debugPrint` will be used.
  MixpanelAnalytics.batch({
    @required String token,
    Stream<String> userId$,
    UserIdProvider userIdProvider,
    @required Duration uploadInterval,
    bool shouldAnonymize,
    ShaFn shaFn,
    bool verbose,
    Function onError,
  })  : assert(uploadInterval != null),
        assert(userId$ != null || userIdProvider != null),
        assert(token != null) {
    _sender = MixpanelBatchSender(this, uploadInterval);
    _token = token;
    _verbose = verbose;
    _uploadInterval = uploadInterval;
    _shouldAnonymize = shouldAnonymize ?? false;
    _shaFn = shaFn ?? _defaultShaFn;

    _onError = onError;
    if (userId$ != null) {
      _userIdProvider = StreamUserIds(userId$);
    } else {
      _userIdProvider = userIdProvider;
    }
  }

  /// Sends a request to track a specific event.
  /// Requests will be sent immediately. If you want to batch the events use [MixpanelAnalytics.batch] instead.
  /// [event] will be the name of the event.
  /// [properties] is a map with the properties to be sent.
  /// [time] is the date that will be added in the event. If not provided, current time will be used.
  /// [ip] is the `ip` property as explained in [mixpanel documentation](https://developer.mixpanel.com/docs/http)
  /// [insertId] is the `$insert_id` property as explained in [mixpanel documentation](https://developer.mixpanel.com/docs/http)
  Future<bool> track({
    @required String event,
    @required Map<String, dynamic> properties,
    DateTime time,
    String ip,
    String insertId,
  }) async {
    if (event == null) {
      throw ArgumentError.notNull('event');
    }
    if (properties == null) {
      throw ArgumentError.notNull('properties');
    }

    var trackEvent = _createTrackEvent(event, properties, time ?? DateTime.now(), ip, insertId);

    return _sender.processTrackEvent(trackEvent);
  }

  /// Sends a request to engage a specific event.
  /// Requests will be sent immediately. If you want to batch the events use [MixpanelAnalytics.batch] instead.
  /// [operation] is the operation update as per [MixpanelUpdateOperations].
  /// [value] is a map with the properties to be sent.
  /// [time] is the date that will be added in the event. If not provided, current time will be used.
  /// [ip] is the `ip` property as explained in [mixpanel documentation](https://developer.mixpanel.com/docs/http)
  /// [ignoreTime] is the `$ignore_time` property as explained in [mixpanel documentation](https://developer.mixpanel.com/docs/http)
  /// [ignoreAlias] is the `$ignore_alias` property as explained in [mixpanel documentation](https://developer.mixpanel.com/docs/http)
  Future<bool> engage({
    @required MixpanelUpdateOperations operation,
    @required Map<String, dynamic> value,
    DateTime time,
    String ip,
    bool ignoreTime,
    bool ignoreAlias,
  }) async {
    if (operation == null) {
      throw ArgumentError.notNull('operation');
    }
    if (value == null) {
      throw ArgumentError.notNull('value');
    }

    var engageEvent = _createEngageEvent(operation, value, time ?? DateTime.now(), ip, ignoreTime, ignoreAlias);

    return _sender.processEngageEvent(engageEvent);
  }

  // The track event is coded into base64 with the required properties.
  Map<String, dynamic> _createTrackEvent(
    String event,
    Map<String, dynamic> props,
    DateTime time,
    String ip,
    String insertId,
  ) {
    final providedUserId = _userIdProvider.userId;
    final userId = props['distinct_id'] == null
        ? providedUserId == null ? null : _shouldAnonymize ? _anonymize('userId', providedUserId) : providedUserId
        : props['distinct_id'];

    var properties = {...props, 'token': _token, 'time': time.millisecondsSinceEpoch, 'distinct_id': userId};
    if (ip != null) {
      properties = {...properties, 'ip': ip};
    }
    if (insertId != null) {
      properties = {...properties, '\$insert_id': insertId};
    }
    var data = {'event': event, 'properties': properties};
    return data;
  }

  // The engage event is coded into base64 with the required properties.
  Map<String, dynamic> _createEngageEvent(MixpanelUpdateOperations operation, Map<String, dynamic> value, DateTime time,
      String ip, bool ignoreTime, bool ignoreAlias) {
    final providedUserId = _userIdProvider.userId;
    final userId = value['distinct_id'] == null
        ? providedUserId == null ? null : _shouldAnonymize ? _anonymize('userId', providedUserId) : providedUserId
        : value['distinct_id'];

    var data = {
      updateOperations[operation]: value,
      '\$token': _token,
      '\$time': time.millisecondsSinceEpoch,
      '\$distinct_id': userId
    };
    if (ip != null) {
      data = {...data, '\$ip': ip};
    }
    if (ignoreTime != null) {
      data = {...data, '\$ignore_time': ignoreTime};
    }
    if (ignoreAlias != null) {
      data = {...data, '\$ignore_alias': ignoreAlias};
    }
    return data;
  }

  // Event data has to be sent with base64 encoding.
  String _base64Encoder(Object event) {
    var str = json.encode(event);
    var bytes = utf8.encode(str);
    var base64 = base64Encode(bytes);
    return base64;
  }

  Future<bool> _sendTrackEvent(String event) => _sendEvent(event, 'track');

  Future<bool> _sendEngageEvent(String event) => _sendEvent(event, 'engage');

  // Sends the event to the mixpanel API endpoint.
  Future<bool> _sendEvent(String event, String op) async {
    var url = '$baseApi/$op/?data=$event&verbose=${_verbose ? 1 : 0}';
    try {
      var response = await http.get(url, headers: {
        'Content-type': 'application/json',
      });
      return response.statusCode == 200 && _validateResponseBody(url, response.body);
    } on Exception catch (error) {
      _onErrorHandler(error, 'Request error to $url');
      return false;
    }
  }

  // Depending on the value of [verbose], this will validate the body and handle the error.
  // Check [mixpanel documentation](https://developer.mixpanel.com/docs/http) for more information on `verbose`.
  bool _validateResponseBody(String url, String body) {
    if (_verbose) {
      var decodedBody = json.decode(body);
      var status = decodedBody['status'];
      var error = decodedBody['error'];
      if (status == 0) {
        _onErrorHandler(null, 'Request error to $url: $error');
        return false;
      }
      return true;
    }
    // no verbose
    if (body == '0') {
      _onErrorHandler(null, 'Request error to $url');
      return false;
    }
    return true;
  }

  // Anonymizes the field but also saves it in a local cache.
  String _anonymize(String field, String value) {
    _anonymized ??= {};
    if (_anonymized[field] == null) {
      _anonymized[field] = _shaFn(value);
    }
    return _anonymized[field];
  }

  // Proxies the error to the callback function provided or to standard `debugPrint`.
  void _onErrorHandler(dynamic error, String message) {
    if (_onError != null) {
      _onError(error ?? message);
    } else {
      debugPrint(message);
    }
  }
}

class MixpanelSyncSender implements MixpanelSender {
  @override
  final MixpanelAnalytics analytics;

  const MixpanelSyncSender(this.analytics);

  @override
  Future<bool> processTrackEvent(Map<String, dynamic> trackEvent) {
    var base64Event = analytics._base64Encoder(trackEvent);
    return analytics._sendTrackEvent(base64Event);
  }

  @override
  Future<bool> processEngageEvent(Map<String, dynamic> event) {
    var base64Event = analytics._base64Encoder(event);
    return analytics._sendEngageEvent(base64Event);
  }

  @override
  Future dispose() async {}
}

class MixpanelBatchSender implements MixpanelSender {
  @override
  final MixpanelAnalytics analytics;

  final _onComplete = Completer();
  bool _isActive = true;

  final Duration uploadInterval;
  SharedPreferences prefs;

  MixpanelBatchSender(this.analytics, this.uploadInterval) {
    scheduleBatch();
  }

  @override
  Future dispose() {
    _isActive = false;
    return _onComplete.future;
  }

  Future scheduleBatch() async {
    _log.info('Starting mixpanel batch processing');
    while (_isActive == true) {
      await Future.delayed(uploadInterval);
      try {
        await _uploadQueuedEvents();
        // ignore: avoid_catches_without_on_clauses
      } catch (e, stack) {
        _log.severe('Error uploading batch: $e', e, stack);
      }
    }
    _log.info('Stopping mixpanel batch processing');
    if (!_onComplete.isCompleted) {
      _onComplete.complete();
    }
  }

  @override
  Future<bool> processEngageEvent(Map<String, dynamic> engageEvent) {
    _engageEvents.add(engageEvent);
    return _saveQueuedEventsToLocalStorage();
  }

  @override
  Future<bool> processTrackEvent(Map<String, dynamic> trackEvent) {
    _trackEvents.add(trackEvent);
    return _saveQueuedEventsToLocalStorage();
  }

  // Reads queued events from the storage when we are in batch mode.
  // We do this in case the app was closed with events pending to be sent.
  Future<void> _restoreQueuedEventsFromStorage() async {
    prefs ??= await SharedPreferences.getInstance();
    var encoded = prefs.getString(_prefsKey);
    if (encoded != null) {
      Map<String, dynamic> events = json.decode(encoded);
      _queuedEvents.addAll(events);
    }
  }

  // If we are in batch mode we save all events in storage in case the app is closed.
  Future<bool> _saveQueuedEventsToLocalStorage() async {
    prefs ??= await SharedPreferences.getInstance();
    var encoded = json.encode(_queuedEvents);
    var result = await prefs.setString(_prefsKey, encoded).catchError((error) {
      analytics._onErrorHandler(error, 'Error saving events in storage');
      return false;
    });
    return result;
  }

  // Tries to send all events pending to be send.
  // TODO if error when sending, send events in isolation identify the incorrect message
  Future<void> _uploadQueuedEvents() async {
    if (!_isQueuedEventsReadFromStorage) {
      await _restoreQueuedEventsFromStorage();
      _isQueuedEventsReadFromStorage = true;
    }
    if (_trackEvents.isNotEmpty || _engageEvents.isNotEmpty) {
      _log.info('Sending ${_trackEvents.length} track; ${_engageEvents.length} engage');
    } else {
      _log.fine('No mixpanel events to send');
    }
    await _uploadEvents(_trackEvents, _sendTrackBatch);
    await _uploadEvents(_engageEvents, _sendEngageBatch);
    await _saveQueuedEventsToLocalStorage();
  }

  // Queued events used when these are sent in batch.
  final Map<String, dynamic> _queuedEvents = {'track': [], 'engage': []};

  List<dynamic> get _trackEvents => _queuedEvents['track'];

  List<dynamic> get _engageEvents => _queuedEvents['engage'];

  // This is false when start and true once the events are restored from storage.
  bool _isQueuedEventsReadFromStorage = false;

// Uploads all pending events in batches of maximum [maxEventsInBatchRequest].
  Future<void> _uploadEvents(List<dynamic> events, Function sendFn) async {
    List<dynamic> unsentEvents = [];
    while (events.isNotEmpty) {
      var maxRange = _getMaximumRange(events.length);
      var range = events.getRange(0, maxRange).toList();
      var batch = analytics._base64Encoder(range);
      var success = await sendFn(batch);
      if (!success) {
        unsentEvents.addAll(range);
      }
      events.removeRange(0, maxRange);
    }
    if (unsentEvents.isNotEmpty) {
      events.addAll(unsentEvents);
    }
  }

  // As the API for Mixpanel only allows 50 events per batch, we need to restrict the events sent on each request.
  int _getMaximumRange(int length) => length < maxEventsInBatchRequest ? length : maxEventsInBatchRequest;

  static const int maxEventsInBatchRequest = 50;

  Future<bool> _sendTrackBatch(String event) => _sendBatch(event, 'track');
  static const _prefsKey = 'mixpanel.analytics';

  Future<bool> _sendEngageBatch(String event) => _sendBatch(event, 'engage');

  // Sends the batch of events to the mixpanel API endpoint.
  Future<bool> _sendBatch(String batch, String op) async {
    var url = '${MixpanelAnalytics.baseApi}/$op/?verbose=${analytics._verbose ? 1 : 0}';
    try {
      var response = await analytics.http.post(url, headers: {
        'Content-type': 'application/x-www-form-urlencoded',
      }, body: {
        'data': batch
      });
      return response.statusCode == 200 && analytics._validateResponseBody(url, response.body);
    } on Exception catch (error) {
      analytics._onErrorHandler(error, 'Request error to $url');
      return false;
    }
  }
}
