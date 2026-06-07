import 'dart:async';
import 'dart:collection';

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
  static const Duration updateStatusCooldown = Duration(seconds: 30);
  static FollowUserService get instance => Get.find<FollowUserService>();
  StreamSubscription<dynamic>? subscription;

  RxList<FollowUser> allList = RxList<FollowUser>();
  RxList<FollowUser> livingList = RxList<FollowUser>();
  Timer? updateTimer;
  bool needUpdate = true;
  int _updateGeneration = 0;
  DateTime? _lastUpdateStatusStartedAt;
  bool _forceNextStatusRefresh = false;

  FollowUserService() {
    pageSize = 60;
  }
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
          refreshData(forceStatus: false);
        },
      );
    } else {
      updateTimer?.cancel();
    }
  }

  var updating = false.obs;

  @override
  Future refreshData({bool forceStatus = true}) async {
    _forceNextStatusRefresh = forceStatus;
    await super.refreshData();
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    if (page == 1) {
      allList.assignAll(_sortFollowUsers(DBService.instance.getFollowList()));
      updateLivingList();
      if (needUpdate) {
        unawaited(startUpdateStatus(
          allList.toList(),
          force: _forceNextStatusRefresh,
        ));
      }
      _forceNextStatusRefresh = false;
      needUpdate = true;
      if (allList.isEmpty) {
        updating.value = false;
      }
    }
    final start = (page - 1) * pageSize;
    if (start >= allList.length) {
      return [];
    }
    final end = (start + pageSize).clamp(0, allList.length).toInt();
    return allList.sublist(start, end);
  }

  void sortList() {
    allList.assignAll(_sortFollowUsers(allList));
    final preferredCount = list.isEmpty ? pageSize : list.length;
    final visibleCount = preferredCount.clamp(0, allList.length).toInt();
    list.assignAll(allList.take(visibleCount));
    currentPage = visibleCount < allList.length
        ? (visibleCount ~/ pageSize) + 1
        : currentPage;
    canLoadMore.value = visibleCount < allList.length;
    updateLivingList();
  }

  List<FollowUser> _sortFollowUsers(Iterable<FollowUser> items) {
    return items.toList()
      ..sort((a, b) => b.liveStatus.value.compareTo(a.liveStatus.value));
  }

  void updateLivingList() {
    livingList.assignAll(allList.where((x) => x.liveStatus.value == 2));
  }

  /// 获取最优并发数
  /// 后台按关注规模自动控制，不再读取用户配置，避免超大关注列表刷崩。
  int _getConcurrency(int total) {
    if (total <= 0) {
      return 1;
    }
    if (total <= 300) {
      return total < 48 ? total : 48;
    }
    if (total <= 1000) {
      return 32;
    }
    if (total <= 3000) {
      return 20;
    }
    if (total <= 5000) {
      return 12;
    }
    return 8;
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

  Future<void> startUpdateStatus(
    List<FollowUser> followList, {
    bool force = false,
  }) async {
    final now = DateTime.now();
    final lastStartedAt = _lastUpdateStatusStartedAt;
    if (!force &&
        lastStartedAt != null &&
        now.difference(lastStartedAt) < updateStatusCooldown) {
      Log.logPrint("关注状态刷新过于频繁，已跳过本次网络刷新");
      updating.value = false;
      sortList();
      return;
    }
    _lastUpdateStatusStartedAt = now;
    final generation = ++_updateGeneration;
    if (updating.value) {
      Log.logPrint("已有关注状态刷新任务，取消旧任务并启动新任务");
    }
    updating.value = true;

    if (followList.isEmpty) {
      updating.value = false;
      return;
    }

    var concurrency = _getConcurrency(followList.length);

    Log.logPrint(
      "开始更新关注状态，并发数: $concurrency，总数: ${followList.length}",
    );

    var taskQueue = Queue<FollowUser>.from(_interleaveByPlatform(followList));

    Future<void> worker() async {
      while (taskQueue.isNotEmpty) {
        if (generation != _updateGeneration) {
          return;
        }
        var item = taskQueue.removeFirst();
        await updateLiveStatus(item, generation: generation);
      }
    }

    var workers = <Future>[];
    for (var i = 0; i < concurrency; i++) {
      workers.add(worker());
    }
    await Future.wait(workers);

    if (generation != _updateGeneration) {
      return;
    }
    sortList();
    updating.value = false;

    Log.logPrint("关注状态更新完成");
  }

  Future updateLiveStatus(FollowUser item, {int? generation}) async {
    try {
      var site = Sites.allSites[item.siteId]!;
      final isLiving = await site.liveSite.getLiveStatus(roomId: item.roomId);
      if (generation != null && generation != _updateGeneration) {
        return;
      }
      item.liveStatus.value = isLiving ? 2 : 1;
    } catch (e) {
      if (generation != null && generation != _updateGeneration) {
        return;
      }
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
      allList.remove(item);
      list.remove(item);
      livingList.remove(item);
    }
  }

  @override
  void onClose() {
    _updateGeneration++;
    updating.value = false;
    updateTimer?.cancel();
    subscription?.cancel();

    super.onClose();
  }
}
