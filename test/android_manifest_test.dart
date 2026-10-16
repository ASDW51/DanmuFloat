// Android 清单的备份口径（#93）。
//
// App 私有目录里是主播列表、各项偏好与凭证密文，而 `android:allowBackup` 缺省为 true：
// 一旦漏掉这条声明，上述文件都会进云备份与换机迁移，「清除所有本地数据」抹不掉云端副本，
// 卸载重装 / 换机时数据自己回来。这条测试纯粹读仓库里的清单文本，不依赖真机或构建产物，
// 作用是把这条容易在改动清单时被删掉的安全基线钉住。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 清单路径相对仓库根目录；`flutter test` 的工作目录就是包根，所以直接按相对路径读。
const String _manifestPath = 'android/app/src/main/AndroidManifest.xml';

void main() {
  test('清单显式关闭应用备份，私有数据不进云备份与换机迁移（#93）', () {
    final File manifest = File(_manifestPath);
    expect(
      manifest.existsSync(),
      isTrue,
      reason: '测试按仓库根目录的相对路径读清单，找不到说明运行目录不对',
    );

    final RegExpMatch? applicationTag =
        RegExp(r'<application\b[^>]*>').firstMatch(manifest.readAsStringSync());
    expect(applicationTag, isNotNull, reason: '清单里应有 <application> 节点');

    expect(
      RegExp(r'android:allowBackup="false"')
          .hasMatch(applicationTag!.group(0)!),
      isTrue,
      reason: 'allowBackup 缺省即 true：不显式声明 false，rooms.json 与凭证密文'
          '会被云备份和设备迁移带走，清除本地数据也追不回来',
    );
  });
}
