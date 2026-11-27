package com.rouddy.bluetooth_communicator.api;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;

/**
 * Which IBleCommunicator this library is, and whether it can talk to the other
 * side's (docs/protocol.md 11절).
 *
 * <p>The communicator and every app that uses it carry this library, whose manifest
 * puts {@link #VERSION}, {@link #MIN_COMPATIBLE_VERSION}, and {@link #HASH} into
 * theirs as meta-data. Each side reads the other's through PackageManager, so the
 * check needs no binding and works however far the two interfaces have drifted.
 */
public final class BleApi {
    /** This library's IBleCommunicator.API_VERSION. */
    public static final int VERSION = IBleCommunicator.API_VERSION;

    /** The oldest API_VERSION this one still works with, in either direction. */
    public static final int MIN_COMPATIBLE_VERSION = BleApiInfo.MIN_COMPATIBLE_VERSION;

    /**
     * SHA-256 of the AIDL files without comments or formatting. Two sides with the
     * same VERSION have the same HASH, unless one changed the AIDL without raising it.
     */
    public static final String HASH = BleApiInfo.HASH;

    public static final String META_VERSION = "com.rouddy.bluetooth_communicator.api.VERSION";
    public static final String META_MIN_COMPATIBLE_VERSION =
            "com.rouddy.bluetooth_communicator.api.MIN_COMPATIBLE_VERSION";
    public static final String META_HASH = "com.rouddy.bluetooth_communicator.api.HASH";

    private BleApi() {
    }

    /**
     * For an app: whether it can use the installed communicator. Call it before
     * binding, and again after onBindingDied (the communicator was updated).
     *
     * <p>With an older communicator that is still COMPATIBLE, methods newer than its
     * getApiVersion() aren't there.
     */
    public static BleCompatibility checkCommunicator(Context context) {
        Info communicator;
        try {
            communicator = Info.read(context.getPackageManager(), IBleCommunicator.SERVICE_PACKAGE);
        } catch (PackageManager.NameNotFoundException e) {
            return BleCompatibility.NOT_INSTALLED;
        }
        return compare(Info.LOCAL, communicator);
    }

    /** For the communicator: whether the app {@code packageName} can use it. */
    public static BleCompatibility checkApp(Context context, String packageName) {
        Info app;
        try {
            app = Info.read(context.getPackageManager(), packageName);
        } catch (PackageManager.NameNotFoundException e) {
            return BleCompatibility.NOT_INSTALLED;
        }
        return compare(app, Info.LOCAL);
    }

    /**
     * The newer side decides, since only it knows what changed since the older one:
     * the older one has to be at least its MIN_COMPATIBLE_VERSION. A null side has no
     * meta-data, so it predates ble-api (or copied the AIDL).
     */
    static BleCompatibility compare(Info app, Info communicator) {
        if (communicator == null) {
            return BleCompatibility.COMMUNICATOR_UPDATE_REQUIRED;
        }
        if (app == null) {
            return BleCompatibility.LIBRARY_UPDATE_REQUIRED;
        }
        if (app.version == communicator.version) {
            return app.hash.equals(communicator.hash)
                    ? BleCompatibility.COMPATIBLE
                    : BleCompatibility.AIDL_MISMATCH;
        }
        if (app.version < communicator.version) {
            return app.version >= communicator.minCompatibleVersion
                    ? BleCompatibility.COMPATIBLE
                    : BleCompatibility.LIBRARY_UPDATE_REQUIRED;
        }
        return communicator.version >= app.minCompatibleVersion
                ? BleCompatibility.COMPATIBLE
                : BleCompatibility.COMMUNICATOR_UPDATE_REQUIRED;
    }

    /** One side's VERSION, MIN_COMPATIBLE_VERSION, and HASH. */
    static final class Info {
        static final Info LOCAL = new Info(VERSION, MIN_COMPATIBLE_VERSION, HASH);

        final int version;
        final int minCompatibleVersion;
        final String hash;

        Info(int version, int minCompatibleVersion, String hash) {
            this.version = version;
            this.minCompatibleVersion = minCompatibleVersion;
            this.hash = hash;
        }

        /** The meta-data of {@code packageName}, or null if it has none. */
        @SuppressWarnings("deprecation") // The flags overload is API 33+.
        static Info read(PackageManager packageManager, String packageName)
                throws PackageManager.NameNotFoundException {
            ApplicationInfo info = packageManager.getApplicationInfo(packageName, PackageManager.GET_META_DATA);
            Bundle meta = info.metaData;
            if (meta == null || !meta.containsKey(META_VERSION)) {
                return null;
            }
            int version = meta.getInt(META_VERSION);
            String hash = meta.getString(META_HASH);
            return new Info(version, meta.getInt(META_MIN_COMPATIBLE_VERSION, version), hash == null ? "" : hash);
        }
    }
}
