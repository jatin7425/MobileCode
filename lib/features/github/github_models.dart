/// A repository as we need it: enough to list and to identify.
class GithubRepo {
  const GithubRepo({
    required this.fullName,
    required this.name,
    required this.isPrivate,
    this.description,
    this.language,
    this.defaultBranch = 'main',
    this.pushedAt,
  });

  /// `owner/repo`.
  final String fullName;
  final String name;
  final bool isPrivate;
  final String? description;
  final String? language;
  final String defaultBranch;
  final DateTime? pushedAt;

  String get owner => fullName.split('/').first;

  factory GithubRepo.fromJson(Map<String, dynamic> json) => GithubRepo(
        fullName: json['full_name'] as String,
        name: json['name'] as String,
        isPrivate: json['private'] as bool? ?? false,
        description: json['description'] as String?,
        language: json['language'] as String?,
        defaultBranch: json['default_branch'] as String? ?? 'main',
        pushedAt: DateTime.tryParse(json['pushed_at'] as String? ?? ''),
      );
}

class GithubPullRequest {
  const GithubPullRequest({
    required this.number,
    required this.title,
    required this.state,
    required this.author,
    required this.isDraft,
    this.updatedAt,
  });

  final int number;
  final String title;

  /// `open` or `closed`. GitHub reports merged PRs as closed here; the list
  /// endpoint does not include the merged flag.
  final String state;

  final String author;
  final bool isDraft;
  final DateTime? updatedAt;

  factory GithubPullRequest.fromJson(Map<String, dynamic> json) =>
      GithubPullRequest(
        number: (json['number'] as num).toInt(),
        title: json['title'] as String? ?? '',
        state: json['state'] as String? ?? 'open',
        author: (json['user'] as Map<String, dynamic>?)?['login'] as String? ??
            'unknown',
        isDraft: json['draft'] as bool? ?? false,
        updatedAt: DateTime.tryParse(json['updated_at'] as String? ?? ''),
      );
}
