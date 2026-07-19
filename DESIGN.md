# log_kit 設計書

## 1. 背景・目的

既存アプリにアドホックに実装されていたログ機構（Talkerベースのカスタム
ロガー、日次ローテーションするファイル出力、zip化して共有する機能）を、
汎用パッケージとして切り出す。

- ログの保持（メモリ上のリングバッファ + ディスク上のローテーションファイル）
- ログの共有ダンプ（zip化してユーザーが送信できる形にする）

を、移行元アプリ固有のロジック（dev ビルド判定、固定タグプレフィックスなど）
を排除した形で、`path:` 依存の他アプリからも利用できる形に一般化する。

Talker への依存はやめ、自前実装とする（外部依存を減らし、ローテーション・
フォーマット仕様を完全に制御下に置くため）。

## 2. 移行元アプリの現状整理

| 機能 | 移行元での実装場所 | 内容 |
|---|---|---|
| ログ出力API | `print.dart: customLogger()` | console + Talker 経由でファイル出力 |
| レガシーAPI互換 | `print.dart: logger (_LegacyLoggerShim)` | `.d/.i/.v/.w/.e` |
| ファイル保持 | `print.dart: FileLogObserver` | 日次ファイル、7日/50MB超で削除 |
| 共有ダンプ | `log_share.dart: shareAppLogs()` | ディレクトリをzip化 → share_plus |
| 有効化条件 | `initLogger()` 内 dev build 判定 | `!kReleaseMode \|\| isDevBuild` |

この設計では上表の「機能」を汎用APIとして再設計し、「移行元での実装」列に
あったアプリ固有判断はすべて呼び出し側の `LogKitConfig` に追い出す。

## 3. パッケージ概要

- **パッケージ名**: `log_kit`（`flutter_plugin/log` ディレクトリはそのまま、
  `pubspec.yaml` の `name: log_kit` とする。当面はローカル path 依存での
  利用を想定）
- **依存**: `path_provider`, `archive`, `share_plus`。`package_info_plus` /
  `device_info_plus` はコアに含めず、メタデータ注入はコールバックで呼び出し側に
  委ねる。

> **レビュー反映**: 当初 `dumpLogs()`（zip生成のみ）と `shareLogs()`
> （share_plus 使用）を「依存を分離する」目的で分けて設計したが、Dart/Flutter
> パッケージに optional dependency は存在せず、`share_plus` を pubspec に書く
> 時点で `dumpLogs()` しか使わないアプリにもネイティブコード込みで入る。
> 対象アプリは全て社内アプリで依存最小化より運用の単純さを優先し、
> **`log_kit` 単一パッケージに `share_plus` を含める**方針とする
> （§4.4 のAPI分割自体は「zip生成」と「共有UI起動」を疎結合にする意味で維持）。

### ディレクトリ構成

```
log_kit/
  lib/
    log_kit.dart                 # public export
    src/
      log_level.dart             # enum LogLevel { verbose, debug, info, warn, error }
      log_entry.dart             # class LogEntry (timestamp, level, tag, message, error, stackTrace)
      log_kit.dart                # LogKit facade (singleton的 static API)
      config.dart                 # LogKitConfig
      sinks/
        log_sink.dart             # abstract interface
        console_sink.dart
        ring_buffer_sink.dart     # 直近N件をメモリ保持（アプリ内ログビューア用）
        file_sink.dart            # 日次ローテーション + サイズ上限
      dump/
        log_dumper.dart           # zip化 + メタデータ同梱
        share_log_dumper.dart     # share_plus を使った共有実装
      viewer/
        log_viewer_page.dart      # （任意）ring buffer を表示する簡易画面
  test/
    file_sink_rotation_test.dart
    log_dumper_test.dart
  example/
    lib/main.dart
```

## 4. 公開 API

### 4.1 初期化

```dart
await LogKit.init(
  LogKitConfig(
    appName: 'my_app',                // タグ prefix / メタデータに使用
    minLevel: LogLevel.debug,
    fileLoggingEnabled: () => !kReleaseMode || _isInternalBuild(),
    retention: const LogRetentionPolicy(
      maxAgeDays: 7,
      maxTotalBytes: 50 * 1024 * 1024,
      maxFileBytes: 5 * 1024 * 1024,  // 単一ファイルの上限（新規追加）
    ),
    ringBufferCapacity: 500,          // アプリ内ログビューア用
    directory: null,                  // 省略時 getApplicationSupportDirectory()/logs
  ),
);
```

