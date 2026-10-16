// 偏好写回的差量合并（#97）。
//
// 设置页与过滤二级页进页时各拍一份快照，之后只在这份快照上 copyWith 并整份回传；
// 悬浮窗引擎是并发的偏好修改者。合并要把「用户真正改过的字段」取过来，其余保持权威值。
import 'package:danmu_float/danmu/model/danmaku_display.dart';
import 'package:danmu_float/danmu/model/danmaku_event.dart';
import 'package:danmu_float/storage/overlay_prefs_store.dart';
import 'package:danmu_float/storage/prefs_merge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('悬浮窗偏好差量合并（#97）', () {
    test('页内没碰过的字段保持权威值，窗内改动不被进页快照覆盖', () {
      // 设置页进页时的快照：默认透明度。
      const OverlayPrefs snapshot = OverlayPrefs();
      // 用户在悬浮球菜单里把透明度改成 0.2，首页的权威值随之变化。
      final OverlayPrefs current = snapshot.copyWith(opacity: 0.2);
      // 接着用户在设置页改「显示栏目标识」：整份回传的是基于进页快照的新值。
      final OverlayPrefs next = snapshot.copyWith(showTitleBar: false);

      final OverlayPrefs merged = mergeOverlayPrefsChanges(
        current: current,
        previous: snapshot,
        next: next,
      );

      expect(merged.opacity, 0.2, reason: '透明度页内没碰过，应保留窗内改后的值');
      expect(merged.showTitleBar, isFalse, reason: '页内真正改动的开关要生效');
    });

    test('没有任何字段变化时原样返回权威值本身', () {
      const OverlayPrefs current = OverlayPrefs();
      expect(
        identical(
          mergeOverlayPrefsChanges(
            current: current,
            previous: current,
            next: current.copyWith(),
          ),
          current,
        ),
        isTrue,
        reason: '调用方要用 identical 判断这次改动能否整个跳过',
      );
    });

    test('集合字段按内容比较：内容相同的列表不算「改过」', () {
      // 两次解析出来的列表是不同实例但内容相同，按引用比较会被误判成改过，
      // 于是页内没碰过的绑定列表照样被旧快照覆盖。
      const OverlayPrefs snapshot = OverlayPrefs(webRids: <String>['111']);
      final OverlayPrefs current = OverlayPrefs(
        webRids: <String>['222'],
        showTitleBar: true,
      );
      final OverlayPrefs next = OverlayPrefs(
        webRids: <String>['111'],
        showTitleBar: false,
      );

      final OverlayPrefs merged = mergeOverlayPrefsChanges(
        current: current,
        previous: snapshot,
        next: next,
      );

      expect(merged.webRids, <String>['222'], reason: '列表内容没变，应保留权威值');
      expect(merged.showTitleBar, isFalse, reason: '页内改动的开关仍要生效');
    });

    test('页内把字段改回快照值时视为未改动（已知取舍）', () {
      // 差量只能看到「相对进页快照的差异」，看不到控件的点击本身：用户把滑杆拖回
      // 进页时的取值时，这次操作与「没动过」不可区分。要覆盖这一格需要每个控件上报
      // 自己改了哪个字段（patch 化），代价是二十余处调用点与回调签名全改，本 PR 未做；
      // 触发条件也苛刻——需要窗内在同一时刻改了同一个字段。
      const OverlayPrefs snapshot = OverlayPrefs();
      final OverlayPrefs current = snapshot.copyWith(opacity: 0.2);
      final OverlayPrefs next = snapshot.copyWith(opacity: snapshot.opacity);

      final OverlayPrefs merged = mergeOverlayPrefsChanges(
        current: current,
        previous: snapshot,
        next: next,
      );

      expect(merged.opacity, 0.2, reason: '视为未改动，保留权威值');
    });
  });

  group('过滤偏好差量合并（#97）', () {
    test('页内加的关键词生效，窗内刚屏蔽的用户不被解封', () {
      const FilterPrefs snapshot = FilterPrefs();
      // 窗内把「张三」加入屏蔽：首页权威值已含它，并已落盘。
      final FilterPrefs current = snapshot.copyWith(blockedUsers: <String>['张三']);
      // 二级页基于进页快照加了一个屏蔽词。
      final FilterPrefs next = snapshot.copyWith(blockedKeywords: <String>['加群']);

      final FilterPrefs merged = mergeFilterPrefsChanges(
        current: current,
        previous: snapshot,
        next: next,
      );

      expect(merged.blockedKeywords, <String>['加群']);
      expect(merged.blockedUsers, <String>['张三'], reason: '窗内屏蔽的用户不能被旧快照解封');
    });

    test('类型多选为空的改动照常写回：空集是有效选择（#83）', () {
      const FilterPrefs snapshot = FilterPrefs();
      final FilterPrefs current = snapshot.copyWith(
        blockedKeywords: <String>['加群'],
      );
      // 用户在二级页把类型全部取消勾选：这是有效改动，必须写回。
      final FilterPrefs next = snapshot.copyWith(
        visibleKinds: const <DanmakuKind>{},
      );

      final FilterPrefs merged = mergeFilterPrefsChanges(
        current: current,
        previous: snapshot,
        next: next,
      );

      expect(merged.visibleKinds, isEmpty);
      expect(merged.blockedKeywords, <String>['加群'], reason: '页内没碰过的屏蔽词保持权威值');
    });
  });
}
