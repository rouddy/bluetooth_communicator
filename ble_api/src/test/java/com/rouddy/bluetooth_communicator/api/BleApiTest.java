package com.rouddy.bluetooth_communicator.api;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class BleApiTest {
    private static final String HASH_A = "a";
    private static final String HASH_B = "b";

    private static BleApi.Info info(int version, int minCompatibleVersion, String hash) {
        return new BleApi.Info(version, minCompatibleVersion, hash);
    }

    @Test
    public void sameVersionAndHashIsCompatible() {
        assertEquals(BleCompatibility.COMPATIBLE, BleApi.compare(info(2, 1, HASH_A), info(2, 1, HASH_A)));
    }

    @Test
    public void sameVersionWithAnotherHashIsAMismatch() {
        assertEquals(BleCompatibility.AIDL_MISMATCH, BleApi.compare(info(2, 1, HASH_A), info(2, 1, HASH_B)));
    }

    @Test
    public void newerCommunicatorDecidesByItsMinimum() {
        assertEquals(BleCompatibility.COMPATIBLE, BleApi.compare(info(2, 1, HASH_A), info(3, 2, HASH_B)));
        assertEquals(
                BleCompatibility.LIBRARY_UPDATE_REQUIRED,
                BleApi.compare(info(2, 1, HASH_A), info(4, 3, HASH_B)));
    }

    @Test
    public void newerAppDecidesByItsMinimum() {
        assertEquals(BleCompatibility.COMPATIBLE, BleApi.compare(info(3, 2, HASH_A), info(2, 1, HASH_B)));
        assertEquals(
                BleCompatibility.COMMUNICATOR_UPDATE_REQUIRED,
                BleApi.compare(info(4, 3, HASH_A), info(2, 1, HASH_B)));
    }

    @Test
    public void aSideWithoutMetaDataPredatesTheLibrary() {
        assertEquals(BleCompatibility.COMMUNICATOR_UPDATE_REQUIRED, BleApi.compare(BleApi.Info.LOCAL, null));
        assertEquals(BleCompatibility.LIBRARY_UPDATE_REQUIRED, BleApi.compare(null, BleApi.Info.LOCAL));
    }

    @Test
    public void localInfoComesFromTheAidl() {
        assertEquals(IBleCommunicator.API_VERSION, BleApi.VERSION);
        assertTrue(BleApi.MIN_COMPATIBLE_VERSION <= BleApi.VERSION);
        assertTrue(BleApi.HASH, BleApi.HASH.matches("[0-9a-f]{64}"));
    }

    /**
     * Apps built before the ids were written out used the declaration order; the
     * codes on the wire must stay what they were (FIRST_CALL_TRANSACTION is 1).
     */
    @Test
    public void transactionCodesDontMove() {
        assertEquals(1, IBleCommunicator.Stub.TRANSACTION_getApiVersion);
        assertEquals(2, IBleCommunicator.Stub.TRANSACTION_getPeers);
        assertEquals(3, IBleCommunicator.Stub.TRANSACTION_send);
        assertEquals(4, IBleCommunicator.Stub.TRANSACTION_registerListener);
        assertEquals(5, IBleCommunicator.Stub.TRANSACTION_unregisterListener);
        assertEquals(1, IBleListener.Stub.TRANSACTION_onMessage);
        assertEquals(2, IBleListener.Stub.TRANSACTION_onPeersChanged);
        assertEquals(1, IBleSendCallback.Stub.TRANSACTION_onResult);
    }
}
