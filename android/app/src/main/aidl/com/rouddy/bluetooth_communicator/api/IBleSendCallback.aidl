package com.rouddy.bluetooth_communicator.api;

oneway interface IBleSendCallback {
    /** status is one of IBleCommunicator.STATUS_*. */
    void onResult(long requestId, int status);
}
