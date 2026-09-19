package com.example.aurora_music

import android.content.Context
import android.net.Uri
import android.os.Handler
import android.os.Looper
import androidx.mediarouter.media.MediaRouteSelector
import androidx.mediarouter.media.MediaRouter
import com.google.android.gms.cast.CastMediaControlIntent
import com.google.android.gms.cast.MediaInfo
import com.google.android.gms.cast.MediaLoadRequestData
import com.google.android.gms.cast.MediaMetadata
import com.google.android.gms.cast.MediaSeekOptions
import com.google.android.gms.cast.MediaStatus
import com.google.android.gms.cast.framework.CastContext
import com.google.android.gms.cast.framework.CastSession
import com.google.android.gms.cast.framework.SessionManagerListener
import com.google.android.gms.cast.framework.media.RemoteMediaClient
import com.google.android.gms.common.images.WebImage
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Flutter ↔ Google Cast SDK (default media receiver).
 */
class CastChannelHelper(
    private val context: Context,
    private val messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    private val main = Handler(Looper.getMainLooper())
    private var devicesSink: EventChannel.EventSink? = null
    private var statusSink: EventChannel.EventSink? = null
    private var router: MediaRouter? = null
    private var callback: MediaRouter.Callback? = null
    private var statusListener: RemoteMediaClient.Callback? = null
    private var sessionListener: SessionManagerListener<CastSession>? = null

    fun register() {
        MethodChannel(messenger, "aurora/cast").setMethodCallHandler(this)
        EventChannel(messenger, "aurora/cast/devices").setStreamHandler(this)
        EventChannel(messenger, "aurora/cast/status").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statusSink = events
                }

                override fun onCancel(arguments: Any?) {
                    statusSink = null
                }
            }
        )
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startDiscovery" -> {
                main.post {
                    try {
                        startDiscovery()
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("CAST", e.message, null)
                    }
                }
            }
            "stopDiscovery" -> {
                main.post {
                    stopDiscovery()
                    result.success(null)
                }
            }
            "connect" -> {
                val id = call.argument<String>("deviceId")
                main.post {
                    try {
                        connect(id) { err ->
                            if (err != null) {
                                result.error("CAST", err, null)
                            } else {
                                result.success(null)
                            }
                        }
                    } catch (e: Exception) {
                        result.error("CAST", e.message, null)
                    }
                }
            }
            "load" -> {
                val url = call.argument<String>("url") ?: ""
                val title = call.argument<String>("title") ?: ""
                val artist = call.argument<String>("artist") ?: ""
                val artwork = call.argument<String>("artworkUrl")
                val positionMs = (call.argument<Number>("positionMs") ?: 0).toLong()
                val contentType = call.argument<String>("contentType") ?: "audio/mp4"
                main.post {
                    try {
                        load(url, title, artist, artwork, positionMs, contentType)
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("CAST", e.message, null)
                    }
                }
            }
            "play" -> main.post {
                remote()?.play()
                result.success(null)
            }
            "pause" -> main.post {
                remote()?.pause()
                result.success(null)
            }
            "seek" -> {
                val ms = (call.argument<Number>("positionMs") ?: 0).toLong()
                main.post {
                    remote()?.seek(
                        MediaSeekOptions.Builder().setPosition(ms).build()
                    )
                    result.success(null)
                }
            }
            "setVolume" -> {
                val vol = (call.argument<Number>("volume") ?: 1.0).toDouble()
                main.post {
                    try {
                        CastContext.getSharedInstance(context)
                            .sessionManager.currentCastSession?.setVolume(vol)
                    } catch (_: Exception) { }
                    result.success(null)
                }
            }
            "stop" -> main.post {
                remote()?.stop()
                result.success(null)
            }
            "disconnect" -> main.post {
                try {
                    CastContext.getSharedInstance(context)
                        .sessionManager.endCurrentSession(true)
                } catch (_: Exception) { }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        devicesSink = events
        emitDevices()
    }

    override fun onCancel(arguments: Any?) {
        devicesSink = null
    }

    private fun startDiscovery() {
        val castContext = CastContext.getSharedInstance(context)
        ensureSessionListener(castContext)
        router = MediaRouter.getInstance(context)
        val selector = MediaRouteSelector.Builder()
            .addControlCategory(
                CastMediaControlIntent.categoryForCast(
                    CastMediaControlIntent.DEFAULT_MEDIA_RECEIVER_APPLICATION_ID
                )
            )
            .build()
        if (callback == null) {
            callback = object : MediaRouter.Callback() {
                override fun onRouteAdded(router: MediaRouter, route: MediaRouter.RouteInfo) {
                    emitDevices()
                }

                override fun onRouteRemoved(router: MediaRouter, route: MediaRouter.RouteInfo) {
                    emitDevices()
                }

                override fun onRouteChanged(router: MediaRouter, route: MediaRouter.RouteInfo) {
                    emitDevices()
                }
            }
        }
        router?.addCallback(selector, callback!!, MediaRouter.CALLBACK_FLAG_REQUEST_DISCOVERY)
        emitDevices()
    }

    private fun stopDiscovery() {
        callback?.let { cb ->
            router?.removeCallback(cb)
        }
    }

    private fun emitDevices() {
        val r = router ?: MediaRouter.getInstance(context).also { router = it }
        val list = ArrayList<HashMap<String, Any?>>()
        for (route in r.routes) {
            if (!route.isEnabled) continue
            if (route.isDefault) continue
            if (route.playbackType != MediaRouter.RouteInfo.PLAYBACK_TYPE_REMOTE) continue
            list.add(
                hashMapOf(
                    "id" to route.id,
                    "name" to route.name,
                    "model" to (route.description ?: "Cast"),
                )
            )
        }
        main.post { devicesSink?.success(list) }
    }

    private fun connect(deviceId: String?, done: (String?) -> Unit) {
        val r = router ?: run {
            done("MediaRouter unavailable")
            return
        }
        val route = r.routes.firstOrNull { it.id == deviceId } ?: run {
            done("Cast device not found")
            return
        }
        val castContext = CastContext.getSharedInstance(context)
        ensureSessionListener(castContext)
        if (castContext.sessionManager.currentCastSession?.isConnected == true &&
            castContext.sessionManager.currentCastSession?.castDevice != null
        ) {
            // Already in a session — selecting a new route still needed.
        }
        var finished = false
        fun finish(err: String?) {
            if (finished) return
            finished = true
            done(err)
        }
        val waiter = object : SessionManagerListener<CastSession> {
            override fun onSessionStarted(session: CastSession, sessionId: String) {
                castContext.sessionManager.removeSessionManagerListener(
                    this, CastSession::class.java
                )
                finish(null)
            }

            override fun onSessionStartFailed(session: CastSession, error: Int) {
                castContext.sessionManager.removeSessionManagerListener(
                    this, CastSession::class.java
                )
                finish("Cast session failed ($error)")
            }

            override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
                castContext.sessionManager.removeSessionManagerListener(
                    this, CastSession::class.java
                )
                finish(null)
            }

            override fun onSessionEnded(session: CastSession, error: Int) {}
            override fun onSessionResumeFailed(session: CastSession, error: Int) {}
            override fun onSessionStarting(session: CastSession) {}
            override fun onSessionEnding(session: CastSession) {}
            override fun onSessionResuming(session: CastSession, sessionId: String) {}
            override fun onSessionSuspended(session: CastSession, reason: Int) {}
        }
        castContext.sessionManager.addSessionManagerListener(waiter, CastSession::class.java)
        r.selectRoute(route)
        main.postDelayed({
            if (!finished) {
                castContext.sessionManager.removeSessionManagerListener(
                    waiter, CastSession::class.java
                )
                if (castContext.sessionManager.currentCastSession != null) {
                    finish(null)
                } else {
                    finish("Cast session timed out")
                }
            }
        }, 12_000)
    }

    private fun load(
        url: String,
        title: String,
        artist: String,
        artwork: String?,
        positionMs: Long,
        contentType: String,
    ) {
        val session = CastContext.getSharedInstance(context).sessionManager.currentCastSession
            ?: throw IllegalStateException("No Cast session — select a device first")
        val meta = MediaMetadata(MediaMetadata.MEDIA_TYPE_MUSIC_TRACK).apply {
            putString(MediaMetadata.KEY_TITLE, title)
            putString(MediaMetadata.KEY_ARTIST, artist)
            if (!artwork.isNullOrBlank()) {
                addImage(WebImage(Uri.parse(artwork)))
            }
        }
        val info = MediaInfo.Builder(url)
            .setStreamType(MediaInfo.STREAM_TYPE_BUFFERED)
            .setContentType(contentType)
            .setMetadata(meta)
            .build()
        val client = session.remoteMediaClient
            ?: throw IllegalStateException("No RemoteMediaClient")
        attachStatus(client)
        val req = MediaLoadRequestData.Builder()
            .setMediaInfo(info)
            .setAutoplay(true)
            .setCurrentTime(positionMs)
            .build()
        client.load(req)
    }

    private fun remote(): RemoteMediaClient? =
        CastContext.getSharedInstance(context)
            .sessionManager.currentCastSession?.remoteMediaClient

    private fun ensureSessionListener(castContext: CastContext) {
        if (sessionListener != null) return
        sessionListener = object : SessionManagerListener<CastSession> {
            override fun onSessionStarted(session: CastSession, sessionId: String) {
                session.remoteMediaClient?.let { attachStatus(it) }
            }

            override fun onSessionResumed(session: CastSession, wasSuspended: Boolean) {
                session.remoteMediaClient?.let { attachStatus(it) }
            }

            override fun onSessionEnded(session: CastSession, error: Int) {}
            override fun onSessionResumeFailed(session: CastSession, error: Int) {}
            override fun onSessionStarting(session: CastSession) {}
            override fun onSessionStartFailed(session: CastSession, error: Int) {
                main.post {
                    statusSink?.success(
                        mapOf(
                            "isPlaying" to false,
                            "isLoading" to false,
                            "error" to "Cast session failed ($error)",
                            "positionMs" to 0,
                            "durationMs" to 0,
                        )
                    )
                }
            }

            override fun onSessionEnding(session: CastSession) {}
            override fun onSessionResuming(session: CastSession, sessionId: String) {}
            override fun onSessionSuspended(session: CastSession, reason: Int) {}
        }
        castContext.sessionManager.addSessionManagerListener(
            sessionListener!!,
            CastSession::class.java
        )
    }

    private fun attachStatus(client: RemoteMediaClient) {
        statusListener?.let { client.unregisterCallback(it) }
        statusListener = object : RemoteMediaClient.Callback() {
            override fun onStatusUpdated() {
                emitStatus(client)
            }

            override fun onMetadataUpdated() {
                emitStatus(client)
            }
        }
        client.registerCallback(statusListener!!)
        emitStatus(client)
    }

    private fun emitStatus(client: RemoteMediaClient) {
        val pos = client.approximateStreamPosition
        val dur = client.streamDuration.coerceAtLeast(0)
        val playing = client.isPlaying
        val loading = !playing && client.playerState == MediaStatus.PLAYER_STATE_BUFFERING
        main.post {
            statusSink?.success(
                mapOf(
                    "positionMs" to pos,
                    "durationMs" to dur,
                    "isPlaying" to playing,
                    "isLoading" to loading,
                    "error" to null,
                )
            )
        }
    }
}
