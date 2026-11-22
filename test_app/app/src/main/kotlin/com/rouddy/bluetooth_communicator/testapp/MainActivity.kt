package com.rouddy.bluetooth_communicator.testapp

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.IBinder
import android.os.RemoteException
import android.util.Log
import android.view.WindowInsets
import android.view.inputmethod.EditorInfo
import android.widget.ArrayAdapter
import android.widget.Button
import android.widget.EditText
import android.widget.ScrollView
import android.widget.Spinner
import android.widget.TextView
import com.rouddy.bluetooth_communicator.api.IBleCommunicator
import com.rouddy.bluetooth_communicator.api.IBleListener
import com.rouddy.bluetooth_communicator.api.IBleSendCallback
import com.rouddy.bluetooth_communicator.api.PeerInfo
import java.util.UUID

/**
 * Sends and receives text through the communicator's AIDL service, to the same app
 * on a paired phone.
 *
 * For scripted tests: `adb shell am start -n <this app>/.MainActivity --es text hi`
 * sends "hi" to the first connected peer once the service is bound (logged under
 * [TAG]).
 */
class MainActivity : Activity() {
    private var service: IBleCommunicator? = null
    private var peers: List<PeerInfo> = emptyList()
    private var pendingText: String? = null
    private var bound = false

    private lateinit var status: TextView
    private lateinit var peerSpinner: Spinner
    private lateinit var input: EditText
    private lateinit var log: TextView
    private lateinit var scroll: ScrollView

    private val path: String
        get() = "$packageName/chat"

