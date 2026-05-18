import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/constant.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/app/utils.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/services/db_service.dart';

class FollowUserService extends BasePageController<FollowUser> {
  static FollowUserService get instance => Get.find<FollowUserService>();
  StreamSubscription<dynamic>? subscription;

  RxList<FollowUser> livingList = RxList<FollowUser>();
  Timer? updateTimer;
  bool needUpdate = true;
  @override
  void onInit() {
    subscription = EventBus.instance.listen(Constant.kUpdateFollow, (p0) {
      needUpdate = false;
      refreshData();
    });

    if (list.isEmpty) {
      refreshData();
    }
    initTimer();
    super.onInit();
  }

  void initTimer() {
    if (AppSettingsController.instance.autoUpdateFollowEnable.value) {
      updateTimer?.cancel();
      updateTimer = Timer.periodic(
        Duration(
          minutes:
              AppSettingsController.instance.autoUpdateFollowDuration.value,
        ),
        (timer) {
          Log.logPrint("Update Follow Timer");
          refreshData();
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  var updating = false.obs;
  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page > 1) {
      return [];
    }

    var followList = DBService.instance.getFollowList();
    if (needUpdate) {
      startUpdateStatus(followList);
    }
    needUpdate = true;
    if (followList.isEmpty) {
      updating.value = false;
    }
    return followList;
  }

  void sortList() {
    list.sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
    updateLivingList();
  }

  void updateLivingList() {
    livingList.assignAll(list.where((x) => x.liveStatus.value == 2));
  }

  /// 获取最优并发数
  /// 用户设置为 0 时根据 CPU 核心数自动计算
  int _getConcurrency(int total) {
    var userSetting =
        AppSettingsController.instance.updateFollowThreadCount.value;

    int concurrency;
    if (userSetting <= 0) {
      var cpuCount = Platform.numberOfProcessors;
      concurrency = (cpuCount * 2.5).round().clamp(4, 20);
    } else {
      concurrency = userSetting;
    }

    if (total > 0 && concurrency > total) {
      concurrency = total;
    }
    return concurrency < 1 ? 1 : concurrency;
  }

  /// 按平台交错排列，避免单一平台阻塞
  List<FollowUser> _interleaveByPlatform(List<FollowUser> list) {
    var grouped = <String, Queue<FollowUser>>{};
    for (var item in list) {
      grouped.putIfAbsent(item.siteId, () => Queue<FollowUser>()).add(item);
    }

    var result = <FollowUser>[];
    while (grouped.values.any((queue) => queue.isNotEmpty)) {
      for (var queue in grouped.values) {
        if (queue.isNotEmpty) {
          result.add(queue.removeFirst());
        }
      }
    }

    return result;
  }

  void startUpdateStatus(List<FollowUser> followList) async {
    updating.value = true;

    if (followList.isEmpty) {
      updating.value = false;
      return;
    }

    var concurrency = _getConcurrency(followList.length);

    Log.logPrint("开始更新关注状态，并发数: $concurrency，总数: ${followList.length}");

    var taskQueue = Queue<FollowUser>.from(_interleaveByPlatform(followList));

    Future<void> worker() async {
      while (taskQueue.isNotEmpty) {
        var item = taskQueue.removeFirst();
        await updateLiveStatus(item);
      }
    }

    var workers = <Future>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);

    sortList();
    updating.value = false;

    Log.logPrint("关注状态更新完成");
  }

  Future updateLiveStatus(FollowUser item) async {
    try {
      var site = Sites.allSites[item.siteId]!;
      item.liveStatus.value =
          (await site.liveSite.getLiveStatus(roomId: item.roomId)) ? 2 : 1;
    } catch (e) {
      Log.logPrint(e);
    }
  }

  void removeItem(FollowUser item, {bool refresh = true}) async {
    var result =
        await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    await DBService.instance.followBox.delete(item.id);
    if (refresh) {
      refreshData();
    } else {
      list.remove(item);
      livingList.remove(item);
    }
  }

  @override
  void onClose() {
    updateTimer?.cancel();
    subscription?.cancel();

    super.onClose();
  }
}
