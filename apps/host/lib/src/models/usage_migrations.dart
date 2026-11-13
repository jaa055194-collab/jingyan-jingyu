import '../storage/migrations.dart';

/// Explicit registration by the host assembly; requires canonical account and
/// ai_profile (501). Decimal TEXT counters avoid SQLite SUM/int64 overflow.
const List<Migration> usageMigrations = [
  Migration(503, 'owner AI daily usage ledger', '''
CREATE TABLE usage_budget (
  owner_id TEXT NOT NULL REFERENCES account(id),
  ai_id TEXT NOT NULL REFERENCES ai_profile(id),
  daily_tokens TEXT NOT NULL,
  layer_limits TEXT NOT NULL CHECK(json_valid(layer_limits)),
  capability_limits TEXT NOT NULL CHECK(json_valid(capability_limits)),
  PRIMARY KEY(owner_id, ai_id)
);
CREATE TABLE usage_ledger (
  owner_id TEXT NOT NULL REFERENCES account(id),
  ai_id TEXT NOT NULL REFERENCES ai_profile(id),
  request_id TEXT NOT NULL,
  budget_day TEXT NOT NULL,
  offset_minutes INTEGER NOT NULL CHECK(offset_minutes BETWEEN -840 AND 840),
  layer TEXT NOT NULL,
  capability TEXT NOT NULL,
  input_tokens TEXT,
  output_tokens TEXT,
  total_tokens TEXT,
  source_usage_unknown INTEGER NOT NULL CHECK(source_usage_unknown IN (0, 1)),
  PRIMARY KEY(owner_id, ai_id, request_id),
  CHECK((source_usage_unknown = 1 AND input_tokens IS NULL AND output_tokens IS NULL AND total_tokens IS NULL)
     OR (source_usage_unknown = 0 AND input_tokens IS NOT NULL AND output_tokens IS NOT NULL AND total_tokens IS NOT NULL))
);
CREATE INDEX usage_ledger_day ON usage_ledger(owner_id, ai_id, budget_day);
CREATE INDEX usage_ledger_unknown ON usage_ledger(owner_id, ai_id, capability, source_usage_unknown);
'''),
];
