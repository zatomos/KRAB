enum BundleKind { image, comment, reaction }

/// One notification sitting under a bundle summary.
class BundleChild {
  const BundleChild({
    required this.id,
    required this.kind,
    required this.line,
    required this.at,
    this.count = 1,
  });

  final int id;
  final BundleKind kind;
  final String line;
  final DateTime at;
  final int count;
}

/// What a bundle's summary should say about the notifications under it.
class BundleSummary {
  const BundleSummary({
    required this.lines,
    required this.children,
    required this.images,
    required this.comments,
    required this.reactions,
  });

  final List<String> lines;
  final int children;
  final int images;
  final int comments;
  final int reactions;

  int get total => images + comments + reactions;
  bool get isWorthPosting => children >= 2;
}

BundleSummary summarizeBundle(Iterable<BundleChild> children) {
  final ordered = children.toList()..sort((a, b) => b.at.compareTo(a.at));

  var images = 0;
  var comments = 0;
  var reactions = 0;
  for (final child in ordered) {
    switch (child.kind) {
      case BundleKind.image:
        images += child.count;
      case BundleKind.comment:
        comments += child.count;
      case BundleKind.reaction:
        reactions += child.count;
    }
  }

  return BundleSummary(
    lines: [
      for (final child in ordered)
        if (child.line.isNotEmpty) child.line
    ],
    children: ordered.length,
    images: images,
    comments: comments,
    reactions: reactions,
  );
}

String bundleSummaryText(
  BundleSummary summary, {
  required String Function(int count) images,
  required String Function(int count) comments,
  required String Function(int count) reactions,
}) =>
    [
      if (summary.images > 0) images(summary.images),
      if (summary.comments > 0) comments(summary.comments),
      if (summary.reactions > 0) reactions(summary.reactions),
    ].join(', ');
