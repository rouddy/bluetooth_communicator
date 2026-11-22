package com.rouddy.bluetooth_communicator.bluetooth_communicator

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Unregisters an app that was uninstalled while this app's process wasn't running.
 * PACKAGE_FULLY_REMOVED is one of the implicit broadcasts a manifest receiver still
 * gets (Android 8+), for the packages visible to us: the apps that declare a RECEIVE
 * service (`<queries>`), and those that bound to us since the phone started.
 */
class PackageRemovedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_PACKAGE_FULLY_REMOVED) {
            return
        }
        val packageName = intent.data?.schemeSpecificPart ?: return
        AppRegistry.onUninstalled(context.applicationContext, packageName)
    }
}
