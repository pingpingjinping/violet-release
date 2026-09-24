// This source code is a part of Project Violet.
// Copyright (C) 2020-2024. violet-team. Licensed under the Apache-2.0 License.

import 'package:flutter/material.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:violet/settings/settings.dart';
import 'package:violet/style/palette.dart';

class DownloadFeaturesMenu extends StatelessWidget {
  const DownloadFeaturesMenu({
    super.key,
    this.incompleteActive = false,
  });

  final bool incompleteActive;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Hero(
        tag: 'features',
        child: Card(
          color: Palette.themeColor,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 8.0),
            width: 280,
            child: IntrinsicHeight(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                child: Column(
                  children: <Widget>[
                    _typeItem(
                      context,
                      Icons.filter_list,
                      'Incomplete',
                      3,
                      selected: incompleteActive,
                    ),
                    _typeItem(
                      context,
                      MdiIcons.contentCopy,
                      'Copy All URL(or Id)',
                      2,
                    ),
                    _typeItem(
                      context,
                      MdiIcons.refresh,
                      'Retry Stopped Item',
                      0,
                    ),
                    _typeItem(context, MdiIcons.rotateLeft, 'Recovery All', 1),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _typeItem(
    BuildContext context,
    IconData icon,
    String text,
    int selection, {
    bool selected = false,
  }) {
    final normalColor = Settings.themeWhat.value
        ? Colors.grey.shade200
        : Colors.grey.shade900;
    final selectedBackground = Settings.themeWhat.value
        ? Colors.white.withOpacity(0.14)
        : Colors.black.withOpacity(0.10);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      color: selected ? selectedBackground : Colors.transparent,
      child: ListTile(
        leading: Icon(
          icon,
          color: normalColor,
        ),
        title: Text(
          text,
          softWrap: false,
          style: TextStyle(
            color: normalColor,
            fontWeight: selected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
        onTap: () async {
          Navigator.pop(context, selection);
        },
      ),
    );
  }
}
