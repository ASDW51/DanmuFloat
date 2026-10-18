// 打包标识（#175）：把「这个 APK 是哪个产物」从构建期带到运行期。
//
// 设备 ABI 只能说「这台机器能跑什么」，说不出用户当初装的是拆分包还是通用包；
// 标识是构建期事实，更新时就靠它对准同一个产物。
import 'package:danmu_float/app/build_marker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('buildMarkerAbi（#175）', () {
    test('解析出产物 ABI', () {
      expect(buildMarkerAbi('danmufloat:arm64-v8a'), 'arm64-v8a');
      expect(buildMarkerAbi('danmufloat:universal'), 'universal');
    });

    test('没有标识时为空（本地构建与老版本都是这个状态）', () {
      expect(buildMarkerAbi(''), isEmpty);
      expect(buildMarkerAbi('   '), isEmpty);
    });

    test('前缀不对时不当成标识，避免把别的内容误读成产物名', () {
      expect(buildMarkerAbi('arm64-v8a'), isEmpty);
      expect(buildMarkerAbi('other:arm64-v8a'), isEmpty);
    });

    test('只有前缀、没有值也算没有标识', () {
      expect(buildMarkerAbi('danmufloat:'), isEmpty);
      expect(buildMarkerAbi('danmufloat:   '), isEmpty);
    });
  });

  group('标识文案（#175）', () {
    test('有标识时直接给 ABI 名，报障能照着填', () {
      expect(buildMarkerLabel('danmufloat:arm64-v8a'), 'arm64-v8a');
      expect(buildMarkerLabel('danmufloat:universal'), 'universal');
    });

    test('没有标识时说明原因，而不是显示空白', () {
      expect(buildMarkerLabel(''), contains('未标记'));
    });
  });

  group('与发布流水线的一致性（#175）', () {
    test('测试用的标识与 release.yml 注入值一致', () {
      // release.yml 里写的是 danmufloat:arm64-v8a / danmufloat:universal，
      // 任何一边改了这里都会红——避免「注入的标识 App 解析不出来」这种哑火。
      expect(expectedArm64Marker, 'danmufloat:arm64-v8a');
      expect(expectedUniversalMarker, 'danmufloat:universal');
      expect(buildMarkerAbi(expectedArm64Marker), 'arm64-v8a');
      expect(buildMarkerAbi(expectedUniversalMarker), 'universal');
    });

    test('本地单测构建没有标识，hasBuildMarker 为假', () {
      expect(
        hasBuildMarker,
        isFalse,
        reason: 'flutter test 不会注入 DANMU_BUILD_MARKER，界面应走「未标记」分支',
      );
    });
  });
}
