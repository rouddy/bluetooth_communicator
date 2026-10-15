import 'dart:async';

import 'package:permission_handler_platform_interface/permission_handler_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

/// In-memory stand-in for the permission_handler platform implementation.
///
/// [checkResult] is what `Permission.status` reports, and [requestResult] is
/// what `request()` returns for every permission. To hold a request open (e.g.
/// to observe the UI while the system dialog would be showing), set
/// [requestGate] and complete it later. Set [requestError] to make requests
/// throw.
class FakePermissionHandler extends PermissionHandlerPlatform
    with MockPlatformInterfaceMixin {
  FakePermissionHandler({
    this.checkResult = PermissionStatus.granted,
    PermissionStatus? requestResult,
  }) : requestResult = requestResult ?? checkResult;

  PermissionStatus checkResult;
  PermissionStatus requestResult;
  Completer<void>? requestGate;
  Object? requestError;
  int requestCount = 0;
  int openSettingsCount = 0;

  @override
  Future<PermissionStatus> checkPermissionStatus(Permission permission) async {
    return checkResult;
  }

  @override
  Future<Map<Permission, PermissionStatus>> requestPermissions(
    List<Permission> permissions,
  ) async {
    requestCount++;
    await requestGate?.future;
    if (requestError case final error?) {
      throw error;
    }
    return {for (final permission in permissions) permission: requestResult};
  }

  @override
  Future<ServiceStatus> checkServiceStatus(Permission permission) async {
    return ServiceStatus.enabled;
  }

  @override
  Future<bool> openAppSettings() async {
    openSettingsCount++;
    return true;
  }

  @override
  Future<bool> shouldShowRequestPermissionRationale(
    Permission permission,
  ) async {
    return false;
  }
}
