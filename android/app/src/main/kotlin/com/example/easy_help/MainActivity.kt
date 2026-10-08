package com.example.easy_help

import android.app.PendingIntent
import android.content.Intent
import android.telephony.SmsManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.guardian.app/sms"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "sendMultipartSms") {
                val phoneNumber = call.argument<String>("phoneNumber")
                val message = call.argument<String>("message")

                if (phoneNumber != null && message != null) {
                    try {
                        sendMultipartSms(phoneNumber, message)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("SMS_ERROR", e.message, null)
                    }
                } else {
                    result.error("INVALID_ARGS", "Phone number and message required", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun sendMultipartSms(phoneNumber: String, message: String) {
        // Use Android 16 compatible SmsManager API
        val smsManager = context.getSystemService(SmsManager::class.java)

        // Divide message into parts to handle UCS-2 encoding (emojis + URLs)
        val parts = smsManager.divideMessage(message)

        // Create PendingIntent arrays with FLAG_IMMUTABLE for Android 16
        val sentIntents = ArrayList<PendingIntent>()
        val deliveryIntents = ArrayList<PendingIntent>()

        for (i in parts.indices) {
            sentIntents.add(
                PendingIntent.getBroadcast(
                    context,
                    0,
                    Intent("SMS_SENT"),
                    PendingIntent.FLAG_IMMUTABLE
                )
            )
            deliveryIntents.add(
                PendingIntent.getBroadcast(
                    context,
                    0,
                    Intent("SMS_DELIVERED"),
                    PendingIntent.FLAG_IMMUTABLE
                )
            )
        }

        // Send multipart SMS (handles long messages with emojis and URLs)
        smsManager.sendMultipartTextMessage(
            phoneNumber,
            null,
            parts,
            sentIntents,
            deliveryIntents
        )
    }
}
