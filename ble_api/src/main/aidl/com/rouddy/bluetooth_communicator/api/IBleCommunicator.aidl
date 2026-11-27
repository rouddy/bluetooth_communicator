package com.rouddy.bluetooth_communicator.api;

import com.rouddy.bluetooth_communicator.api.IBleListener;
import com.rouddy.bluetooth_communicator.api.IBleSendCallback;
import com.rouddy.bluetooth_communicator.api.PeerInfo;

/**
 * Lets an app exchange data with the same app on a paired phone (docs/protocol.md
 * 11절). Bind with ACTION_BIND, setPackage(SERVICE_PACKAGE).
 *
 * An app can only reach the same app (package name and signing certificate) on the
 * other phone, and only send paths that start with its own package name. A message
 * may rarely arrive twice; filter by (peerId, msgId).
 *
 * Check BleApi.checkCommunicator() before binding: it says whether this copy of the
 * interface and the installed communicator's can talk.
 *
 * Changing these files (ble_api/README.md): every method keeps its transaction id
 * ("= n"), and new methods and parcelable fields go at the end. Any change to the
 * interface raises API_VERSION; the build refuses a changed interface under a
 * version that was already frozen (frozen-api.properties).
 */
interface IBleCommunicator {
    /**
     * 2: send() returns the message's msgId, which a reply to it carries as replyTo
     * (1 returned a local request id).
     */
    const int API_VERSION = 2;
    const String SERVICE_PACKAGE = "com.rouddy.bluetooth_communicator.bluetooth_communicator";
    const String ACTION_BIND = "com.rouddy.bluetooth_communicator.action.BIND";

    /**
     * Declare a service with this action, returning an IBleListener, to receive
     * messages while no listener is registered (e.g. the app isn't running).
     */
    const String ACTION_RECEIVE = "com.rouddy.bluetooth_communicator.action.RECEIVE";

    // Results passed to IBleSendCallback.onResult: the peer's ACK status, or a
    // local result.
    const int STATUS_OK = 0;
    const int STATUS_NO_RECEIVER = 1;
    const int STATUS_UNSUPPORTED = 2;
    const int STATUS_TOO_LARGE = 3;
    const int STATUS_BUSY = 4;
    const int STATUS_DENIED = 5;
    const int STATUS_MALFORMED = 6;
    const int STATUS_ERROR = 255;
    /** Not sent before the TTL ran out; safe to retry. */
    const int STATUS_EXPIRED_NOT_SENT = 1000;
    /** Sent, but not acknowledged; the peer may have received it. */
    const int STATUS_EXPIRED_UNCONFIRMED = 1001;

    /** Never moves (id 0): an app of any version can ask it. */
    int getApiVersion() = 0;

    /** Paired phones on which the calling app can receive. */
    List<PeerInfo> getPeers() = 1;

    /**
     * Sends data to path on peerId; path must be "<calling package>/...". replyTo is
     * 0, or the msgId this answers (a reply isn't acknowledged, and its onResult is OK
     * once it's written to the link). ttlMillis <= 0 means the default (30 s, at most
     * 60 s).
     *
     * Returns the message's msgId, never 0: onResult reports it exactly once, and the
     * peer's reply to it (IBleListener.onMessage) carries it as replyTo. It's returned
     * before the message goes out, so a reply can't arrive before it. A request that
     * fails right away (DENIED, MALFORMED, BUSY) gets an id too.
     */
    long send(String peerId, String path, in byte[] data, long replyTo, long ttlMillis,
            IBleSendCallback callback) = 2;

    void registerListener(IBleListener listener) = 3;

    void unregisterListener(IBleListener listener) = 4;
}
