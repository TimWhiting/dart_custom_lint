import 'dart:async';
import 'dart:io';

import 'package:analyzer/dart/analysis/context_locator.dart' as analyzer;
import 'package:analyzer/dart/analysis/context_root.dart' as analyzer;
import 'package:analyzer/dart/analysis/results.dart' as analyzer;
import 'package:analyzer/file_system/file_system.dart' as analyzer;
import 'package:analyzer/source/line_info.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/context_builder.dart' as analyzer;
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/driver.dart' as analyzer;
import 'package:analyzer_plugin/protocol/protocol_common.dart'
    as analyzer_plugin;
import 'package:analyzer_plugin/protocol/protocol_generated.dart'
    as analyzer_plugin;
import 'package:collection/collection.dart';
import 'package:source_span/source_span.dart';
import 'package:stack_trace/stack_trace.dart';

import '../../custom_lint_builder.dart';
import '../internal_protocol.dart';
import 'plugin_client.dart';

/// An exception thrown during [PluginBase.getLints].
class GetLintException implements Exception {
  /// An exception thrown during [PluginBase.getLints].
  GetLintException({required this.error, required this.filePath});

  /// The thrown exception by [PluginBase.getLints].
  final Object error;

  /// The while that was being analyzed
  final String filePath;

  @override
  String toString() {
    return 'The following exception was thrown while trying to obtain lints for $filePath:\n'
        '$error';
  }
}

/// An internal client for connecting a custom_lint plugin to the server
/// using the analyzer_plugin protocol
class Client extends ClientPlugin {
  /// An internal client for connecting a custom_lint plugin to the server
  /// using the analyzer_plugin protocol
  Client(this.plugin, [analyzer.ResourceProvider? provider]) : super(provider);

  /// The plugin that will be connected to the analyzer server
  final PluginBase plugin;

  late bool _includeBuiltInLints;

  @override
  List<String> get fileGlobsToAnalyze => ['*.dart'];

  @override
  String get name => 'custom_lint_client';

  @override
  String get version => '1.0.0-alpha.0';

  final _pendingGetLintsSubscriptions = <String, StreamSubscription>{};
  final _lastResolvedUnits = <String, analyzer.ResolvedUnitResult>{};

  @override
  analyzer.AnalysisDriver createAnalysisDriver(
    analyzer_plugin.ContextRoot contextRoot,
  ) {
    final analyzerContextRoot = contextRoot.asAnalyzerContextRoot(
      resourceProvider: resourceProvider,
    );

    final builder = analyzer.ContextBuilderImpl(
      resourceProvider: resourceProvider,
    );
    final context = builder.createContext(contextRoot: analyzerContextRoot);

// TODO cancel sub
    context.driver.results.listen((analysisResult) {
      if (analysisResult is! analyzer.ResolvedUnitResult ||
          !analysisResult.exists) {
        return;
      }
      // TODO handle ErrorsResult

      // TODO test that getLints stops being listened if a new Result is emitted
      // before the previous getLints completes
      _pendingGetLintsSubscriptions[analysisResult.path]?.cancel();
      _lastResolvedUnits[analysisResult.path] = analysisResult;
      // ignore: cancel_subscriptions, the subscription is stored in the object and cancelled later
      final sub = _getAnalysisErrors(analysisResult).listen(
        (event) => channel.sendNotification(event.toNotification()),
        onDone: () => _pendingGetLintsSubscriptions.remove(analysisResult.path),
      );

      _pendingGetLintsSubscriptions[analysisResult.path] = sub;
    });

    return context.driver;
  }

  /// Calls [PluginBase.getLints], applies `// ignore` & error handling,
  /// and encode them.
  ///
  /// Using `async*` such that we can "cancel" the subscription to [PluginBase.getLints]
  Stream<analyzer_plugin.AnalysisErrorsParams> _getAnalysisErrors(
    analyzer.ResolvedUnitResult analysisResult,
  ) {
    final lineInfo = analysisResult.lineInfo;
    final source = analysisResult.content;
    final fileIgnoredCodes = _getAllIgnoredForFileCodes(analysisResult.content);

    // Lints are disabled for the entire file, so no point to even execute `getLints`
    if (fileIgnoredCodes.contains('type=lint')) return const Stream.empty();

    final analysisErrors = plugin
        .getLints(analysisResult)
        .where(
          (lint) =>
              !fileIgnoredCodes.contains(lint.code) &&
              !_isIgnored(lint, lineInfo, source),
        )
        .map<analyzer_plugin.AnalysisError?>((e) => e.asAnalysisError())
        // ignore: avoid_types_on_closure_parameters
        .handleError((Object error, StackTrace stackTrace) =>
            _handleGetLintsError(analysisResult, error, stackTrace))
        .where((e) => e != null)
        .cast<analyzer_plugin.AnalysisError>();

    return analysisErrors.toListStream().map((event) {
      return analyzer_plugin.AnalysisErrorsParams(analysisResult.path, event);
    });
  }

