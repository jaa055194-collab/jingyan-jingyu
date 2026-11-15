import 'package:jingyu_host/src/brain/domain_packs.dart';
import 'package:jingyu_host/src/brain/meme_library.dart';
import 'package:test/test.dart';

final DateTime now = DateTime.utc(2026, 11, 15, 12);

Meme meme(
  String id,
  MemeLayer layer,
  String reply, {
  List<String> triggers = const <String>[],
  List<String> keywords = const <String>[],
  String? occasion,
  String? relationship,
  DateTime? expiresAt,
}) => Meme(
  id: id,
  layer: layer,
  reply: reply,
  regexTriggers: triggers,
  keywords: keywords,
  occasion: occasion,
  relationship: relationship,
  expiresAt: expiresAt,
);

void main() {
  group('MemeLibrary three-layer matching (AC-34)', () {
    test('personal beats circle and general when all match', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme('g1', MemeLayer.general, '通用梗', triggers: <String>['666']),
          meme('c1', MemeLayer.circle, '圈内梗', triggers: <String>['666']),
          meme('p1', MemeLayer.personal, '内部梗', triggers: <String>['666']),
        ],
      );
      final Meme? hit = library.find('这也太666了', now: now);
      expect(hit, isNotNull);
      expect(hit!.id, 'p1');
      expect(hit.layer, MemeLayer.personal);
    });

    test('falls back to circle then general as more specific layers vanish', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme('g1', MemeLayer.general, '通用梗', triggers: <String>['666']),
          meme('c1', MemeLayer.circle, '圈内梗', triggers: <String>['666']),
        ],
      );
      expect(library.find('666', now: now)!.id, 'c1');

      final MemeLibrary generalOnly = MemeLibrary(
        memes: <Meme>[
          meme('g1', MemeLayer.general, '通用梗', triggers: <String>['666']),
        ],
      );
      expect(generalOnly.find('666', now: now)!.id, 'g1');
    });

    test('returns null when nothing matches so callers can degrade', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme('g1', MemeLayer.general, '通用梗', triggers: <String>['666']),
        ],
      );
      expect(library.find('今天天气不错', now: now), isNull);
      expect(library.match('今天天气不错', now: now), isNull);
    });

    test('keyword triggers match without regex', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme('g1', MemeLayer.general, '笑死', keywords: <String>['笑死']),
        ],
      );
      expect(library.find('真的笑死我了', now: now)!.id, 'g1');
    });

    test('match wraps the winning meme', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme('g1', MemeLayer.general, '笑死', keywords: <String>['笑死']),
        ],
      );
      final MemeMatch? hit = library.match('笑死', now: now);
      expect(hit, isNotNull);
      expect(hit!.meme.id, 'g1');
    });
  });

  group('MemeLibrary expiry (AC-34)', () {
    test('expired memes are not matched and are reported inactive', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme(
            'g1',
            MemeLayer.general,
            '过气梗',
            triggers: <String>['yyds'],
            expiresAt: DateTime.utc(2026, 11, 1),
          ),
        ],
      );
      expect(library.find('yyds', now: now), isNull);
      expect(library.activeAt(now), isEmpty);
      expect(library.expiredAt(now).map((Meme m) => m.id), <String>['g1']);
    });

    test('a meme is active before its expiry', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme(
            'g1',
            MemeLayer.general,
            '流行梗',
            triggers: <String>['yyds'],
            expiresAt: DateTime.utc(2027, 1, 1),
          ),
        ],
      );
      expect(library.find('yyds', now: now)!.id, 'g1');
      expect(library.activeAt(now).map((Meme m) => m.id), <String>['g1']);
    });

    test('a null expiry never expires', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme('p1', MemeLayer.personal, '老梗', triggers: <String>['老地方']),
        ],
      );
      expect(library.find('老地方见', now: now)!.id, 'p1');
      expect(library.expiredAt(now), isEmpty);
    });
  });

  group('MemeLibrary occasion and relationship scope', () {
    test('occasion-scoped meme only answers in that occasion', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme(
            'c1',
            MemeLayer.circle,
            '群梗',
            triggers: <String>['摸鱼'],
            occasion: 'group',
          ),
        ],
      );
      expect(library.find('摸鱼', now: now), isNull);
      expect(library.find('摸鱼', now: now, occasion: 'private'), isNull);
      expect(library.find('摸鱼', now: now, occasion: 'group')!.id, 'c1');
    });

    test('relationship-scoped meme only answers for that relationship', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme(
            'p1',
            MemeLayer.personal,
            '我们之间的梗',
            triggers: <String>['月亮'],
            relationship: 'friend-1',
          ),
        ],
      );
      expect(library.find('看月亮', now: now), isNull);
      expect(library.find('看月亮', now: now, relationship: 'friend-2'), isNull);
      expect(
        library.find('看月亮', now: now, relationship: 'friend-1')!.id,
        'p1',
      );
    });
  });

  group('MemeLibrary semantic matcher seam (FR-47)', () {
    test('regex-only when no semantic matcher is bound', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[
          meme('p1', MemeLayer.personal, '懂的都懂', keywords: <String>['暗号']),
        ],
      );
      expect(library.find('那个东西', now: now), isNull);
    });

    test('semantic matcher can hit a meme with no regex trigger', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[meme('p1', MemeLayer.personal, '懂的都懂')],
        semanticMatcher: (Meme m, String text) =>
            m.reply == '懂的都懂' && text.contains('那个东西'),
      );
      expect(library.find('那个东西', now: now)!.id, 'p1');
      expect(library.find('别的话', now: now), isNull);
    });
  });

  group('MemeLibrary proposal inbox (AC-34)', () {
    test('propose adds a pending proposal and no meme', () {
      final MemeLibrary library = MemeLibrary();
      final MemeProposal proposal = library.propose(
        id: 'prop1',
        ai: 'ai1',
        suggestedReply: '咱们以后这么说',
        suggestedTriggers: <String>['暗号'],
      );
      expect(proposal.status, MemeProposalStatus.pending);
      expect(library.pendingProposals.map((MemeProposal p) => p.id),
          <String>['prop1']);
      expect(library.memes, isEmpty);
      expect(library.find('暗号', now: now), isNull);
    });

    test('approve turns a proposal into a usable meme and clears the inbox', () {
      final MemeLibrary library = MemeLibrary();
      library.propose(
        id: 'prop1',
        ai: 'ai1',
        suggestedReply: '咱们以后这么说',
        suggestedTriggers: <String>['暗号'],
      );
      final Meme approved = library.approve('prop1');
      expect(approved.id, 'meme-prop1');
      expect(approved.layer, MemeLayer.personal);
      expect(library.pendingProposals, isEmpty);
      expect(library.proposals.single.status, MemeProposalStatus.approved);
      expect(library.find('暗号', now: now)!.id, 'meme-prop1');
    });

    test('reject drops a proposal without creating a meme', () {
      final MemeLibrary library = MemeLibrary();
      library.propose(id: 'prop1', ai: 'ai1', suggestedReply: '算了');
      library.reject('prop1');
      expect(library.pendingProposals, isEmpty);
      expect(library.proposals.single.status, MemeProposalStatus.rejected);
      expect(library.memes, isEmpty);
    });

    test('duplicate proposal ids are rejected', () {
      final MemeLibrary library = MemeLibrary();
      library.propose(id: 'prop1', ai: 'ai1', suggestedReply: '一');
      expect(
        () => library.propose(id: 'prop1', ai: 'ai2', suggestedReply: '二'),
        throwsArgumentError,
      );
    });

    test('approving an unknown or resolved proposal throws', () {
      final MemeLibrary library = MemeLibrary();
      expect(() => library.approve('missing'), throwsArgumentError);
      library.propose(id: 'prop1', ai: 'ai1', suggestedReply: '一');
      library.approve('prop1');
      expect(() => library.approve('prop1'), throwsArgumentError);
      expect(() => library.reject('prop1'), throwsArgumentError);
    });
  });

  group('MemeLibrary invariants', () {
    test('duplicate meme ids are rejected', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[meme('g1', MemeLayer.general, '一', keywords: <String>['a'])],
      );
      expect(
        () => library.add(meme('g1', MemeLayer.general, '二')),
        throwsArgumentError,
      );
    });

    test('exposed collections are unmodifiable', () {
      final MemeLibrary library = MemeLibrary(
        memes: <Meme>[meme('g1', MemeLayer.general, '一', keywords: <String>['a'])],
      );
      expect(() => library.memes.add(meme('g2', MemeLayer.general, '二')),
          throwsUnsupportedError);
      expect(() => library.proposals.clear(), throwsUnsupportedError);
    });
  });

  group('DomainPack rendering (AC-34)', () {
    test('renders glossary, hotspots and stance', () {
      final DomainPack pack = DomainPack(
        domain: '游戏',
        keywords: <String>['开黑'],
        glossary: '打野=打野怪',
        hotspots: '新赛季上线',
        stance: '她偏爱辅助位',
      );
      final String text = pack.render();
      expect(text, contains('术语：打野=打野怪'));
      expect(text, contains('热点：新赛季上线'));
      expect(text, contains('立场：她偏爱辅助位'));
    });

    test('never exceeds the per-domain cap and marks truncation', () {
      final DomainPack pack = DomainPack(
        domain: '影视',
        keywords: <String>['追剧'],
        glossary: '词' * 600,
      );
      final String text = pack.render();
      expect(text.runes.length, lessThanOrEqualTo(500));
      expect(text.endsWith('…'), isTrue);
    });

    test('respects a custom character budget', () {
      final DomainPack pack = DomainPack(
        domain: '美食',
        glossary: '麻' * 100,
      );
      final String text = pack.render(maxChars: 20);
      expect(text.runes.length, lessThanOrEqualTo(20));
    });

    test('a zero or negative budget renders nothing', () {
      final DomainPack pack = DomainPack(domain: 'x', glossary: '内容');
      expect(pack.render(maxChars: 0), isEmpty);
    });
  });

  group('DomainPackRegistry injection (AC-34)', () {
    DomainPackRegistry registry() => DomainPackRegistry(
      packs: <DomainPack>[
        DomainPack(
          domain: '游戏',
          keywords: <String>['开黑', '上分'],
          glossary: '打野=打野怪',
          stance: '她偏爱辅助位',
        ),
      ],
      knownDomains: <String>['编程'],
    );

    test('injects the matched domain under the cap', () {
      final DomainInjection injection = registry().injectionFor('今晚开黑吗');
      expect(injection.status, DomainInjectionStatus.injected);
      expect(injection.isInjected, isTrue);
      expect(injection.domain, '游戏');
      expect(injection.text.runes.length, lessThanOrEqualTo(500));
      expect(injection.text, contains('打野'));
    });

    test('injection is ephemeral and never persisted', () {
      expect(registry().injectionFor('上分').ephemeral, isTrue);
    });

    test('a known domain without a pack is reported unfamiliar', () {
      final DomainInjection injection = registry().injectionFor('想学编程');
      expect(injection.status, DomainInjectionStatus.unfamiliar);
      expect(injection.isUnfamiliar, isTrue);
      expect(injection.domain, '编程');
      expect(injection.text, isEmpty);
    });

    test('text with no known domain yields no injection', () {
      final DomainInjection injection = registry().injectionFor('今天心情不错');
      expect(injection.status, DomainInjectionStatus.none);
      expect(injection.domain, isNull);
    });

    test('a registered pack wins over a known-domain stub', () {
      final DomainPackRegistry reg = DomainPackRegistry(
        packs: <DomainPack>[
          DomainPack(domain: '编程', keywords: <String>['bug'], glossary: '调试'),
        ],
        knownDomains: <String>['编程'],
      );
      final DomainInjection injection = reg.injectionFor('这个bug');
      expect(injection.isInjected, isTrue);
      expect(injection.text, contains('调试'));
    });
  });
}