- `fileLoggingEnabled` を `bool Function()` にすることで、移行元アプリの
  dev-build 判定のようなアプリ固有ロジックを外側で自由に注入できる。
- `LogKit.init` の idempotent 定義（レビュー反映で明確化）:
  - 2回目以降の呼び出しは **最初に成功した `config` を採用し、渡された引数は
    無視して warning ログのみ出す**（上書き禁止）。バックグラウンド Isolate
    のエントリポイントと main 側で異なる config を渡してしまう事故を防ぐため。
  - `RingBufferSink` は Isolate ローカルであり、Isolate 間で共有されない
    （= バックグラウンド Isolate で出したログはメイン Isolate の
    `LogViewerPage` には表示されない。ファイルには両方書き込まれるので
    ダンプには含まれる）。この制約を README に明記する。

### 4.2 ログ出力

```dart
LogKit.d('画面遷移: Home -> Chat', tag: 'Nav');
LogKit.e('token refresh failed', error: e, stackTrace: st, tag: 'Auth');
```

- 内部で `LogEntry` を組み立て、登録済み全 `LogSink` に配布する。
- タグ・カテゴリ規約（`.logs/LOGS.md` にある `[Chat][STREAM]` や FlowID 相関ID
  など）はコア機能にせず、README に「推奨フォーマット」として記載するのみ。
  `tag` 引数と `context: {'flowId': ...}` のような自由な Map を持たせ、
  フォーマットは `LogFormatter`（差し替え可能）が文字列化する。
- `LogLevel` は `enum` に `index`（`verbose=0 < debug=1 < info=2 < warn=3 <
  error=4`）を用いた `Comparable<LogLevel>` 実装を持たせ、`entry.level >=
  LogLevel.warn` のような比較を可能にする（enum は素の演算子を持たないため
  明示的に実装が必要）。
- **Redaction（機微情報マスキング）**: 共有ダンプは端末外に持ち出される前提
  のため、`LogFormatter` にメッセージ整形の最終段として
  `List<RedactionRule>`（正規表現 → 置換文字列）を通すフックを設ける。
  デフォルトは空リスト（呼び出し側が明示的に設定）。README で
  「認証トークン・電話番号等をログに出す場合は redaction ルールを設定すること」
  を明記する。

### 4.3 独自 Sink の追加（Crashlytics/Sentry 連携）

```dart
LogKit.addSink(CallbackLogSink((entry) {
  if (entry.level >= LogLevel.warn) {
    FirebaseCrashlytics.instance.log(entry.format());
  }
}));
```

現状の移行元アプリでは Talker とCrashlyticsが無関係に併存しているが、これを
sink として明示的に繋げられるようにする（任意）。

### 4.4 ダンプ／共有

```dart
final zipFile = await LogKit.dumpLogs(
  metadata: {
    'appVersion': packageInfo.version,
    'device': deviceInfo.model,
  },
);

await LogKit.shareLogs(
  context,
  subject: 'アプリログ',
  metadata: {...},               // 上と同様、呼び出し側で自由に注入
  extraFiles: [someDebugFile],   // 任意の追加ファイルを同梱可能（新規）
  sharePositionOrigin: box,      // iPad 必須。省略時はレンダーボックスから自動解決を試みる
);
```

- `dumpLogs()`（zip生成）と `shareLogs()`（共有UI起動）は同一パッケージ内だが
  **API としては疎結合を維持**する（`shareLogs` は内部で `dumpLogs` を呼ぶ薄い
  ラッパー）。共有UIを使わないアプリは `dumpLogs()` だけを呼べばよい
  （依存パッケージ自体は同梱されるが、呼び出しは分離できる）。
- zip 内に `metadata.json` を同梱し、端末情報・アプリバージョン・生成日時を
  機械可読に残す（現状の移行元アプリにはなくレビュー時に有用）。
- ログファイルが1件もない場合の確認ダイアログは `LogViewerPage` 側のUIヘルパー
  として提供し、コアAPIとは独立させる。
