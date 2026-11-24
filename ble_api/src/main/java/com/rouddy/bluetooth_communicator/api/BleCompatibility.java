package com.rouddy.bluetooth_communicator.api;

/**
 * Whether an app and the communicator can talk over IBleCommunicator, from
 * {@link BleApi#checkCommunicator} (in an app) or {@link BleApi#checkApp} (in the
 * communicator).
 */
public enum BleCompatibility {
    /** The same interface, or the newer side still supports the older one. */
    COMPATIBLE,

    /**
     * The communicator is too old for the app's ble-api, or predates these checks
     * (before ble-api 2.0.0). Update Bluetooth Communicator.
     */
    COMMUNICATOR_UPDATE_REQUIRED,

    /**
     * The app's ble-api is too old for the communicator, or the app copied the AIDL
     * files instead of using ble-api. Update the app's ble-api and release the app.
     */
    LIBRARY_UPDATE_REQUIRED,

    /**
     * Both have the same API_VERSION but not the same AIDL: one was built from an
     * interface that changed without raising it. A developer has to fix it.
     */
    AIDL_MISMATCH,

    /** The other side isn't installed, or isn't visible to this app. */
    NOT_INSTALLED
}
