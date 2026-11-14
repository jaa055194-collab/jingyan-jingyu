import '../storage/migrations.dart';

/// Null deliberately means a legacy budget still needs an explicit timezone.
const budgetTimezoneMigration = Migration(504, 'explicit budget timezone', '''
ALTER TABLE usage_budget ADD COLUMN offset_minutes INTEGER
 CHECK(offset_minutes IS NULL OR (typeof(offset_minutes) = 'integer' AND offset_minutes BETWEEN -840 AND 840));
''');