- **`shareLogs()` は iOS/iPadOS で `sharePositionOrigin` 省略時に
  クラッシュし得る**（share_plus の既知の制約）。`context` から
  `context.findRenderObject()` のグローバル座標を自動解決してデフォルト値と
  し、呼び出し側が明示指定した場合はそれを優先する。

#### ダンプ時の競合・パフォーマンス対策（レビュー反映）

- **書き込み中ファイルとの競合**: `dumpLogs()` はまず `FileSink` の内部
  書き込みチェーン（`_writeChain`）に「フラッシュ完了を待つ」タスクを積み、
  それが解決してから zip 対象ファイルを**一時ディレクトリへコピー**する。
  コピー後のスナップショットに対して zip 化するため、zip 中に新規ログが
  追記されても壊れたzipにならない。
- **zip 化はバックグラウンドで実行**: `archive` の `ZipFileEncoder` は同期
  APIで、ログ総量が大きい（最大 `maxTotalBytes` = 50MB 想定）と UI スレッドを
  数百ms〜数秒ブロックし得る。`Isolate.run()`（Dart 2.19+）でzip処理を
  別Isolateに逃がす。Isolate 境界を越えるため、渡すのは
  「一時コピー先ディレクトリのパス文字列」「出力先パス文字列」「metadataの
  JSON文字列」のみとし、`path_provider` 等プラグイン呼び出しは事前にメイン
  Isolate側で解決してから渡す。

### 4.5 アプリ内ログビューア（新規・任意機能）

現状の移行元アプリにはリングバッファも簡易ビューアもない。`ringBufferCapacity`
を設定すると、直近N件をメモリに保持する `RingBufferSink` が有効になり、
`LogViewerPage` で開発中に確認できるようにする（QA/社内ビルドでの一次切り分けに有効）。

## 5. ファイル保持（Retention）の設計

`FileSink` は移行元アプリの `FileLogObserver` を一般化する:

- 書き込み先: `<config.directory ?? appSupportDir/logs>/log_YYYYMMDD.log`
- 同一プロセス内での書き込み直列化: `Future` チェーン（現行踏襲）
- マルチプロセス/複数Isolateからの追記は OS の `O_APPEND` に依存（現行踏襲、
  ドキュメントに明記し「同一ファイルへの追記はアトミックだが行の分割書き込み
  は避けること」を注意書きする）
- ローテーションを2軸に拡張:
  - 日付が変わったら新規ファイル
  - **単一ファイルサイズが `maxFileBytes` を超えたら連番サフィックス
    (`log_YYYYMMDD_2.log`) で新規ファイル**（移行元アプリには無い、長時間起動アプリ
    でも安全にするための追加）
- 起動時 `_rotate()`：`maxAgeDays` より古いファイル削除、その後total sizeが
  `maxTotalBytes` を超える分を古い順に削除（現行踏襲）
- **削除順序は必ず `File.lastModifiedSync()`（mtime）でソートする**（レビュー
  反映）。ファイル名の辞書順ソートだと連番サフィックス方式で `log_20260101_10.log`
  が `log_20260101_2.log` より前に来てしまい、削除順が意図と逆転するため。

## 6. マイグレーション方針（移行元アプリ側）

1. `flutter_plugin/log` を `pubspec.yaml` に `path:` 依存として追加
2. `print.dart` の `customLogger`/`logger` 呼び出し箇所（100+ 箇所）は、
   まず `print.dart` 内部で `LogKit.d/i/w/e/v` に委譲する薄いラッパーとして
   残し、一括置換はしない（既存コールサイトを壊さないため）
3. `log_share.dart: shareAppLogs()` を `LogKit.shareLogs()` 呼び出しに置き換え
4. dev-build 判定・Crashlytics連携は `LogKitConfig` / `addSink` に移設
5. 動作確認後、余力があれば `print.dart` の薄ラッパーを段階的に `LogKit` 直呼びへ
   置換（本設計のスコープ外、別タスク）

## 7. テスト方針

- `FileSink` のローテーション（日次/サイズ超過/期限超過削除）をユニットテスト
  （`Directory.systemTemp` を使い、Clock を注入可能にして日付をモック）