  /// Re-maps uncaught errors by [PluginBase.getLints] and, if in the IDE,
  /// shows a synthetic lint at the top of the file corresponding to the error.
  analyzer_plugin.AnalysisError? _handleGetLintsError(
    analyzer.ResolvedUnitResult analysisResult,
    Object error,
    StackTrace stackTrace,
  ) {
    final rethrownError = GetLintException(
      error: error,
      filePath: analysisResult.path,
    );

    // Sending the error back to the zone without rethrowing.
    // This allows the server can correctly log the error, and the client to
    // render the error at the top of the inspected file.
    Zone.current.handleUncaughtError(rethrownError, stackTrace);

    if (!_includeBuiltInLints) return null;

    // TODO test and handle all error cases
    final trace = Trace.from(stackTrace);

    final firstFileFrame = trace.frames.firstWhereOrNull(
      (frame) => frame.uri.scheme == 'file',
    );

    if (firstFileFrame == null) return null;

    final file = File.fromUri(firstFileFrame.uri);
    final sourceFile = SourceFile.fromString(file.readAsStringSync());

    return analyzer_plugin.AnalysisError(
      analyzer_plugin.AnalysisErrorSeverity.ERROR,
      analyzer_plugin.AnalysisErrorType.LINT,
      analysisResult
          .lintLocationFromLines(startLine: 1, endLine: 2)
          .asLocation(),
      'A lint plugin threw an exception',
      'custom_lint_get_lint_fail',
      contextMessages: [
        analyzer_plugin.DiagnosticMessage(
          error.toString(),
          analyzer_plugin.Location(
            firstFileFrame.library,
            sourceFile.getOffset(
              // frame location indices start at 1 not 0 so removing -1
              (firstFileFrame.line ?? 1) - 1,
              (firstFileFrame.column ?? 1) - 1,
            ),
            0,
            firstFileFrame.line ?? 1,
            firstFileFrame.column ?? 1,
          ),
        ),
      ],
    );
  }

  @override
  Future<analyzer_plugin.EditGetFixesResult> handleEditGetFixes(
    analyzer_plugin.EditGetFixesParams parameters,
  ) async {
    final result = await driverForPath(parameters.file)!
        .getResult(parameters.file) as analyzer.ResolvedUnitResult;

    return plugin.handleEditGetFixes(result, parameters.offset);
  }

  @override
  Future<AwaitAnalysisDoneResult> handleAwaitAnalysisDone(
    AwaitAnalysisDoneParams parameters,
  ) async {
    if (parameters.reload) {
      reLint();
    }
    bool hasPendingDriver() {
      return driverMap.values.any((driver) => driver.hasFilesToAnalyze);
    }

    while (hasPendingDriver() || _pendingGetLintsSubscriptions.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }

    return const AwaitAnalysisDoneResult();
  }

  @override
  Future<SetConfigResult> handleSetConfig(SetConfigParams params) async {
    _includeBuiltInLints = params.includeBuiltInLints;
    return const SetConfigResult();
  }

  /// A hook to re-lint files when the linter itself has potentially changed due to hot-reload
  @override
  void reLint() {
    for (final unit in _lastResolvedUnits.entries) {
      _pendingGetLintsSubscriptions[unit.key]?.cancel();
      // ignore: cancel_subscriptions, the subscription is stored in the object and cancelled later
      final sub = _getAnalysisErrors(unit.value).listen(
        (event) {
          channel.sendNotification(event.toNotification());
        },
        onDone: () => _pendingGetLintsSubscriptions.remove(unit.key),
      );
      _pendingGetLintsSubscriptions[unit.key] = sub;
    }
  }
}

extension<T> on Stream<T> {
  /// Creates a [Stream] that emits a single event containing a list of all the
  /// events from the passed stream.
  ///
  /// This is different from [Stream.toList] in that the returned [Stream]
  /// supports pausing/cancelling.
  /// In particular, if the returned stream stops being listened before the inner
  /// stream completes, then the subscription to the inner stream will be closed.
  Stream<List<T>> toListStream() {
    late StreamSubscription<T> sub;

    final controller = StreamController<List<T>>();
    controller.onListen = () {
      final ints = <T>[];
      sub = listen(
        ints.add,
        onError: controller.addError,
        onDone: () {
          controller.add(ints);
          controller.onCancel!();
        },
      );
    };
    controller.onPause = () => sub.pause();
    controller.onResume = () => sub.resume();
    controller.onCancel = () {
      sub.cancel();
      controller.close();
    };

    return controller.stream;
  }
}

final _ignoreRegex = RegExp(r'//\s*ignore\s*:(.+)$', multiLine: true);
final _ignoreForFileRegex =
    RegExp(r'//\s*ignore_for_file\s*:(.+)$', multiLine: true);

bool _isIgnored(Lint lint, LineInfo lineInfo, String source) {
  // -1 because lines starts at 1 not 0
  final line = lint.location.startLine - 1;

  if (line == 0) return false;

  final previousLine = source.substring(
    lineInfo.getOffsetOfLine(line - 1),
    lint.location.offset - 1,
  );

  final codeContent = _ignoreRegex.firstMatch(previousLine)?.group(1);
  if (codeContent == null) return false;

  final codes = codeContent.split(',').map((e) => e.trim()).toSet();

  return codes.contains(lint.code) || codes.contains('type=lint');
}

Set<String> _getAllIgnoredForFileCodes(String source) {
  return _ignoreForFileRegex
      .allMatches(source)
      .map((e) => e.group(1)!)
      .expand((e) => e.split(','))
      .map((e) => e.trim())
      .toSet();
}

extension on analyzer_plugin.ContextRoot {
  analyzer.ContextRoot asAnalyzerContextRoot({
    required analyzer.ResourceProvider resourceProvider,
  }) {
    final locator =
        analyzer.ContextLocator(resourceProvider: resourceProvider).locateRoots(
      includedPaths: [root],
      excludedPaths: exclude,
      optionsFile: optionsFile,
    );

    return locator.single;
  }
}
