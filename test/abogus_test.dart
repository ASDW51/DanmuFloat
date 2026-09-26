import 'package:danmu_float/sign/abogus.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与参考实现 bili-live-tools/packages/DouYinRecorder/src/sign.ts 交叉校验。
///
/// 基准值生成方式（一次性，不随仓库提交）：
///   1. 用 tsc 将 sign.ts 编译为 CommonJS；
///   2. 固定 `Math.random = () => 0.5`、`Date.now = () => 1758900005000`；
///   3. 传入下方相同的 fingerprint / userAgent / params 调用 generateAbogus 取得 a_bogus。
/// 若本用例失败，说明 Dart 移植与参考实现存在偏差。
void main() {
  const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/119.0.0.0 Safari/537.36';
  const String fingerprint =
      '1500|900|1530|980|0|0|0|0|1800|1000|1600|900|1500|900|24|24|Win32';
  const String params =
      'aid=6383&live_id=1&device_platform=web&language=zh-CN&enter_from=web_live'
      '&cookie_enabled=true&screen_width=1920&screen_height=1080'
      '&browser_language=zh-CN&browser_platform=MacIntel&browser_name=Chrome'
      '&browser_version=108.0.0.0&web_rid=123456789&Room-Enter-User-Login-Ab=0'
      '&is_need_double_stream=false';

  Abogus buildAbogus() => Abogus(
        fingerprint: fingerprint,
        userAgent: userAgent,
        now: () => 1758900005000,
        randomDouble: () => 0.5,
      );

  test('a_bogus 与参考实现逐字节一致', () {
    final AbogusResult result = buildAbogus().sign(params);
    expect(
      result.aBogus,
      'xfmZ/RLdkrosDEWG5fQLfY3q6XH3YhNF0SVkMD2fGxVPHL39HMOm9exogWUvhEuji4/sIeYjy4hbT3OprQCj01wf9W0x/2AMmDSkKl5Q5xSSs1XaeyUgrUkN-hsAtlaQsvHlEKi8owAaSY8kAnAJ5kIlO62-zo0/9XY=',
    );
  });

  test('query 在原始参数后追加 a_bogus', () {
    final AbogusResult result = buildAbogus().sign(params);
    expect(result.query, '$params&a_bogus=${result.aBogus}');
  });

  test('回传使用的 User-Agent，供请求头保持一致', () {
    expect(buildAbogus().sign(params).userAgent, userAgent);
  });

  test('相同输入结果确定；指纹变化结果随之变化', () {
    final String first = buildAbogus().sign(params).aBogus;
    expect(buildAbogus().sign(params).aBogus, first);

    final String other = Abogus(
      fingerprint: '1024|768|1048|843|0|0|0|0|1024|768|1280|800|1024|768|24|24|Win32',
      userAgent: userAgent,
      now: () => 1758900005000,
      randomDouble: () => 0.5,
    ).sign(params).aBogus;
    expect(other, isNot(first));
  });
}