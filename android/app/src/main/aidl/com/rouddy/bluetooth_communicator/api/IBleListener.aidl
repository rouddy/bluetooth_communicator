package com.rouddy.bluetooth_communicator.api;

oneway interface IBleListener {
    /** A message for the calling app; replyTo is 0 unless it answers one of ours. */
    void onMessage(String peerId, String path, in byte[] data, long msgId, long replyTo);

    /** getPeers() may return something else now. */
    void onPeersChanged();
}
