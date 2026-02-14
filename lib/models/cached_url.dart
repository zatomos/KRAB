class CachedUrl {
  final String url;
  final DateTime expiry;

  const CachedUrl(this.url, this.expiry);

  bool get isValid => DateTime.now().isBefore(expiry);

  Map<String, dynamic> toJson() => {
    'url': url,
    'expiry': expiry.toIso8601String(),
  };

  factory CachedUrl.fromJson(Map<String, dynamic> json) => CachedUrl(
    json['url'] as String,
    DateTime.parse(json['expiry'] as String),
  );
}