import '../storage/migrations.dart';

/// Owner-private Android transcript exchanges. Deliberately separate from
/// `messages`, ordinary chat seq, direct-conversation consent and model usage:
/// a row pairs the owner's own typed text and the AI reply that the Android
/// client already produced locally. Only the bounded envelope and both exact
/// texts are stored, encrypted with an AAD bound to owner/profile/seq/exchange.
///
/// Deletion links are restricted: an AI profile, owner account or AI account
/// removal fails closed rather than silently deleting private transcript rows.
const androidPrivateChatMigration = Migration(
  609,
  'owner private Android transcript exchanges',
  '''
CREATE TABLE android_private_chat_exchanges (
  owner_id TEXT NOT NULL REFERENCES account(id),
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id),
  seq INTEGER NOT NULL CHECK(typeof(seq)='integer' AND seq>0),
  exchange_id TEXT NOT NULL CHECK(length(exchange_id) BETWEEN 1 AND 64),
  encrypted_payload TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id,ai_profile_id,seq),
  UNIQUE(owner_id,ai_profile_id,exchange_id)
);
CREATE INDEX android_private_chat_exchanges_profile
  ON android_private_chat_exchanges(ai_profile_id);
''',
);