    private val connection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            val communicator = IBleCommunicator.Stub.asInterface(binder)
            service = communicator
            try {
                communicator.registerListener(listener)
                status.text = "서비스 연결됨 (API v${communicator.apiVersion})"
            } catch (e: RemoteException) {
                status.text = "서비스 오류: ${e.message}"
            }
            refreshPeers()
            sendPendingText()
        }

        // The communicator's process died; Android binds again once it's back.
        override fun onServiceDisconnected(name: ComponentName) {
            service = null
            status.text = "서비스 연결 끊김 · 다시 연결하는 중…"
        }

        // The communicator was updated or reinstalled: this binding is over for good.
        override fun onBindingDied(name: ComponentName) {
            service = null
            bound = false
            unbindService(this)
            status.text = "서비스가 다시 시작됨 · 다시 연결하는 중…"
            status.postDelayed({ if (!isDestroyed) bind() }, REBIND_DELAY_MS)
        }
    }

    // Binder calls arrive on binder threads.
    private val listener = object : IBleListener.Stub() {
        override fun onMessage(peerId: String, path: String, data: ByteArray, msgId: Long, replyTo: Long) {
            val text = data.toString(Charsets.UTF_8)
            if (MessageLog.received(this@MainActivity, peerId, text, msgId, via = "listener")) {
                Log.i(TAG, "Received from $peerId #$msgId: $text")
            }
        }

        override fun onPeersChanged() {
            runOnUiThread { refreshPeers() }
        }
    }

    private val logChanged: () -> Unit = { runOnUiThread { renderLog() } }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        status = findViewById(R.id.status)
        peerSpinner = findViewById(R.id.peers)
        input = findViewById(R.id.input)
        log = findViewById(R.id.log)
        scroll = findViewById(R.id.scroll)
        // Edge to edge (targetSdk 35+): keep the content clear of the bars and keyboard.
        findViewById<android.view.View>(R.id.root).setOnApplyWindowInsetsListener { view, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars() or WindowInsets.Type.ime())
            view.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            WindowInsets.CONSUMED
        }
        findViewById<Button>(R.id.send).setOnClickListener { sendInput() }
        findViewById<Button>(R.id.refresh).setOnClickListener { refreshPeers() }
        input.setOnEditorActionListener { _, actionId, _ ->
            (actionId == EditorInfo.IME_ACTION_SEND).also { if (it) sendInput() }
        }
        MessageLog.addListener(logChanged)
        renderLog()
        pendingText = intent.getStringExtra(EXTRA_TEXT)
        bind()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        intent.getStringExtra(EXTRA_TEXT)?.let {
            pendingText = it
            sendPendingText()
        }
    }

    override fun onDestroy() {
        MessageLog.removeListener(logChanged)
        try {
            service?.unregisterListener(listener)
        } catch (e: RemoteException) {
            // The service is gone already.
        }
        if (bound) {
            unbindService(connection)
        }
        super.onDestroy()
    }

    private fun bind() {
        val intent = Intent(IBleCommunicator.ACTION_BIND).setPackage(IBleCommunicator.SERVICE_PACKAGE)
        bound = bindService(intent, connection, Context.BIND_AUTO_CREATE)
        if (!bound) {
            status.text = "BLE Communicator 앱이 설치되어 있지 않습니다"
        }
    }

    private fun refreshPeers() {
        val communicator = service ?: return
        peers = try {
            communicator.peers
        } catch (e: RemoteException) {
            emptyList()
        }
        peers.forEach { MessageLog.rememberName(this, it.peerId, it.name) }
        val selected = (peerSpinner.selectedItemPosition).takeIf { it >= 0 }?.let { peers.getOrNull(it)?.peerId }
        peerSpinner.adapter = ArrayAdapter(
            this,
            android.R.layout.simple_spinner_dropdown_item,
            peers.map { "${it.name} · ${if (it.connected) "연결됨" else "연결 안 됨"}" }
        )
        peers.indexOfFirst { it.peerId == selected }.takeIf { it >= 0 }?.let(peerSpinner::setSelection)
        if (peers.isEmpty()) {
            status.text = "이 앱이 설치된 페어링 기기가 없습니다"
        } else {
            status.text = "서비스 연결됨 · 기기 ${peers.size}대"
        }
        Log.i(TAG, "Peers: ${peers.map { "${it.name}(${it.peerId}, connected=${it.connected})" }}")
    }

    private fun sendInput() {
        val text = input.text.toString().trim()
        if (text.isEmpty()) {
            return
        }
        val peer = peers.getOrNull(peerSpinner.selectedItemPosition) ?: return
        if (send(peer, text)) {
            input.text.clear()
        }
    }

    private fun sendPendingText() {
        val text = pendingText ?: return
        val peer = peers.firstOrNull { it.connected } ?: peers.firstOrNull() ?: return
        pendingText = null
        send(peer, text)
    }

    private fun send(peer: PeerInfo, text: String): Boolean {
        val communicator = service
        if (communicator == null) {
            Log.w(TAG, "Not bound to the communicator; not sending")
            return false
        }
        val localId = UUID.randomUUID().toString()
        MessageLog.sent(this, localId, peer.name, text)
        val callback = object : IBleSendCallback.Stub() {
            override fun onResult(requestId: Long, status: Int) {
                Log.i(TAG, "Request $requestId to ${peer.peerId}: ${statusName(status)} ($status)")
                MessageLog.result(this@MainActivity, localId, statusName(status))
            }
        }
        return try {
            val requestId = communicator.send(peer.peerId, path, text.toByteArray(Charsets.UTF_8), 0, 0, callback)
            Log.i(TAG, "Sending request $requestId to ${peer.name}: $text")
            true
        } catch (e: RemoteException) {
            MessageLog.result(this, localId, "오류: ${e.message}")
            false
        }
    }

    private fun renderLog() {
        log.text = MessageLog.lines(this).joinToString("\n")
        scroll.post { scroll.fullScroll(ScrollView.FOCUS_DOWN) }
    }

    companion object {
        const val TAG = "TestApp"
        const val EXTRA_TEXT = "text"
        private const val REBIND_DELAY_MS = 1_000L

        fun statusName(status: Int) = when (status) {
            IBleCommunicator.STATUS_OK -> "전달됨"
            IBleCommunicator.STATUS_NO_RECEIVER -> "받을 앱 없음"
            IBleCommunicator.STATUS_UNSUPPORTED -> "지원하지 않음"
            IBleCommunicator.STATUS_TOO_LARGE -> "너무 김"
            IBleCommunicator.STATUS_BUSY -> "대기열이 가득 참"
            IBleCommunicator.STATUS_DENIED -> "거부됨"
            IBleCommunicator.STATUS_MALFORMED -> "형식 오류"
            IBleCommunicator.STATUS_EXPIRED_NOT_SENT -> "보내지 못함(시간 초과)"
            IBleCommunicator.STATUS_EXPIRED_UNCONFIRMED -> "확인 못 함(시간 초과)"
            else -> "오류 $status"
        }
    }
}
