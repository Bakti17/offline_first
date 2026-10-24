import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sqflite/sqflite.dart' as sqflite;

import 'package:offline_first/offline_first.dart';

/// SQLite-backed [OutboxStore]. Single `outbox` table, FIFO by
/// auto-increment `sequence`.
class SqfliteOutboxStore extends OutboxStore {
  SqfliteOutboxStore({sqflite.Database? database, String? dbName})
      : _owned = database == null,
        _dbName = dbName ?? 'offline_first.db';

  static const _table = 'outbox';

  final bool _owned;
  final String _dbName;
  sqflite.Database? _db;

  sqflite.Database get db => _db!;

  @override
  Future<void> open() async {
    if (_db != null) return;
    if (_owned) {
      final dir = await sqflite.getDatabasesPath();
      _db = await sqflite.openDatabase(
        '$dir${Platform.pathSeparator}$_dbName',
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE $_table (
              id TEXT NOT NULL UNIQUE,
              feature TEXT NOT NULL,
              type TEXT NOT NULL,
              payload TEXT NOT NULL,
              idempotency_key TEXT,
              status TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              response_body TEXT,
              next_attempt_at INTEGER,
              created_at INTEGER NOT NULL,
              sequence INTEGER PRIMARY KEY AUTOINCREMENT
            )
          ''');
          await db.execute(
              'CREATE INDEX idx_${_table}_feature_status ON $_table (feature, status, sequence)');
        },
      );
    }
  }

  @override
  Future<void> close() async {
    if (_owned) await _db?.close();
    _db = null;
  }

  @override
  Future<SyncOperation> enqueue(SyncOperation operation) async {
    final row = await db.insert(_table, _toRow(operation));
    return operation.copyWith(sequence: row);
  }

  @override
  Future<List<SyncOperation>> nextBatch(
    String feature, {
    int limit = 20,
    List<SyncStatus> statuses = const [SyncStatus.pending],
  }) async {
    final placeholders = List.filled(statuses.length, '?').join(', ');
    final rows = await db.query(
      _table,
      where: 'feature = ? AND status IN ($placeholders)',
      whereArgs: [feature, ...statuses.map((s) => s.name)],
      orderBy: 'sequence ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<List<SyncOperation>> retryable({int limit = 50}) async {
    final rows = await db.query(
      _table,
      where: 'status IN (?, ?)',
      whereArgs: [SyncStatus.failed.name, SyncStatus.dead.name],
      orderBy: 'sequence ASC',
      limit: limit,
    );
    return rows.map(_fromRow).toList();
  }

  @override
  Future<void> update(SyncOperation operation) async {
    await db.update(
      _table,
      _toRow(operation),
      where: 'id = ?',
      whereArgs: [operation.id],
    );
  }

  @override
  Future<int> purge({
    SyncStatus status = SyncStatus.synced,
    Duration olderThan = const Duration(hours: 24),
  }) async {
    final cutoff = DateTime.now().toUtc().subtract(olderThan);
    return db.delete(
      _table,
      where: 'status = ? AND created_at < ?',
      whereArgs: [status.name, cutoff.millisecondsSinceEpoch],
    );
  }

  @override
  Future<Map<SyncStatus, int>> counts({String? feature}) async {
    final rows = await db.rawQuery(
      'SELECT status, COUNT(*) AS n FROM $_table'
      '${feature != null ? ' WHERE feature = ?' : ''} GROUP BY status',
      feature != null ? [feature] : null,
    );
    return {
      for (final row in rows)
        SyncStatus.values.byName(row['status']! as String): row['n']! as int,
    };
  }

  Map<String, Object?> _toRow(SyncOperation op) => {
        'id': op.id,
        'feature': op.feature,
        'type': op.type.name,
        'payload': jsonEncode(op.payload),
        'idempotency_key': op.idempotencyKey,
        'status': op.status.name,
        'attempts': op.attempts,
        'last_error': op.lastError,
        'response_body': op.responseBody,
        'next_attempt_at': op.nextAttemptAt?.millisecondsSinceEpoch,
        'created_at': op.createdAt.millisecondsSinceEpoch,
        'sequence': op.sequence >= 0 ? op.sequence : null,
      };

  SyncOperation _fromRow(Map<String, Object?> row) => SyncOperation(
        id: row['id']! as String,
        feature: row['feature']! as String,
        type: SyncOperationType.values.byName(row['type']! as String),
        payload:
            (jsonDecode(row['payload']! as String) as Map).cast<String, Object?>(),
        idempotencyKey: row['idempotency_key'] as String?,
        status: SyncStatus.values.byName(row['status']! as String),
        attempts: row['attempts']! as int,
        lastError: row['last_error'] as String?,
        responseBody: row['response_body'] as String?,
        nextAttemptAt: row['next_attempt_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(row['next_attempt_at']! as int,
                isUtc: true),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
            row['created_at']! as int,
            isUtc: true),
        sequence: row['sequence']! as int,
      );
}

/// [ConnectivityAdapter] over connectivity_plus.
///
/// Online = any non-none connectivity result.
class ConnectivityPlusAdapter extends ConnectivityAdapter {
  ConnectivityPlusAdapter({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Future<bool> isOnline() async =>
      _anyOnline(await _connectivity.checkConnectivity());

  @override
  Stream<bool> get onConnectivityChanged =>
      _connectivity.onConnectivityChanged.map(_anyOnline);

  static bool _anyOnline(List<ConnectivityResult> results) =>
      results.any((r) => r != ConnectivityResult.none);
}

/// AES-256-GCM [PayloadCipher]. Key generated on first use, persisted in
/// [FlutterSecureStorage] (Keychain / Keystore), one key per feature.
class FlutterSecurePayloadCipher extends PayloadCipher {
  FlutterSecurePayloadCipher({
    FlutterSecureStorage? storage,
    Random? random,
  })  : _storage = storage ?? const FlutterSecureStorage(),
        _random = random ?? Random.secure();

  static const _keyPrefix = 'offline_first_key_';
  static const _nonceLen = 12;
  static const _macLen = 16;

  final FlutterSecureStorage _storage;
  final Random _random;
  final Map<String, List<int>> _keys = {};

  @override
  Future<List<int>> encrypt(List<int> plaintext, {required String feature}) async {
    final key = await _keyBytes(feature);
    final nonce = List<int>.generate(_nonceLen, (_) => _random.nextInt(256));
    final box = AesGcm.with256bits();
    final secretBox = await box.encrypt(
      plaintext,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    return [...nonce, ...secretBox.cipherText, ...secretBox.mac.bytes];
  }

  @override
  Future<List<int>> decrypt(List<int> ciphertext, {required String feature}) async {
    final key = await _keyBytes(feature);
    if (ciphertext.length < _nonceLen + _macLen) {
      throw ArgumentError('Ciphertext too short');
    }
    final nonce = ciphertext.sublist(0, _nonceLen);
    final mac = Mac(ciphertext.sublist(ciphertext.length - _macLen));
    final cipherText =
        ciphertext.sublist(_nonceLen, ciphertext.length - _macLen);
    final box = AesGcm.with256bits();
    return box.decrypt(
      SecretBox(cipherText, nonce: nonce, mac: mac),
      secretKey: SecretKey(key),
    );
  }

  Future<List<int>> _keyBytes(String feature) async {
    final cached = _keys[feature];
    if (cached != null) return cached;

    final storageKey = '$_keyPrefix$feature';
    var stored = await _storage.read(key: storageKey);
    if (stored == null) {
      stored = base64Encode(
          List<int>.generate(32, (_) => _random.nextInt(256)));
      await _storage.write(key: storageKey, value: stored);
    }
    final key = base64Decode(stored);
    _keys[feature] = key;
    return key;
  }
}