- `LogDumper` の zip 内容検証（ファイル一覧・metadata.json の中身）
- `RingBufferSink` の容量超過時の先頭破棄
- 実機/共有UIの疎通は `example/` アプリで手動確認

## 8. 未決事項 / 次ステップで詰める点

- ログフォーマット（1行のプレフィックス形式）を移行元アプリの
  `[PID][Isolate][UUID]` 形式のままデフォルトにするか、簡略化するか
- `LogViewerPage` を最初のスコープに含めるか、v2 に回すか
- Web/Desktop対応の要否（移行元アプリはモバイル中心、他アプリでdesktop/webがあれば
  `path_provider` の対応状況を要確認）

上記が固まり次第、`pubspec.yaml` とコア実装（`LogLevel`, `LogEntry`,
`LogKitConfig`, `FileSink`, `LogDumper`）から実装に着手する。

## 9. 実装後レビューでの修正（実績）

初回実装をレビューした結果、以下を修正した:

- **`FileSink`のローテーションサイズ判定を UTF-8 バイト長に修正**: 当初
  `String.length`（UTF-16コードユニット数）で `maxFileBytes` 判定していたため、
  日本語や絵文字を含むログでローテーションが最大3倍程度緩くなっていた。
  `utf8.encode()` したバイト列の長さで判定し、そのバイト列をそのまま
  `writeAsBytes` するよう変更（二重エンコードも回避）。
- **ダンプ zip の一時ファイル漏れを解消**: `LogDumper` を毎回使い捨てで
  生成していたため、`dumpLogs()`/`shareLogs()` を呼ぶたびに `tempRoot`
  以下の zip がシステム一時ディレクトリに残り続けていた。`LogKit` が
  `LogDumper` を単一インスタンスとして保持し、次回 `dumpLogs()` 呼び出し時に
  前回分を自動削除する方式に変更。加えて `LogKit.disposeLastDump()` /
  `LogDumper.disposeLastDump()` を公開し、呼び出し側がアップロード完了後
  などに即時削除できるようにした。
- **iPad の `sharePositionOrigin` 解決失敗を可視化**: `BuildContext` から
  `RenderBox` を解決できなかった場合、無言で `null` を返していたのを
  `developer.log` で警告するように変更。
- **`LogKit.init()` 前のログ呼び出しが release ビルドで完全に消える問題を修正**:
  `assert(false, ...)` はリリースビルドで除去されるため、信号ゼロで
  ログが消えていた。`developer.log` による警告を assert とは別に追加。
- **`LogDumper` が `directory` 内の全ファイルを無条件に zip 対象にしていたのを、
  `FileSink.fileNamePattern` に一致するファイルのみに限定**（`directory` が
  専用ディレクトリでない場合の巻き込み事故を防止）。

いずれもテスト（`file_sink_test.dart`, `log_dumper_test.dart`）に回帰テストを
追加済み。

## 10. ネイティブ連携（Kotlin/Swift からのログ出力）

移行元アプリ側の調査で「ネイティブ(Android/Swift)側のログ収集がない」ことが判明して
いたため、`log_kit` を（Dart単体パッケージではなく）**真の Flutter plugin**
として実装した。

### 方式

ネイティブ→Dart の `MethodChannel` 呼び出しで `LogKit` に転送する方式を採用
（採用理由: ローテーション/保持/フォーマット/リダクションのロジックを
Dart側に一本化でき、Kotlin/Swiftに再実装・再保守する必要がない）。

- **制約**: `FlutterEngine` が起動し、Dart側isolateでチャンネルハンドラが
  登録された後（= `LogKit.init()` 完了後）でなければネイティブ→Dartの呼び出しは
  届かない。`Application.onCreate()` など Flutter 起動前のネイティブコードから
  のログは届かず、サイレントに破棄される（Dart側の「`init()`前ログ破棄」と
  同じ制約）。純ネイティブ・クラッシュハンドラ等、Flutterエンジン起動前から
  ログを取りたい場合は本方式の対象外（将来の直接ファイル書き込み方式の
  検討対象、DESIGN.md §8「未決事項」に近い位置づけ）。

### 構成

- `pubspec.yaml` に `flutter.plugin.platforms.android/ios` を追加し、
  plugin化。
