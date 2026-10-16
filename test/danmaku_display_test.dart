// 弹幕展示口径：悬浮窗与 App 内弹幕页共用，这里锁死过滤范围与文案格式。
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('列表只保留聊天类：普通 / 飘屏 / 特权', () {
    expect(isChatKind(DanmakuKind.chat), isTrue);
    expect(isChatKind(DanmakuKind.screenChat), isTrue);
    expect(isChatKind(DanmakuKind.privilegeScreenChat), isTrue);
    expect(isChatKind(DanmakuKind.gift), isFalse);
    expect(isChatKind(DanmakuKind.member), isFalse);
    expect(isChatKind(DanmakuKind.roomStats), isFalse);
    expect(isChatKind(DanmakuKind.other), isFalse);
  });

  test('订阅范围含房间统计与全部可展示类型：是否入列交给类型筛选决定', () {
    expect(isStreamRelevant(DanmakuKind.roomStats), isTrue);
    expect(isStreamRelevant(DanmakuKind.member), isTrue);
    expect(isStreamRelevant(DanmakuKind.chat), isTrue);
    // 礼物 / 点赞 / 关注 / 榜单必须在流层放行，否则设置里勾选这些类型后
    // 永远收不到数据，表现为「勾了也不生效」。
    expect(isStreamRelevant(DanmakuKind.gift), isTrue);
    expect(isStreamRelevant(DanmakuKind.like), isTrue);
    expect(isStreamRelevant(DanmakuKind.social), isTrue);
    expect(isStreamRelevant(DanmakuKind.roomRank), isTrue);
    // 累计观看人次推送滞后、只用于在线人数兜底，不入列也不订阅；
    // 未登记 method 的文本是 method 名占位，同样不订阅。
    expect(isStreamRelevant(DanmakuKind.roomUserSeq), isFalse);
    expect(isStreamRelevant(DanmakuKind.other), isFalse);
  });

  test('勾选某类型后它进入可见列表，未勾选的类型不入列', () {
    const FilterPrefs onlyGift =
        FilterPrefs(visibleKinds: <DanmakuKind>{DanmakuKind.gift});
    expect(isListKind(DanmakuKind.gift, onlyGift), isTrue);
    expect(isListKind(DanmakuKind.chat, onlyGift), isFalse);
    expect(isListKind(DanmakuKind.member, onlyGift), isFalse);
  });

  test('类型前缀：普通弹幕无前缀', () {
    expect(danmakuTypeLabel(DanmakuKind.screenChat), '飘屏');
    expect(danmakuTypeLabel(DanmakuKind.privilegeScreenChat), '特权');
    expect(danmakuTypeLabel(DanmakuKind.chat), isNull);
    // F13 起礼物可作为可选展示类型，带「礼物」前缀。
    expect(danmakuTypeLabel(DanmakuKind.gift), '礼物');
  });

  test('在线人数给完整数字，不再折算成万（UX-12）', () {
    expect(formatOnlineCount(0), '0');
    expect(formatOnlineCount(9999), '9999');
    expect(formatOnlineCount(10000), '10000');
    expect(formatOnlineCount(123456), '123456');
    expect(
      formatOnlineCount(123456),
      isNot(contains('万')),
      reason: '人数不可省略：折算后就拿不到准确人数了',
    );
  });

  test('时间戳为毫秒，0 或负数给占位', () {
    expect(formatClock(0), '--:--:--');
    expect(formatClock(-1), '--:--:--');
    final int ms = DateTime(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch;
    expect(formatClock(ms), '03:04:05');
  });

  test('滚动速度越界收敛，NaN 回落默认值', () {
    expect(clampDanmuScrollSpeed(0.1), minDanmuScrollSpeed);
    expect(clampDanmuScrollSpeed(9), maxDanmuScrollSpeed);
    expect(clampDanmuScrollSpeed(1.25), 1.25);
    expect(clampDanmuScrollSpeed(double.nan), defaultDanmuScrollSpeed);
  });

  test('滚动动画时长与距离成正比：距离越大时长越长', () {
    // 900 距离 ÷ 900px/s = 1s。
    expect(danmuScrollDuration(900, 1), const Duration(seconds: 1));
    expect(
      danmuScrollDuration(1800, 1).inMilliseconds,
      greaterThan(danmuScrollDuration(900, 1).inMilliseconds),
    );
  });

  test('滚动速度越大时长越短，但被收敛在上下限内', () {
    expect(
      danmuScrollDuration(900, 3).inMilliseconds,
      lessThan(danmuScrollDuration(900, 0.5).inMilliseconds),
    );
    // 距离为 0 或非法时仍给一个最小可见时长，不会是 0。
    expect(danmuScrollDuration(0, 1).inMilliseconds, 80);
    expect(danmuScrollDuration(double.nan, 1).inMilliseconds, 80);
    // 超长距离封顶，避免动画明显落后于直播。
    expect(danmuScrollDuration(100000, 0.5).inMilliseconds, 1200);
  });

  test('屏蔽词：普通模式按包含匹配，正则模式按正则匹配（prd F10）', () {
    final DanmakuEvent spam = _chat('666666');
    // 普通模式：子串包含。
    expect(
      isBlockedBy(spam, const FilterPrefs(blockedKeywords: <String>['666'])),
      isTrue,
    );
    // 正则模式：整条都是 6 且不少于 3 个。
    expect(
      isBlockedBy(
        spam,
        const FilterPrefs(blockedKeywords: <String>[r'^6{3,}$'], regexEnabled: true),
      ),
      isTrue,
    );
    // 同一条规则在普通模式下是字面量，不会被当成正则。
    expect(
      isBlockedBy(
        spam,
        const FilterPrefs(blockedKeywords: <String>[r'^6{3,}$']),
      ),
      isFalse,
    );
    // 正则要求「以 6 开头」，不以 6 开头的普通内容不受影响。
    expect(
      isBlockedBy(
        _chat('你好 666'),
        const FilterPrefs(blockedKeywords: <String>[r'^6{3,}$'], regexEnabled: true),
      ),
      isFalse,
    );
  });

  test('正则模式下非法规则被跳过，其它规则照常生效', () {
    final FilterPrefs prefs = const FilterPrefs(
      blockedKeywords: <String>['(未闭合', '加群'],
      regexEnabled: true,
    );
    expect(isBlockedBy(_chat('加群看福利'), prefs), isTrue);
    // 只有写法非法的规则被列出来，合法的规则不报。
    expect(invalidFilterRules(<String>['(未闭合', '加群']), <String>['(未闭合']);
    expect(compileFilterRule('  '), isNull);
  });

  test('屏蔽用户始终精确匹配，不受正则开关影响', () {
    final DanmakuEvent event = _chat('正常弹幕', userId: '42', nick: '张三');
    expect(
      isBlockedBy(event, const FilterPrefs(blockedUsers: <String>['42'])),
      isTrue,
    );
    expect(
      isBlockedBy(event, const FilterPrefs(blockedUsers: <String>['张三'])),
      isTrue,
    );
    // 正则开关打开也仍然精确匹配，'张' 不会命中 '张三'。
    expect(
      isBlockedBy(
        event,
        const FilterPrefs(blockedUsers: <String>['张'], regexEnabled: true),
      ),
      isFalse,
    );
  });

  test('高亮切分：正则模式按正则区间高亮，普通模式按子串', () {
    expect(
      _highlighted(splitHighlights('抽奖开始了 666', <String>[r'抽奖', r'\d+'], regex: true)),
      <String>['抽奖', '666'],
    );
    // 同规则在普通模式下只能命中 '抽奖' 这个字面量。
    expect(
      _highlighted(splitHighlights('抽奖开始了 666', <String>[r'抽奖', r'\d+'])),
      <String>['抽奖'],
    );
    // 正则模式无命中时原样返回一段未高亮文本。
    final List<HighlightSegment> none =
        splitHighlights('平淡内容', <String>[r'^\d+$'], regex: true);
    expect(none.length, 1);
    expect(none.single.highlighted, isFalse);
  });

  test('regexEnabled 参与 isDefault 判定与 JSON 序列化', () {
    expect(const FilterPrefs(regexEnabled: true).isDefault, isFalse);
    expect(
      const FilterPrefs(regexEnabled: true).toJson()['regexEnabled'],
      isTrue,
    );
    // copyWith 不传时保留原值，避免拖动其它设置时被顺手关掉。
    expect(
      const FilterPrefs(regexEnabled: true).copyWith(blockedUsers: <String>['张三']).regexEnabled,
      isTrue,
    );
  });

  group('规则编译缓存（#79）', () {
    test('同一份规则只编译一次：两条匹配路径复用同一个 RegExp 实例', () {
      // 热路径上 isBlockedBy 按「每条弹幕 × 每条规则」、splitHighlights 按
      // 「每个可见行 × 每条规则」取规则，页面又在 build 里现算可见列表，
      // 不缓存就是每帧重建全部 RegExp。
      expect(
        identical(compileFilterRule(r'\d+'), compileFilterRule(r'\d+')),
        isTrue,
        reason: '同一规则第二次取必须命中缓存，而不是重新构造',
      );
      expect(
        identical(compileFilterRule(r'\d+'), compileMatchableFilterRule(r'\d+')),
        isTrue,
        reason: '屏蔽与高亮两条路径共用同一份缓存',
      );
      // 前后空白不同也算同一条规则。
      expect(
        identical(compileFilterRule(r'\d+'), compileFilterRule(r'  \d+  ')),
        isTrue,
      );
    });

    test('非法规则的否定结果同样缓存，空规则不进缓存', () {
      expect(compileFilterRule('(未闭合'), isNull);
      expect(compileFilterRule('(未闭合'), isNull);
      expect(compileFilterRule('   '), isNull);
      expect(compileMatchableFilterRule(''), isNull);
    });
  });

  group('灾难性回溯筛查（#79）', () {
    test('嵌套量词 / 重叠分支判定为风险', () {
      for (final String rule in <String>[
        r'(a+)+$',
        r'([a-z]+)*',
        r'(a?)+',
        r'(a|aa)+$',
        r'(a|a)*',
        r'(\d+){2,}',
        r'((a+))+',
        r'(?:a+)+',
      ]) {
        expect(hasBacktrackingRisk(rule), isTrue, reason: '$rule 应当被判为风险写法');
      }
    });

    test('线性写法不能被误判（否则用户规则会白白失效）', () {
      for (final String rule in <String>[
        r'\d+',
        r'^6{3,}$', // 设置页 placeholder 的写法
        r'(抽奖|福利)',
        r'(抽奖|福利)+', // 分支首字符不同，不会互相回溯
        r'(?:abc)+', // 组前缀不是量词
        r'(\d+)-(\d+)',
        r'[a-z]+',
        r'\(a+\)\+', // 转义后的字面量
      ]) {
        expect(hasBacktrackingRisk(rule), isFalse, reason: '$rule 是线性写法，不能误判');
      }
    });

    test('风险规则被停用匹配，非法规则与正常规则的口径不变', () {
      expect(riskyFilterRules(<String>[r'(a+)+', '(未闭合', '加群']), <String>[r'(a+)+']);
      // 写法非法的仍只由 invalidFilterRules 负责，两者不互相串。
      expect(invalidFilterRules(<String>[r'(a+)+', '(未闭合']), <String>['(未闭合']);
      expect(compileMatchableFilterRule(r'(a+)+'), isNull);
      expect(compileMatchableFilterRule(r'加群'), isNotNull);
      // 语法校验不管风险：设置页要能把「写法合法但有风险」单独提示出来。
      expect(compileFilterRule(r'(a+)+'), isNotNull);
    });

    test('屏蔽过滤跳过高风险规则，其它规则照常生效', () {
      // (a+)+ 本身能匹配 'aaa'，这里必须不生效——风险规则一律不参与匹配。
      const FilterPrefs onlyRisky = FilterPrefs(
        blockedKeywords: <String>[r'(a+)+'],
        regexEnabled: true,
      );
      expect(isBlockedBy(_chat('aaa'), onlyRisky), isFalse);

      const FilterPrefs mixed = FilterPrefs(
        blockedKeywords: <String>[r'(a+)+', '加群'],
        regexEnabled: true,
      );
      expect(isBlockedBy(_chat('aaa'), mixed), isFalse);
      expect(isBlockedBy(_chat('加群看福利'), mixed), isTrue);
    });

    test('正则高亮同样跳过风险规则', () {
      expect(
        _highlighted(splitHighlights('aaa', <String>[r'(a+)+'], regex: true)),
        isEmpty,
      );
      expect(
        _highlighted(splitHighlights('aaa 666', <String>[r'(a+)+', r'\d+'], regex: true)),
        <String>['666'],
      );
    });
  });
}

/// 构造一条聊天弹幕，供过滤用例使用。
DanmakuEvent _chat(String text, {String userId = '1', String nick = '甲'}) =>
    DanmakuEvent(
      kind: DanmakuKind.chat,
      method: 'WebcastChatMessage',
      msgId: 1,
      roomId: 1,
      timeMs: 1700000000000,
      text: text,
      user: DanmakuUser(
        userId: userId,
        nickName: nick,
        avatarUrl: '',
        level: 0,
        fanLevel: 0,
      ),
    );

/// 取出被高亮的片段文本，便于断言切分结果。
List<String> _highlighted(List<HighlightSegment> segments) => <String>[
      for (final HighlightSegment segment in segments)
        if (segment.highlighted) segment.text,
    ];