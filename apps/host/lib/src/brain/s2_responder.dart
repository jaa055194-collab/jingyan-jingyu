import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';

import 'domain_packs.dart';
import 'router.dart';

/// Trusted composition must resolve cards authorized for this AI and target
/// conversation on every request. This port grants no access by itself.
typedef DomainRegistryResolver =
    Future<DomainPackRegistry> Function(AiId ai, IncomingMessage message);

/// Main-dialog generation port. Domain data is separate, untrusted reference
/// context for this turn only: never promote it to system instructions, append
/// it to stored history, or treat it as authorization to disclose other data.
/// Implementations still own budget/ACL checks and provider lifecycle.
abstract class S2Generation {
  Stream<String> respond(
    AiId ai,
    IncomingMessage message, {
    required DomainInjection domain,
  });
}

/// FR-47 composition for the existing router, not a default-host model adapter.
/// Uses the registry's first-match semantics; no network lookup or persistence.
/// Registry and generation failures remain stream errors for the trusted caller
/// to translate into a safe transport failure; they are never retried here.
class DomainAwareS2Responder implements S2Responder {
  DomainAwareS2Responder({
    required DomainRegistryResolver domains,
    required S2Generation generation,
  }) : _domains = domains,
       _generation = generation;

  final DomainRegistryResolver _domains;
  final S2Generation _generation;

  @override
  Stream<String> respond(AiId ai, IncomingMessage message) {
    var cancelled = false;
    StreamSubscription<String>? upstream;
    late final StreamController<String> output;

    Future<void> start() async {
      try {
        final registry = await _domains(ai, message);
        // Cancellation during a non-cancellable lookup must not start a model.
        if (cancelled) return;
        final found = registry.injectionFor(message.text);
        if (found.isUnfamiliar) {
          output.add('这个我不熟');
          unawaited(output.close());
          return;
        }

        // Enforce FR-47 even if the registry has a larger configured budget.
        final runes = found.text.runes.take(501).toList(growable: false);
        final domain = found.isInjected && runes.length > 500
            ? DomainInjection.injected(
                domain: found.domain!,
                text: '${String.fromCharCodes(runes.take(499))}…',
              )
            : found;
        upstream = _generation
            .respond(ai, message, domain: domain)
            .listen(
              output.add,
              onError: output.addError,
              onDone: () {
                unawaited(output.close());
              },
            );
        if (output.isPaused) upstream!.pause();
      } catch (error, stack) {
        if (!cancelled) {
          output.addError(error, stack);
          unawaited(output.close());
        }
      }
    }

    output = StreamController<String>(
      onListen: () {
        unawaited(start());
      },
      onPause: () => upstream?.pause(),
      onResume: () => upstream?.resume(),
      onCancel: () {
        cancelled = true;
        return upstream?.cancel();
      },
    );
    return output.stream;
  }
}