- **Android**: `android/src/main/kotlin/.../LogKitPlugin.kt`
  （`FlutterPlugin` 実装、`onAttachedToEngine`/`onDetachedFromEngine`で
  `MethodChannel` の attach/detach）+ `LogKitNative.kt`（アプリの任意の
  Kotlin/Javaコードから呼べる `LogKitNative.d(tag, message)` 等の
  静的API、内部でメインスレッドへ`invokeMethod`）。
- **iOS**: `ios/Classes/LogKitPlugin.swift`（`FlutterPlugin`実装、
  `register(with:)`でチャンネル登録）+ `LogKitNative.swift`（同様の
  `LogKitNative.d(tag:message:)` 等）。
- **Dart**: `lib/src/native_bridge.dart` の `NativeLogBridge` が
  `MethodChannel('log_kit')` の `'log'` メソッド呼び出しを受け取り、
  `LogEntry` を再構築して `LogKit` の全 sink（`FileSink` 含む）へ配布する。
  `LogKit.init()` 内で `LogKitConfig.enableNativeBridge`（デフォルト`true`）
  に応じて attach。
- ネイティブ側は `timestampMillis`（送信時刻）を payload に含め、Dart側の
  受信処理時刻とのズレ（チャンネル往復レイテンシ）を排除している。
- `LogKit._dispatch()` を新設し、Dart呼び出し経由（`LogKit.d/i/w/e/v`）と
  ネイティブ経由の両方が同じ `minLevel` フィルタ・sink配布ロジックを共有
  するようリファクタリング。

### 未検証事項

この環境には Android SDK / Xcode のビルド環境がないため、Kotlin/Swift側の
コードは **静的なコードレビューのみ**で、実機/エミュレータでのビルド・実行
検証は未実施。移行元アプリ側に組み込む際に Android Studio / Xcode で
ビルドが通ることを確認する必要がある。

## 11. 深掘りレビューでの修正（実績・第2回）

初回レビュー後の実装に対して「並行処理・Isolate安全性・エッジケース・性能・
アプリ移行時のデグレリスク」観点で深掘りレビューを行い、以下を修正した。

- **`LogKit.init()` がバインディング未初期化のIsolateでクラッシュする問題を
  修正**: `enableNativeBridge`（デフォルト`true`）による
  `MethodChannel.setMethodCallHandler` 呼び出しと、`config.directory` 省略時の
  `getApplicationSupportDirectory()` 呼び出しは、いずれも Flutter バインディング
  を持たない素の `Isolate.spawn`/`Isolate.run` 上で例外を投げる。修正前は
  この例外が `LogKit.init()` を reject し、かつ `_initStarted` が例外前に
  立っていたため再initも不能だった。修正後は両者を try/catch で包み、失敗時は
  警告ログを出して**コンソール/リングバッファのみで縮退動作**する
  （`logFilesDirectory`/`dumpLogs`/`shareLogs` は縮退状態を反映）。
  `test/isolate_resilience_test.dart` で実際に `Isolate.run` 経由で
  バインディングなしIsolate上の `init()` が例外を投げないことを検証済み。
- **`FileSink._cleanup()` の削除処理が競合で例外化する問題を修正**: 複数
  Isolate/プロセスが同じログディレクトリに対しほぼ同時に `init()` を実行した
  場合、片方が削除した後にもう片方が同じファイルを `delete()` して
  `PathNotFoundException` が飛び、`init()` 全体が失敗し得た
  （移行元アプリはworkmanager/FCMから初期化する設計のため理論値ではない）。
  ファイル単位で try/catch し、既に消えているファイルは「クリーンアップ済み」
  として扱うよう修正。回帰テストとして2つの `FileSink` を同一ディレクトリに
  対して同時に `init()` させるテストを追加。
- **`LogDumper.dumpLogs()` の並行呼び出しで進行中のダンプが破壊される問題を
  修正**: 共有ボタンの連打等で `dumpLogs()` が多重に呼ばれると、後発の呼び出しが
  冒頭の `disposeLastDump()` で先発の一時ディレクトリを削除してしまい得た。
  FIFOキュー（`_enqueue`）で直列化し、同一 `LogDumper` インスタンスへの
  呼び出しは呼び出し順に1つずつ処理されるよう修正。
