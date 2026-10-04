// 凭证管理（prd F27）：格式校验、多份凭证的加密落盘往返、增删改、旧格式迁移、
// 解密失败不静默降级，以及 CookieProvider 对指定凭证的优先级。
import 'package:danmu_float/credential/cookie_provider.dart';
import 'package:danmu_float/credential/credential_store.dart';
import 'package:danmu_float/net/http_transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 内存后端：单测不依赖 Android Keystore 插件通道。
class FakeBackend implements CredentialBackend {
  FakeBackend({this.readError});

  String? stored;

  /// 读取时抛出的异常，用来模拟解密失败。
  Object? readError;

  @override
  Future<String?> read() async {
    final Object? error = readError;
    if (error != null) throw error;
    return stored;
  }

  @override
  Future<void> write(String value) async => stored = value;

  @override
  Future<void> delete() async => stored = null;
}

/// 记录请求的假传输层，用于验证「指定凭证优先」时不联网。
class RecordingTransport implements HttpTransport {
  int calls = 0;

  @override
  Future<HttpResponseData> get(Uri uri, {Map<String, String>? headers}) async {
    calls++;
    return const HttpResponseData(
      statusCode: 200,
      body: '',
      setCookie: <String>['ttwid=anonymous'],
    );
  }

  @override
  void close() {}
}

