# Nonfinite Protocol Integer Decode Fix

Authorized overnight main-based native TDD/review. Strict decoder promises Err, not throws. Valid JSON number1e999 parses Infinity in Dart; `_asInt` accepted Infinity==roundToDouble then toInt threw. Actual RED observed UnsupportedError at codec111 from message.ack seq1e999.

Minimal production change: require double.isFinite before integral-double conversion. No schema/finite range/sequence semantics or sync.chunk opaque-map contract change, no production endpoint exploit claim (no production decode callers found).

- [x] Write valid rawJSON exponent overflow regression and observe RED.
- [x] Add positive/negative exponent overflow across hello.lastSeq/message.event.seq/ack.seq/sync.request.afterSeq+limit, raw+decodedMap APIs; finiteintegral2.0 and fractional invalid behavior; directMapNaN.
- [x] One-line finiteguard; fullprotocol22/analyzeclean.
- [ ] Independentreview/fullrepo/finalheadCI; explicitagent treeverified newPR.