- **`CallbackLogSink` 経由でRedactionが素通りする問題を修正**: Redactionは
  `LogFormatter.format()` の最終段でのみ適用されるため、生の `LogEntry` を
  受け取る `CallbackLogSink`（Crashlytics連携等）には効かない。加えて
  README のサンプルコードが `const LogFormatter()`（redactionルールなし）で
  フォーマットしていたため、そのままコピーしたアプリは未マスクのログを
  外部送信し得た。`LogKit.formatter`（設定済みフォーマッタを返すgetter）を
  追加し、README/REFERENCEの例をそれを使う形に修正。
- **`ConsoleSink` の `dart:developer` ログレベルへのマッピングが誤っていた
  問題を修正**: `severity * 200` では `error` が `dart:developer` の
  `INFO`(800)相当に、`warn` が `CONFIG`〜`FINE`間(600)相当になり、
  DevTools/IDEのレベルフィルタ・色分けが崩れていた。
  `FINEST=300/FINE=500/INFO=800/WARNING=900/SEVERE=1000` への明示的な
  マッピングテーブル（`ConsoleSink.developerLevels`、テストから参照可能に
  公開）に修正。

いずれも `test/isolate_resilience_test.dart`, `test/file_sink_test.dart`,
`test/log_dumper_test.dart`, `test/console_sink_test.dart` に回帰テストを
追加済み（テスト総数32件、全通過）。

## 12. 深掘りレビューでの修正（実績・第3回）

「修正自体が新たな穴を作っていないか」「ネイティブのライフサイクル・
`init()`の並行性・sinkの例外設計」観点での第3回レビューにより、以下を修正した。

- **Android: マルチエンジン構成で先に破棄されたエンジンが後発エンジンの
  ログを止めてしまう問題を修正**: `LogKitPlugin.onDetachedFromEngine` が
  無条件に `LogKitNative.detach()`（`channel = null`）していたため、
  `FlutterEngineGroup`/add-to-app で複数エンジンが動く構成では、後から
  attachしたエンジンが生きているのに先に破棄されたエンジンのdetachで
  ネイティブログが全て黙って消える事故があり得た。`LogKitPlugin` が自分の
  channelインスタンスを保持し、`LogKitNative.detachIf(expected)` で
  「今の channel が自分の登録したものと同一の場合のみ」null化するよう修正。
  iOS側はそもそも detach 処理が皆無だった（生きているengineが破棄後も死んだ
  messengerへ`invokeMethod`し続ける）ため、`registrar.addMethodCallDelegate`
  経由でインスタンス登録し `detachFromEngine(for:)` を実装、同様の
  `detachIf` ガードを追加して Android と揃えた。
  （Dartテスト対象外。移行先アプリ組み込み時の実機確認項目とする）
- **`LogKit.init()` の2回目呼び出しが1回目の完了を待たずに解決する問題を
  修正**: 冪等ガードが `bool _initStarted` フラグだったため、1回目が
  `getApplicationSupportDirectory()`/`FileSink.init()` を await 中に2回目が
  呼ばれると、2回目の呼び出し元は「await済み＝準備完了」と誤認するが、
  実際にはまだ `_dumper` 等が未設定で `dumpLogs()` が失敗し得た。
  `Future<void>? _initFuture` を記憶し、2回目以降は**1回目と同じFuture**を
  返す方式に変更。`await LogKit.init(...)` が解決した時点で、それがどの
  呼び出し元であっても初期化が完全に終わっていることを保証する。
  回帰テストで「2回目の`await`直後に`dumpLogs()`が成功する」ことを検証。
- **ユーザー追加sinkの例外が`LogKit.e()`等の呼び出し元に伝播する問題を
  修正**: `_dispatch()` が sink を無防備にループしており、
  `CallbackLogSink`（Crashlytics連携等）が一時的に例外を投げると、それが
  そのまま `LogKit.e(...)` を呼んだアプリコードの例外になっていた。
  sink単位で try/catch し、失敗したsinkのみスキップして他のsinkには
  引き続き配布する方式に修正。**なお修正の初版では debug ビルドで
  `assert(false, ...)` を使って「開発中は気づけるように」意図したが、
  `assert` は debug/testビルドでも例外を投げるため、まさに検証しようと
  していた「sinkの例外がテストをクラッシュさせない」という保証自体を
  破壊するリグレッションを自己回帰テストで検出・修正した**（`assert`を
  やめ `developer.log` のみに変更）。この経緯自体、「デバッグ時に大声で
  知らせる」仕組みは「例外を外に漏らさない」保証と両立しないことを示す
  ケースとして記録しておく。

