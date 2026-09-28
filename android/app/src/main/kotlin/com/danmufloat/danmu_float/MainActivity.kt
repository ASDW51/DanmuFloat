package com.danmufloat.danmu_float

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import androidx.annotation.RequiresApi
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * 系统权限相关的最小原生实现（prd 4.10 首次启动引导）。
 *
 * 通知权限（Android 13+）与电池优化白名单没有现成插件接口，这里用一条
 * MethodChannel 暴露给 Dart 侧（见 lib/system/system_permissions.dart）：
 * 查询类方法直接返回布尔值，跳系统设置的三个方法返回 null，
 * 结果由 Dart 侧回到前台后重新查询。
 *
 * 另有一条备份文件通道（见 lib/storage/data_transfer.dart）：导出落公共「下载」
 * 目录、导入走系统文件选择器，两条路都不需要存储权限。
 */
class MainActivity : FlutterActivity() {
    private val channelName = "danmu_float/system"
    private val notificationRequestCode = 4101
    private var pendingNotificationResult: MethodChannel.Result? = null

    private val dataFileChannelName = "danmu_float/data_file"
    private val jsonMimeType = "application/json"

    /** 导入文件的大小上限：备份 JSON 只有几十 KB，超过这个量级基本是选错了文件。 */
    private val maxImportBytes = 2 * 1024 * 1024

