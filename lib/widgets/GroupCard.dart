import 'package:flutter/material.dart';

import 'package:krab/pages/GroupPage.dart';
import 'package:krab/models/Group.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/UserPreferences.dart';

class GroupCard extends StatefulWidget {
  final Group group;

  const GroupCard({super.key, required this.group});

  @override
  State<GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<GroupCard> {
  bool isFavorite = false;

  @override
  void initState() {
    super.initState();
    _loadFavoriteStatus();
  }

  Future<void> _loadFavoriteStatus() async {
    bool favorite = await UserPreferences.isGroupFavorite(widget.group.id);
    setState(() {
      isFavorite = favorite;
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => GroupPage(group: widget.group),
          ),
        );
      },
      child: Card(
        margin: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 8,
        ),
        elevation: 0,
        child: ListTile(
          leading: const Icon(Icons.group, size: 40),
          title: Text(
            widget.group.name,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          subtitle: Text(
            "${widget.group.memberCount} ${widget.group.memberCount == 1 ? "member" : "members"}",
            style: const TextStyle(fontSize: 14, color: Colors.grey),
          ),
          trailing: IconButton(
            onLongPress: () {
              showSnackBar(context,
                  "Starred groups will be automatically selected when sending images.");
            },
            onPressed: () async {
              if (isFavorite) {
                await UserPreferences.removeFavoriteGroup(widget.group.id);
                showSnackBar(
                    context, "Removed ${widget.group.name} from favorites.");
              } else {
                await UserPreferences.addFavoriteGroup(widget.group.id);
                showSnackBar(
                    context, "Added ${widget.group.name} to favorites.");
              }
              setState(() {
                isFavorite = !isFavorite;
              });
            },
            icon: Icon(
              isFavorite ? Icons.star_rounded : Icons.star_border_rounded,
              color: isFavorite ? Colors.amber : Colors.grey,
            ),
          ),
        ),
      ),
    );
  }
}
