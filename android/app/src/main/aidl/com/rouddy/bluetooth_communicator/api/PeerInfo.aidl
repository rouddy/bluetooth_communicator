package com.rouddy.bluetooth_communicator.api;

parcelable PeerInfo {
    /** The peer install's id (a UUID); stable until its app is reinstalled. */
    String peerId;
    String name;
    boolean connected;
}