    /**
     * 系统「另存为」与文件选择器的请求码。FlutterActivity 继承自 android.app.Activity，
     * 没有 androidx 的 registerForActivityResult，这里用经典的 startActivityForResult。
     */
    private val saveDocumentRequestCode = 4201
    private val pickDocumentRequestCode = 4202
    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveContent: String? = null
    private var pendingSaveName: String? = null
    private var pendingPickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasNotificationPermission" -> result.success(hasNotificationPermission())
                    "requestNotificationPermission" -> requestNotificationPermission(result)
                    "isBatteryOptimizationIgnored" -> result.success(isBatteryOptimizationIgnored())
                    "requestIgnoreBatteryOptimizations" -> {
                        requestIgnoreBatteryOptimizations()
                        result.success(null)
                    }
                    "openAppSettings" -> {
                        openAppSettings()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, dataFileChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveToDownloads" -> {
                        val fileName = call.argument<String>("fileName")
                        val content = call.argument<String>("content")
                        if (fileName == null || content == null) {
                            result.error("INVALID_ARG", "fileName 与 content 不能为空", null)
                        } else {
                            saveToDownloads(fileName, content, result)
                        }
                    }
                    "pickTextFile" -> pickTextFile(result)
                    else -> result.notImplemented()
                }
            }
    }

    /**
     * 把备份文本写进公共「下载」目录。
     *
     * Android 10（API 29）起应用不能直接写公共目录，必须经 MediaStore 落盘，
     * 这样文件管理器里能直接看到；更低版本没有 MediaStore.Downloads，退回系统
     * 「另存为」让用户自己选位置（同样不需要存储权限）。
     * 返回展示给用户的位置描述；失败或用户取消返回 null。
     */
    private fun saveToDownloads(
        fileName: String,
        content: String,
        result: MethodChannel.Result,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            result.success(saveViaMediaStore(fileName, content))
            return
        }
        // 同一时刻只保留一个待回结果：重复触发时后者覆盖前者即可。
        pendingSaveResult = result
        pendingSaveContent = content
        pendingSaveName = fileName
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = jsonMimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        try {
            startActivityForResult(intent, saveDocumentRequestCode)
        } catch (exception: Exception) {
            pendingSaveResult = null
            pendingSaveContent = null
            pendingSaveName = null
            result.success(null)
        }
    }

    /** 经 MediaStore 往「下载」写一份 JSON，返回「下载/文件名」；失败返回 null。 */
    @RequiresApi(Build.VERSION_CODES.Q)
    private fun saveViaMediaStore(fileName: String, content: String): String? {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, fileName)
            put(MediaStore.Downloads.MIME_TYPE, jsonMimeType)
            // 写完再发布，避免其他应用在写入过程中读到半截文件。
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        val uri = try {
            contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
        } catch (exception: Exception) {
            null
        } ?: return null
        try {
            val output = contentResolver.openOutputStream(uri)
                ?: return null
            output.use { it.write(content.toByteArray(Charsets.UTF_8)) }
            values.clear()
            values.put(MediaStore.Downloads.IS_PENDING, 0)
            contentResolver.update(uri, values, null, null)
        } catch (exception: Exception) {
            // 没写成就把记录删掉，别在「下载」里留一个打不开的空文件。
            try {
                contentResolver.delete(uri, null, null)
            } catch (ignored: Exception) {
                // 删不掉也无妨：文件管理器里最多多一个空文件。
            }
            return null
        }
        // 重名时系统会自动改名（xxx (1).json），回读真实展示名。
        val name = displayNameOf(uri) ?: fileName
        return "下载/$name"
    }

    /** 「另存为」返回：把备份文本写进用户选定的位置。 */
    private fun finishSaveToDocument(uri: Uri?) {
        val result = pendingSaveResult
        val content = pendingSaveContent
        val fileName = pendingSaveName
        pendingSaveResult = null
        pendingSaveContent = null
        pendingSaveName = null
        if (result == null) return
        if (uri == null || content == null) {
            result.success(null)
            return
        }
        val name = try {
            val output = contentResolver.openOutputStream(uri)
            if (output == null) {
                null
            } else {
                output.use { it.write(content.toByteArray(Charsets.UTF_8)) }
                // 部分 provider 不支持 DISPLAY_NAME 查询，回退到用户看到的文件名。
                displayNameOf(uri) ?: fileName
            }
        } catch (exception: Exception) {
            null
        }
        result.success(name)
    }

    /** 打开系统文件选择器读一份备份文本；用户取消返回 null。 */
    private fun pickTextFile(result: MethodChannel.Result) {
        pendingPickResult = result
        // 备份 JSON 的 MIME 在部分文件管理器里报 octet-stream，故不限定类型，
        // 读完再由 Dart 侧按备份格式校验内容。
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        try {
            startActivityForResult(intent, pickDocumentRequestCode)
        } catch (exception: Exception) {
            pendingPickResult = null
            result.success(null)
        }
    }

    /** 系统「另存为」/ 文件选择器的返回；不属于本通道的请求交回父类。 */
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            saveDocumentRequestCode -> {
                finishSaveToDocument(if (resultCode == Activity.RESULT_OK) data?.data else null)
            }
            pickDocumentRequestCode -> {
                finishPickTextFile(if (resultCode == Activity.RESULT_OK) data?.data else null)
            }
            else -> super.onActivityResult(requestCode, resultCode, data)
        }
    }

    /** 文件选择返回：读回文本交给 Dart 侧。 */
    private fun finishPickTextFile(uri: Uri?) {
        val result = pendingPickResult ?: return
        pendingPickResult = null
        if (uri == null) {
            // 用户取消：Dart 侧据此保持输入框原样。
            result.success(null)
            return
        }
        val text = readText(uri)
        result.success(
            mapOf(
                "text" to text,
                "error" to if (text == null) {
                    "文件读取失败，或超过 ${maxImportBytes / (1024 * 1024)} MB 上限"
                } else {
                    null
                },
            ),
        )
    }

    /** 按 UTF-8 读回文本；读不到或超过上限返回 null。 */
    private fun readText(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
                val buffer = ByteArrayOutputStream()
                val chunk = ByteArray(8192)
                var total = 0
                while (true) {
                    val read = input.read(chunk)
                    if (read < 0) break
                    total += read
                    if (total > maxImportBytes) return null
                    buffer.write(chunk, 0, read)
                }
                buffer.toString("UTF-8")
            }
        } catch (exception: Exception) {
            null
        }
    }

    /** 查一个 content URI 的展示名；查不到返回 null。 */
    private fun displayNameOf(uri: Uri): String? = try {
        contentResolver
            .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    } catch (exception: Exception) {
        null
    }

    /** Android 13 以下没有通知权限，视为已授予。 */
    private fun hasNotificationPermission(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (hasNotificationPermission()) {
            result.success(true)
            return
        }
        // 同一时刻只保留一个待回结果：重复点击时后者直接复用前者即可。
        pendingNotificationResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            notificationRequestCode,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationRequestCode) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
    }

    private fun isBatteryOptimizationIgnored(): Boolean {
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(packageName)
    }

    /**
     * 请求加入电池优化白名单。部分 ROM 可能拦截该 Intent，
     * 此时退回到电池优化设置列表页，让用户手动添加。
     */
    private fun requestIgnoreBatteryOptimizations() {
        if (isBatteryOptimizationIgnored()) return
        val direct = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
            data = Uri.parse("package:$packageName")
        }
        try {
            startActivity(direct)
        } catch (exception: Exception) {
            val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
            try {
                startActivity(fallback)
            } catch (ignored: Exception) {
                // 系统页面打开失败时静默返回：引导页会提示用户手动去设置。
            }
        }
    }

    private fun openAppSettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:$packageName")
        }
        try {
            startActivity(intent)
        } catch (ignored: Exception) {
            // 同上：打不开时不影响其他步骤。
        }
    }
}