回帰テストを `test/log_kit_test.dart` に追加（init並行性テスト、sink例外
分離テスト）。テスト総数34件、全通過。

## 13. 深掘りレビューでの修正（実績・第4回）

第3回で入れたネイティブ修正自体の正しさ、および Dart 側の memoized future /
FIFO キューのエラー時挙動を反証的に検証した。Dart 側は
`_initImpl` が内部で try/catch 済みでエラー完了しないため memoized future の
poisoning は起きず、`_enqueue` も `_queue` を常に解決させる設計でエラーは
呼び出し元のみに伝わることを確認（いずれも問題なし）。一方、第3回で入れた
ネイティブ側修正に2件の欠陥が見つかり修正した。

- **iOS: `detachFromEngine(for:)` が実際には呼ばれない登録方法だった問題を
  修正**: 第3回で `registrar.addMethodCallDelegate(_, channel:)` を使って
  インスタンス登録したが、Flutter の `FlutterPlugin.h` によれば
  `detachFromEngineForRegistrar:` コールバックは **`publish:` で登録された
  インスタンスにのみ** 配信される（`addMethodCallDelegate` は対象外）。
  このままでは detach が永久に呼ばれず、第3回で直したはずのマルチエンジンの
  channel クリア自体が動かなかった。`registrar.publish(instance)` に変更
  （インスタンスをエンジン生存期間保持しつつ detach コールバックを有効化）。
  このチャンネルは native→Dart 片方向で Dart から native への呼び返しが
  ないため、`handle(_:result:)`（プロトコル上は `@optional`。ヘッダで
  `@required` は `registerWithRegistrar:` のみと確認）は不要として削除。
- **Android: `channel` フィールドの可視性データ競合を修正**: `attach()`/
  `detachIf()` は `@Synchronized` だが `log()` からの読み取りは非同期
  （バックグラウンドスレッドからの呼び出しもあり得る）で無防備だった。
  JMM のメモリ境界を越えて古い channel 参照を読む可能性があるため
  `@Volatile` を付与。

いずれも Android/iOS の実機ビルドが必要な変更で、この環境では静的検証のみ
（`FlutterPlugin.h` のプロトコル定義との突き合わせは実施済み）。Dart テストは
34件全通過を維持。

## 14. 深掘りレビューでの修正（実績・第5回）

これまで精査していなかった「信頼境界でのデータ処理・入力バリデーション・
hostile入力」観点を、確証/捏造どちらのバイアスも排して実コードから検証。
結果、**修正に値する問題は1件のみ**で、他候補（retention/ring bufferの負値
=不正設定値の縮退動作、RedactionRuleの暴走regex=利用側責任、native引数の
cast=自前native専用の信頼境界）はいずれも実害が低いため見送った（捏造して
並べない方針）。

- **dump metadata が JSON 化不能な値でcrypticにクラッシュする問題を修正**:
  `LogDumper` の `metadata.json` 生成で `JsonEncoder.convert()` を使っていた
  ため、公開API `dumpLogs({metadata})`/`shareLogs({metadata})`（型は
  `Map<String, Object?>`）に `DateTime`/`Duration`/任意オブジェクト等の
  JSON非対応値を渡すと `JsonUnsupportedObjectError` がdump途中で送出され、
  特に `shareLogs` では共有シートが開かず原因が分かりにくかった。これは
  本パッケージが一貫して守ってきた「ログ/ダンプ処理はアプリを落とさない」
  方針と矛盾する。`JsonEncoder.withIndent('  ', toEncodable)` で非対応値を
  `toString()` にフォールバックし、決して例外を投げないよう修正。
  `test/log_dumper_test.dart` に `DateTime` を metadata に渡す回帰テストを
  追加（テスト総数35件、全通過）。REFERENCE.md にも metadata 値の
  best-effort 文字列化を明記。