void main() {
  tearDown(() => setRoomCookieBindings(const <String, String>{}));

  group('validateManualCookies', () {
    test('接受分号分隔的 name=value 列表', () {
      expect(validateManualCookies('ttwid=abc; msToken=xyz'), isNull);
      expect(validateManualCookies('  ttwid=abc  '), isNull);
    });

    test('拒绝空值与换行；超长内容不设上限', () {
      expect(validateManualCookies('   '), isNotNull);
      expect(validateManualCookies('ttwid=a\nCookie: b'), isNotNull);
      // 长度不做限制：任意长度的合法 name=value 均接受。
      expect(validateManualCookies('a=${'x' * 100000}'), isNull);
    });

    test('拒绝缺等号、空名与非法字符', () {
      expect(validateManualCookies('ttwid'), isNotNull);
      expect(validateManualCookies('=abc'), isNotNull);
      expect(validateManualCookies('tt wid=abc'), isNotNull);
      expect(validateManualCookies('ttwid=a\u0000b'), isNotNull);
    });
  });

  group('CredentialProfile 序列化', () {
    test('编码后能原样解码', () {
      const List<CredentialProfile> profiles = <CredentialProfile>[
        CredentialProfile(
          id: 'a',
          name: '主号',
          cookies: 'ttwid=abc',
          createdAt: 1700000000000,
        ),
        CredentialProfile(id: 'b', name: '备用', cookies: 'ttwid=def', createdAt: 0),
      ];
      final List<CredentialProfile> decoded =
          decodeCredentialProfiles(encodeCredentialProfiles(profiles));

      expect(decoded.length, 2);
      expect(decoded[0].id, 'a');
      expect(decoded[0].name, '主号');
      expect(decoded[0].cookies, 'ttwid=abc');
      expect(decoded[0].createdAt, 1700000000000);
      expect(decoded[1].name, '备用');
    });

    test('跳过缺 id / 内容非法 / 校验不通过的坏数据', () {
      final List<CredentialProfile> decoded = decodeCredentialProfiles(
        '[{"id":"a","name":"ok","cookies":"ttwid=abc","created_at":0},'
        '{"name":"缺 id","cookies":"ttwid=abc"},'
        '{"id":"c","cookies":"不是 cookie"},'
        '"字符串"]',
      );

      expect(decoded.length, 1);
      expect(decoded.single.id, 'a');
    });

    test('旧版单份明文 cookie 串迁移为一份「默认凭证」', () {
      final List<CredentialProfile> decoded = decodeCredentialProfiles('ttwid=legacy');

      expect(decoded.length, 1);
      expect(decoded.single.id, 'legacy');
      expect(decoded.single.name, '默认凭证');
      expect(decoded.single.cookies, 'ttwid=legacy');
    });

    test('空内容与非凭证串解析结果为空', () {
      expect(decodeCredentialProfiles(null), isEmpty);
      expect(decodeCredentialProfiles('   '), isEmpty);
      expect(decodeCredentialProfiles('不是 cookie'), isEmpty);
    });
  });

  group('CredentialStore', () {
    test('新增凭证后加密落盘，能读回并默认命名', () async {
      final FakeBackend backend = FakeBackend();
      final CredentialStore store = CredentialStore(backend: backend);

      expect(
        await store.saveProfile(name: '主号', raw: 'ttwid=abc'),
        isNull,
      );
      expect(store.hasProfiles, isTrue);
      expect(store.profiles.single.name, '主号');
      // 落盘的是列表密文（编码后内容），不是明文 cookie 串。
      expect(backend.stored, isNotNull);
      expect(backend.stored, isNot('ttwid=abc'));

      // 新实例冷启动读回。
      final CredentialStore restored = CredentialStore(backend: backend);
      expect(await restored.load(), isTrue);
      expect(restored.profiles.single.name, '主号');
      expect(restored.profiles.single.cookies, 'ttwid=abc');
    });

    test('名字留空时按「凭证 N」占位', () async {
      final CredentialStore store = CredentialStore(backend: FakeBackend());
      await store.saveProfile(name: '', raw: 'ttwid=a');
      await store.saveProfile(name: '   ', raw: 'ttwid=b');

      expect(store.profiles[0].name, '凭证 1');
      expect(store.profiles[1].name, '凭证 2');
    });

    test('校验不通过时不写盘、不改状态', () async {
      final FakeBackend backend = FakeBackend();
      final CredentialStore store = CredentialStore(backend: backend);

      expect(await store.saveProfile(name: 'x', raw: '不是 cookie'), isNotNull);
      expect(backend.stored, isNull);
      expect(store.hasProfiles, isFalse);
    });

    test('按 id 更新只换内容并保留名字与创建时间', () async {
      final CredentialStore store = CredentialStore(backend: FakeBackend());
      await store.saveProfile(name: '主号', raw: 'ttwid=a');
      final CredentialProfile first = store.profiles.single;

      await store.saveProfile(id: first.id, name: '', raw: 'ttwid=b');
      expect(store.profiles.single.id, first.id);
      expect(store.profiles.single.name, '主号');
      expect(store.profiles.single.createdAt, first.createdAt);
      expect(store.profiles.single.cookies, 'ttwid=b');
    });

    test('renameProfile 只改名、不动内容', () async {
      final CredentialStore store = CredentialStore(backend: FakeBackend());
      await store.saveProfile(name: '主号', raw: 'ttwid=a');
      final CredentialProfile first = store.profiles.single;

      expect(await store.renameProfile(first.id, '备用'), isNull);
      expect(store.profiles.single.name, '备用');
      expect(store.profiles.single.cookies, 'ttwid=a');
    });

    test('deleteProfile 删除指定凭证', () async {
      final CredentialStore store = CredentialStore(backend: FakeBackend());
      await store.saveProfile(name: '主号', raw: 'ttwid=a');
      await store.saveProfile(name: '备用', raw: 'ttwid=b');
      final String target = store.profiles.first.id;

      expect(await store.deleteProfile(target), isNull);
      expect(store.profiles.length, 1);
      expect(store.profiles.single.name, '备用');
      expect(store.profileOf(target), isNull);
    });

    test('clearAll 清空全部凭证，且不影响其他信息', () async {
      final FakeBackend backend = FakeBackend();
      final CredentialStore store = CredentialStore(backend: backend);
      await store.saveProfile(name: '主号', raw: 'ttwid=a');

      await store.clearAll();
      expect(backend.stored, isNull);
      expect(store.hasProfiles, isFalse);
      expect(store.profiles, isEmpty);
    });

    test('解密失败不静默降级：标记失败并回落空列表', () async {
      final FakeBackend backend = FakeBackend(readError: Exception('bad key'))
        ..stored = 'ttwid=abc';
      final CredentialStore store = CredentialStore(backend: backend);

      expect(await store.load(), isFalse);
      expect(store.decryptFailed, isTrue);
      expect(store.hasProfiles, isFalse);
    });

    test('无已保存凭证时按空列表加载', () async {
      final CredentialStore store = CredentialStore(backend: FakeBackend());
      expect(await store.load(), isTrue);
      expect(store.decryptFailed, isFalse);
      expect(store.hasProfiles, isFalse);
    });
  });

  group('主播凭证绑定', () {
    test('按主播的凭证 id 解析成 webRid → Cookie 串', () {
      const List<CredentialProfile> profiles = <CredentialProfile>[
        CredentialProfile(id: 'a', name: '主号', cookies: 'ttwid=a', createdAt: 0),
      ];
      final Map<String, String> bindings = buildRoomCookieBindings(
        rooms: const <({String webRid, String? credentialId})>[
          (webRid: '111', credentialId: 'a'),
          (webRid: '222', credentialId: null),
          (webRid: '333', credentialId: 'missing'),
        ],
        profiles: profiles,
      );

      expect(bindings, <String, String>{'111': 'ttwid=a'});
    });

    test('setRoomCookieBindings 丢弃空 key / 空值，并可按下标取值', () {
      setRoomCookieBindings(const <String, String>{
        '111': 'ttwid=a',
        '': 'ttwid=b',
        '222': '   ',
      });

      expect(roomCookiesFor('111'), 'ttwid=a');
      expect(roomCookiesFor('222'), isNull);
      expect(roomCookieBindings.length, 1);
    });
  });

  group('CookieProvider 优先级', () {
    test('指定凭证后不再联网取匿名凭证', () async {
      final RecordingTransport transport = RecordingTransport();
      final String cookies = await CookieProvider(
        transport: transport,
        credentialCookies: 'ttwid=manual',
      ).getCookies();

      expect(cookies, 'ttwid=manual');
      expect(transport.calls, 0);
    });

    test('未指定凭证时走匿名自动获取', () async {
      final RecordingTransport transport = RecordingTransport();
      final String cookies =
          await CookieProvider(transport: transport).getCookies();

      expect(cookies, 'ttwid=anonymous');
      expect(transport.calls, 1);
    });

    test('指定空白凭证按未指定处理，退回匿名', () async {
      final RecordingTransport transport = RecordingTransport();
      final String cookies = await CookieProvider(
        transport: transport,
        credentialCookies: '   ',
      ).getCookies();

      expect(cookies, 'ttwid=anonymous');
      expect(transport.calls, 1);
    });
  });
}