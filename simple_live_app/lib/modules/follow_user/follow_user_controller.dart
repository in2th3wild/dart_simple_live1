// ignore_for_file: invalid_use_of_protected_member

import 'dart:async';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/follow_service.dart';

enum FollowGroupMode {
  liveStatus,
  platform,
}

class FollowGroupOption {
  final String id;
  final String title;
  final String? siteId;
  final int? liveStatus;

  const FollowGroupOption({
    required this.id,
    required this.title,
    this.siteId,
    this.liveStatus,
  });
}

class FollowUserController extends BasePageController<FollowUser> {
  StreamSubscription<dynamic>? onUpdatedIndexedStream;
  StreamSubscription<dynamic>? onUpdatedListStream;

  var groupMode = FollowGroupMode.liveStatus.obs;
  var selectedGroupId = "all".obs;
  RxList<FollowUserTag> tagList = [
    FollowUserTag(id: "0", tag: "全部", userId: []),
    FollowUserTag(id: "1", tag: "直播中", userId: []),
    FollowUserTag(id: "2", tag: "未开播", userId: []),
  ].obs;

  // 用户自定义标签
  RxList<FollowUserTag> userTagList = <FollowUserTag>[].obs;

  @override
  void onInit() {
    _restoreGroupSelection();
    onUpdatedIndexedStream = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 1) {
          scrollToTopOrRefresh();
        }
      },
    );
    onUpdatedListStream =
        FollowService.instance.updatedListStream.listen((event) {
      filterData();
    });
    super.onInit();
  }

  void _restoreGroupSelection() {
    final settings = AppSettingsController.instance;
    groupMode.value = settings.followGroupMode.value == "platform"
        ? FollowGroupMode.platform
        : FollowGroupMode.liveStatus;
    selectedGroupId.value = settings.followSelectedGroupId.value;
  }

  @override
  Future refreshData({bool forceStatus = true}) async {
    await FollowService.instance.loadData(forceUpdateStatus: forceStatus);
    updateTagList();
    filterData();
  }

  @override
  Future<List<FollowUser>> getData(int page, int pageSize) async {
    final items = _filterBySelectedGroup();
    final start = (page - 1) * pageSize;
    if (start >= items.length) {
      return Future.value([]);
    }
    final end = (start + pageSize).clamp(0, items.length).toInt();
    return items.sublist(start, end);
  }

  void updateTagList() {
    userTagList.assignAll(FollowService.instance.followTagList);
    tagList.value = tagList.take(3).toList();
    for (var i in userTagList) {
      if (!tagList.contains(i)) {
        tagList.add(i);
      }
    }
  }

  void filterData() {
    currentPage = 1;
    final items = _filterBySelectedGroup();
    final end = pageSize.clamp(0, items.length).toInt();
    list.assignAll(items.sublist(0, end));
    currentPage = end < items.length ? 2 : 1;
    canLoadMore.value = end < items.length;
    pageEmpty.value = items.isEmpty;
  }

  List<FollowUser> _distinctFollowUsers(Iterable<FollowUser> items) {
    final result = <FollowUser>[];
    final seenIds = <String>{};
    for (final item in items) {
      final id = item.id.trim().isNotEmpty
          ? item.id.trim()
          : "${item.siteId}_${item.roomId}";
      if (seenIds.add(id)) {
        result.add(item);
      }
    }
    return result;
  }

  List<FollowGroupOption> get groupOptions {
    final options = <FollowGroupOption>[
      const FollowGroupOption(id: "all", title: "全部"),
    ];
    if (groupMode.value == FollowGroupMode.liveStatus) {
      options.addAll(const [
        FollowGroupOption(id: "live", title: "直播中", liveStatus: 2),
        FollowGroupOption(id: "not_live", title: "未开播", liveStatus: 1),
      ]);
    } else {
      final siteIds = FollowService.instance.followList
          .map((item) => item.siteId)
          .toSet()
          .toList();
      final siteSort = Sites.supportSites.map((site) => site.id).toList();
      siteIds.sort((a, b) {
        final aIndex = siteSort.indexOf(a);
        final bIndex = siteSort.indexOf(b);
        if (aIndex < 0 && bIndex < 0) {
          return a.compareTo(b);
        }
        if (aIndex < 0) {
          return 1;
        }
        if (bIndex < 0) {
          return -1;
        }
        return aIndex.compareTo(bIndex);
      });
      for (final siteId in siteIds) {
        final site = Sites.allSites[siteId];
        options.add(
          FollowGroupOption(
            id: "site:$siteId",
            title: site?.name ?? siteId,
            siteId: siteId,
          ),
        );
      }
    }
    return options;
  }

  List<FollowUser> _filterBySelectedGroup() {
    FollowGroupOption? selected;
    for (final option in groupOptions) {
      if (option.id == selectedGroupId.value) {
        selected = option;
        break;
      }
    }
    final source = FollowService.instance.followList;
    if (selected == null || selected.id == "all") {
      selectedGroupId.value = "all";
      return FollowService.instance.sortFollowUsers(
        _distinctFollowUsers(source),
      );
    }
    final liveStatus = selected.liveStatus;
    if (liveStatus != null) {
      final expectedStatus = liveStatus == 1 ? {0, 1} : {liveStatus};
      return FollowService.instance.sortFollowUsers(
        _distinctFollowUsers(
          source
              .where((item) => expectedStatus.contains(item.liveStatus.value)),
        ),
      );
    }
    final siteId = selected.siteId;
    if (siteId != null) {
      return FollowService.instance.sortFollowUsers(
        _distinctFollowUsers(source.where((item) => item.siteId == siteId)),
      );
    }
    return FollowService.instance.sortFollowUsers(
      _distinctFollowUsers(source),
    );
  }

  void setGroupMode(FollowGroupMode mode) {
    groupMode.value = mode;
    selectedGroupId.value = "all";
    _saveGroupSelection();
    filterData();
  }

  void setGroupOption(FollowGroupOption option) {
    selectedGroupId.value = option.id;
    _saveGroupSelection();
    filterData();
  }

  void _saveGroupSelection() {
    AppSettingsController.instance.setFollowGroupSelection(
      mode: groupMode.value == FollowGroupMode.platform
          ? "platform"
          : "liveStatus",
      groupId: selectedGroupId.value,
    );
  }

  void removeItem(FollowUser item) async {
    var result =
        await Utils.showAlertDialog("确定要取消关注${item.userName}吗?", title: "取消关注");
    if (!result) {
      return;
    }
    // 取消关注同时删除标签内的 userId
    if (item.tag != "全部") {
      var tag = tagList.firstWhere((tag) => tag.tag == item.tag);
      tag.userId.remove(item.id);
      updateTag(tag);
    }
    await DBService.instance.followBox.delete(item.id);
    refreshData();
  }

  void updateItem(FollowUser item) {
    FollowService.instance.addFollow(item);
  }

  void toggleSpecialFollow(FollowUser item) async {
    await FollowService.instance.updateSpecialFollow(
      item,
      !item.isSpecialFollow,
    );
    filterData();
  }

  // 修改item的标签
  void setItemTag(FollowUser item, FollowUserTag targetTag) {
    FollowUserTag tarTag = targetTag;
    FollowUserTag curTag = tagList.firstWhere((tag) => tag.tag == item.tag);
    // 从当前标签（非全部）删除item 向目标标签(全部包含所有item == 非全部)添加item
    curTag.userId.remove(item.id);
    tarTag.userId.addIf(!tarTag.userId.contains(item.id), item.id);
    // 数据库更新
    item.tag = tarTag.tag;
    updateTag(curTag);
    updateTag(tarTag);
    updateItem(item);
    filterData();
  }

  Future<void> removeTag(FollowUserTag tag) async {
    // 将tag下的所有follow设置为全部
    for (var i in tag.userId) {
      var follow = DBService.instance.followBox.get(i);
      if (follow != null) {
        follow.tag = "全部";
        updateItem(follow);
      }
    }
    await FollowService.instance.delFollowUserTag(tag);
    updateTagList();
    Log.i('删除tag${tag.tag}');
  }

  void addTag(String tag) async {
    FollowService.instance
        .addFollowUserTag(tag)
        .then((value) => updateTagList());
  }

  void updateTag(FollowUserTag followUserTag) {
    if (followUserTag.tag == '全部') {
      return;
    }
    FollowService.instance.updateFollowUserTag(followUserTag);
  }

  void updateTagName(FollowUserTag followUserTag, String newTagName) {
    // 未操作
    if (followUserTag.tag == newTagName) {
      return;
    }
    // 避免重名
    if (tagList.any((item) => item.tag == newTagName)) {
      SmartDialog.showToast("标签名重复，修改失败");
      return;
    }
    final FollowUserTag newTag = followUserTag.copyWith(tag: newTagName);
    updateTag(newTag);
    // update item's tag when update tagName
    for (var i in newTag.userId) {
      var follow = DBService.instance.followBox.get(i);
      if (follow != null) {
        follow.tag = newTagName;
        updateItem(follow);
      }
    }
    SmartDialog.showToast("标签名修改成功");
    updateTagList();
  }

  // 调整标签顺序
  void updateTagOrder(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1; // 处理索引调整
    final item = userTagList.removeAt(oldIndex);
    userTagList.insert(newIndex, item);
    tagList.value = tagList.take(3).toList();
    tagList.addAll(userTagList);
    DBService.instance.updateFollowTagOrder(userTagList);
  }

  @override
  void onClose() {
    onUpdatedIndexedStream?.cancel();
    onUpdatedListStream?.cancel();
    super.onClose();
  }
}
