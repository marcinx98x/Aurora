package com.example.aurora_music

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * NSD advertise + discover for Aurora Connect (`_aurora-music._tcp.`).
 */
class NsdChannelHelper(
    private val context: Context,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        const val SERVICE_TYPE = "_aurora-music._tcp."
    }

    private val main = Handler(Looper.getMainLooper())
    private val nsd = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private var devicesSink: EventChannel.EventSink? = null
    private var discoveryListener: NsdManager.DiscoveryListener? = null
    private var registrationListener: NsdManager.RegistrationListener? = null
    private val found = LinkedHashMap<String, HashMap<String, Any?>>()

    init {
        MethodChannel(messenger, "aurora/nsd").setMethodCallHandler(this)
        EventChannel(messenger, "aurora/nsd/devices").setStreamHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "advertise" -> {
                val name = call.argument<String>("name") ?: "Aurora"
                val port = call.argument<Int>("port") ?: 0
                try {
                    stopAdvertiseInternal()
                    val info = NsdServiceInfo().apply {
                        serviceName = name
                        serviceType = SERVICE_TYPE
                        setPort(port)
                    }
                    registrationListener = object : NsdManager.RegistrationListener {
                        override fun onServiceRegistered(serviceInfo: NsdServiceInfo) {}
                        override fun onRegistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                        override fun onServiceUnregistered(serviceInfo: NsdServiceInfo) {}
                        override fun onUnregistrationFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                    }
                    nsd.registerService(info, NsdManager.PROTOCOL_DNS_SD, registrationListener)
                    result.success(null)
                } catch (e: Exception) {
                    result.error("NSD", e.message, null)
                }
            }
            "stopAdvertise" -> {
                stopAdvertiseInternal()
                result.success(null)
            }
            "startDiscovery" -> {
                startDiscovery()
                result.success(null)
            }
            "stopDiscovery" -> {
                stopDiscoveryInternal()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        devicesSink = events
        emit()
    }

    override fun onCancel(arguments: Any?) {
        devicesSink = null
    }

    private fun startDiscovery() {
        stopDiscoveryInternal()
        found.clear()
        discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}

            override fun onServiceFound(serviceInfo: NsdServiceInfo) {
                nsd.resolveService(serviceInfo, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {}
                    override fun onServiceResolved(resolved: NsdServiceInfo) {
                        val host = resolved.host?.hostAddress ?: return
                        val id = "${resolved.serviceName}@$host:${resolved.port}"
                        found[id] = hashMapOf(
                            "id" to id,
                            "name" to resolved.serviceName,
                            "host" to host,
                            "port" to resolved.port,
                        )
                        emit()
                    }
                })
            }

            override fun onServiceLost(serviceInfo: NsdServiceInfo) {
                val keys = found.keys.filter {
                    it.startsWith(serviceInfo.serviceName)
                }
                keys.forEach { found.remove(it) }
                emit()
            }
        }
        nsd.discoverServices(SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, discoveryListener)
    }

    private fun stopDiscoveryInternal() {
        try {
            discoveryListener?.let { nsd.stopServiceDiscovery(it) }
        } catch (_: Exception) { }
        discoveryListener = null
    }

    private fun stopAdvertiseInternal() {
        try {
            registrationListener?.let { nsd.unregisterService(it) }
        } catch (_: Exception) { }
        registrationListener = null
    }

    private fun emit() {
        val list = ArrayList(found.values)
        main.post { devicesSink?.success(list) }
    }
}
